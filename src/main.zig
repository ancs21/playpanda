const std = @import("std");
const browser = @import("browser.zig");
const auth = @import("auth.zig");

const version = "0.0.3";

const usage =
    \\Usage: playpanda <command>
    \\
    \\Commands:
    \\  profile              Open browser to log in to sites, then save cookies
    \\  upgrade              Upgrade playpanda to the latest version
    \\  <url>                Fetch URL and output markdown to stdout
    \\  <url>,<url>,...      Fetch multiple URLs, separated by ---
    \\
    \\Examples:
    \\  playpanda profile                                   # log in to save cookies
    \\  playpanda https://example.com                       # single URL to stdout
    \\  playpanda https://example.com,https://ziglang.org   # multiple to stdout
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // Parse args
    var args = std.process.args();
    _ = args.next(); // skip program name

    const command = args.next() orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try stdout.writeAll(usage);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try stdout.writeAll("playpanda " ++ version ++ "\n");
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "upgrade")) {
        runUpgrade(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "profile")) {
        // "playpanda profile" or "playpanda profile init" both do init
        const subcommand = args.next();

        if (subcommand == null or std.mem.eql(u8, subcommand.?, "init")) {
            auth.loginFlow(allocator) catch |err| {
                std.debug.print("Profile init failed: {}\n", .{err});
                std.process.exit(1);
            };
            return;
        }

        if (std.mem.eql(u8, subcommand.?, "import")) {
            const filter = args.next();
            const count = auth.initFlow(allocator, filter) catch |err| {
                std.debug.print("Import failed: {}\n", .{err});
                std.process.exit(1);
            };
            std.debug.print("Saved {d} cookies to ~/.playpanda/cookies.json\n", .{count});
            return;
        }

        std.debug.print("Unknown: playpanda profile {s}\n", .{subcommand.?});
        std.process.exit(1);
    }

    // Treat as URL(s)
    if (!std.mem.startsWith(u8, command, "http://") and !std.mem.startsWith(u8, command, "https://")) {
        std.debug.print("Unknown command: {s}\n\n{s}", .{ command, usage });
        std.process.exit(1);
    }

    const wait_ms: u32 = 3000;

    // Support comma-separated URLs
    var url_it = std.mem.splitScalar(u8, command, ',');
    var count: u32 = 0;
    while (url_it.next()) |raw| {
        const url = std.mem.trim(u8, raw, " \t\r\n");
        if (url.len == 0) continue;
        count += 1;

        // Separator between multiple URLs
        if (count > 1) {
            try stdout.writeAll("\n---\n\n");
        }

        runFetch(allocator, url, wait_ms, stdout) catch |err| {
            std.debug.print("Fetch error for {s}: {}\n", .{ url, err });
            continue;
        };
    }
    try stdout.flush();
}

fn runUpgrade(allocator: std.mem.Allocator) void {
    std.debug.print("playpanda {s} → checking for updates...\n", .{version});

    const args = [_][]const u8{
        "sh", "-c",
        "curl -fsSL https://raw.githubusercontent.com/ancs21/playpanda/main/scripts/install.sh | sh",
    };
    _ = allocator;

    var child = std.process.Child.init(&args, std.heap.page_allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.stdin_behavior = .Inherit;

    child.spawn() catch {
        std.debug.print("Upgrade failed. Run manually:\n  curl -fsSL https://raw.githubusercontent.com/ancs21/playpanda/main/scripts/install.sh | sh\n", .{});
        return;
    };
    _ = child.wait() catch {};
}

/// Clean markdown for LLM consumption (native Zig, no Python).
fn cleanMarkdown(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    // Tier 1 output already goes through html2md.zig (clean).
    // Tier 2/3 output is already markdown from Lightpanda/CloakBrowser.
    // Just do basic post-processing: collapse whitespace, strip empty lines.
    return @import("html2md.zig").postProcess(allocator, raw);
}

fn runFetch(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, stdout: *std.Io.Writer) !void {
    {
        const b = browser.findBinary(allocator) catch {
            std.debug.print("Lightpanda not found. Run: bash scripts/install.sh\n", .{});
            std.process.exit(1);
        };
        allocator.free(b);
    }

    var jar = try auth.loadCookies(allocator);
    defer if (jar) |*j| j.deinit();

    const jar_ptr: ?*const @import("cookie_jar.zig").CookieJar = if (jar) |*j| j else null;

    const raw_md = browser.fetchMarkdown(allocator, url, jar_ptr, wait_ms) catch |err| {
        std.debug.print("Fetch failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(raw_md);

    const markdown = cleanMarkdown(allocator, raw_md) catch raw_md;
    defer if (markdown.ptr != raw_md.ptr) allocator.free(markdown);

    try stdout.writeAll(markdown);
    try stdout.writeAll("\n");
}
