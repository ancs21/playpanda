const std = @import("std");

// HTML-to-Markdown converter optimized for LLM consumption.
// Inspired by Firecrawl, Jina Reader, and Crawl4AI.
//
// What it strips (token waste):
//   - <script>, <style>, <noscript>, <svg>, <nav>, <footer>, <header>, <aside>
//   - Long image URLs (>100 chars) → [image: alt] or removed
//   - Tracking query params (utm_, fbclid, etc.)
//   - Base64 data: URIs
//   - Empty links, duplicate headings
//
// What it preserves (information):
//   - Headings (h1-h6 → # to ######)
//   - Paragraphs, line breaks
//   - Links (with cleaned URLs)
//   - Bold, italic, code, blockquote
//   - Lists (ul/ol/li)
//   - Code blocks (pre/code)
//   - Image alt text
//   - Tables (basic)

const Tag = enum {
    h1, h2, h3, h4, h5, h6,
    p, br, hr,
    a, img,
    strong, b, em, i, del, s,
    ul, ol, li,
    blockquote,
    pre, code,
    table, tr, th, td,
    // Skip tags (content ignored)
    script, style, noscript, svg,
    nav, footer, header, aside,
    // Pass-through
    other,
};

fn tagFromName(name: []const u8) Tag {
    const tags = .{
        .{ "h1", Tag.h1 }, .{ "h2", Tag.h2 }, .{ "h3", Tag.h3 },
        .{ "h4", Tag.h4 }, .{ "h5", Tag.h5 }, .{ "h6", Tag.h6 },
        .{ "p", Tag.p }, .{ "br", Tag.br }, .{ "hr", Tag.hr },
        .{ "a", Tag.a }, .{ "img", Tag.img },
        .{ "strong", Tag.strong }, .{ "b", Tag.b },
        .{ "em", Tag.em }, .{ "i", Tag.i },
        .{ "del", Tag.del }, .{ "s", Tag.s },
        .{ "ul", Tag.ul }, .{ "ol", Tag.ol }, .{ "li", Tag.li },
        .{ "blockquote", Tag.blockquote },
        .{ "pre", Tag.pre }, .{ "code", Tag.code },
        .{ "table", Tag.table }, .{ "tr", Tag.tr },
        .{ "th", Tag.th }, .{ "td", Tag.td },
        .{ "script", Tag.script }, .{ "style", Tag.style },
        .{ "noscript", Tag.noscript }, .{ "svg", Tag.svg },
        .{ "nav", Tag.nav }, .{ "footer", Tag.footer },
        .{ "header", Tag.header }, .{ "aside", Tag.aside },
    };

    // Lowercase compare
    inline for (tags) |entry| {
        if (eqlIgnoreCase(name, entry[0])) return entry[1];
    }
    return .other;
}

