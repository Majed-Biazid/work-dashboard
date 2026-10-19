// Quick Tools (web/tools.js): the transforms and the clipboard router.
// Run: node --test
const test = require("node:test");
const assert = require("node:assert/strict");
const { load, plain } = require("./harness.js");

const page = (config = {}) => load({ config: { timezone: "UTC", ...config }, page: "palette.html" });
const tool = (get, id) => get(`TOOLS.find((t) => t.id === ${JSON.stringify(id)})`);
const run = async (get, id, ...inputs) => plain(await tool(get, id).run(inputs));
const value = (blocks, label) => (blocks.find((b) => b.label === label) || {}).value;
const notes = (blocks) => blocks.filter((b) => b.note).map((b) => b.note).join(" | ");

test("router: each kind of paste goes to the right tool first", () => {
  const { get } = page({ claude: { issueKeys: ["ABC"] } });
  const top = (t) => { const h = get(`detectAll(${JSON.stringify(t)})`)[0]; return h && (h.jump || h.tool.id); };
  const jwt = ["{\"alg\":\"HS256\"}", "{\"sub\":\"1\"}"].map((s) => Buffer.from(s).toString("base64url")).join(".") + ".sig";
  assert.equal(top(jwt), "jwt");
  assert.equal(top(`Bearer ${jwt}`), "jwt");
  assert.equal(top("ABC-123"), "linear");
  assert.equal(top("api#42"), "github");
  assert.equal(top(String(Math.floor(Date.now() / 1000))), "time");
  assert.equal(top('{"a": 1}'), "json");
  assert.equal(top("SA0380000000608010167519"), "ksa");
  assert.equal(top("0501234567"), "phone");
  assert.equal(top("*/15 * * * *"), "cron");
  assert.equal(top("https://example.com/a?b=1"), "url");
});

test("router: an unknown KEY-123 is never offered as a Linear jump", () => {
  const { get } = page({ claude: { issueKeys: ["ABC"] } });
  const hit = get('detectAll("SHA-256")').find((h) => h.jump === "linear");
  assert.ok(!hit || hit.score < 50);   // the palette shows only hits scoring 50+
});

test("JWT: decodes, and says when it expired", async () => {
  const { get } = page();
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const out = await run(get, "jwt", `${b64({ alg: "HS256" })}.${b64({ sub: "7", exp: 1_000_000_000 })}.abc`);
  assert.match(notes(out), /^Expired/);
  assert.deepEqual(JSON.parse(value(out, "Payload")), { sub: "7", exp: 1_000_000_000 });
  await assert.rejects(async () => tool(get, "jwt").run(["a.b.c.d.e"]), /encrypted JWT/);
});

test("JSON: long numbers are kept exactly", async () => {
  const { get } = page();
  const out = await run(get, "json", '{"id": 12345678901234567890, "n": 1.5}');
  assert.match(value(out, "Pretty"), /"id": 12345678901234567890,/);
  assert.equal(value(out, "Minified"), '{"id":12345678901234567890,"n":1.5}');
  assert.match(notes(out), /1 long number kept exactly/);
});

test("JSON: Python and Ruby literals become JSON, strings untouched", async () => {
  const { get } = page();
  const py = await run(get, "json", "{'a': None, 'b': True, 'c': 'None story', 'd': (1, 2), 'e': Decimal('10.50')}");
  assert.deepEqual(JSON.parse(value(py, "Minified")), { a: null, b: true, c: "None story", d: [1, 2], e: "10.50" });
  const rb = await run(get, "json", '{:a => 1, "b" => nil, c: :sym}');
  assert.deepEqual(JSON.parse(value(rb, "Minified")), { a: 1, b: null, c: "sym" });
  await assert.rejects(async () => tool(get, "json").run(["{nope"]));
});

test("Base64: UTF-8 round trip, URL-safe variant", async () => {
  const { get } = page();
  const enc = value(await run(get, "b64", "مرحبا?>"), "Encoded");
  assert.equal(value(await run(get, "b64", enc), "Decoded"), "مرحبا?>");
  assert.doesNotMatch(value(await run(get, "b64", "مرحبا?>"), "Encoded, URL-safe"), /[+/=]/);
});

test("URL: a repeated query key becomes a list", async () => {
  const { get } = page();
  const out = await run(get, "url", "https://user:pw@example.com/p?a=1&a=2&b=x");
  assert.deepEqual(JSON.parse(value(out, "Query as JSON")), { a: ["1", "2"], b: "x" });
  assert.match(notes(out), /user name and password/);
});

test("Saudi phone: any format, Arabic digits, and a dev test phone", async () => {
  const { get } = page({ devTestPhone: { fromUserId: "+9665550{id3}", prefix: "+9665550" } });
  assert.equal(value(await run(get, "phone", "0501234567"), "E.164"), "+966501234567");
  assert.equal(value(await run(get, "phone", "٠٥٠١٢٣٤٥٦٧"), "E.164"), "+966501234567");
  assert.equal(value(await run(get, "phone", "00966 50 123 4567"), "E.164"), "+966501234567");
  assert.equal(value(await run(get, "phone", "7"), "Test phone"), "+9665550007");
  assert.match(notes(await run(get, "phone", "+966555000123")), /Dev test number/);
  await assert.rejects(async () => tool(get, "phone").run(["12345"]));
});

