// The judgement calls (web/core.js) that every surface shares: what needs you,
// the briefing, workstreams, reviews and the day. Run: node --test
const test = require("node:test");
const assert = require("node:assert/strict");
const { load, plain } = require("./harness.js");

const now = () => new Date().toISOString();
const hoursAgo = (h) => new Date(Date.now() - h * 3600000).toISOString();
const ok = (name) => ({ name, status: "ok", reasons: [] });

test("formatting helpers", () => {
  const { get } = load({ config: { timezone: "UTC" } });
  assert.equal(get('h(`<a href="x">&</a>`)'), "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;");
  assert.equal(get("span(45)"), "45 min");
  assert.equal(get("span(90)"), "1 h 30 min");
  assert.equal(get("span(60 * 30)"), "1 day");
  assert.equal(get("plural(1, 'PR')"), "1 PR");
  assert.equal(get("plural(2, 'PR')"), "2 PRs");
  assert.equal(get("list(['a', 'b', 'c'])"), "a, b and c");
  assert.equal(get("hm('09:30')"), 570);
  assert.equal(get("ago(new Date())"), "just now");
});

test("dayKey uses the configured timezone, not this Mac's", () => {
  const { get } = load({ config: { timezone: "Asia/Tokyo" } });
  assert.equal(get('dayKey("2026-10-18T20:00:00Z")'), "2026-10-19");
  const utc = load({ config: { timezone: "UTC" } });
  assert.equal(utc.get('dayKey("2026-10-18T20:00:00Z")'), "2026-10-18");
});

test("titles: PR prefixes and Basecamp noise come off", () => {
  const { get } = load();
  assert.equal(get('prTitle("fix(api): ABC-123 totals are wrong")'), "Totals are wrong");
  assert.equal(get('cleanTitle("Re: [12-03-101500] [High] Payments page shows the wrong total")'), "Payments page shows the wrong total");
});

test("briefing: never a false calm before the sources answer", () => {
  const { get } = load({ config: { timezone: "UTC" } });
  const b = plain(get("briefing()"));
  assert.equal(b.level, "unknown");
  assert.match(b.line, /^Still checking System health, GitHub and Linear/);
});

test("briefing: all clear once every source has answered", () => {
  const { get } = load({ config: { timezone: "UTC" }, data: {
    health: { systems: [ok("API"), ok("Web")], checkedAt: now() }, github: { mine: [], reviews: [], checkedAt: now() }, linear: { active: [], all: [], checkedAt: now() } } });
  const b = plain(get("briefing()"));
  assert.equal(b.level, "clear");
  assert.equal(b.line, "All systems normal. Nothing needs you right now.");
});

test("a system is announced down only after two health runs agree", () => {
  const down = { name: "API", status: "down", reasons: [{ level: "down", text: "Health check timed out" }], http: [] };
  const { get, WD } = load({ config: { timezone: "UTC" }, data: { health: { systems: [down], checkedAt: "t1" } } });
  const first = plain(get("alerts()")).find((a) => a.id === "sys.API.down");
  assert.equal(first.level, "red");
  assert.equal(first.notify, false);
  assert.equal(plain(get("alerts()")).find((a) => a.id === "sys.API.down").notify, false);   // same run, asked again
  WD.data.health.checkedAt = "t2";
  assert.equal(plain(get("alerts()")).find((a) => a.id === "sys.API.down").notify, true);
});

test("degraded while deploying is not an alert at first", () => {
  const warn = { name: "Web", status: "warn", reasons: [{ level: "warn", text: "Health check slow (4s)" }], release: { running: { status: "in_progress" } } };
  const { get } = load({ config: { timezone: "UTC" }, data: { health: { systems: [warn], checkedAt: "t1" } } });
  assert.equal(plain(get("alerts()")).filter((a) => a.id.startsWith("sys.")).length, 0);
});

test("technology issues start yellow; only red ones interrupt", () => {
  const issue = { id: 9, title: "Wrong total", updated: now(), url: "https://example.com/9" };
  const { get, WD } = load({ config: { timezone: "UTC" }, data: { basecamp: { issues: [issue], checkedAt: now() } } });
  assert.equal(get("issueLevel(techItems()[0])"), "amber");
  assert.equal(plain(get("alerts()")).filter((a) => a.id.startsWith("issue.")).length, 0);
  WD.state = { issueLevel: { 9: "red" } };
  assert.equal(plain(get("alerts()")).filter((a) => a.id.startsWith("issue.")).length, 1);
  WD.state = { issueLevel: { 9: "red" }, muted: { 9: Date.now() } };
  assert.equal(plain(get("alerts()")).filter((a) => a.id.startsWith("issue.")).length, 0);
});