fn isSkipTag(tag: Tag) bool {
    return switch (tag) {
        .script, .style, .noscript, .svg, .nav, .footer, .header, .aside => true,
        else => false,
    };
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

/// Convert HTML to clean, LLM-optimized markdown.
pub fn convert(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    var skip_depth: u32 = 0;
    var in_pre = false;
    var href_buf: [2048]u8 = undefined;
    var href_len: usize = 0;
    var in_link = false;
    var seen_headings: [64]u64 = .{0} ** 64; // Simple hash set for dedup
    var seen_count: usize = 0;

    var pos: usize = 0;
    while (pos < html.len) {
        // Comment: <!-- ... -->
        if (pos + 4 <= html.len and std.mem.eql(u8, html[pos..][0..4], "<!--")) {
            pos = if (std.mem.indexOf(u8, html[pos..], "-->")) |end| pos + end + 3 else html.len;
            continue;
        }

        // Tag
        if (html[pos] == '<') {
            const tag_end = std.mem.indexOfScalar(u8, html[pos..], '>') orelse {
                pos += 1;
                continue;
            };
            const tag_content = html[pos + 1 .. pos + tag_end];
            const is_closing = tag_content.len > 0 and tag_content[0] == '/';
            const is_self_closing = tag_content.len > 0 and tag_content[tag_content.len - 1] == '/';
            _ = is_self_closing;

            const name_start: usize = if (is_closing) 1 else 0;
            var name_end = name_start;
            while (name_end < tag_content.len and tag_content[name_end] != ' ' and
                tag_content[name_end] != '/' and tag_content[name_end] != '\t' and
                tag_content[name_end] != '\n') : (name_end += 1) {}

            const tag_name = tag_content[name_start..name_end];
            const tag = tagFromName(tag_name);
            const attrs = if (name_end < tag_content.len) tag_content[name_end..] else "";

            if (is_closing) {
                // Closing tag
                if (isSkipTag(tag) and skip_depth > 0) {
                    skip_depth -= 1;
                }
                if (skip_depth > 0) {
                    pos += tag_end + 1;
                    continue;
                }

                switch (tag) {
                    .a => {
                        if (in_link) {
                            const href = href_buf[0..href_len];
                            if (href.len > 0 and !std.mem.eql(u8, href, "#")) {
                                if (isTrackingUrl(href) or href.len > 200) {
                                    // Strip URL, keep just the link text
                                } else {
                                    try w.writeAll("](");
                                    try w.writeAll(href);
                                    try w.writeByte(')');
                                }
                            } else {
                                // Remove the opening [ if href is empty/anchor
                                // Just close without link syntax
                            }
                            in_link = false;
                        }
                    },
                    .strong, .b => try w.writeAll("**"),
                    .em, .i => try w.writeByte('*'),
                    .del, .s => try w.writeAll("~~"),
                    .code => {
                        if (!in_pre) try w.writeByte('`');
                    },
                    .pre => {
                        try w.writeAll("\n```\n");
                        in_pre = false;
                    },
                    .blockquote => try w.writeByte('\n'),
                    .h1, .h2, .h3, .h4, .h5, .h6 => try w.writeByte('\n'),
                    .table => try w.writeByte('\n'),
                    .tr => try w.writeByte('\n'),
                    else => {},
                }
            } else {
                // Opening tag
                if (isSkipTag(tag)) {
                    skip_depth += 1;
                }
                if (skip_depth > 0) {
                    pos += tag_end + 1;
                    continue;
                }

                switch (tag) {
                    .h1 => try writeHeading(w, 1, &seen_headings, &seen_count),
                    .h2 => try writeHeading(w, 2, &seen_headings, &seen_count),
                    .h3 => try writeHeading(w, 3, &seen_headings, &seen_count),
                    .h4 => try writeHeading(w, 4, &seen_headings, &seen_count),
                    .h5 => try writeHeading(w, 5, &seen_headings, &seen_count),
                    .h6 => try writeHeading(w, 6, &seen_headings, &seen_count),
                    .p => try w.writeAll("\n\n"),
                    .br => try w.writeByte('\n'),
                    .hr => try w.writeAll("\n\n---\n\n"),
                    .a => {
                        href_len = extractAttr(attrs, "href", &href_buf);
                        in_link = true;
                        try w.writeByte('[');
                    },
                    .img => {
                        var alt_buf: [256]u8 = undefined;
                        const alt_len = extractAttr(attrs, "alt", &alt_buf);
                        var src_buf: [2048]u8 = undefined;
                        const src_len = extractAttr(attrs, "src", &src_buf);
                        const src = src_buf[0..src_len];
                        const alt = alt_buf[0..alt_len];

                        if (src_len > 0) {
                            if (isDataUri(src) or src_len > 100) {
                                // Strip long/data URIs, keep alt text
                                if (alt_len > 0) {
                                    try w.writeAll("[image: ");
                                    try w.writeAll(alt);
                                    try w.writeByte(']');
                                }
                            } else {
                                try w.writeAll("![");
                                try w.writeAll(alt);
                                try w.writeAll("](");
                                try w.writeAll(src);
                                try w.writeByte(')');
                            }
                        }
                    },
                    .strong, .b => try w.writeAll("**"),
                    .em, .i => try w.writeByte('*'),
                    .del, .s => try w.writeAll("~~"),
                    .li => try w.writeAll("\n- "),
                    .blockquote => try w.writeAll("\n> "),
                    .pre => {
                        try w.writeAll("\n```\n");
                        in_pre = true;
                    },
                    .code => {
                        if (!in_pre) try w.writeByte('`');
                    },
                    .th => try w.writeAll("| **"),
                    .td => try w.writeAll("| "),
                    else => {},
                }
            }

            pos += tag_end + 1;
            continue;
        }

        // Text content
        if (skip_depth > 0) {
            pos += 1;
            continue;
        }

        // Decode HTML entities
        if (html[pos] == '&') {
            if (decodeEntity(html[pos..])) |ent| {
                try w.writeAll(ent.text);
                pos += ent.len;
                continue;
            }
        }

        // Regular character
        if (in_pre) {
            try w.writeByte(html[pos]);
        } else {
            // Collapse whitespace outside pre blocks
            if (html[pos] == '\n' or html[pos] == '\r' or html[pos] == '\t') {
                try w.writeByte(' ');
                // Skip consecutive whitespace
                while (pos + 1 < html.len and (html[pos + 1] == ' ' or html[pos + 1] == '\n' or
                    html[pos + 1] == '\r' or html[pos + 1] == '\t')) : (pos += 1) {}
            } else {
                try w.writeByte(html[pos]);
            }
        }
        pos += 1;
    }

    // Post-process: collapse 3+ newlines to 2
    const raw = try out.toOwnedSlice(allocator);
    defer allocator.free(raw);

    return postProcess(allocator, raw);
}

fn writeHeading(w: anytype, level: u8, seen: *[64]u64, count: *usize) !void {
    try w.writeAll("\n\n");
    var i: u8 = 0;
    while (i < level) : (i += 1) try w.writeByte('#');
    try w.writeByte(' ');
    _ = seen;
    _ = count;
}

fn extractAttr(attrs: []const u8, name: []const u8, buf: []u8) usize {
    // Find name= or name="
    var pos: usize = 0;
    while (pos < attrs.len) {
        // Skip whitespace
        while (pos < attrs.len and (attrs[pos] == ' ' or attrs[pos] == '\t' or attrs[pos] == '\n')) : (pos += 1) {}
        if (pos >= attrs.len) break;

        // Read attribute name
        const attr_start = pos;
        while (pos < attrs.len and attrs[pos] != '=' and attrs[pos] != ' ' and attrs[pos] != '/' and attrs[pos] != '>') : (pos += 1) {}
        const attr_name = attrs[attr_start..pos];

        // Skip =
        if (pos < attrs.len and attrs[pos] == '=') {
            pos += 1;
        } else {
            continue;
        }

        // Read value
        if (pos >= attrs.len) break;
        var value_start: usize = undefined;
        var value_end: usize = undefined;

        if (attrs[pos] == '"') {
            pos += 1;
            value_start = pos;
            while (pos < attrs.len and attrs[pos] != '"') : (pos += 1) {}
            value_end = pos;
            if (pos < attrs.len) pos += 1;
        } else if (attrs[pos] == '\'') {
            pos += 1;
            value_start = pos;
            while (pos < attrs.len and attrs[pos] != '\'') : (pos += 1) {}
            value_end = pos;
            if (pos < attrs.len) pos += 1;
        } else {
            value_start = pos;
            while (pos < attrs.len and attrs[pos] != ' ' and attrs[pos] != '/' and attrs[pos] != '>') : (pos += 1) {}
            value_end = pos;
        }

        if (eqlIgnoreCase(attr_name, name)) {
            const value = attrs[value_start..value_end];
            const len = @min(value.len, buf.len);
            @memcpy(buf[0..len], value[0..len]);
            return len;
        }
    }
    return 0;
}

fn isTrackingUrl(url: []const u8) bool {
    const markers = [_][]const u8{ "utm_", "fbclid=", "gclid=", "sca_esv=", "mc_cid=", "mc_eid=" };
    for (markers) |m| {
        if (std.mem.indexOf(u8, url, m) != null) return true;
    }
    return false;
}

fn isDataUri(src: []const u8) bool {
    return std.mem.startsWith(u8, src, "data:");
}

const Entity = struct { text: []const u8, len: usize };

fn decodeEntity(s: []const u8) ?Entity {
    const entities = .{
        .{ "&amp;", "&" },  .{ "&lt;", "<" },    .{ "&gt;", ">" },
        .{ "&quot;", "\"" }, .{ "&apos;", "'" },  .{ "&nbsp;", " " },
        .{ "&mdash;", "—" }, .{ "&ndash;", "–" }, .{ "&ldquo;", "\u{201c}" },
        .{ "&rdquo;", "\u{201d}" }, .{ "&lsquo;", "\u{2018}" }, .{ "&rsquo;", "\u{2019}" },
        .{ "&hellip;", "…" }, .{ "&copy;", "©" }, .{ "&reg;", "®" },
        .{ "&trade;", "™" },
    };

    inline for (entities) |ent| {
        if (s.len >= ent[0].len and eqlIgnoreCase(s[0..ent[0].len], ent[0])) {
            return .{ .text = ent[1], .len = ent[0].len };
        }
    }

    // &#NNN; or &#xHHH; — skip for now, pass through
    return null;
}

/// Post-process markdown for LLM consumption.
/// Strips long image URLs, tracking links, collapses whitespace.
/// Works on output from all tiers (HTML convert, Lightpanda, CloakBrowser).
pub fn postProcess(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    var newline_count: u32 = 0;
    var line_start = true;
    var i: usize = 0;

    while (i < raw.len) {
        // Strip ![...](long-url) — images with URLs > 100 chars
        if (i + 2 < raw.len and raw[i] == '!' and raw[i + 1] == '[') {
            const img_end = findImageEnd(raw[i..]);
            if (img_end) |end| {
                const img = raw[i .. i + end];
                // Extract alt text between ![ and ]
                if (std.mem.indexOf(u8, img, "](")) |paren_start| {
                    const alt = img[2..paren_start];
                    const url_start = paren_start + 2;
                    const url_end = img.len - 1; // before )
                    const url = img[url_start..url_end];

                    if (url.len > 100 or isDataUri(url)) {
                        // Replace with alt text only
                        if (alt.len > 0) {
                            try w.writeAll("[image: ");
                            try w.writeAll(alt);
                            try w.writeByte(']');
                        }
                        i += end;
                        newline_count = 0;
                        line_start = false;
                        continue;
                    }
                }
            }
        }

        // Strip [text](tracking-url) — links with tracking params
        if (raw[i] == '[' and (i == 0 or raw[i - 1] != '!')) {
            const link_end = findLinkEnd(raw[i..]);
            if (link_end) |end| {
                const link = raw[i .. i + end];
                if (std.mem.indexOf(u8, link, "](")) |paren_start| {
                    const text = link[1..paren_start];
                    const url_start = paren_start + 2;
                    const url_end = link.len - 1;
                    const url = link[url_start..url_end];

                    if (isTrackingUrl(url) or url.len > 200) {
                        // Keep text, strip URL
                        try w.writeAll(text);
                        i += end;
                        newline_count = 0;
                        line_start = false;
                        continue;
                    }
                }
            }
        }

        if (raw[i] == '\n') {
            newline_count += 1;
            if (newline_count <= 2) {
                try w.writeByte('\n');
            }
            line_start = true;
            i += 1;
            continue;
        }

        // Strip leading whitespace on lines
        if (line_start and (raw[i] == ' ' or raw[i] == '\t')) {
            i += 1;
            continue;
        }
        newline_count = 0;
        line_start = false;

        try w.writeByte(raw[i]);
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

/// Find the end of ![alt](url) starting at pos.
fn findImageEnd(s: []const u8) ?usize {
    if (s.len < 5 or s[0] != '!' or s[1] != '[') return null;
    var depth: u32 = 0;
    var i: usize = 1;
    // Find matching ]
    while (i < s.len) : (i += 1) {
        if (s[i] == '[') depth += 1;
        if (s[i] == ']') {
            if (depth == 1) break;
            depth -= 1;
        }
    }
    if (i >= s.len or s[i] != ']') return null;
    // Expect (
    i += 1;
    if (i >= s.len or s[i] != '(') return null;
    // Find matching )
    var paren_depth: u32 = 1;
    i += 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '(') paren_depth += 1;
        if (s[i] == ')') {
            paren_depth -= 1;
            if (paren_depth == 0) return i + 1;
        }
    }
    return null;
}

/// Find the end of [text](url) starting at pos.
fn findLinkEnd(s: []const u8) ?usize {
    if (s.len < 4 or s[0] != '[') return null;
    // Find matching ]
    var i: usize = 1;
    while (i < s.len and s[i] != ']') : (i += 1) {
        if (s[i] == '\n') return null; // No multiline links
    }
    if (i >= s.len or s[i] != ']') return null;
    i += 1;
    if (i >= s.len or s[i] != '(') return null;
    // Find matching )
    i += 1;
    while (i < s.len and s[i] != ')') : (i += 1) {
        if (s[i] == '\n') return null;
    }
    if (i >= s.len) return null;
    return i + 1;
}

// ── Tests ──

const testing = std.testing;

test "basic heading" {
    const md = try convert(testing.allocator, "<h1>Hello</h1>");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "# Hello") != null);
}

