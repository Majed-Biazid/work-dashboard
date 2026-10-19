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