test("stale sources: offline is one quiet line; an error is named", () => {
  const off = load({ config: { timezone: "UTC" }, data: { health: { offline: true }, github: { error: "boom" } } });
  assert.deepEqual(plain(off.get("staleSources()")).map((s) => s.kind), ["offline"]);
  const err = load({ config: { timezone: "UTC" }, data: { github: { error: "rate limited" } } });
  assert.match(plain(err.get("staleSources()"))[0].text, /GitHub data couldn't be read — rate limited/);
});

test("stale sources: judged against each source's own refresh interval", () => {
  const at = new Date(Date.now() - 12 * 60000).toISOString();   // 12 min old
  const { get } = load({ config: { timezone: "UTC" }, data: { github: { checkedAt: at }, basecamp: { checkedAt: at } } });
  // GitHub refreshes every 3 min (stale after 10), Basecamp every 5 (stale after 15)
  assert.deepEqual(plain(get("staleSources()")).map((s) => s.name), ["github"]);
});

test("workstreams: PRs that close the same issue are one row", () => {
  const pr = (repo, n, level) => ({ repo, number: n, title: `fix: ABC-1 thing`, url: `https://github.com/o/${repo}/pull/${n}`, keys: ["ABC-1"], updated: now(),
    action: { kind: level === "red" ? "ci" : "wait", level, text: level === "red" ? "Fix CI" : "Waiting" } });
  const { get } = load({ config: { timezone: "UTC", claude: { issueKeys: ["ABC"] } }, data: {
    github: { mine: [pr("api", 1, "quiet"), pr("web", 2, "red")] },
    linear: { active: [{ id: "ABC-1", title: "The thing", priority: 2, state: "In Progress", updated: now() }], all: [] } } });
  const w = plain(get("workstreams()"));
  assert.equal(w.streams.length, 1);
  assert.equal(w.streams[0].prs.length, 2);
  assert.equal(w.streams[0].title, "The thing");
  assert.equal(w.streams[0].action.level, "red");   // the most urgent PR speaks for the row
});

test("workstreams: an urgent issue with no PR gets its own row and an alert", () => {
  const { get } = load({ config: { timezone: "UTC" }, data: {
    linear: { active: [], all: [{ id: "ABC-9", title: "Outage fix", priority: 1, state: "Todo", stateType: "unstarted", updated: now() }] } } });
  const w = plain(get("workstreams()"));
  assert.equal(w.streams[0].issues[0].id, "ABC-9");
  assert.ok(plain(get("alerts()")).some((a) => a.id === "urgent.ABC-9"));
});

test("reviews: team first, red after the configured wait", () => {
  const r = (teammate, h) => ({ teammate, waitingHours: h, url: "u", keys: [] });
  const { get } = load({ config: { team: [{ name: "Sara" }], github: { reviewWaitHours: { amber: 24, red: 72 } } },
    data: { github: { reviews: [r(null, 100), r("Sara", 30)] } } });
  const g = plain(get("reviewGroups()"));
  assert.deepEqual(g.map((x) => [x.name, x.level]), [["Sara", "amber"], ["Others", "red"]]);
});

test("today's timeline leaves out what happened before midnight", () => {
  const { get } = load({ config: { timezone: "UTC" }, data: { today: {
    merged: [{ at: now(), title: "Today's PR", url: "u1", repo: "api", number: 1 }, { at: hoursAgo(48), title: "Old PR", url: "u2", repo: "api", number: 2 }] } } });
  const d = plain(get("dayTimeline()"));
  assert.deepEqual(d.items.map((x) => x.text), ["Today's PR"]);
  assert.equal(d.summary, "Merged 1 PR.");
});

test("day panel: the standup window switches the column by itself", () => {
  const { get, WD } = load({ config: { timezone: "UTC", workday: { days: [0, 1, 2, 3, 4, 5, 6], standupPanelFrom: "00:00", standupPanelUntil: "23:59" } } });
  assert.equal(get("dayMode()"), "standup");
  WD.state = { dayMode: "today", dayModeAt: Date.now() };   // a peek at the other tab lasts 10 minutes
  assert.equal(get("dayMode()"), "today");
  WD.state = { dayMode: "today", dayModeAt: Date.now() - 11 * 60000 };
  assert.equal(get("dayMode()"), "standup");
});

test("today: meetings from the calendar — ended ones in the log, the rest listed apart", () => {
  const at = (min) => new Date(Date.now() + min * 60000).toISOString();
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  // pick times that stay inside today, whatever the hour the test runs at
  const midnight = new Date(); midnight.setHours(24, 0, 0, 0);
  const left = (midnight - Date.now()) / 60000, since = 24 * 60 - left;
  if (left < 50 || since < 50) return;   // too close to midnight for a same-day spread
  const events = [
    { title: "Done sync", start: at(-45), end: at(-30), allDay: false },
    { title: "In it now", start: at(-10), end: at(10), allDay: false },
    { title: "Design review", start: at(20), end: at(40), allDay: false, link: "https://meet.example.com/x" },
  ];
  const { get } = load({ config: { timezone: tz }, data: { calendar: { events } } });
  const d = plain(get("dayTimeline()"));
  assert.deepEqual(d.items.filter((x) => x.kind === "Meeting").map((x) => x.text), ["Done sync"]);
  assert.deepEqual(d.upcoming.map((x) => [x.kind, x.text]), [["Now", "In it now"], ["Next", "Design review"]]);
  assert.equal(d.upcoming[1].url, "https://meet.example.com/x");
  const row = d.glance.find((g) => g.k === "Meetings");
  assert.match(row.v, /^3 meetings · 1 done · now: In it now · next: Design review at /);
  assert.equal(plain(load({ config: { timezone: tz }, data: { calendar: { events: [] } } }).get("dayTimeline()")).glance[0].v, "none today");
  assert.equal(plain(load({ config: { timezone: tz } }).get("dayTimeline()")).glance[0].v, "checking…");
});

test("an expired login carries a Sign in; one without a fix doesn't", () => {
  const logins = [{ name: "Google Cloud", ok: false, fix: "gcloud auth login" }, { name: "Other", ok: false, fix: "" }];
  const { get } = load({ data: { local: { logins } } });
  const a = plain(get("alerts()")).filter((x) => x.id.startsWith("login."));
  assert.deepEqual(a.map((x) => [x.text, x.signin]), [["Google Cloud login expired", "Google Cloud"], ["Other login expired", ""]]);
});

test("standup: once it has started, it says when it ends", () => {
  const now = Date.now(), iso = (m) => new Date(now + m * 60000).toISOString();
  const { get } = load({ config: { timezone: "UTC" }, data: { calendar: { events: [
    { title: "Daily Standup — Engineering & Product", start: iso(-15), end: iso(15), allDay: false }] } } });
  const st = get("nextStandup()");
  assert.ok(st.inMinutes < 0);
  assert.ok(Math.abs(st.endsIn - 15) < 1);
  assert.equal(get("startsIn(0.4)"), "starts now");
  assert.equal(get("startsIn(5)"), "starts in 5 min");
  assert.equal(get("hhmm(600)"), "10:00");
});

test("calendar: a work calendar with no change for 10 days is flagged as not syncing", () => {
  const old = new Date(Date.now() - 30 * 86400000).toISOString(), fresh = new Date(Date.now() - 86400000).toISOString();
  const stale = load({ config: { timezone: "UTC" }, data: { calendar: { events: [], lastChange: old } } });
  assert.match(stale.get("calendarStale()"), /hasn't synced since/);
  assert.ok(stale.get("alerts()").some((a) => a.id.startsWith("calendar.stale")));
  const ok = load({ config: { timezone: "UTC" }, data: { calendar: { events: [], lastChange: fresh } } });
  assert.equal(ok.get("calendarStale()"), "");
});

test("databases: load held over a limit warns; a single spike does not", () => {
  const t = Math.floor(Date.now() / 1000), at = (vals) => vals.map((v, i) => [t - (vals.length - 1 - i) * 300, v]);
  const db = (series, extra = {}) => ({ id: "db1", name: "Hub", detail: "", up: 1, maxConnections: 100, diskGrows: true,
    series, now: Object.fromEntries(Object.entries(series).map(([k, p]) => [k, p[p.length - 1][1]])), ...extra });
  const issues = (d, config = {}) => plain(load({ config: { timezone: "UTC", ...config }, data: {} }).get(`dbIssues(${JSON.stringify(d)})`));
  assert.deepEqual(issues(db({ cpu: at([0.1, 0.1, 0.95]) })), []);                                   // one heavy query
  assert.equal(issues(db({ cpu: at([0.1, 0.85, 0.9, 0.92]) }))[0].metric, "cpu");                   // 15 minutes over 80%
  assert.deepEqual(issues(db({ cpu: at([0.1, 0.85, 0.9, 0.92]) }), { databases: { warn: { cpu: 0.95 } } }), []);   // the limit is yours
  assert.match(issues(db({ connections: at([50, 82, 85, 90]) }))[0].text, /90 of 100 connections/);
  assert.deepEqual(issues(db({ disk: at([0.95]) })), []);                                            // grows by itself
  assert.equal(issues(db({ disk: at([0.95]) }, { diskGrows: false }))[0].metric, "disk");
  assert.deepEqual(issues(db({ lag: at([90, 120, 150]) })), []);                                     // lag counts on replicas only
  assert.equal(issues(db({ lag: at([90, 120, 150]) }, { replica: true }))[0].metric, "lag");
});

test("databases: down is a red alert that notifies; high load is amber", () => {
  const t = Math.floor(Date.now() / 1000);
  const { get } = load({ config: { timezone: "UTC" }, data: { databases: { instances: [
    { id: "a", name: "Watchtower", detail: "primary", up: 0, series: {}, now: {} },
    { id: "b", name: "Hub", detail: "", up: 1, series: { cpu: [[t - 600, 0.9], [t - 300, 0.9], [t, 0.9]] }, now: { cpu: 0.9 } }] } } });
  const a = plain(get("alerts()"));
  const down = a.find((x) => x.id === "db.a.down"), cpu = a.find((x) => x.id.startsWith("db.b.cpu"));
  assert.equal(down.level, "red"); assert.equal(down.notify, true);
  assert.equal(cpu.level, "amber"); assert.match(cpu.text, /Hub database: CPU at 90%/);
});

// ── Sentry spikes ──────────────────────────────────────────────────────────
// hourly series ending at `now`: `days` of the given hourly values, oldest first
const hourly = (vals, now = 1794474000) => vals.map((v, i) => [now - (vals.length - 1 - i) * 3600, v]);
const quietWeek = (n = 168) => Array(n).fill(0);

test("sentry: a burst over its own usual rate is a spike; steady noise is not", () => {
  const { get } = load({ config: { timezone: "UTC" } });
  const spikes = (v) => plain(get(`sentrySpikes(${JSON.stringify(hourly(v))})`));
  // yesterday's BNPL status-refresh burst (real counts): quiet, then 10–15 an hour for 8 hours
  const bnpl = [...quietWeek(), 0, 0, 2, 10, 9, 13, 11, 9, 8, 15, 8, 4, 0, 2, 0, 0, 0, 0, 0, 1, 4, 4, 7, 4];
  const s = spikes(bnpl);
  assert.equal(s.length, 1);
  assert.equal(s[0].events, 83);                 // 13:00–20:59, the quiet hours either side left out
  assert.equal(s[0].peak[1], 15);
  assert.equal(s[0].active, false);
  assert.deepEqual(spikes([...Array(168).fill(5), ...Array(24).fill(7)]), []);   // 7 an hour, usually 5: not a spike
  assert.deepEqual(spikes([...quietWeek(), ...Array(23).fill(0), 9]), []);       // under minEvents
  assert.equal(spikes([...Array(168).fill(10), ...Array(23).fill(10), 40]).length, 0);   // 4× usual, not 5×
  assert.equal(spikes([...quietWeek(), ...Array(22).fill(0), 30, 25])[0].active, true);  // still going
  // a short burst on an earlier day inside a long spike's hours does not make it recurring
  const early = [...quietWeek()]; early[168 - 24 * 3 + 5] = 21; early[168 - 24 * 5 + 4] = 20;
  assert.equal(spikes([...early, 0, 0, 2, 10, 9, 13, 11, 9, 8, 15, 8, 4, 0, 2, 0, 0, 0, 0, 0, 1, 4, 4, 7, 4])[0].recurring, false);
});

test("sentry: the same burst at the same time each day is recurring, not announced", () => {
  const day = (v) => { const d = Array(24).fill(0); d[3] = v; return d; };
  const series = [...day(60), ...day(0), ...day(0), ...day(0), ...day(62), ...day(64), ...day(65), ...day(65)];
  const { get } = load({ config: { timezone: "UTC" }, data: { sentry: { org: "https://x.sentry.io", projects: [
    { slug: "watchtower", name: "Watchtower", id: "1", total: [], titles: [{ title: "Zoho request failed", events24h: 65, issues24h: 1, series: hourly(series) }] }] } } });
  const g = plain(get("sentrySignals()"));
  assert.equal(g[0].level, "info"); assert.equal(g[0].recurring, true);
  assert.ok(!plain(get("alerts()")).some((a) => /Zoho/.test(a.text)));
});

test("sentry: a payment spike happening now is red and notifies; a split error says so", () => {
  const now = Math.floor(Date.now() / 3600000) * 3600;
  const series = hourly([...quietWeek(), ...Array(21).fill(0), 12, 20, 18], now);
  const { get } = load({ config: { timezone: "UTC" }, data: { sentry: { org: "https://x.sentry.io", projects: [
    { slug: "watchtower", name: "Watchtower", id: "1", total: [], titles: [{ title: "ERR TITLE: FAILURE IN BNPL STATUS REFRESHING", events24h: 50, issues24h: 50, series }] }],
    escalating: [{ id: "QASIMAPLUS-3K", title: "NoMethodError", project: "qasimaplus", events: 48, users: 9, lastSeen: new Date().toISOString(), url: "u" }] } } });
  const g = plain(get("sentrySignals()"));
  assert.equal(g[0].kind, "spike"); assert.equal(g[0].level, "red"); assert.equal(g[0].split, 50);
  const a = plain(get("alerts()")).filter((x) => x.id.startsWith("sentry"));
  assert.equal(a[0].level, "red"); assert.equal(a[0].notify, true);
  assert.match(a[0].text, /^Watchtower errors spiking: FAILURE IN BNPL STATUS REFRESHING — 50 errors from/);
  assert.equal(a.length, 1);   // escalating with 9 users stays on the card, not in the alerts
});

test("sentry: Sentry's own verdicts interrupt only when they reach people or payments", () => {
  const iss = (id, users, title) => ({ id, title, project: "qasimaplus", events: 40, users, lastSeen: new Date().toISOString(), url: "u" });
  const { get } = load({ config: { timezone: "UTC" }, data: { sentry: { org: "https://x.sentry.io", projects: [],
    escalating: [iss("A", 12, "NoMethodError"), iss("B", 0, "Refund webhook failed"), iss("C", 2, "TypeError")],
    regressed: [iss("D", 50, "Cron failure: reconcile-rating-refunds")] } } });
  const ids = plain(get("alerts()")).filter((x) => x.id.startsWith("sentry")).map((x) => x.id.split(".")[2]);
  assert.deepEqual(ids.sort(), ["A", "B"]);
});

test("the briefing leads with what matters most, not with what came first", () => {
  const { get } = load({ config: { timezone: "UTC" }, data: {} });
  const order = plain(get(`[{ id: "src.github.stale", level: "amber" }, { id: "sentry.escalating.X.d", level: "amber" }, { id: "rev.Ola.30", level: "amber" },
    { id: "sentry.spike.wt.t.1", level: "amber" }, { id: "db.wt.cpu.d", level: "amber" }].sort((a, b) => alertWeight(b) - alertWeight(a)).map((a) => a.id.split(".")[0] + "." + a.id.split(".")[1])`));
  assert.deepEqual(order, ["sentry.spike", "db.wt", "rev.Ola", "sentry.escalating", "src.github"]);
});

test("sentry: a longer window finds an older spike; alerts still look at 24 hours", () => {
  const v = [...Array(168).fill(0), ...Array(168).fill(0)]; v[336 - 72] = 40;   // three days ago
  const { get } = load({ config: { timezone: "UTC" }, data: { sentry: { org: "https://x.sentry.io", projects: [
    { slug: "hub", name: "Hub", id: "3", total: [], titles: [{ title: "Provider dashboard refresh failed", events24h: 0, issues24h: 0, events7d: 40, issues7d: 1, series: hourly(v) }] }] } } });
  assert.equal(plain(get("sentrySignals(24)")).length, 0);
  const week = plain(get("sentrySignals(168)"));
  assert.equal(week.length, 1); assert.equal(week[0].events, 40); assert.equal(week[0].split, 0);
  assert.ok(!plain(get("alerts()")).some((a) => a.id.startsWith("sentry")));
});

test("every page's own script parses (a typo there blanks the live dashboard)", () => {
  const fs = require("node:fs"), path = require("node:path"), vm = require("node:vm");
  for (const page of ["dashboard.html", "palette.html", "settings.html", "widget.html"]) {
    const html = fs.readFileSync(path.join(__dirname, "..", "web", page), "utf8");
    for (const [, code] of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) assert.doesNotThrow(() => new vm.Script(code, { filename: page }), page);
  }
});
