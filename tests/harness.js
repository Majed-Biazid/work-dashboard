// Loads web/core.js and web/tools.js into a sandbox the way a page would (one
// shared global scope), with just enough browser to run them. No dependencies.
//   const { get, WD } = load({ config, data, state });
//   get("briefing()")   — evaluate any expression inside the page
const vm = require("node:vm");
const fs = require("node:fs");
const path = require("node:path");

function load({ config = {}, data = {}, state = {}, updated = {}, page = "dashboard.html" } = {}) {
  const ctx = {
    console, URL, URLSearchParams, TextEncoder, TextDecoder, atob, btoa, setTimeout, clearTimeout,
    crypto: globalThis.crypto,
    location: { pathname: `/web/${page}`, search: "" },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    document: { addEventListener() {}, body: null, documentElement: { style: { setProperty() {} }, dataset: {} } },
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  for (const f of ["core.js", "tools.js"]) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "web", f), "utf8"), ctx, { filename: f });
  }
  const get = (expr) => vm.runInContext(expr, ctx);
  const WD = get("WD");
  Object.assign(WD, { config, data, state, updated });
  return { get, WD };
}

// Values made inside the sandbox have its own Array/Object prototypes; compare plain copies.
const plain = (x) => JSON.parse(JSON.stringify(x));

module.exports = { load, plain };
