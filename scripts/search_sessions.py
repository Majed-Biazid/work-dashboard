#!/usr/bin/env python3
"""Search past Claude Code sessions (last 90 days) for keywords in what YOU typed.

  search_sessions.py refund webhook       → JSON list, best match first

A session matches when every keyword appears in your own messages. Ranked by how
many of your messages match, then by recency. Prints title, folder, dates, one
matching line, and the resume command.
"""
import glob, json, os, re, shlex, sys, time

CONFIG = os.environ.get("WD_CONFIG", os.path.expanduser("~/.config/work-dashboard/config.json"))
try:
    root = os.path.expanduser(json.load(open(CONFIG)).get("claude", {}).get("projectsDir", "~/.claude/projects"))
except Exception:
    root = os.path.expanduser("~/.claude/projects")
words = [w.lower() for w in sys.argv[1:] if w.strip()]
if not words:
    print("[]"); sys.exit(0)
pats = [re.compile(re.escape(w)) for w in words]
SKIP = ("<", "Caveat:", "[Request interrupted", "This session is being continued", "API Error", "[Image:")
cutoff = time.time() - 90 * 86400
hits = []

for path in glob.glob(os.path.join(root, "*", "*.jsonl")):
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        continue
    if mtime < cutoff:
        continue
    title = cwd = first = last = None
    score, snip = 0, None
    try:   # a transcript that vanished or can't be read is skipped, not fatal
        with open(path, errors="ignore") as fh:
            for line in fh:
                if '"ai-title"' in line or '"custom-title"' in line or cwd is None or '"type":"user"' in line:
                    try:
                        o = json.loads(line)
                    except Exception:
                        continue
                    cwd = cwd or o.get("cwd")
                    if o.get("type") == "ai-title":
                        title = o.get("aiTitle") or title
                    if o.get("type") == "custom-title":
                        title = o.get("customTitle") or title
                    if o.get("type") != "user" or o.get("isMeta") or o.get("isSidechain"):
                        continue
                    c = o.get("message", {}).get("content")
                    if isinstance(c, list):
                        if any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c):
                            continue
                        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
                    if not isinstance(c, str) or c.strip().startswith(SKIP) or len(c) > 2000:
                        continue
                    ts = o.get("timestamp")
                    first = first or ts; last = ts or last
                    low = c.lower()
                    if all(p.search(low) for p in pats):
                        score += 1
                        snip = snip or " ".join(c.split())[:200]
    except OSError:
        continue
    if score:
        sid = os.path.basename(path)[:-6]
        hits.append({"id": sid, "title": title or sid[:8], "cwd": cwd, "first": (first or "")[:10], "last": (last or "")[:10],
                     "score": score, "snip": snip, "mtime": mtime,
                     "resume": f"cd {shlex.quote(cwd)} && claude --resume {shlex.quote(sid)}" if cwd else f"claude --resume {shlex.quote(sid)}"})

hits.sort(key=lambda h: (-h["score"], -h["mtime"]))
json.dump(hits[:12], sys.stdout)
