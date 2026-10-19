// Quick Tools — every transform runs here, in this page. Nothing leaves the Mac:
// no network, no history on disk, no libraries from anywhere else.
//
// A tool is { id, name, hint, keys, inputs, detect(text) → 0..100, run(inputs) → blocks }.
// A block is { label, value } (copyable text), { label, html } (rendered), or
// { note, tone } (a one-line remark). run() may return a Promise.
// { primary: true } on a value block marks what ⌘↩ copies.
//
// detect() powers the clipboard router: when Quick Tools opens, the clipboard is
// scored against every tool and the best match is offered first.

// Times show in the configured timezone (config.timezone), else this Mac's.
const toolsTZ = () => (window.WD && WD.config && WD.config.timezone) || Intl.DateTimeFormat().resolvedOptions().timeZone;
const tzName = () => toolsTZ().split("/").pop().replace(/_/g, " ");
// How far a timezone is from UTC at a given moment, in ms (DST-safe).
function tzOffsetMs(tz, ms) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" })
    .formatToParts(ms).map((x) => [x.type, x.value]));
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - Math.floor(ms / 1000) * 1000;
}
const tzOffsetHours = () => tzOffsetMs(toolsTZ(), Date.now()) / 3600000;
// a wall-clock time in the configured timezone (given as if it were UTC) → the moment it names
const fromWall = (wall) => wall - tzOffsetMs(toolsTZ(), wall - tzOffsetMs(toolsTZ(), wall));
const toolsCfg = () => (window.WD && WD.config) || {};
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const fmtLocal = { format: (d) => new Intl.DateTimeFormat("en-GB", { timeZone: toolsTZ(), weekday: "short", day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false }).format(d) };
const fmtUTC = new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", weekday: "short", day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
const rel = (d) => {
  const s = Math.round((d - Date.now()) / 1000), a = Math.abs(s);
  const v = a < 60 ? `${a}s` : a < 3600 ? `${Math.round(a / 60)}m` : a < 86400 ? `${Math.round(a / 3600)}h` : `${Math.round(a / 86400)}d`;
  return s < 0 ? `${v} ago` : `in ${v}`;
};
const pretty = (o) => JSON.stringify(o, null, 2);

// ── shared codecs ──────────────────────────────────────────────────────────
const utf8 = { enc: (s) => new TextEncoder().encode(s), dec: (b) => new TextDecoder("utf-8", { fatal: true }).decode(b) };
const b64enc = (s) => { let bin = ""; utf8.enc(s).forEach((b) => (bin += String.fromCharCode(b))); return btoa(bin); };
const b64bytes = (s) => {
  let t = s.trim().replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/");
  while (t.length % 4) t += "=";
  return Uint8Array.from(atob(t), (c) => c.charCodeAt(0));
};
const b64dec = (s) => utf8.dec(b64bytes(s));
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const bytesB64 = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf)));
const hexBytes = (s) => { const h = s.replace(/\s+/g, ""); if (!/^([0-9a-f]{2})*$/i.test(h)) throw new Error("the hex key has an odd length or a character that isn't 0–9 / a–f"); return Uint8Array.from(h.match(/../g) || [], (b) => parseInt(b, 16)); };