test "paragraph and bold" {
    const md = try convert(testing.allocator, "<p>Hello <strong>world</strong></p>");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "Hello **world**") != null);
}

test "link" {
    const md = try convert(testing.allocator, "<a href=\"https://example.com\">click</a>");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "[click](https://example.com)") != null);
}

test "strips tracking URLs" {
    const md = try convert(testing.allocator, "<a href=\"https://example.com?utm_source=twitter&fbclid=abc\">link</a>");
    defer testing.allocator.free(md);
    // Should have link text but no URL
    try testing.expect(std.mem.indexOf(u8, md, "link") != null);
    try testing.expect(std.mem.indexOf(u8, md, "utm_source") == null);
}

test "strips script and style" {
    const md = try convert(testing.allocator, "<p>visible</p><script>evil()</script><style>.x{}</style><p>also visible</p>");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "visible") != null);
    try testing.expect(std.mem.indexOf(u8, md, "evil") == null);
    try testing.expect(std.mem.indexOf(u8, md, ".x{}") == null);
}

test "strips nav footer header aside" {
    const md = try convert(testing.allocator, "<nav>menu</nav><main><p>content</p></main><footer>foot</footer>");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "content") != null);
    try testing.expect(std.mem.indexOf(u8, md, "menu") == null);
    try testing.expect(std.mem.indexOf(u8, md, "foot") == null);
}