test("Saudi IBAN, ID, VAT: check digits", async () => {
  const { get } = page();
  const iban = await run(get, "ksa", "SA03 8000 0000 6080 1016 7519");
  assert.match(notes(iban), /IBAN check \(mod 97\) is correct/);
  assert.match(value(iban, "Bank"), /Al Rajhi/);
  assert.match(notes(await run(get, "ksa", "SA0380000000608010167518")), /wrong/);
  assert.match(notes(await run(get, "ksa", "1000000008")), /Check digit is correct/);
  assert.match(notes(await run(get, "ksa", "1000000007")), /wrong/);
  assert.match(notes(await run(get, "ksa", "300000000000003")), /Looks like a VAT number/);
});

test("Timestamp: seconds, milliseconds, and an ISO time with a zone", async () => {
  const { get } = page();
  const s = await run(get, "time", "1700000000");
  assert.match(notes(s), /Unix seconds/);
  assert.equal(value(s, "ISO 8601 (UTC)"), "2023-11-14T22:13:20.000Z");
  assert.equal(value(await run(get, "time", "1700000000000"), "ISO 8601 (UTC)"), "2023-11-14T22:13:20.000Z");
  assert.equal(value(await run(get, "time", "2026-10-19 10:00+03"), "ISO 8601 (UTC)"), "2026-10-19T07:00:00.000Z");
  await assert.rejects(async () => tool(get, "time").run(["2026-02-30"]), /isn't a real date/);
});

test("Timestamp: a time without a zone is read in the configured timezone", async () => {
  const { get } = page({ timezone: "Asia/Riyadh" });
  assert.equal(value(await run(get, "time", "2026-10-19 10:00"), "ISO 8601 (UTC)"), "2026-10-19T07:00:00.000Z");
});

test("Hash & HMAC: known vectors, and a signature check", async () => {
  const { get } = page();
  const msg = "The quick brown fox jumps over the lazy dog";
  const out = await run(get, "hash", msg, "key", "sha256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
  assert.equal(value(out, "HMAC-SHA256 (hex)"), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
  assert.match(notes(out), /Signature matches/);
  assert.equal(value(out, "SHA-256"), "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592");
});

test("UUID / ULID: generated v7 carries its own time", async () => {
  const { get } = page();
  const v7 = get("uuidv7()");
  const out = await run(get, "uuid", v7);
  assert.equal(value(out, "Version"), "v7");
  assert.match(notes(out), /Created .* \((in )?\d+s( ago)?\)/);
  assert.equal(get("ulid()").length, 26);
});

test("Cron: next runs, impossible dates, and Quartz", () => {
  const { get } = page();
  const c = get('parseCron("*/15 * * * *")');
  const next = get("cronNext")(c, 3, 0).map(Number);
  assert.equal(next[1] - next[0], 15 * 60000);
  assert.equal(get("cronNext")(get('parseCron("0 0 31 2 *")'), 1, 0).length, 0);
  assert.throws(() => get('parseCron("0 0 12 * * ?")'), /Quartz/);
  assert.throws(() => get('parseCron("0 0 L * *")'), /Quartz syntax/);
});

test("Text: hidden characters, SMS parts", async () => {
  const { get } = page();
  const out = await run(get, "text", "a​b");
  assert.match(notes(out), /1 hidden character/);
  assert.equal(value(out, "Without hidden characters"), "ab");
  assert.equal(get('smsParts("x".repeat(161))').parts, 2);
  assert.equal(get('smsParts("م".repeat(70))').parts, 1);
});

test("Case, lines, diff", async () => {
  const { get } = page();
  assert.equal(value(await run(get, "case", "HTTPServerError"), "snake_case"), "http_server_error");
  const lines = await run(get, "lines", "1\n2\n2\n007");
  assert.equal(value(lines, "SQL IN list (unique)"), "('1', '2', '007')");
  assert.equal(value(await run(get, "lines", "3\n1\n2"), "SQL IN list (unique)"), "(3, 1, 2)");
  const d = plain(get('lineDiff("a\\nb\\nc", "a\\nc\\nd")'));
  assert.deepEqual([d.add, d.del], [1, 1]);
});

test("Standup notes: the spoken list and the checks", () => {
  const { get } = page();
  const md = "# Standup 2026-10-18\n_Covering Thursday_\n- Shipped the thing\n  with a detail\n- **Check** the deploy\n";
  const p = plain(get("parseNotes")(md));
  assert.equal(p.title, "Standup 2026-10-18");
  assert.deepEqual(p.items, [{ head: "Shipped the thing", detail: "with a detail" }]);
  assert.equal(p.checks[0].head, "Check");
  assert.equal(get("spokenList")(md), "- Shipped the thing\n  with a detail");
});
