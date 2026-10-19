#!/usr/bin/env python3
"""Claude Code sessions touched in the last N hours (config claude.activeHours).

For each session: its title (Claude's own "ai-title", or your custom title), the
folder it ran in, when it was last active, whether it looks live (written in the
last 15 minutes), the issue keys you mentioned in what YOU typed (ABC-123, …),
and the resume command. Reads transcript files only; prints one JSON object.
"""
import glob, json, os, re, shlex, sys, time

CONFIG = os.environ.get("WD_CONFIG", os.path.expanduser("~/.config/work-dashboard/config.json"))
try:
    cfg = json.load(open(CONFIG))
except Exception:
    cfg = {}
c = cfg.get("claude", {})
root = os.path.expanduser(c.get("projectsDir", "~/.claude/projects"))
hours = float(c.get("activeHours", 24))
prefixes = c.get("issueKeys") or []
# Which sessions are work: run inside a work folder, mention an issue key, or have a
# title with a work word. Everything else (personal projects, errands) is left out
# of the day summary.
work_roots = [os.path.expanduser(p).rstrip("/") for p in c.get("workRoots", [])]
work_words = [w.lower() for w in c.get("workWords", [])]
key_re = re.compile(r"\b(%s)-\d{1,6}\b" % "|".join(map(re.escape, prefixes))) if prefixes else re.compile(r"\b[A-Z][A-Z0-9]{1,6}-\d{1,6}\b")
SKIP = ("<", "Caveat:", "[Request interrupted", "This session is being continued", "Please continue", "API Error", "[Image:")
now = time.time()


def typed_text(msg):
    content = msg.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        if any(isinstance(x, dict) and x.get("type") == "tool_result" for x in content):
            return ""
        return " ".join(x.get("text", "") for x in content if isinstance(x, dict) and x.get("type") == "text")
    return ""


sessions = []
for path in glob.glob(os.path.join(root, "*", "*.jsonl")):
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        continue
    if now - mtime > hours * 3600:
        continue
    title = custom = cwd = first_prompt = None
    keys, prompts, started = {}, 0, None
    try:
        with open(path, errors="ignore") as fh:
            for line in fh:
                if '"type":"user"' not in line and '"ai-title"' not in line and '"custom-title"' not in line and cwd is not None:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                cwd = cwd or o.get("cwd")
                t = o.get("type")
                if t == "ai-title":
                    title = o.get("aiTitle") or title
                elif t == "custom-title":
                    custom = o.get("customTitle") or custom
                elif t == "user" and not o.get("isMeta") and not o.get("isSidechain"):
                    body = typed_text(o.get("message", {})).strip()
                    if not body or body.startswith(SKIP) or len(body) > 2000:
                        continue
                    started = started or o.get("timestamp")
                    prompts += 1
                    first_prompt = first_prompt or " ".join(body.split())[:140]
                    for m in key_re.finditer(body):
                        keys[m.group(0)] = keys.get(m.group(0), 0) + 1
    except OSError:
        continue
    if not prompts:
        continue   # agent-only or empty transcripts are not "your" sessions
    sid = os.path.basename(path)[:-6]
    sessions.append({
        "id": sid,
        "title": custom or title or first_prompt or sid[:8],
        "cwd": cwd,
        "folder": os.path.basename(cwd) if cwd and cwd != os.path.expanduser("~") else "~",
        "last": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(mtime)),
        "started": started,
        "live": now - mtime < 15 * 60,
        "prompts": prompts,
        "keys": sorted(keys, key=lambda k: -keys[k]),
        "work": bool((cwd and any(cwd == r or cwd.startswith(r + "/") for r in work_roots)) or keys
                     or any(w in (custom or title or first_prompt or "").lower() for w in work_words)),
        "resume": (f"cd {shlex.quote(cwd)} && claude --resume {shlex.quote(sid)}" if cwd else f"claude --resume {shlex.quote(sid)}"),
    })

sessions.sort(key=lambda s: s["last"], reverse=True)
json.dump({"sessions": sessions[:40], "checkedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, sys.stdout)
