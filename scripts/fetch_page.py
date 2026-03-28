#!/usr/bin/env python3
"""Fetch a page via CloakBrowser (non-headless) and output markdown.
Uses CDP to extract content after page renders."""
import asyncio, json, sys, urllib.request, os, subprocess, time

WAIT_MS = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
PORT = 19555

BLOCKED = ["security verification", "just a moment", "checking your browser",
           "challenge-platform", "cdn-cgi/challenge", "performing security",
           "attention required", "sorry, you have been blocked",
           "you've been blocked", "blocked by network security",
           "access denied", "403 forbidden", "enable javascript",
           "please verify you are a human", "are not a robot",
           "captcha", "unusual traffic"]

MD_JS = r"""
(function(){
    var a = document.querySelector('article') || document.querySelector('[role="main"]') || document.querySelector('main') || document.body;
    if(!a) return document.title + '\n\n' + (document.body ? document.body.innerText : '');
    function w(n){
        if(n.nodeType===3) return n.textContent;
        if(n.nodeType!==1) return '';
        var t=n.tagName.toLowerCase(), c='';
        for(var i=0;i<n.childNodes.length;i++) c+=w(n.childNodes[i]);
        c=c.trim();
        if(!c && t!=='img' && t!=='br') return '';
        if(t==='script'||t==='style'||t==='noscript'||t==='svg') return '';
        if(t==='h1') return '\n\n# '+c+'\n\n';
        if(t==='h2') return '\n\n## '+c+'\n\n';
        if(t==='h3') return '\n\n### '+c+'\n\n';
        if(t==='p') return '\n\n'+c+'\n\n';
        if(t==='a'){var h=n.getAttribute('href');return h&&h!=='#'?'['+c+']('+h+')':c;}
        if(t==='strong'||t==='b') return '**'+c+'**';
        if(t==='em'||t==='i') return '*'+c+'*';
        if(t==='li') return '- '+c+'\n';
        if(t==='br') return '\n';
        if(t==='img'){var s=n.getAttribute('src'),al=n.getAttribute('alt')||'';return s?'!['+al+']('+s+')':'';}
        if(t==='pre'||t==='code') return '\n```\n'+n.textContent+'\n```\n';
        return c;
    }
    var md = '# '+document.title+'\n\n'+w(a);
    return md.replace(/\n{3,}/g,'\n\n').trim();
})()
"""

def is_blocked(text):
    t = text[:2000].lower()
    return any(m in t for m in BLOCKED)

async def extract(port, max_retries=10):
    import websockets
    for attempt in range(max_retries):
        try:
            resp = urllib.request.urlopen(f"http://127.0.0.1:{port}/json")
            targets = json.loads(resp.read())
        except:
            await asyncio.sleep(2)
            continue

        page = None
        for t in targets:
            if t["type"] == "page" and "about:blank" not in t.get("url", ""):
                page = t
                break
        if not page:
            page = next((t for t in targets if t["type"] == "page"), None)
        if not page:
            await asyncio.sleep(2)
            continue

        try:
            async with websockets.connect(page["webSocketDebuggerUrl"]) as ws:
                await ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                    "params": {"expression": MD_JS, "returnByValue": True}}))
                r = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
                text = r.get("result", {}).get("result", {}).get("value", "")

                if text and len(text) > 100 and not is_blocked(text):
                    return text

                if attempt < max_retries - 1:
                    await asyncio.sleep(3)
                else:
                    return text
        except Exception as e:
            await asyncio.sleep(2)

    return ""

async def extract_stable(port, wait_ms, max_polls=8):
    """Poll until page content stabilizes (stops changing between polls)."""
    import websockets
    last_len = 0
    stable_count = 0
    result = ""

    for poll in range(max_polls):
        try:
            resp = urllib.request.urlopen(f"http://127.0.0.1:{port}/json")
            targets = json.loads(resp.read())
        except:
            await asyncio.sleep(1)
            continue

        page = None
        for t in targets:
            if t["type"] == "page" and "about:blank" not in t.get("url", ""):
                page = t
                break
        if not page:
            page = next((t for t in targets if t["type"] == "page"), None)
        if not page:
            await asyncio.sleep(1)
            continue

        try:
            async with websockets.connect(page["webSocketDebuggerUrl"]) as ws:
                await ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                    "params": {"expression": MD_JS, "returnByValue": True}}))
                r = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
                text = r.get("result", {}).get("result", {}).get("value", "")

                if text and not is_blocked(text):
                    cur_len = len(text)
                    if abs(cur_len - last_len) < 50:
                        stable_count += 1
                        if stable_count >= 2:
                            return text  # Content stabilized
                    else:
                        stable_count = 0
                    last_len = cur_len
                    result = text

                await asyncio.sleep(1)
        except:
            await asyncio.sleep(1)

    return result

def run_browser(binary, url, headless=False):
    args = [binary, f"--remote-debugging-port={PORT}"]
    if headless:
        args.append("--headless=new")
    args.append(url)

    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Wait for CDP
    for _ in range(20):
        time.sleep(0.5)
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/version")
            return proc
        except:
            continue

    # CDP didn't start
    proc.terminate()
    return None

def main():
    url = sys.argv[1] if len(sys.argv) > 1 else ""
    if not url:
        print("Usage: fetch_page.py <url> [wait_ms]", file=sys.stderr)
        sys.exit(1)

    binary = os.path.join(os.environ.get("HOME", ""), ".cloakbrowser", "chrome")
    if not os.path.isfile(binary):
        print("CloakBrowser not found", file=sys.stderr)
        sys.exit(1)

    # Non-headless — needed for Cloudflare/bot detection
    proc = run_browser(binary, url, headless=False)
    if not proc:
        sys.exit(1)

    try:
        # Initial wait for page load
        time.sleep(min(WAIT_MS / 1000, 3))
        # Then poll until content stabilizes (no more JS loading)
        result = asyncio.run(extract_stable(PORT, WAIT_MS))
        if result:
            print(result)
        else:
            sys.exit(1)
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except: proc.kill()

if __name__ == "__main__":
    main()
