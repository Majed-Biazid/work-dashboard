// Shared by the dashboard, the widgets and Quick Tools.
//   WD.data / WD.config / WD.state  — pushed by the app (WD.receive)
//   WD.on(fn)                       — re-render when anything changes
//   alerts(), briefing(), workstreams(), reviewGroups(), dayTimeline()
//     — the judgement calls, in one place, so every surface agrees.

const WD = {
  data: {}, config: {}, state: {}, updated: {}, listeners: [],
  bridge(msg) {
    return window.webkit && window.webkit.messageHandlers.bridge
      ? window.webkit.messageHandlers.bridge.postMessage(msg) : Promise.reject("Open this inside the Manara app.");
  },
  async boot() {
    try {
      const b = JSON.parse(await WD.bridge({ cmd: "boot" }));
      WD.config = JSON.parse(b.config || "{}"); WD.state = JSON.parse(b.state || "{}"); WD.updated = b.updated || {};
      for (const [k, v] of Object.entries(b.data || {})) WD.data[k] = safeParse(v);
    } catch (e) { WD.bootError = String(e); }
    applyLook(); WD.emit();
  },
  receive(kind, name, payload) {
    if (kind === "data") { WD.data[name] = safeParse(payload); WD.updated[name] = Date.now(); }
    if (kind === "config") WD.config = safeParse(payload) || {};
    if (kind === "state") {
      const next = safeParse(payload) || {};
      if (JSON.stringify(next) === JSON.stringify(WD.state)) return;   // our own change, echoed back
      WD.state = next;
    }
    applyLook(); WD.emit(kind, name);
  },
  on(fn) { WD.listeners.push(fn); },
  emit(kind, name) { WD.listeners.forEach((fn) => { try { fn(kind, name); } catch (e) { console.error(e); } }); },
  setState(key, value) { WD.state[key] = value; WD.bridge({ cmd: "state", key, value }).catch(() => {}); applyLook(); WD.emit("state", key); },
  open(url) { if (url) WD.bridge({ cmd: "open", url }).catch(() => {}); },
  copy(text) { return WD.bridge({ cmd: "copy", text }); },
};
window.WD = WD;   // the app pushes updates to window.WD (a top-level const is not on window)
const safeParse = (s) => { try { return typeof s === "string" ? JSON.parse(s) : s; } catch (e) { return null; } };

// ── look: text size, hide ───────────────────────────────────────────────────
function textScale() { return Number(WD.state.textScale || WD.config.textScale || 1); }
/** The theme from Settings → Appearance. Liquid Glass needs the app's backdrop, which
 *  only the dashboard window has: other pages show Graphite instead. */
function theme() {
  let t = WD.config.appearance?.theme || "graphite";
  if (t === "system") t = matchMedia("(prefers-color-scheme: light)").matches ? "light" : "graphite";
  if (t === "glass" && !/(dashboard|widget)\.html$/.test(location.pathname)) t = "graphite";   // widgets get the app's glass too
  return t;
}
matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => applyLook());
// Called on every push: write only what changed, so a data push never invalidates
// the whole page's style.
let lookSig = "";
function applyLook() {
  const root = document.documentElement, scale = textScale(), t = theme(), glass = WD.config.appearance?.glass || "smoked";
  const next = `${scale}|${t}|${glass}`;
  if (next !== lookSig) {
    lookSig = next;
    root.style.setProperty("--scale", scale);
    root.dataset.theme = t;
    root.dataset.glass = glass;
  }
  if (document.body && document.body.classList.contains("hidden") !== !!WD.state.hidden) document.body.classList.toggle("hidden", !!WD.state.hidden);
}
document.addEventListener("keydown", (e) => {
  if (!e.metaKey) return;
  const k = e.key;
  if (k === "=" || k === "+") { e.preventDefault(); WD.setState("textScale", Math.min(1.6, +(textScale() + 0.05).toFixed(2))); }
  else if (k === "-") { e.preventDefault(); WD.setState("textScale", Math.max(0.8, +(textScale() - 0.05).toFixed(2))); }
  else if (k === "0") { e.preventDefault(); WD.setState("textScale", 1); }
  else if (k.toLowerCase() === "h" && e.shiftKey) { e.preventDefault(); WD.setState("hidden", !WD.state.hidden); }
});

