```
 ╭───────────╮
 │  ■     ■  │
 │    ▶      │
 │   ╰──╯   │
 ╰───────────╯
```

# playpanda

Fetch any webpage as clean, LLM-ready markdown. Single binary, zero config.

![demo](demo.gif)

## Why playpanda?

| | playpanda | Crawl4AI | Firecrawl | Jina Reader |
|---|:---:|:---:|:---:|:---:|
| Single binary | Zig | Python + pip | Node + API key | curl only |
| Zero config | Yes | Nearly | No | Yes |
| Auth built-in | Login + cookies | Hooks/profiles | Dashboard | x-set-cookie |
| Anti-bot | 3-tier auto-escalation | Manual config | Partial | No |
| API key required | No | No | Yes | Freemium |
| Avg speed | 1.8s | ~3s | ~5s | ~2s |
| Avg tokens/page | 2,868 | varies | varies | varies |

## How It Works

playpanda uses a 3-tier fetch engine that automatically escalates until it gets content:

| Tier | Method | Speed | When |
|------|--------|-------|------|
| 1 | HTTP + native Zig HTML-to-markdown | ~150ms | Default for most sites |
| 2 | [Lightpanda](https://lightpanda.io/) headless browser | ~1.5s | When Tier 1 returns empty/broken content |
| 3 | [CloakBrowser](https://github.com/CloakHQ/CloakBrowser) | ~6s | Bot-protected sites (Facebook, LinkedIn, Medium, etc.) |

If a page is blocked or empty, playpanda automatically tries the next tier.

## Install

One-liner (installs binary + all dependencies):

```
curl -fsSL https://raw.githubusercontent.com/ancs21/playpanda/main/scripts/install.sh | sh
```

### From source

Requires [Zig](https://ziglang.org/) 0.15+:

```
git clone https://github.com/ancs21/playpanda.git
cd playpanda
zig build -Doptimize=.ReleaseFast
cp zig-out/bin/playpanda ~/.local/bin/
```

### Dependencies

The installer handles these automatically, or install manually:

- [Lightpanda](https://lightpanda.io/) — headless browser for Tier 2
- Python 3 + `websockets` — Tier 3 stealth browser and cookie harvesting
- Chrome/Chromium — for Tier 3 stealth and login flow

## Usage

### Fetch a page

```
playpanda https://example.com                       # markdown to stdout
playpanda https://example.com > article.md          # save to file
```

### Fetch multiple pages

```
playpanda https://example.com,https://ziglang.org   # multiple URLs, separated by ---
```

### Log in to sites

```
playpanda profile                                   # opens browser, log in, press Enter
```

Cookies are saved to `~/.playpanda/cookies.json` and used automatically on subsequent fetches.

### Upgrade

```
playpanda upgrade
```

## How Cookies Work

1. **`playpanda profile`** opens a browser with CDP enabled. Log in to any site, then press Enter. Cookies are harvested via Chrome DevTools Protocol and saved.

2. **Fetch flow**: Cookies are automatically loaded and matched by domain. Tier 1 uses HTTP cookie headers, Tier 2 injects via `Network.setCookies` over CDP.

## Bot-Protected Sites

These domains automatically use Tier 3 (stealth browser):

facebook.com, instagram.com, linkedin.com, x.com, twitter.com, medium.com, google.com, youtube.com, tiktok.com, reddit.com, substack.com, threads.net, pinterest.com

Other sites start at Tier 1 and escalate if blocked.

## Use as Agent Skill

```
npx skills add ancs21/playpanda
```

## License

[Apache 2.0](LICENSE)
