const std = @import("std");
const cdp = @import("cdp_client.zig");
const cookie_jar_mod = @import("cookie_jar.zig");
const CookieJar = cookie_jar_mod.CookieJar;

pub const AuthError = error{
    SaveFailed,
    NoSessionFiles,
    LaunchFailed,
    HarvestFailed,
};

const login_port: u16 = 9444;

/// Find CloakBrowser wrapper at ~/.cloakbrowser/chrome.
fn findCloakBrowser(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.LaunchFailed;
    const path = try std.fmt.allocPrint(allocator, "{s}/.cloakbrowser/chrome", .{home});
    std.fs.accessAbsolute(path, .{}) catch {
        allocator.free(path);
        return error.LaunchFailed;
    };
    return path;
}

/// Open CloakBrowser for the user to log in, then harvest cookies via CDP.
pub fn loginFlow(allocator: std.mem.Allocator) !void {
    const binary = findCloakBrowser(allocator) catch {
        std.debug.print("CloakBrowser not found. Run: bash scripts/install.sh\n", .{});
        return AuthError.LaunchFailed;
    };
    defer allocator.free(binary);

    std.debug.print("Opening browser — log in to your accounts, then press Enter to save cookies.\n\n", .{});
    const start_url = "https://www.google.com";

    // Launch CloakBrowser wrapper with CDP enabled
    const port_arg = try std.fmt.allocPrint(allocator, "--remote-debugging-port={d}", .{login_port});
    defer allocator.free(port_arg);

    const args = [_][]const u8{ binary, port_arg, start_url };

    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Ignore;

    child.spawn() catch return AuthError.LaunchFailed;

    // Wait for CDP to be available
    var attempts: u32 = 0;
    while (attempts < 30) : (attempts += 1) {
        std.Thread.sleep(500 * std.time.ns_per_ms);
        const address = std.net.Address.parseIp4("127.0.0.1", login_port) catch continue;
        const stream = std.net.tcpConnectToAddress(address) catch continue;
        stream.close();
        break;
    }

    // Wait for user to press Enter (DON'T close the browser before this!)
    std.debug.print("Press Enter when done (keep the browser open!)...\n", .{});
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var buf: [64]u8 = undefined;
    _ = stdin_file.read(&buf) catch {};

    // Check if browser is still running
    {
        const address = std.net.Address.parseIp4("127.0.0.1", login_port) catch {
            std.debug.print("Browser closed before cookies could be saved. Run again and keep browser open.\n", .{});
            return AuthError.HarvestFailed;
        };
        const stream = std.net.tcpConnectToAddress(address) catch {
            std.debug.print("Browser closed before cookies could be saved. Run again and keep browser open.\n", .{});
            return AuthError.HarvestFailed;
        };
        stream.close();
    }

    std.debug.print("Harvesting cookies...\n", .{});

    // Harvest cookies via Python helper (CDP in Zig hits Chrome 146 event flood issues)
    const count = harvestViaPython(allocator, login_port) catch |err| {
        std.debug.print("Cookie harvest failed: {}\n", .{err});
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return AuthError.HarvestFailed;
    };

    // Close browser
    _ = child.kill() catch {};
    _ = child.wait() catch {};

    std.debug.print("Saved {d} cookies to ~/.playpanda/cookies.json\n", .{count});
}

/// Harvest cookies by calling the Python helper script.
fn harvestViaPython(allocator: std.mem.Allocator, port: u16) !usize {
    const sp = @import("browser.zig").findScript(allocator, "harvest_cookies.py") catch return AuthError.HarvestFailed;
    defer allocator.free(sp);

    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    const args = [_][]const u8{ "python3", sp, port_str };

    var proc = std.process.Child.init(&args, allocator);
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Ignore;
    proc.stdin_behavior = .Ignore;

    proc.spawn() catch return AuthError.HarvestFailed;

    const stdout_pipe = proc.stdout.?;
    const output = stdout_pipe.readToEndAlloc(allocator, 1024) catch return AuthError.HarvestFailed;
    defer allocator.free(output);

    const term = proc.wait() catch return AuthError.HarvestFailed;
    if (term.Exited != 0) return AuthError.HarvestFailed;

    const trimmed = std.mem.trimRight(u8, output, "\n\r \t");
    return std.fmt.parseInt(usize, trimmed, 10) catch return AuthError.HarvestFailed;
}