// ── formatting ──────────────────────────────────────────────────────────────
const TZ = () => WD.config.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone;
const h = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const minsSince = (t) => (Date.now() - new Date(t)) / 60000;
function ago(t) {
  if (!t) return "";
  const m = Math.max(0, Math.round(minsSince(t)));
  if (m < 1) return "just now";
  if (m < 60) return `${m} min ago`;
  if (m < 1440) return `${Math.floor(m / 60)} h ago`;
  const d = Math.floor(m / 1440); return d === 1 ? "yesterday" : `${d} days ago`;
}
function span(mins) {   // a duration in plain words
  const m = Math.max(0, Math.round(mins));
  if (m < 60) return `${m} min`;
  if (m < 1440) { const hh = Math.floor(m / 60), mm = m % 60; return mm && hh < 3 ? `${hh} h ${mm} min` : `${hh} h`; }
  const d = Math.floor(m / 1440); return d === 1 ? "1 day" : `${d} days`;
}
// A formatter in the configured timezone, made once per (locale, options, zone):
// building an Intl.DateTimeFormat costs far more than using one, and a render asks ~50×.
const FMT = new Map();
function fmt(locale, opts) {
  const tz = TZ(), k = `${locale}|${tz}|${JSON.stringify(opts)}`;
  let f = FMT.get(k);
  if (!f) { f = new Intl.DateTimeFormat(locale, { ...opts, timeZone: tz }); FMT.set(k, f); }
  return f;
}
// The calendar day of a moment in the CONFIGURED timezone (not this Mac's), "2026-10-18".
// Every "is it today?" question goes through this, so travelling never shifts a day.
const dayKey = (t) => fmt("en-CA", { year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(t));
const daysBetween = (a, b) => Math.round((Date.parse(dayKey(b)) - Date.parse(dayKey(a))) / 86400000);
const clock = (t) => fmt("en-GB", { hour: "2-digit", minute: "2-digit" }).format(new Date(t));
const plural = (n, one, many) => `${n} ${n === 1 ? one : many || one + "s"}`;
const list = (a) => a.length <= 1 ? (a[0] || "") : a.slice(0, -1).join(", ") + " and " + a[a.length - 1];
function hm(str) { const [a, b] = String(str || "0:0").split(":").map(Number); return a * 60 + (b || 0); }
const hhmm = (mins) => `${String(Math.floor(mins / 60) % 24).padStart(2, "0")}:${String(mins % 60).padStart(2, "0")}`;   // 600 → "10:00"
/** "starts in 5 min", or "starts now" in its last minute (never "in 0 min"). */
const startsIn = (mins) => (mins < 1 ? "starts now" : `starts in ${span(mins)}`);
const minutesOf = (d) => hm(fmt("en-GB", { hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(d));
function nowMinutes() { return minutesOf(new Date()); }
const weekdayOf = (d) => ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(fmt("en-GB", { weekday: "short" }).format(d));
function weekday() { return weekdayOf(new Date()); }
const workday = () => (WD.config.workday?.days || [0, 1, 2, 3, 4]).includes(weekday());
const issuePrefixes = () => WD.config.claude?.issueKeys || [];
const isIssueKey = (k) => { const p = issuePrefixes(); return !p.length || p.includes(k.split("-")[0]); };

// ── calendar ────────────────────────────────────────────────────────────────
/** A work calendar with nothing changed for 10 days has stopped syncing: macOS keeps
 *  repeating its old meetings. The fix is signing in to that account again. */
function calendarStale() {
  const lc = WD.data.calendar?.lastChange;
  if (!lc || Date.now() - new Date(lc) < 10 * 86400000) return "";
  return `Your calendar hasn't synced since ${fmt("en-GB", { day: "numeric", month: "short", year: "numeric" }).format(new Date(lc))} — the meetings shown may be wrong. Sign in again: System Settings → Internet Accounts`;
}
function meetings() {
  const c = WD.data.calendar;
  if (!c || c.error) return { error: c && c.error, list: [] };
  const today = dayKey(Date.now());
  const list = (c.events || []).filter((e) => !e.allDay).map((e) => ({ ...e, s: new Date(e.start), e: new Date(e.end) }))
    .sort((a, b) => a.s - b.s);
  const now = new Date();
  return {
    list: list.filter((e) => dayKey(e.s) === today),
    current: list.find((e) => e.s <= now && now < e.e),
    next: list.find((e) => e.s > now),
  };
}
/** The next standup, or the one on now: inMinutes is to its start (negative once it
 *  has started), endsIn to its end. */
function nextStandup() {
  // a calendar event called "…standup…" wins over the configured time
  const ev = (WD.data.calendar?.events || []).filter((e) => !e.allDay && /stand-?up/i.test(e.title))
    .map((e) => ({ s: new Date(e.start), e: new Date(e.end) })).filter((x) => x.e > Date.now()).sort((a, b) => a.s - b.s)[0];
  if (ev) {
    const mins = (ev.s - Date.now()) / 60000, days = daysBetween(Date.now(), ev.s);
    return { inMinutes: mins, endsIn: (ev.e - Date.now()) / 60000, day: days, at: clock(ev.s), until: clock(ev.e) };
  }
  const w = WD.config.workday || {}, at = hm(w.standup || "09:30"), days = w.days || [0, 1, 2, 3, 4];
  const now = new Date();
  for (let i = 0; i < 8; i++) {
    const d = new Date(now.getTime() + i * 86400000);
    if (!days.includes(weekdayOf(d))) continue;
    const mins = i === 0 ? at - nowMinutes() : i * 1440 + at - nowMinutes();
    if (mins > -30) return { inMinutes: mins, endsIn: mins + 30, day: i, at: w.standup || "09:30", until: hhmm(at + 30) };
  }
  return null;
}

// How many health runs in a row have given a system its current verdict.
// Kept per page (a reload starts again at 1, which only delays a notification).
const sysRuns = {};
function confirmSystem(s) {
  const at = WD.data.health?.checkedAt || "", r = sysRuns[s.name];
  if (!r || r.status !== s.status) sysRuns[s.name] = { status: s.status, at, n: 1 };
  else if (r.at !== at) { r.at = at; r.n++; }
  return sysRuns[s.name].n;
}

// What Claude's incident investigation is told when you press Investigate:
// the facts on screen, in one line (times in your timezone).
function incidentSubject(i) {
  return `Better Stack incident "${i.name}"${i.cause ? `, cause: ${i.cause}` : ""}, started ${i.started ? `${dayKey(i.started)} ${clock(i.started)} (${TZ()})` : "recently"}${i.url ? `, ${i.url}` : ""}`;
}
function systemSubject(s) {
  const word = { down: "down", warn: "degraded" }[s.status] || s.status;
  const urls = (s.http || []).map((x) => `${x.url} → ${x.code || "no answer"}`).join("; ");
  return `${s.name}${s.detail ? ` (${s.detail})` : ""} is ${word}: ${s.reasons.map((r) => r.text).join("; ")}${urls ? `. Health checks: ${urls}` : ""}. Seen at ${clock(Date.now())} ${TZ()}.`;
}

// Sources whose data failed or is older than three refresh intervals.
const SOURCE_NAME = { health: "System health", github: "GitHub", linear: "Linear", basecamp: "Basecamp" };
// The app's default refresh seconds (Store.swift → collectors); config.intervals overrides.
const DEFAULT_EVERY = { health: 60, local: 60, github: 180, linear: 180, basecamp: 300, sessions: 120, today: 600, standup: 900 };
function staleSources() {
  const out = [], iv = WD.config.intervals || {};
  // offline: one quiet line, not a failure per source
  if (WD.data.health?.offline || WD.data.local?.offline) return [{ name: "network", kind: "offline", text: "No network — the dashboard is showing the last data it had" }];
  for (const [k, name] of Object.entries(SOURCE_NAME)) {
    const d = WD.data[k];
    if (!d) continue;
    if (d.error) { out.push({ name: k, kind: "error", text: `${name} data couldn't be read — ${String(d.error).slice(0, 80)}` }); continue; }
    const at = Date.parse(d.checkedAt || "") || WD.updated[k];
    const every = (Number(iv[k]) || DEFAULT_EVERY[k]) * 1000;
    if (at && Date.now() - at > Math.max(3 * every, 10 * 60000)) out.push({ name: k, kind: "stale", text: `${name} data is ${span((Date.now() - at) / 60000)} old` });
  }
  return out;
}

// ── what needs you: one list, used by the briefing, menu bar, widgets, notifications
function alerts() {
  const out = [];
  const add = (a) => out.push(a);
  const cfgN = WD.config.notifications || {};
  const muted = WD.state.muted || {};

  // systems: one failed check is not an outage. A verdict counts once two health
  // runs in a row agree (confirmSystem), and a degraded system that is deploying
  // right now is the expected blip of a rollout, not something to chase.
  for (const s of WD.data.health?.systems || []) {
    const runs = confirmSystem(s), deploying = !!s.release?.running;
    if (s.status === "down") add({ id: `sys.${s.name}.down`, level: "red", text: `${s.name} is down — ${s.reasons.find((r) => r.level === "down")?.text || "check failing"}`, notify: cfgN.systemDown !== false && runs >= 2, url: s.reasons.find((r) => r.url)?.url, investigate: systemSubject(s) });
    else if (s.status === "warn" && !(deploying && runs < 3)) add({ id: `sys.${s.name}.warn.${s.reasons[0]?.text}`, level: "amber", text: `${s.name}: ${s.reasons.map((r) => r.text).join("; ")}` });
  }
  // a source that failed or went quiet: the calm on screen may not be real
  for (const st of staleSources()) add({ id: `src.${st.name}.${st.kind}`, level: "amber", text: st.text });
  // macOS keeps showing a calendar account's old copy when it stops syncing
  const cs = calendarStale();
  if (cs) add({ id: `calendar.stale.${dayKey(Date.now())}`, level: "amber", text: cs, notify: true });
  for (const i of WD.data.health?.incidents || []) add({ id: `inc.${i.name}.${i.started}`, level: "red", text: `Incident: ${i.name}${i.cause ? ` — ${i.cause}` : ""}`, url: i.url, notify: true, investigate: incidentSubject(i) });
  // logins that stop things working
  for (const l of WD.data.local?.logins || []) if (!l.ok) add({ id: `login.${l.name}.${dayKey(Date.now())}`, level: l.name === "Google Cloud" ? "red" : "amber", text: `${l.name} login expired`, fix: l.fix, signin: l.fix ? l.name : "", notify: cfgN.loginExpired !== false });
  // tech issues: only the ones YOU marked red interrupt you
  for (const i of techItems()) {
    if (muted[i.id] || issueLevel(i) !== "red") continue;
    add({ id: `issue.${i.id}.${i.updated}`, level: "red", text: `${i.title}${i.why ? ` — ${i.why}` : ""}`, url: i.url, notify: cfgN.newUrgentIssue !== false, private: true });
  }
  const err = WD.data.basecamp?.errors;
  if (err && err.last24h >= 6 && err.lastHour > 2 * (err.last24h / 24)) add({ id: `errs.${new Date().getHours()}`, level: "amber", text: `${err.label}: ${err.lastHour} prod errors in the last hour (usually ${Math.round(err.last24h / 24)})`, url: err.url });
  // meetings
  const m = meetings();
  if (m.next && (m.next.s - Date.now()) / 60000 <= 10) add({ id: `meet.${m.next.id}`, level: "amber", text: `${m.next.title} ${startsIn((m.next.s - Date.now()) / 60000)}`, url: m.next.link, private: true });
  // an urgent issue with no PR yet is work that waits on you too
  for (const s of workstreams().streams) if (!s.prs.length && s.priority === 1)
    add({ id: `urgent.${s.issues[0].id}`, level: "amber", text: `Urgent: ${s.issues[0].id} ${String(s.title).replace(/^\[[^\]]+\]\s*/, "")} has no PR yet`, url: s.issues[0].url, private: true });
  // work that waits on you
  for (const g of reviewGroups()) if (g.level === "red") add({ id: `rev.${g.name}.${g.oldestHours}`, level: "amber", text: `${g.name}'s ${plural(g.prs.length, "PR")} ${g.prs.length === 1 ? "has" : "have"} waited ${span(g.oldestHours * 60)} for your review`, private: true });
  // one alert per piece of work, not per PR (a fix across two repos is one thing)
  for (const s of workstreams().streams) if (s.action.level === "red" && s.prs.length)
    add({ id: `pr.${s.prs.map((p) => p.repo + p.number).join(".")}.${s.action.kind}`, level: "amber", url: s.prs[0].url, private: true,
          text: `${s.action.text} on ${s.prs.map((p) => `${p.repo} #${p.number}`).join(" and ")}` });
  // the standup couldn't be written close to the standup
  const st = nextStandup();
  if (st && st.day === 0 && st.inMinutes < 120 && st.inMinutes > -30 && WD.data.standup?.error && WD.data.standup.day !== dayKey(Date.now()))
    add({ id: `standup.${dayKey(Date.now())}`, level: "amber", text: "Today's standup couldn't be written — open Standup and try Write now" });

  const rank = { red: 0, amber: 1 };
  return out.sort((a, b) => rank[a.level] - rank[b.level]);
}

// "Re: [12-03-101500] [High] Payments page shows the wrong total" → "Payments page shows the wrong total"
const cleanTitle = (t) => String(t || "").replace(/^(Re|Completed|Added|Assigned you|Mentioned you|Ping)\s*:\s*/i, "")
  .replace(/\s*\[[^\]]*\]\s*/g, " ").trim();
const baseUrl = (u) => String(u || "").split("#")[0].replace(/\/$/, "");

/** Technology issues: the open tickets in your Basecamp column. */
function techItems() {
  return (WD.data.basecamp?.issues || []).map((i) => ({ ...i, source: "column", mentions: [] }));
}
/** What was said TO you in Basecamp: unread @mentions and private chats (pings). */
function basecampMessages() { return WD.data.basecamp?.inbox?.items || []; }

/** A technology issue's colour is yours to set: every open issue starts yellow,
 *  turns red only when you make it red, and green means "not important for me". */
function issueLevel(i) { return (WD.state.issueLevel || {})[i.id] || "amber"; }

/** One sentence that says what matters right now. */
function briefing() {
  const a = alerts();
  const reds = a.filter((x) => x.level === "red"), ambers = a.filter((x) => x.level === "amber");
  const sys = WD.data.health?.systems || [];
  let line;
  const waiting = ["health", "github", "linear"].filter((k) => !WD.data[k]).map((k) => SOURCE_NAME[k]);
  if (!reds.length && waiting.length) return { line: `Still checking ${list(waiting)}…`, level: "unknown", count: ambers.length, alerts: a };
  if (reds.length) line = reds[0].text + (reds.length > 1 ? `, and ${plural(reds.length - 1, "more thing")} need${reds.length - 1 === 1 ? "s" : ""} you now.` : ".");
  else if (ambers.length) line = ambers[0].text + (ambers.length > 1 ? ` — and ${ambers.length - 1} more to look at.` : ".");
  else if (sys.length && sys.every((s) => s.status === "ok")) line = "All systems normal. Nothing needs you right now.";
  else line = "Nothing needs you right now.";
  return { line, level: reds.length ? "red" : ambers.length ? "amber" : "clear", count: reds.length + ambers.length, alerts: a };
}

// "fix(api): ABC-123 totals are wrong" → "Totals are wrong"
const prTitle = (t) => cap(String(t || "").replace(/^\w+(\([\w-]+\))?!?:\s*/, "").replace(/^([A-Z]+-\d+\s*(…|\.\.\.|,|&)?\s*)+:?\s*/, ""));

// ── workstreams: PRs + Linear issues + Claude sessions, one row each ─────────
function workstreams() {
  const active = WD.data.linear?.active || [];
  const byId = Object.fromEntries(active.map((i) => [i.id, i]));
  const prs = (WD.data.github?.mine || []).map((p) => ({ ...p, issueKeys: (p.keys || []).filter((k) => isIssueKey(k)) }));
  // join PRs that share an active Linear issue (e.g. one fix across two repos)
  const groups = [];
  for (const p of prs) {
    const keys = p.issueKeys.filter((k) => byId[k]);
    const g = groups.find((x) => keys.some((k) => x.keys.has(k)));
    if (g) { g.prs.push(p); keys.forEach((k) => g.keys.add(k)); } else groups.push({ prs: [p], keys: new Set(keys) });
  }
  const rank = { red: 0, amber: 1, go: 2, quiet: 3 };
  const streams = groups.map((g) => {
    const issues = [...g.keys].map((k) => byId[k]).filter(Boolean);
    const pr = g.prs.slice().sort((a, b) => rank[a.action.level] - rank[b.action.level])[0];
    const title = g.prs.length > 1 && issues.length === 1 ? issues[0].title : prTitle(pr.title);
    return { title, prs: g.prs, issues, action: pr.action, priority: Math.min(...issues.map((i) => i.priority || 5), 5) };
  });
  // active issues whose PR already merged: one row per merged PR, not "No PR yet"
  const linked = new Set(streams.flatMap((s) => s.issues.map((i) => i.id)));
  for (const m of WD.data.github?.merged || []) {
    const issues = (m.keys || []).filter(isIssueKey).map((k) => byId[k]).filter((i) => i && !linked.has(i.id));
    if (!issues.length) continue;
    issues.forEach((i) => linked.add(i.id));
    streams.push({ title: prTitle(m.title),
      prs: [{ ...m, issueKeys: m.keys, merged: true }], issues, priority: Math.min(...issues.map((i) => i.priority || 5)),
      action: { kind: "merged", level: "quiet", text: `Merged ${ago(m.mergedAt)} into ${m.base} — move ${issues.length === 1 ? "the issue" : `its ${issues.length} issues`} on when it's released` } });
  }
  // urgent issues assigned to you that aren't started yet still belong in Focus
  for (const i of WD.data.linear?.all || []) if (i.priority === 1 && !byId[i.id] && !linked.has(i.id) && i.stateType !== "completed" && i.stateType !== "canceled") {
    linked.add(i.id);
    streams.push({ title: i.title, prs: [], issues: [i], priority: 1, action: { kind: "nopr", level: "red", text: `Urgent, ${String(i.state || "not started").toLowerCase()}, no PR yet` } });
  }
  // active issues with no PR yet
  for (const i of active) if (!linked.has(i.id)) streams.push({ title: i.title, prs: [], issues: [i], action: { kind: "nopr", level: "quiet", text: i.state === "In Progress" ? "No PR yet" : i.state }, priority: i.priority || 5 });
  // attach Claude sessions by issue key
  const sessions = WD.data.sessions?.sessions || [];
  const used = new Set();
  for (const s of streams) {
    const keys = new Set(s.issues.map((i) => i.id).concat(s.prs.flatMap((p) => p.issueKeys)));
    s.sessions = sessions.filter((x) => x.keys.some((k) => keys.has(k)));
    s.sessions.forEach((x) => used.add(x.id));
    s.lastTouched = [s.sessions[0]?.last, ...s.prs.map((p) => p.updated), ...s.issues.map((i) => i.updated)].filter(Boolean).sort().pop();
  }
  streams.sort((a, b) => rank[a.action.level] - rank[b.action.level] || a.priority - b.priority || String(b.lastTouched).localeCompare(String(a.lastTouched)));
  const loose = sessions.filter((s) => !used.has(s.id) && s.prompts >= 2 && isWork(s));
  const shown = new Set(streams.flatMap((s) => s.issues.map((i) => i.id)));
  return { streams, loose, next: (WD.data.linear?.next || []).filter((i) => !shown.has(i.id)) };
}

// ── reviews: grouped by teammate, team first ────────────────────────────────
function reviewGroups() {
  const reviews = WD.data.github?.reviews || [];
  const team = (WD.config.team || []).map((t) => t.name);
  const wait = WD.config.github?.reviewWaitHours || { amber: 24, red: 72 };
  const map = new Map();
  for (const r of reviews) {
    const name = r.teammate || "Others";
    if (!map.has(name)) map.set(name, []);
    map.get(name).push(r);
  }
  return [...map.entries()].map(([name, prs]) => {
    const oldestHours = Math.max(...prs.map((p) => p.waitingHours));
    const keys = [...new Set(prs.flatMap((p) => (p.keys || []).filter(isIssueKey)))];
    const isTeam = name !== "Others";
    return { name, isTeam, prs, keys, oldestHours,
             level: oldestHours >= wait.red ? "red" : (isTeam && oldestHours >= wait.amber) ? "amber" : "quiet" };
  }).sort((a, b) => (b.isTeam - a.isTeam) || (team.indexOf(a.name) - team.indexOf(b.name)) || b.oldestHours - a.oldestHours);
}

// ── the day: the standup, or what you did today ─────────────────────────────
// The day column switches by itself: the standup (your previous working day,
// written by standup.sh from the days Manara recorded)
// during the standup window, today's work the rest of the time. Tapping the
// other tab is a 10-minute peek, then it goes back to the automatic view.
const PEEK_MS = 10 * 60000;
function autoDayMode() {
  const w = WD.config.workday || {}, n = nowMinutes();
  return workday() && n >= hm(w.standupPanelFrom || "09:00") && n < hm(w.standupPanelUntil || "11:00") ? "standup" : "today";
}
function dayMode() {
  const forced = WD.state.dayMode;   // "standup" | "today" | undefined
  if (forced && forced !== autoDayMode() && WD.state.dayModeAt && Date.now() - WD.state.dayModeAt < PEEK_MS) return forced;
  return autoDayMode();
}
/** A quiet line saying when the column switches next. */
function dayModeNote() {
  const w = WD.config.workday || {}, mode = dayMode(), auto = autoDayMode();
  if (mode !== auto) return `Back to ${auto === "standup" ? "the standup" : "today"} in ${span((PEEK_MS - (Date.now() - WD.state.dayModeAt)) / 60000)}`;
  if (auto === "standup") return `Switches to today at ${w.standupPanelUntil || "11:00"}`;
  return workday() && nowMinutes() < hm(w.standupPanelFrom || "09:00") ? `Standup notes from ${w.standupPanelFrom || "09:00"}` : "";
}
function dayTimeline() {
  const t = WD.data.today || {}, out = [], today = dayKey(Date.now());
  // only today's: data kept from before midnight (e.g. while offline) is yesterday's
  const add = (at, kind, text, url, extra) => at && dayKey(at) === today && out.push({ at, kind, text, url, ...extra });
  for (const p of t.merged || []) add(p.at, "Merged", p.title, p.url, { ref: `${p.repo} #${p.number}` });
  for (const p of t.opened || []) if (!(t.merged || []).some((m) => m.url === p.url)) add(p.at, "Opened", p.title, p.url, { ref: `${p.repo} #${p.number}` });
  for (const p of t.reviewed || []) add(p.at, "Reviewed", p.title, p.url, { ref: `${p.repo} #${p.number}` });
  for (const i of WD.data.linear?.done || []) add(i.at, "Closed", i.title, i.url, { ref: i.id });
  for (const b of t.basecamp || []) add(b.at, b.kind === "comment" ? "Replied" : "Posted", cleanTitle(b.title), b.url, { ref: b.where });
  const claude = (WD.data.sessions?.sessions || []).filter((s) => isWork(s) && dayKey(s.last) === today && s.prompts >= 2).sort((a, b) => String(b.last).localeCompare(String(a.last)));
  for (const s of claude.slice(0, 2)) add(s.last, "Claude", s.title, null, { resume: s.resume, ref: s.folder === "~" ? "" : s.folder });
  if (claude.length > 2) add(claude[2].last, "Claude", `${plural(claude.length - 2, "more session")}: ${claude.slice(2, 5).map((s) => s.title).join(", ")}${claude.length > 5 ? "…" : ""}`, null, {});
  // meetings (macOS Calendar, so Google calendars added there too): the ones that
  // ended join the log; the one you're in and the rest of today are listed apart
  const now = new Date(), upcoming = [];
  for (const m of meetings().list) {
    if (m.e <= now) add(m.start, "Meeting", m.title, null, { ref: span((m.e - m.s) / 60000) });
    else upcoming.push({ at: m.start, kind: m.s <= now ? "Now" : upcoming.some((u) => u.kind !== "Now") ? "Later" : "Next", text: m.title, url: m.link || null,
                         ref: m.s <= now ? `until ${clock(m.e)}` : `${clock(m.s)}–${clock(m.e)}${m.tentative ? ", tentative" : ""}` });
  }
  // commits: one line per repo, at the latest commit
  const byRepo = {};
  for (const c of t.commits || []) (byRepo[c.repo] = byRepo[c.repo] || []).push(c);
  for (const [repo, cs] of Object.entries(byRepo)) { cs.sort((a, b) => String(b.at).localeCompare(String(a.at)));
    add(cs[0].at, "Committed", cs.length === 1 ? cs[0].title : `${cs.length} commits — latest: ${cs[0].title}`, cs[0].url, { ref: repo }); }
  const commits = (t.commits || []).length;
  out.sort((a, b) => new Date(b.at) - new Date(a.at));
  const count = (k) => out.filter((x) => x.kind === k).length;
  const parts = [count("Merged") && `merged ${plural(count("Merged"), "PR")}`, count("Reviewed") && `reviewed ${count("Reviewed")}`,
                 count("Closed") && `closed ${plural(count("Closed"), "issue")}`, count("Meeting") && plural(count("Meeting"), "meeting"),
                 commits && plural(commits, "commit")].filter(Boolean);
  return { items: out, upcoming, summary: parts.length ? cap(list(parts)) + "." : "Nothing recorded yet today.", glance: dayGlance(out, claude, commits, byRepo) };
}
const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
// A session is work if the collector says so (work folder, issue key, work word).
// Older data without the flag counts as work, so nothing disappears unexpectedly.
const isWork = (s) => s.work !== false;
/** The day at a glance, one line per source: meetings, Linear, pull requests, git, Claude. */
function dayGlance(items, claude, commits, byRepo) {
  const n = (k) => items.filter((x) => x.kind === k).length;
  const lin = WD.data.linear || {}, now = nowIssues();
  const inProgress = now.filter((i) => i.stateType === "started");
  const rows = [];
  const ms = meetings(), now0 = new Date();
  const later = ms.list.filter((m) => m.s > now0), done = ms.list.filter((m) => m.e <= now0), cur = ms.list.find((m) => m.s <= now0 && now0 < m.e);
  rows.push({ k: "Meetings", wait: !WD.data.calendar, v: ms.error === "no-access" ? "no calendar access — allow it in Settings"
    : calendarStale() ? "calendar out of date — sign in again in Internet Accounts"
    : ms.error ? "calendar unavailable"
    : !ms.list.length ? "none today"
    : [plural(ms.list.length, "meeting"), done.length && `${done.length} done`, cur && `now: ${cur.title}`,
       later[0] && `next: ${later[0].title} at ${clock(later[0].s)}`].filter(Boolean).join(" · ") });
  rows.push({ k: "Linear", v: [n("Closed") && `closed ${plural(n("Closed"), "issue")}`,
    inProgress.length ? `in progress: ${inProgress.slice(0, 2).map((i) => i.id).join(", ")}` : now[0] && `next: ${now[0].id}`].filter(Boolean).join(" · ") || "nothing moved yet" });
  rows.push({ k: "Pull requests", v: [n("Merged") && `merged ${n("Merged")}`, n("Opened") && `opened ${n("Opened")}`, n("Reviewed") && `reviewed ${n("Reviewed")}`].filter(Boolean).join(" · ") || "none yet" });
  rows.push({ k: "Git", v: commits ? `${plural(commits, "commit")} in ${list(Object.keys(byRepo))}` : "no commits yet" });
  rows.push({ k: "Claude", v: claude.length ? `${plural(claude.length, "work session")} — ${claude.slice(0, 2).map((s) => s.title).join(", ")}${claude.length > 2 ? "…" : ""}` : "no work sessions yet" });
  if (lin.error) rows[0].v = "Linear unavailable";
  // before a source has answered, "nothing yet" would be a false calm
  const waiting = [!WD.data.linear, !WD.data.today, !WD.data.today, !WD.data.sessions];
  rows.slice(1).forEach((r, i) => { if (waiting[i]) r.wait = true; });
  return rows.map(({ k, v, wait }) => ({ k, v: wait ? "checking…" : v }));
}
/** Your Linear issues in the order you'd pick them up: In Progress first, then by
 *  priority (Urgent → Low, none last), then the most recently touched. */
function nowIssues() {
  const all = WD.data.linear?.all || [];
  const stage = { started: 0, unstarted: 1, triage: 1, backlog: 2 };
  const pr = (p) => (p ? p : 5);
  return all.filter((i) => i.stateType !== "completed" && i.stateType !== "canceled")
    .sort((a, b) => (stage[a.stateType] ?? 3) - (stage[b.stateType] ?? 3) || pr(a.priority) - pr(b.priority) || String(b.updated).localeCompare(String(a.updated)));
}
function standupDraft() {
  return dayTimeline().items.filter((x) => x.kind !== "Claude").map((x) => `- ${x.kind} ${x.text}${x.ref ? ` (${x.ref})` : ""}`).join("\n");
}

// ── one computation per render ──────────────────────────────────────────────
// alerts() asks workstreams() twice, and the briefing, the columns and the header
// ask again. Inside WD.batch(fn) each judgement below runs once and is shared;
// outside a batch (tests, click handlers) every call computes fresh, as before.
let memoScope = null;
WD.batch = (fn) => { if (memoScope) return fn(); memoScope = new Map(); try { return fn(); } finally { memoScope = null; } };
const memo = (name, f) => function () {
  if (!memoScope || arguments.length) return f.apply(this, arguments);
  if (!memoScope.has(name)) memoScope.set(name, f());
  return memoScope.get(name);
};
alerts = memo("alerts", alerts); briefing = memo("briefing", briefing); workstreams = memo("workstreams", workstreams);
reviewGroups = memo("reviewGroups", reviewGroups); meetings = memo("meetings", meetings); nextStandup = memo("nextStandup", nextStandup);
dayTimeline = memo("dayTimeline", dayTimeline); nowIssues = memo("nowIssues", nowIssues); staleSources = memo("staleSources", staleSources);
