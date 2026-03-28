---
name: playpanda
description: Fetch any URL and convert to clean markdown for LLM consumption. Use when the user asks to "fetch a page", "get content from URL", "scrape this website", "convert to markdown", "read this article", or needs web content as context. Supports authenticated sites (Facebook, Medium, etc.) via stealth browser.
metadata:
  author: ancs21
  version: "0.0.3"
---

# PlayPanda — Web to Markdown for LLMs

Fetch any URL and get clean, token-optimized markdown. Three-tier engine: HTTP (fastest), Lightpanda (JS rendering), stealth browser (anti-detection for protected sites).

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/ancs21/playpanda/main/scripts/install.sh | sh
```

## Commands

```bash
playpanda <url>                                     # fetch → markdown to stdout
playpanda <url>,<url>,...                            # multiple URLs, separated by ---
playpanda profile                                   # open browser, log in, save cookies
playpanda upgrade                                   # upgrade to latest version
```

## How It Works — 3-Tier Engine

| Tier | Speed | Method | When |
|------|-------|--------|------|
| 1: HTTP | ~150ms | curl + native Zig HTML-to-markdown | Static pages |
| 2: Lightpanda | ~1.5s | Headless browser + LP.getMarkdown | JS-rendered pages |
| 3: [CloakBrowser](https://github.com/CloakHQ/CloakBrowser) | ~6s | Real Chrome + CDP | Protected sites (Facebook, Medium, Google) |

**Auto-routing:**
- Known protected domains (facebook.com, medium.com, google.com, etc.) → Tier 3
- Otherwise → Tier 1, auto-escalate to Tier 2 if content is empty/blocked, then Tier 3
- If any tier returns a Cloudflare challenge, CAPTCHA, or "blocked" message, it automatically escalates

## When to Use This Skill

- User asks to read/fetch/scrape a web page
- User needs web content as context for a task
- User wants to convert HTML to markdown
- User needs to access paywalled/authenticated content

## Examples

```bash
# Single URL
playpanda https://example.com

# Multiple URLs
playpanda https://example.com,https://ziglang.org

# Pipe to Claude
playpanda https://example.com | claude "Summarize this:"

# Save to file
playpanda https://example.com > article.md

# Log in first for protected sites
playpanda profile
playpanda https://medium.com/the-andela-way/graph-databases-why-are-they-important-c438e1a224ae
```

## Output

The output is markdown optimized for LLM consumption:
- Navigation, ads, script, style, footer, header stripped
- Long CDN image URLs removed (alt text preserved)
- Tracking URLs stripped (utm_, fbclid, etc.)
- HTML entities decoded
- Token-efficient (~90% reduction from raw HTML)

## Troubleshooting

- **"Lightpanda not found"** → Run `playpanda upgrade` or set `LIGHTPANDA_BINARY_PATH`
- **Blocked by Cloudflare** → Run `playpanda profile` to log in and save cookies
- **Empty output** → Site may need JS rendering (auto-escalates to Tier 2)