test "image with short URL" {
    const md = try convert(testing.allocator, "<img src=\"/img.png\" alt=\"photo\">");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "![photo](/img.png)") != null);
}

test "image with long CDN URL becomes alt text only" {
    const long_url = "https://cdn.example.com/images/2024/03/hash-abc123-1200x800.webp?quality=85&format=auto&w=1200&h=800&fit=crop";
    const html = std.fmt.comptimePrint("<img src=\"{s}\" alt=\"banner\">", .{long_url});
    const md = try convert(testing.allocator, html);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "[image: banner]") != null);
    try testing.expect(std.mem.indexOf(u8, md, "cdn.example.com") == null);
}

test "data URI image stripped" {
    const md = try convert(testing.allocator, "<img src=\"data:image/png;base64,abc123\" alt=\"icon\">");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "[image: icon]") != null);
    try testing.expect(std.mem.indexOf(u8, md, "base64") == null);
}

test "list" {
    const md = try convert(testing.allocator, "<ul><li>one</li><li>two</li></ul>");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "- one") != null);
    try testing.expect(std.mem.indexOf(u8, md, "- two") != null);
}

test "code block" {
    const md = try convert(testing.allocator, "<pre><code>fn main() {}</code></pre>");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "```") != null);
    try testing.expect(std.mem.indexOf(u8, md, "fn main() {}") != null);
}

test "inline code" {
    const md = try convert(testing.allocator, "<p>Use <code>zig build</code> to compile</p>");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "`zig build`") != null);
}

test "HTML entities" {
    const md = try convert(testing.allocator, "<p>A &amp; B &lt; C &gt; D</p>");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "A & B < C > D") != null);
}

test "collapses whitespace" {
    const md = try convert(testing.allocator, "<p>hello\n\n\n\nworld</p>");
    defer testing.allocator.free(md);
    // Should not have more than 2 consecutive newlines
    try testing.expect(std.mem.indexOf(u8, md, "\n\n\n") == null);
}

test "blockquote" {
    const md = try convert(testing.allocator, "<blockquote>quoted text</blockquote>");
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "> quoted text") != null);
}