// ── JSON that keeps long numbers ───────────────────────────────────────────
// A JavaScript number holds about 15–16 digits, so a longer one (an amount, a
// bigint id) would be rounded. Those stay as their original text: parsed as a
// marked string, then written back without quotes. The markers (U+E000 here,
// U+E001 in relaxedJSON) are private-use characters no real text contains.
const BIG = "\uE000";
const longNum = (n) => n.split(/[eE]/)[0].replace(/\D/g, "").replace(/^0+/, "").length >= 16;
const SOURCE_TEXT = (() => { let ok = false; try { JSON.parse("1", (k, v, c) => ((ok = !!(c && "source" in c)), v)); } catch (e) { /* old engine */ } return ok; })();
const parseViaSource = (s) => JSON.parse(s, (k, v, c) => (typeof v === "number" && c && longNum(c.source) ? BIG + c.source : v));
const parseViaText = (s) => JSON.parse(s.replace(/("(?:[^"\\]|\\[\s\S])*")|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g, (m, str) => (!str && longNum(m) ? `"${BIG}${m}"` : m)));
const parseJSON = (s) => (SOURCE_TEXT ? parseViaSource(s) : parseViaText(s));
const showBig = (s) => s.replace(new RegExp(`"${BIG}([-+.\\deE]+)"`, "g"), "$1");
const bigCount = (s) => (s.match(new RegExp(`"${BIG}`, "g")) || []).length;
const westernDigits = (s) => s.replace(/[\u0660-\u0669]/g, (c) => c.charCodeAt(0) - 0x660).replace(/[\u06F0-\u06F9]/g, (c) => c.charCodeAt(0) - 0x6f0);

// ── time ───────────────────────────────────────────────────────────────────
function parseTime(raw) {
  const t = westernDigits(raw.trim());
  if (!t || /^now$/i.test(t)) return { d: new Date(), how: "now" };
  if (/^-?\d+(\.\d+)?$/.test(t)) {
    const n = Number(t), digits = t.replace(/^-/, "").split(".")[0].length;
    if (digits <= 11) return { d: new Date(n * 1000), how: "Unix seconds" };
    if (digits <= 14) return { d: new Date(n), how: "Unix milliseconds" };
    if (digits <= 17) return { d: new Date(n / 1000), how: "Unix microseconds" };
    return { d: new Date(n / 1e6), how: "Unix nanoseconds" };
  }
  const m = t.match(ISO_LIKE);
  if (m) {
    const [, y, mo, da, h, mi = "0", s = "0", frac = "", zone] = m;
    const wall = Date.UTC(+y, mo - 1, +da, +(h || 0), +mi, +s, Math.round(Number("0" + frac) * 1000));
    const back = new Date(wall);
    if (back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== +da || +(h || 0) > 23 || +mi > 59 || +s > 59) throw new Error(`${t} isn't a real date or time`);
    if (!zone && h === undefined) return { d: back, how: "a date only, so midnight UTC (the ISO 8601 rule)" };
    if (!zone) return { d: new Date(fromWall(wall)), how: `${tzName()} time (no timezone given)` };
    const off = /^(Z|UTC|GMT)$/i.test(zone) ? 0 : (zone[0] === "-" ? -1 : 1) * (zone.slice(1, 3) * 60 + Number(zone.replace(/^[+-]\d\d:?/, "") || 0)) * 60000;
    return { d: new Date(wall - off), how: `a date with timezone ${/^Z$/i.test(zone) ? "UTC" : zone.toUpperCase()}` };
  }
  const p = Date.parse(t);
  if (isNaN(p)) return null;
  if (/\b(UTC|GMT)\b|Z$|[+-]\d\d:?\d\d\b/i.test(t)) return { d: new Date(p), how: "a date with timezone" };
  // no timezone: the engine read it as this Mac's time; read it as the configured one instead
  return { d: new Date(fromWall(p - new Date(p).getTimezoneOffset() * 60000)), how: `${tzName()} time (no timezone given)` };
}
// 2026-10-19 · 2026-10-19 10:00 · 2026-10-19T10:00:00.123456Z · …+03 · …+03:00 · … UTC (psql, Rails, Django)
const ISO_LIKE = /^(\d{4})-(\d\d)-(\d\d)(?:[T ](\d\d):(\d\d)(?::(\d\d)(\.\d+)?)?)?\s*(Z|UTC|GMT|[+-]\d\d(?::?\d\d)?)?$/i;
const hijriDate = (d) => {
  try {
    const f = (loc, wd) => new Intl.DateTimeFormat(loc, { timeZone: toolsTZ(), weekday: wd, day: "numeric", month: "long", year: "numeric" }).format(d);
    return `${f("en-u-ca-islamic-umalqura", "short")}\n${f("ar-SA-u-ca-islamic-umalqura-nu-latn", "long")}`;
  } catch (e) { return "(this Mac has no Umm al-Qura calendar)"; }
};
const timeBlocks = (d, primary) => [
  { label: tzName(), value: fmtLocal.format(d) },
  { label: "UTC", value: fmtUTC.format(d) },
  { label: "ISO 8601 (UTC)", value: d.toISOString(), primary: primary === "iso" },
  { label: "Unix seconds", value: String(Math.floor(d / 1000)), primary: primary === "unix" },
  { label: "Unix milliseconds", value: String(d.getTime()) },
  { label: "Hijri (Umm al-Qura)", value: hijriDate(d) },
];

// ── cron ───────────────────────────────────────────────────────────────────
const CRON_NAMES = { mon: "jan feb mar apr may jun jul aug sep oct nov dec".split(" "), dow: "sun mon tue wed thu fri sat".split(" ") };
function cronField(spec, min, max, names) {
  const set = new Set();
  for (let part of spec.toLowerCase().split(",")) {
    if (!part) throw new Error(`empty value in "${spec}" (a stray comma?)`);
    if (/^(\d*[lw]+|\d+#\d+|l-\d+)$/.test(part)) throw new Error(`"${part.toUpperCase()}" is Quartz syntax (L, W, #) — standard cron doesn't support it`);
    let step = 1;
    const stepped = part.includes("/");
    if (stepped) { const [a, b] = part.split("/"); part = a; step = Number(b); if (!step) throw new Error(`bad step in "${spec}"`); }
    let lo = min, hi = max;
    const val = (v) => { const i = names ? names.indexOf(v) : -1; const n = i >= 0 ? i + (names === CRON_NAMES.mon ? 1 : 0) : Number(v); if (isNaN(n)) throw new Error(`"${v}" is not a number`); return n; };
    if (part !== "*") {
      if (part.includes("-")) { const [a, b] = part.split("-"); lo = val(a); hi = val(b); }
      else { lo = val(part); hi = stepped ? max : lo; }
    }
    if (lo < min || hi > max || lo > hi) throw new Error(`"${part}" is outside ${min}–${max}`);
    for (let v = lo; v <= hi; v += step) set.add(max === 7 && v === 7 ? 0 : v);
  }
  return set;
}
const MACROS = { "@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *" };
function parseCron(expr) {
  const e = MACROS[expr.trim().toLowerCase()] || expr.trim();
  if (e.startsWith("@")) throw new Error(`${e} isn't a time schedule (use @hourly, @daily, @weekly, @monthly or @yearly)`);
  const f = e.split(/\s+/);
  if (f.length === 6 || f.length === 7) throw new Error(`${f.length} fields: this looks like Quartz / Spring / AWS cron (with seconds or a year) — paste the 5-field form (minute hour day month weekday)`);
  if (f.length !== 5) throw new Error(`expected 5 fields (minute hour day month weekday), got ${f.length}`);
  if (f[2] === "?") f[2] = "*";   // Quartz "no specific value"
  if (f[4] === "?") f[4] = "*";
  return {
    raw: f, min: cronField(f[0], 0, 59), hour: cronField(f[1], 0, 23), dom: cronField(f[2], 1, 31),
    mon: cronField(f[3], 1, 12, CRON_NAMES.mon), dow: cronField(f[4], 0, 7, CRON_NAMES.dow),
    domAny: f[2] === "*", dowAny: f[4] === "*",
  };
}
function cronNext(c, count, offsetHours) {
  // walk "schedule time" (UTC shifted by the schedule's offset) for up to 4 years,
  // skipping whole days and hours that can't match (so 29 February is found)
  const out = [], shift = offsetHours * 3600000, end = Date.now() + 4 * 366 * 86400000 + shift;
  let t = Math.floor(Date.now() / 60000) * 60000 + 60000 + shift;
  while (t < end && out.length < count) {
    const d = new Date(t), y = d.getUTCFullYear(), mo = d.getUTCMonth(), da = d.getUTCDate();
    const domOk = c.dom.has(da), dowOk = c.dow.has(d.getUTCDay());
    const dayOk = c.domAny && c.dowAny ? true : c.domAny ? dowOk : c.dowAny ? domOk : domOk || dowOk;
    if (!c.mon.has(mo + 1) || !dayOk) { t = Date.UTC(y, mo, da + 1); continue; }
    if (!c.hour.has(d.getUTCHours())) { t = Date.UTC(y, mo, da, d.getUTCHours() + 1); continue; }
    if (c.min.has(d.getUTCMinutes())) out.push(new Date(t - shift));
    t += 60000;
  }
  return out;
}
function cronWords(c) {
  const list = (set, names, fmt = (v) => v) => { const a = [...set].sort((x, y) => x - y); return a.map((v) => (names ? names[v] : fmt(v))).join(", "); };
  const f = c.raw;
  const part = (spec, all, every, set, names, fmt) => spec === "*" ? all : /^\*\/\d+$/.test(spec) ? `${every} ${spec.split("/")[1]}` : list(set, names, fmt);
  return [
    `minute: ${part(f[0], "every minute", "every", c.min)}`,
    `hour: ${part(f[1], "every hour", "every", c.hour, null, (v) => String(v).padStart(2, "0"))}`,
    `day of month: ${part(f[2], "any", "every", c.dom)}`,
    `month: ${part(f[3], "any", "every", c.mon, [null, ...CRON_NAMES.mon])}`,
    `weekday: ${part(f[4], "any", "every", c.dow, CRON_NAMES.dow)}`,
  ].join(" · ");
}

// ── diff (line LCS) ────────────────────────────────────────────────────────
function lineDiff(a, b) {
  const A = a.replace(/\r\n?/g, "\n").split("\n"), B = b.replace(/\r\n?/g, "\n").split("\n");
  if (A.length * B.length > 4e6) throw new Error("too large to diff here (over ~2000 × 2000 lines)");
  const n = A.length, m = B.length, L = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) L[i][j] = A[i] === B[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  const out = []; let i = 0, j = 0, add = 0, del = 0;
  while (i < n && j < m) {
    if (A[i] === B[j]) { out.push([" ", A[i]]); i++; j++; }
    else if (L[i + 1][j] >= L[i][j + 1]) { out.push(["-", A[i++]]); del++; }
    else { out.push(["+", B[j++]]); add++; }
  }
  while (i < n) { out.push(["-", A[i++]]); del++; }
  while (j < m) { out.push(["+", B[j++]]); add++; }
  return { out, add, del };
}

// ── Python / Ruby literal → JSON ───────────────────────────────────────────
const PY_ESC = { n: "\n", t: "\t", r: "\r", 0: "\0", b: "\b", f: "\f", a: "\x07", v: "\v" };
const unescapeLiteral = (body) => body.replace(/\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|[\s\S])/g, (m, e) => (e.length > 1 ? String.fromCodePoint(parseInt(e.slice(1), 16)) : PY_ESC[e] ?? e));
const pad2 = (v) => String(v).padStart(2, "0");
function pyDate(kind, args) {
  // datetime.datetime(2026, 1, 1, 9, 30[, s, µs][, tzinfo=…utc]) / datetime.date(2026, 1, 1) → ISO text
  const n = args.split(",").map((a) => a.trim()).filter((a) => /^\d+$/.test(a)).map(Number);
  let iso = `${n[0]}-${pad2(n[1])}-${pad2(n[2])}`;
  if (kind === "datetime") iso += `T${pad2(n[3] || 0)}:${pad2(n[4] || 0)}:${pad2(n[5] || 0)}${n[6] ? "." + String(n[6]).padStart(6, "0") : ""}${/utc/i.test(args) ? "Z" : ""}`;
  return iso;
}
function relaxedJSON(s) {
  // Strings are set aside first and only the code around them is rewritten, so
  // 'None' or 'True story' inside a string stays exactly as written.
  const strs = [], keep = (v) => `\uE001${strs.push(v) - 1}\uE001`;
  const code = s.trim().replace(/'(?:[^'\\]|\\[\s\S])*'|"(?:[^"\\]|\\[\s\S])*"/g, (m) => keep(unescapeLiteral(m.slice(1, -1))))
    .replace(/#[^\n]*/g, "")                                    // Python comments
    .replace(/\b[uUbB](?=\uE001)/g, "")                          // u'…' and b'…'
    .replace(/\b(?:Decimal|UUID|ObjectId)\(\s*(\uE001\d+\uE001|-?[\d.]+)\s*\)/g, "$1")   // Decimal('10.50') → "10.50", exact
    .replace(/\bdatetime\.(datetime|date)\(([^()]*)\)/g, (m, kind, args) => keep(pyDate(kind, args)))
    .replace(/\(/g, "[").replace(/\)/g, "]")                    // tuples → arrays
    .replace(/:(\w+[?!]?)\s*=>/g, '"$1":')                      // Ruby :sym => v
    .replace(/(^|[\s{,[]):(?=\uE001)/g, "$1")                   // Ruby :"quoted sym" => v
    .replace(/=>/g, ":")                                        // Ruby "k" => v
    .replace(/(^|[\s{,[]):(?!(?:true|false|nil)\b)([A-Za-z_]\w*[?!]?)/g, '$1"$2"')   // Ruby :sym values
    .replace(/\bNone\b|\bnil\b/g, "null").replace(/\bTrue\b/g, "true").replace(/\bFalse\b/g, "false")
    .replace(/(^|[{,]\s*)([A-Za-z_]\w*)\s*:(?!:)/g, '$1"$2":')  // bare keys (Ruby 1.9 / JS)
    .replace(/([{,]\s*)(-?\d+(?:\.\d+)?)\s*:/g, '$1"$2":')      // Python number keys
    .replace(/,\s*([}\]])/g, "$1");                             // trailing commas
  return parseJSON(code.replace(/\uE001(\d+)\uE001/g, (m, i) => JSON.stringify(strs[i])));
}
const sortKeys = (v) => Array.isArray(v) ? v.map(sortKeys) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])])) : v;

// ── text facts ─────────────────────────────────────────────────────────────
const HIDDEN = { "\u200B": "zero-width space", "\u200C": "zero-width non-joiner", "\u200D": "zero-width joiner", "\u200E": "left-to-right mark", "\u200F": "right-to-left mark",
  "\u202A": "LTR embedding", "\u202B": "RTL embedding", "\u202C": "pop directional", "\u202D": "LTR override", "\u202E": "RTL override (can disguise text)",
  "\u2066": "LTR isolate", "\u2067": "RTL isolate", "\u2068": "first-strong isolate", "\u2069": "pop isolate", "\uFEFF": "byte-order mark", "\u00A0": "non-breaking space", "\u061C": "Arabic letter mark",
  "\u2028": "line separator", "\u2029": "paragraph separator", "\u00AD": "soft hyphen", "\u2060": "word joiner", "\u180E": "Mongolian vowel separator", "\u3164": "Hangul filler (looks blank)" };
const isTag = (ch) => { const cp = ch ? ch.codePointAt(0) : 0; return cp >= 0xe0000 && cp <= 0xe007f; };
const EMOJI = /\p{Extended_Pictographic}|\uFE0F|[\u{1F3FB}-\u{1F3FF}]/u;
// what hides at chars[i], or null. A joiner inside an emoji (\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67) and the tags of
// a flag (\uD83C\uDFF4 + tags) are part of the emoji, not hidden.
function hiddenAt(chars, i) {
  const ch = chars[i];
  if (ch === "\u200D" && EMOJI.test(chars[i - 1] || "") && EMOJI.test(chars[i + 1] || "")) return null;
  if (isTag(ch)) { let j = i - 1; while (j >= 0 && isTag(chars[j])) j--; return chars[j] === "\u{1F3F4}" ? null : "tag character (invisible; can smuggle text)"; }
  return HIDDEN[ch] || null;
}
const GSM7 = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà^{}\\[~]|€";
function smsParts(s) {
  const gsm = [...s].every((ch) => GSM7.includes(ch));
  const units = gsm ? [...s].reduce((n, ch) => n + ("^{}\\[~]|€".includes(ch) ? 2 : 1), 0) : s.length;
  const [one, multi] = gsm ? [160, 153] : [70, 67];
  return { gsm, units, parts: units <= one ? (units ? 1 : 0) : Math.ceil(units / multi), per: units <= one ? one : multi };
}

// ── phone ──────────────────────────────────────────────────────────────────
// mobiles 5X + 7 digits; landlines 01X + 7; unified 9200 + 5; toll-free 800 + 7
function saudiNumber(raw) {
  if (/[A-Za-z]/.test(raw.replace(/^\s*tel:/i, ""))) return null;
  let d = westernDigits(raw).replace(/[^\d+]/g, "");
  if (d.startsWith("00")) d = "+" + d.slice(2);
  d = d.replace(/^\+?966/, "").replace(/^0/, "");
  const kind = /^5\d{8}$/.test(d) ? "mobile" : /^1[1-7]\d{7}$/.test(d) ? "landline" : /^9200\d{5}$/.test(d) ? "unified" : /^800\d{7}$/.test(d) ? "toll-free" : null;
  return kind && { e164: "+966" + d, kind };
}
const saudiPhone = (raw) => { const n = saudiNumber(raw); return n && n.kind === "mobile" ? n.e164 : null; };
// the operator each prefix was first given to; numbers can be ported since
const MOBILE_PREFIX = { 50: "STC", 53: "STC", 55: "STC", 54: "Mobily", 56: "Mobily", 58: "Zain", 59: "Zain", 57: "Virgin / Lebara / Salam" };
const AREA = { 11: "Riyadh", 12: "Makkah, Jeddah, Taif", 13: "Eastern Province", 14: "Madinah, Tabuk, the north", 16: "Qassim, Ha'il", 17: "Asir, Jazan, Najran" };

// ── Saudi IBAN, National ID / Iqama, VAT ───────────────────────────────────
const luhnOk = (s) => [...s].reverse().reduce((n, c, i) => { let d = +c; if (i % 2) { d *= 2; if (d > 9) d -= 9; } return n + d; }, 0) % 10 === 0;
const saudiIdOk = (s) => /^[12]\d{9}$/.test(s) && luhnOk(s);   // the NIC check digit is Luhn
const ibanOk = (s) => { let m = 0; for (const ch of (s.slice(4) + s.slice(0, 4)).replace(/[A-Z]/g, (c) => c.charCodeAt(0) - 55)) m = (m * 10 + +ch) % 97; return m === 1; };
const VAT_NO = /^3\d{13}3$/;
const SA_BANKS = { "05": "Alinma Bank", 10: "Saudi National Bank (ex-NCB)", 15: "Bank Albilad", 20: "Riyad Bank", 30: "Arab National Bank", 40: "Saudi National Bank (ex-Samba)",
  45: "Saudi Awwal Bank (SAB)", 50: "Saudi Awwal Bank (ex-Alawwal)", 55: "Banque Saudi Fransi", 60: "Bank AlJazira", 65: "Saudi Investment Bank", 80: "Al Rajhi Bank" };
const idText = (t) => westernDigits(t.trim()).replace(/[\s-]/g, "").toUpperCase();

// ── uuid / ulid ────────────────────────────────────────────────────────────
function uuidv7() {
  const b = crypto.getRandomValues(new Uint8Array(16)), ms = Date.now();
  for (let i = 0; i < 6; i++) b[i] = Math.floor(ms / 2 ** (8 * (5 - i))) & 0xff;
  b[6] = (b[6] & 0x0f) | 0x70; b[8] = (b[8] & 0x3f) | 0x80;
  const h = hex(b); return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
function ulid() {
  // 48-bit milliseconds (10 characters) + 80 random bits (16 characters)
  const ms = Date.now(), bits = [...crypto.getRandomValues(new Uint8Array(10))].map((b) => b.toString(2).padStart(8, "0")).join("");
  let s = "";
  for (let i = 0; i < 10; i++) s += CROCKFORD[Math.floor(ms / 32 ** (9 - i)) % 32];
  for (let i = 0; i < 80; i += 5) s += CROCKFORD[parseInt(bits.slice(i, i + 5), 2)];
  return s;
}

// ── Linear / GitHub jumps ──────────────────────────────────────────────────
// KEY-123 is a Linear issue only when KEY is one of your teams (config.claude.issueKeys);
// otherwise SHA-256, UTF-8 or HTTP-200 would jump to Linear.
const LINEAR_KEY = /^([A-Za-z][A-Za-z0-9]{1,6})-(\d{1,6})$/;
const issueKeys = () => ((toolsCfg().claude && toolsCfg().claude.issueKeys) || []).map((k) => k.toUpperCase());
const REPO_REF = /^([\w.-]+)#(\d+)$/;

// ── the tools ──────────────────────────────────────────────────────────────
const TOOLS = [
  {
    id: "jwt", name: "JWT decoder", hint: "Header, payload, and when it expires — in your time", keys: "jwt token bearer auth otp decode",
    inputs: ["Token"],
    detect: (t) => /^(Bearer\s+)?eyJ[\w-]+\.eyJ[\w-]+\.[\w-]*$/i.test(t.trim()) ? 100 : 0,
    run([t]) {
      const parts = t.trim().replace(/^Bearer\s+/i, "").split(".");
      if (parts.length === 5) throw new Error("this is an encrypted JWT (JWE, 5 parts) — it can't be read without the key");
      if (parts.length < 2) throw new Error("a JWT has three parts separated by dots");
      let header, payload;
      try { header = parseJSON(b64dec(parts[0])); payload = parseJSON(b64dec(parts[1])); }
      catch (e) { throw new Error("not a JWT: the first two parts must be Base64URL-encoded JSON"); }
      const blocks = [];
      // the spec says seconds; some issuers send milliseconds
      const when = (v) => new Date(v > 1e11 ? v : v * 1000), msNote = (v) => (v > 1e11 ? " — this looks like milliseconds; the JWT spec uses seconds" : "");
      if (payload.exp) {
        const d = when(payload.exp), expired = d < new Date();
        blocks.push({ note: `${expired ? "Expired" : "Valid until"} ${fmtLocal.format(d)} ${tzName()} (${rel(d)})${msNote(payload.exp)}`, tone: expired ? "bad" : "good" });
      }
      for (const k of ["iat", "nbf"]) if (payload[k]) blocks.push({ note: `${k === "iat" ? "Issued" : "Not before"} ${fmtLocal.format(when(payload[k]))} ${tzName()} (${rel(when(payload[k]))})${msNote(payload[k])}` });
      blocks.push({ label: "Payload", value: showBig(pretty(payload)), primary: true }, { label: "Header", value: showBig(pretty(header)) });
      blocks.push({ note: `Signature not checked (${parts[2] ? parts[2].length + " chars" : "none"}) — decoding only.` });
      return blocks;
    },
  },
  {
    id: "time", name: "Timestamp converter", hint: "Epoch (s/ms/µs) or a date → your time, UTC, ISO, Hijri", keys: "time epoch unix timestamp date utc local iso hijri umm al-qura",
    inputs: ["Epoch or date (empty = now)"],
    detect: (t) => {
      const x = westernDigits(t.trim());
      if (/^1\d{9}(\d{3}|\d{6}|\d{9})?$/.test(x)) {
        // a 10-digit number near today is a timestamp even when it also passes the
        // National ID check digit (about 1 in 10 do); any other valid ID goes to the ID tool first
        const near = Math.abs(Number(x.slice(0, 10)) * 1000 - Date.now()) < 3 * 365 * 86400000;
        return near ? 97 : saudiIdOk(x) ? 90 : 95;
      }
      return /^\d{4}-\d\d-\d\d([T ]\d\d:\d\d|$)/.test(x) ? 80 : 0;
    },
    run([t]) {
      const p = parseTime(t);
      if (!p) throw new Error("not a timestamp or a date I can read");
      return [{ note: `Read as ${p.how} · ${rel(p.d)}` }, ...timeBlocks(p.d, /^Unix/.test(p.how) ? "iso" : "unix")];
    },
  },
  {
    id: "json", name: "JSON formatter", hint: "Pretty, minified, sorted — also turns Python dicts and Ruby hashes into JSON", keys: "json format pretty minify sort python dict ruby hash validate",
    inputs: ["JSON (or a Python dict / Ruby hash)"],
    detect: (t) => { const x = t.trim(); if (!/^[[{]/.test(x)) return 0; try { JSON.parse(x); return 85; } catch (e) { return /=>|\bNone\b|\bTrue\b|'/.test(x) ? 70 : 40; } },
    run([t]) {
      let v, note = null;
      try { v = parseJSON(t); }
      catch (e) {
        try { v = relaxedJSON(t); note = { note: "Converted from a Python / Ruby literal", tone: "good" }; }
        catch (e2) {
          const literal = /=>|\b(None|True|False|nil)\b|'|\(/.test(t);
          throw new Error(literal ? `Not valid JSON, and not a Python / Ruby literal I can convert: ${e2.message}` : `Not valid JSON: ${e.message.replace(/^JSON Parse error: /, "")}`);
        }
      }
      const min = JSON.stringify(v), n = bigCount(min);
      return [note, n ? { note: `${n} long number${n === 1 ? "" : "s"} kept exactly as written (JavaScript would round ${n === 1 ? "it" : "them"})`, tone: "good" } : null,
        { label: "Pretty", value: showBig(pretty(v)), primary: true }, { label: "Minified", value: showBig(min) }, { label: "Sorted keys", value: showBig(pretty(sortKeys(v))) }].filter(Boolean);
    },
  },
  {
    id: "b64", name: "Base64", hint: "Encode / decode, URL-safe too — Arabic-safe (UTF-8)", keys: "base64 b64 encode decode atob btoa",
    inputs: ["Text or Base64"],
    detect: (t) => { const x = t.trim(); if (x.length < 12 || !/^[A-Za-z0-9+/_-]+={0,2}$/.test(x) || /^\d+$/.test(x)) return 0; try { const d = b64dec(x); return /[\x00-\x08\x0e-\x1f]/.test(d) ? 0 : 60; } catch (e) { return 0; } },
    run([t]) {
      const out = [];
      let bytes = null, text = null;
      try { bytes = b64bytes(t); text = utf8.dec(bytes); } catch (e) { /* not Base64, or not text */ }
      if (text !== null) out.push({ label: "Decoded", value: text, primary: true });
      else if (bytes) out.push({ note: `Decodes to ${bytes.length} bytes that aren't text (a key, a signature, a file?) — shown as hex` }, { label: "Decoded, as hex", value: hex(bytes) });
      else out.push({ note: "Not Base64 — showing the encoding only" });
      const enc = b64enc(t);
      out.push({ label: "Encoded", value: enc, primary: text === null }, { label: "Encoded, URL-safe", value: enc.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "") });
      return out;
    },
  },
  {
    id: "url", name: "URL inspector", hint: "Split a URL; query string ↔ JSON; encode / decode", keys: "url query params encode decode percent uri link utm",
    inputs: ["URL or text"],
    detect: (t) => /^https?:\/\/\S+$/.test(t.trim()) ? 75 : /%[0-9A-Fa-f]{2}/.test(t) ? 60 : 0,
    run([t]) {
      const out = [], x = t.trim();
      let u = null;
      try { u = new URL(x); }
      catch (e) {
        if (/^[\w-]+(\.[\w-]+)+(:\d+)?([/?#]|$)/.test(x)) try { u = new URL("https://" + x); out.push({ note: "No scheme — read as https://" }); } catch (e2) { /* not a URL */ }
      }
      let decoded = null;
      try { decoded = decodeURIComponent(t.replace(/\+/g, " ")); } catch (e) { /* malformed % */ }
      if (u) {
        if (u.username || u.password) out.push({ note: `It has a ${u.password ? "user name and password" : "user name"} in it — don't paste it anywhere shared`, tone: "bad" });
        if (u.host) out.push({ label: "Host", value: u.host });
        let path = u.pathname;
        try { path = decodeURIComponent(u.pathname); } catch (e) { /* keep raw */ }
        out.push({ label: "Path", value: u.pathname });
        if (path !== u.pathname) out.push({ label: "Path, decoded (%2F becomes / here — the server sees the raw path)", value: path });
        const q = Object.create(null);   // a key that repeats (a=1&a=2) becomes a list
        for (const [k, v] of u.searchParams) q[k] = Object.prototype.hasOwnProperty.call(q, k) ? [].concat(q[k], v) : v;
        if (/%(?![0-9A-Fa-f]{2})/.test(u.search)) out.push({ note: "The query has a broken %-escape — shown as � below", tone: "bad" });
        if (Object.keys(q).length) out.push({ label: "Query as JSON", value: pretty(q), primary: true });
        if (u.hash) { let f = u.hash.slice(1); try { f = decodeURIComponent(f); } catch (e) { /* keep raw */ } out.push({ label: "Fragment", value: f }); }
      }
      if (decoded !== null) out.push({ label: "Decoded", value: decoded, primary: !out.some((b) => b.primary) });
      else out.push({ note: "Has a broken %-escape, so there's no decoded version", tone: "bad" });
      out.push({ label: "Encoded (component)", value: encodeURIComponent(t), primary: !out.some((b) => b.primary) });
      out.push({ label: "HTML-escaped", value: esc(t) });
      return out;
    },
  },
  {
    id: "phone", name: "Saudi phone", hint: "Any format → +966…; a dev test phone from a dev user id (if configured)", keys: "phone mobile saudi 966 05 normalize e164 otp test dev landline",
    inputs: ["Phone number, or a dev user id"],
    detect: (t) => {
      const n = saudiNumber(t), digits = westernDigits(t).replace(/\D/g, "");
      if (!n || digits.length < 9) return 0;
      return n.kind === "mobile" ? 90 : /^(0|966|00966)/.test(digits) ? 70 : 0;
    },
    run([t]) {
      const x = westernDigits(t.trim());
      // config.devTestPhone = {fromUserId: "+9665550{id3}", prefix: "+9665550", note: "…"}
      const dev = toolsCfg().devTestPhone || null;
      if (dev && dev.fromUserId && /^\d{1,3}$/.test(x)) {
        const p = dev.fromUserId.replace("{id3}", x.padStart(3, "0")).replace("{id}", x);
        return [{ note: `Test phone for dev user ${x}${dev.note ? " — " + dev.note : ""}`, tone: "good" }, { label: "Test phone", value: p, primary: true }];
      }
      const n = saudiNumber(x);
      if (!n) throw new Error("not a Saudi number (a mobile is 5 + 8 digits, with or without 0 / 966 / +966)");
      const p = n.e164, out = [{ label: "E.164", value: p, primary: true }];
      if (n.kind === "mobile") {
        const op = MOBILE_PREFIX[p.slice(4, 6)];
        out.unshift({ note: op ? `Mobile · prefix first given to ${op} (numbers can be ported)` : `05${p[5]} isn't a mobile prefix in common use — check the number`, tone: op ? null : "bad" });
        out.push({ label: "Local", value: "0" + p.slice(4) });
      } else if (n.kind === "landline") {
        out.unshift({ note: `Landline · area 0${p.slice(4, 6)} ${AREA[p.slice(4, 6)] || ""}`.trim() });
        out.push({ label: "Local", value: "0" + p.slice(4) });
      } else out.unshift({ note: `${n.kind === "unified" ? "Unified number (9200)" : "Toll-free (800)"} — usually can't be called from outside Saudi Arabia, so it gets no OTP SMS`, tone: "bad" });
      out.push({ label: "Digits only", value: p.slice(1) });
      if (dev && dev.prefix && p.startsWith(dev.prefix)) out.unshift({ note: `Dev test number${dev.note ? " — " + dev.note : ""}`, tone: "good" });
      return out;
    },
  },
  {
    id: "ksa", name: "Saudi IBAN, ID, VAT", hint: "Checks a Saudi IBAN (and names its bank), a National ID / Iqama, or a VAT number", keys: "iban bank account national id iqama nid resident vat zatca tax saudi check digit",
    inputs: ["IBAN, National ID / Iqama, or VAT number"],
    detect: (t) => { const x = idText(t); return /^SA\d{22}$/.test(x) && ibanOk(x) ? 96 : saudiIdOk(x) ? 96 : VAT_NO.test(x) ? 85 : 0; },
    run([t]) {
      const x = idText(t), verdict = (ok, what) => ({ note: ok ? `${what} is correct` : `${what} is wrong — a typo, or a made-up number`, tone: ok ? "good" : "bad" });
      if (/^SA/.test(x)) {
        if (!/^SA\d{22}$/.test(x)) throw new Error(`a Saudi IBAN is SA + 22 digits (24 characters); this has ${x.length}`);
        const code = x.slice(4, 6);
        return [verdict(ibanOk(x), "IBAN check (mod 97)"), { label: "IBAN", value: x, primary: true }, { label: "As printed", value: x.replace(/(.{4})/g, "$1 ").trim() },
          { label: "Bank", value: `${code} · ${SA_BANKS[code] || "a bank code not in this list"}` }, { label: "Account number", value: x.slice(6) }];
      }
      if (/^[12]\d{9}$/.test(x)) return [verdict(luhnOk(x), "Check digit"), { label: "Type", value: x[0] === "1" ? "Saudi National ID (citizen)" : "Iqama (resident)" }, { label: "Number", value: x, primary: true }];
      if (/^\d{15}$/.test(x)) {
        const ok = VAT_NO.test(x);
        return [{ note: ok ? "Looks like a VAT number: 15 digits, starts and ends with 3 (a format check — ZATCA publishes no check digit)" : "Not a VAT number: it must start and end with 3", tone: ok ? "good" : "bad" }, { label: "VAT number", value: x, primary: true }];
      }
      throw new Error("not a Saudi IBAN (SA + 22 digits), National ID / Iqama (10 digits from 1 or 2), or VAT number (15 digits)");
    },
  },
  {
    id: "text", name: "Text inspector", hint: "Length, bytes, SMS parts, hidden characters, Arabic digits", keys: "text count length sms arabic hidden characters rtl bidi bytes graphemes digits",
    inputs: ["Text"],
    detect: (t) => { const chars = [...t]; return chars.some((c, i) => hiddenAt(chars, i)) ? 70 : /[\u0600-\u06FF]/.test(t) ? 45 : 5; },
    run([t]) {
      const graphemes = typeof Intl.Segmenter === "function" ? [...new Intl.Segmenter("ar", { granularity: "grapheme" }).segment(t)].length : [...t].length;
      const sms = smsParts(t), chars = [...t];
      const hidden = [];
      chars.forEach((ch, i) => { const what = hiddenAt(chars, i); if (what) hidden.push(`#${i + 1} U+${ch.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")} ${what}`); });
      const out = [{ label: "Counts", value: `${graphemes} characters · ${chars.length} code points · ${utf8.enc(t).length} UTF-8 bytes · ${t.split(/\s+/).filter(Boolean).length} words · ${t.split("\n").length} lines` },
        { label: "SMS", value: `${sms.parts} part${sms.parts === 1 ? "" : "s"} · ${sms.units} ${sms.gsm ? "GSM-7" : "UCS-2 (Arabic / emoji)"} units · ${sms.per} per part` }];
      if (hidden.length) out.push({ note: `${hidden.length} hidden character${hidden.length === 1 ? "" : "s"}`, tone: "bad" }, { label: "Hidden characters", value: hidden.join("\n") },
        { label: "Without hidden characters", value: chars.filter((ch, i) => !hiddenAt(chars, i) || ch === "\u00A0").join("").replace(/\u00A0/g, " "), primary: true });
      if (/[\u0660-\u0669\u06F0-\u06F9]/.test(t)) out.push({ label: "Arabic digits → 0–9", value: westernDigits(t), primary: !hidden.length });
      if (!out.some((b) => b.primary)) out[0].primary = true;
      return out;
    },
  },
  {
    id: "hash", name: "Hash & HMAC", hint: "SHA-1 / 256 / 512, and HMAC with a key — e.g. checking a webhook signature", keys: "hash sha sha256 sha1 sha512 hmac signature checksum webhook verify",
    inputs: ["Text", "HMAC key (optional) — as text, or hex:… / base64:…", "Signature to check (optional) — hex or Base64"],
    detect: () => 0,
    async run([t, key, sig]) {
      const data = utf8.enc(t);
      const out = [];
      if (key) {
        const kb = /^hex:/i.test(key) ? hexBytes(key.slice(4)) : /^base64:/i.test(key) ? b64bytes(key.slice(7)) : utf8.enc(key);
        const macs = [];
        for (const alg of ["SHA-256", "SHA-512"]) {
          const k = await crypto.subtle.importKey("raw", kb, { name: "HMAC", hash: alg }, false, ["sign"]);
          const s = await crypto.subtle.sign("HMAC", k, data), name = `HMAC-${alg.replace("-", "")}`;
          macs.push({ label: `${name} (hex)`, value: hex(s), primary: alg === "SHA-256" }, { label: `${name} (Base64)`, value: bytesB64(s) });
        }
        if (sig && sig.trim()) {
          // GitHub sends "sha256=…", Stripe "v1=…"; compare hex without case, Base64 URL-safe or not
          const norm = (s) => (/^[0-9a-f]+$/i.test(s) ? s.toLowerCase() : s.replace(/=+$/, "").replace(/-/g, "+").replace(/_/g, "/"));
          const want = norm(sig.trim().replace(/^(sha256|sha512|v1)=/i, "")), hit = macs.find((m) => norm(m.value) === want);
          out.push(hit ? { note: `Signature matches ${hit.label}`, tone: "good" } : { note: "Signature doesn't match — check the key, and that the text is the raw body, byte for byte", tone: "bad" });
        }
        out.push(...macs);
      } else if (sig && sig.trim()) out.push({ note: "Add the HMAC key to check the signature" });
      for (const alg of ["SHA-256", "SHA-1", "SHA-512"]) out.push({ label: alg, value: hex(await crypto.subtle.digest(alg, data)), primary: !key && alg === "SHA-256" });
      return out;
    },
  },
  {
    id: "uuid", name: "UUID / ULID", hint: "Generate v4, v7 and ULID; read the time inside a v1, v7 or ULID", keys: "uuid guid ulid v4 v7 generate random id",
    inputs: ["UUID or ULID to inspect (empty = generate)"],
    detect: (t) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(t.trim()) ? 85 : /^[0-7][0-9A-HJKMNP-TV-Z]{25}$/.test(t.trim()) ? 70 : 0,
    run([t]) {
      const x = t.trim().replace(/^urn:uuid:/i, "").replace(/^\{(.*)\}$/, "$1");
      if (!x) return [{ label: "UUID v4", value: crypto.randomUUID(), primary: true }, { label: "UUID v7 (time-ordered)", value: uuidv7() }, { label: "ULID", value: ulid() },
        { label: "5 × v4", value: Array.from({ length: 5 }, () => crypto.randomUUID()).join("\n") }];
      if (/^[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}$/i.test(x)) {
        const h = x.replace(/-/g, "").toLowerCase(), canon = `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
        if (/^0+$/.test(h)) return [{ label: "Version", value: "Nil UUID (all zeros)" }, { label: "Canonical", value: canon, primary: true }];
        const v = h[12], out = [{ label: "Version", value: `v${v}${/[89ab]/.test(h[16]) ? "" : " (not the standard RFC 9562 variant)"}` }, { label: "Canonical", value: canon, primary: true }];
        const created = (ms) => out.push({ note: `Created ${fmtLocal.format(new Date(ms))} ${tzName()} (${rel(new Date(ms))})` });
        if (v === "7") created(parseInt(h.slice(0, 12), 16));
        if (v === "1") created(Number((BigInt("0x" + h.slice(13, 16) + h.slice(8, 12) + h.slice(0, 8)) - 122192928000000000n) / 10000n));   // 100 ns ticks since 1582
        return out;
      }
      const u = x.toUpperCase();
      if (!/^[0-7][0-9A-HJKMNP-TV-Z]{25}$/.test(u)) throw new Error("not a UUID (8-4-4-4-12 hex) or a ULID (26 Crockford characters, starting 0–7)");
      const ms = [...u.slice(0, 10)].reduce((n, c) => n * 32 + CROCKFORD.indexOf(c), 0);
      return [{ label: "Type", value: "ULID" }, { label: "Canonical", value: u, primary: true }, { note: `Created ${fmtLocal.format(new Date(ms))} ${tzName()} (${rel(new Date(ms))})` }];
    },
  },
  {
    id: "case", name: "Case converter", hint: "snake_case ↔ camelCase ↔ kebab-case ↔ PascalCase — Python / Ruby / JS names", keys: "case snake camel kebab pascal title constant naming",
    inputs: ["Name or phrase"],
    detect: (t) => /^[A-Za-z][A-Za-z0-9]*([_-][A-Za-z0-9]+)+$|^[a-z]+([A-Z][a-z0-9]*)+$/.test(t.trim()) ? 35 : 0,
    run([t]) {
      const words = t.trim().replace(/([A-Z])(?=[A-Z][a-z])/g, "$1 ").replace(/([a-z0-9])([A-Z])/g, "$1 $2")   // HTTPServer → HTTP Server
        .replace(/[_\-.\s]+/g, " ").trim().toLowerCase().split(" ").filter(Boolean);
      const cap = (w) => w[0].toUpperCase() + w.slice(1);
      return [
        { label: "snake_case", value: words.join("_"), primary: true }, { label: "camelCase", value: words.map((w, i) => (i ? cap(w) : w)).join("") },
        { label: "PascalCase", value: words.map(cap).join("") }, { label: "kebab-case", value: words.join("-") },
        { label: "CONSTANT_CASE", value: words.join("_").toUpperCase() }, { label: "Title Case", value: words.map(cap).join(" ") },
      ];
    },
  },
  {
    id: "lines", name: "Lines → SQL IN / sort / unique", hint: "A pasted column → ('a','b') for SQL, a JSON array, sorted, unique, counted", keys: "lines list sql in sort unique dedupe count array ids column",
    inputs: ["One value per line"],
    detect: (t) => { const l = t.trim().split("\n"); return l.length >= 3 && l.every((x) => x.trim().length < 80) ? 30 : 0; },
    run([t]) {
      const lines = t.split("\n").map((x) => x.trim()).filter(Boolean);
      // numbers only when every value is a plain number; "0501234567" keeps its zero as text
      const uniq = [...new Set(lines)], nums = uniq.every((x) => /^-?\d+(\.\d+)?$/.test(x) && !/^-?0\d/.test(x));
      const sql = (a) => `(${a.map((x) => (nums ? x : `'${x.replace(/'/g, "''")}'`)).join(", ")})`;
      return [
        { note: `${lines.length} lines · ${uniq.length} unique${lines.length - uniq.length ? ` · ${lines.length - uniq.length} duplicates` : ""}` },
        { label: "SQL IN list (unique)", value: sql(uniq), primary: true },
        { label: "JSON array (unique)", value: nums ? `[${uniq.join(",")}]` : JSON.stringify(uniq) },   // the digits as written: long ids aren't rounded
        { label: "Sorted, unique", value: [...uniq].sort((a, b) => (nums ? a - b : a.localeCompare(b))).join("\n") },
        { label: "Comma-separated", value: uniq.join(",") },
      ];
    },
  },
  {
    id: "cron", name: "Cron explainer", hint: "What it means and the next runs — in UTC (Kubernetes default) and your time", keys: "cron schedule crontab cronjob celery beat kubernetes next run",
    inputs: ["Cron expression (5 fields)"],
    detect: (t) => {
      const x = t.trim();
      if (MACROS[x.toLowerCase()]) return 80;
      if (!/^([\d*/,\-?A-Za-z]+\s+){4}[\d*/,\-?A-Za-z]+$/.test(x) || !/[*\d]/.test(x)) return 0;
      try { parseCron(x); return 80; } catch (e) { return 0; }   // "call me at 5 pm" has five words but isn't cron
    },
    run([t]) {
      const c = parseCron(t);
      const asUTC = cronNext(c, 5, 0), asLocal = cronNext(c, 3, tzOffsetHours());
      if (!asUTC.length) return [{ label: "Meaning", value: cronWords(c), primary: true }, { note: "This schedule never runs in the next 4 years (for example 31 February).", tone: "bad" }];
      return [
        { label: "Meaning", value: cronWords(c), primary: true },
        { label: `Next runs if it runs in UTC (Kubernetes CronJob default) — shown in ${tzName()} time`, value: asUTC.map((d) => `${fmtLocal.format(d)}  (${rel(d)})`).join("\n") },
        { label: `Next runs if the schedule is in ${tzName()} time`, value: asLocal.map((d) => `${fmtLocal.format(d)}  (${rel(d)})`).join("\n") },
      ];
    },
  },
  {
    id: "diff", name: "Text diff", hint: "Compare two texts line by line", keys: "diff compare difference changes text two",
    inputs: ["Before", "After"], detect: () => 0,
    run([a, b]) {
      if (!b) return [{ note: "Paste the second text in “After”." }];
      const { out, add, del } = lineDiff(a, b);
      const endings = /\r/.test(a) !== /\r/.test(b) ? [{ note: "Line endings differ (CRLF vs LF) — ignored below" }] : [];
      return [...endings, { note: add || del ? `${del} removed · ${add} added` : "Identical", tone: add || del ? null : "good" },
        { label: "Changes", html: `<pre class="diff">${out.map(([k, l]) => `<span class="${k === "+" ? "add" : k === "-" ? "del" : ""}">${k} ${esc(l)}</span>`).join("\n")}</pre>` }];
    },
  },
];

// Not text transforms: they read live data through the app (see palette.html).
const APP_TOOLS = [
  { id: "sessions", name: "Find a Claude session", hint: "Search past sessions; copy the resume command", keys: "claude session resume find history conversation", inputs: ["Keywords"] },
  { id: "db", name: "Database connections", hint: "Your proxy ports, which are up, and a ready psql command (read-only accounts)", keys: "database db postgres psql proxy port tableplus connect sql replica" },
  { id: "standup", name: "Copy standup list", hint: "The standup Manara wrote, ready to read out", keys: "standup copy list notes daily" },
];

// ── the standup (shared with the dashboard) ─────────────────────────────
// standup.sh's Markdown → the spoken list ("- headline" + indented detail; "- **bold**" = check note)
const cleanMd = (s) => s.replace(/\*\*|`/g, "");
function parseNotes(text) {
  const out = { title: "", covering: "", context: "", items: [], checks: [] };
  let cur = null;
  for (const raw of (text || "").split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    if (raw.startsWith("# ")) { out.title = line.slice(2); continue; }
    if (/^_Covering/.test(line)) { out.covering = line.replace(/^_|_$/g, ""); continue; }
    const m = raw.match(/^- (.*)$/);
    if (m) {
      const b = m[1].match(/^\*\*(.+?)\*\*\s*(.*)$/);
      cur = b ? { head: b[1], detail: cleanMd(b[2]) } : { head: cleanMd(m[1]), detail: "" };
      (b ? out.checks : out.items).push(cur);
      continue;
    }
    if (/^\s+\S/.test(raw) && cur) { cur.detail += (cur.detail ? " " : "") + cleanMd(line); continue; }
    cur = null;
    if (!out.context && /standup/i.test(line)) out.context = line;
  }
  return out;
}
const spokenList = (notes) => parseNotes(notes).items.map((i) => `- ${i.head}${i.detail ? `\n  ${i.detail}` : ""}`).join("\n");

// Router: score text against every tool; the jump targets come first.
function detectAll(text) {
  const t = (text || "").trim();
  if (!t || t.length > 200000) return [];
  const hits = [];
  const k = t.match(LINEAR_KEY);
  if (k) {
    const keys = issueKeys(), team = k[1].toUpperCase();
    const score = keys.includes(team) ? 98 : !keys.length && k[1] === team ? 60 : 25;   // 25: never offered on its own
    hits.push({ jump: "linear", score, key: `${team}-${k[2]}` });
  }
  const r = t.match(REPO_REF);
  if (r) hits.push({ jump: "github", score: 97, repo: r[1], n: r[2] });
  for (const tool of TOOLS) { try { const s = tool.detect(t); if (s >= 30) hits.push({ tool, score: s }); } catch (e) { /* ignore */ } }
  return hits.sort((a, b) => b.score - a.score);
}