/// Parse cookies from CDP Network.getCookies response.
fn parseCdpCookies(allocator: std.mem.Allocator, data: std.json.Value) CookieJar {
    var jar = CookieJar.init(allocator);

    const obj = switch (data) {
        .object => |o| o,
        else => return jar,
    };
    const result_val = obj.get("result") orelse return jar;
    const result_obj = switch (result_val) {
        .object => |o| o,
        else => return jar,
    };
    const cookies_val = result_obj.get("cookies") orelse return jar;
    const cookies_arr = switch (cookies_val) {
        .array => |a| a,
        else => return jar,
    };

    for (cookies_arr.items) |cookie_val| {
        const cookie_obj = switch (cookie_val) {
            .object => |o| o,
            else => continue,
        };
        const name = getString(cookie_obj, "name") orelse continue;
        const value = getString(cookie_obj, "value") orelse continue;
        const domain = getString(cookie_obj, "domain") orelse continue;

        jar.add(.{
            .name = name,
            .value = value,
            .domain = domain,
            .path = getString(cookie_obj, "path") orelse "/",
            .secure = getBool(cookie_obj, "secure"),
            .http_only = getBool(cookie_obj, "httpOnly"),
        }) catch continue;
    }
    return jar;
}

/// Import cookies from CloakBrowser session JSON files (~/.cloakbrowser/*_session.json).
pub fn initFlow(allocator: std.mem.Allocator, filter: ?[]const u8) !usize {
    const home = std.posix.getenv("HOME") orelse return AuthError.SaveFailed;

    var cloak_dir_buf: [1024]u8 = undefined;
    const cloak_dir_path = std.fmt.bufPrint(&cloak_dir_buf, "{s}/.cloakbrowser", .{home}) catch
        return AuthError.SaveFailed;

    var dir = std.fs.openDirAbsolute(cloak_dir_path, .{ .iterate = true }) catch {
        std.debug.print("CloakBrowser directory not found at {s}\n", .{cloak_dir_path});
        return AuthError.NoSessionFiles;
    };
    defer dir.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var merged_jar = CookieJar.init(arena_alloc);
    var files_loaded: u32 = 0;

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;

        const is_session = std.mem.endsWith(u8, name, "_session.json");
        const is_cookies = std.mem.endsWith(u8, name, "_cookies.json");
        if (!is_session and !is_cookies) continue;

        if (filter) |f| {
            if (!containsIgnoreCase(name, f)) continue;
        }

        var file_path_buf: [1024]u8 = undefined;
        const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ cloak_dir_path, name }) catch continue;

        const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
        defer file.close();

        const json = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch continue;
        defer allocator.free(json);

        var jar = CookieJar.fromJson(allocator, json) catch continue;
        defer jar.deinit();

        const count = jar.count();
        if (count == 0) continue;

        std.debug.print("  {s}: {d} cookies\n", .{ name, count });

        for (jar.cookies.items) |cookie| {
            merged_jar.add(.{
                .name = arena_alloc.dupe(u8, cookie.name) catch continue,
                .value = arena_alloc.dupe(u8, cookie.value) catch continue,
                .domain = arena_alloc.dupe(u8, cookie.domain) catch continue,
                .path = arena_alloc.dupe(u8, cookie.path) catch continue,
                .expires = cookie.expires,
                .secure = cookie.secure,
                .http_only = cookie.http_only,
            }) catch continue;
        }
        files_loaded += 1;
    }

    if (files_loaded == 0) {
        if (filter) |f| {
            std.debug.print("No session files matching '{s}' found in {s}\n", .{ f, cloak_dir_path });
        } else {
            std.debug.print("No session files found in {s}\n", .{cloak_dir_path});
        }
        return AuthError.NoSessionFiles;
    }

    const total = merged_jar.count();
    const json = try merged_jar.toJson(allocator);
    defer allocator.free(json);

    try saveCookieFile(json);
    return total;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn saveCookieFile(json: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse return AuthError.SaveFailed;

    var path_buf: [1024]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&path_buf, "{s}/.playpanda", .{home}) catch return AuthError.SaveFailed;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return AuthError.SaveFailed,
    };

    var file_buf: [1024]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_buf, "{s}/.playpanda/cookies.json", .{home}) catch return AuthError.SaveFailed;
    const file = std.fs.createFileAbsolute(file_path, .{}) catch return AuthError.SaveFailed;
    defer file.close();
    file.writeAll(json) catch return AuthError.SaveFailed;
}

pub fn loadCookies(allocator: std.mem.Allocator) !?CookieJar {
    const home = std.posix.getenv("HOME") orelse return null;
    var path_buf: [1024]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/.playpanda/cookies.json", .{home}) catch return null;
    const file = std.fs.openFileAbsolute(file_path, .{}) catch return null;
    defer file.close();
    const json = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return null;
    defer allocator.free(json);
    return CookieJar.fromJson(allocator, json) catch null;
}

// Re-export from cookie_jar to avoid duplication
const getString = cookie_jar_mod.getString;
const getBool = cookie_jar_mod.getBool;
