// The flags page must not focus anything on load: a focused search box
// swallows the first keystroke, and the shortcuts (?, j, 1…) are how the
// page is driven. Boots the real shortcuts.js + flags_core.js + flags.js in
// node:vm against a small stub DOM (no dependencies) and records focus().
// Run: node --test 'test/js/*.test.js'
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const STATIC = path.join(__dirname, "../../priv/static/");
const src = (f) => fs.readFileSync(STATIC + f, "utf8");

// A permissive element: any unknown method is a no-op returning a stub, so
// flags.js can boot; the bits the test cares about are real.
function makeDom(focused) {
  const els = {};
  function el(id, extra = {}) {
    const listeners = {};
    const node = Object.assign({
      id, tagName: (extra.tag || "DIV").toUpperCase(), hidden: false, value: "", dataset: {}, style: {},
      attrs: {}, children: [],
      classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
      getAttribute(n) { return n in this.attrs ? this.attrs[n] : null; },
      setAttribute(n, v) { this.attrs[n] = String(v); },
      removeAttribute(n) { delete this.attrs[n]; },
      hasAttribute(n) { return n in this.attrs; },
      addEventListener(t, fn) { (listeners[t] = listeners[t] || []).push(fn); },
      dispatch(t, ev) { (listeners[t] || []).forEach((fn) => fn(ev)); },
      querySelector() { return null; },
      querySelectorAll() { return []; },
      appendChild(c) { this.children.push(c); return c; },
      removeChild() {},
      closest() { return null; },
      focus() { focused.push(id); doc.activeElement = node; },
      blur() {}, select() {},
      scrollIntoView() {},
      getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0, height: 0, width: 0 }; },
      get firstChild() { return null; },
      get lastChild() { return null; },
      textContent: "", innerHTML: "", scrollTop: 0,
    }, extra);
    els[id] = node;
    return node;
  }
  const body = el("body", { attrs: { "data-base": "/flags", "data-viewer": "" } });
  const doc = {
    body, activeElement: body,
    documentElement: el("html"),
    getElementById(id) { return els[id] || null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    createElement(t) { return el("new-" + t, { tag: t }); },
    createElementNS(_ns, t) { return el("new-" + t, { tag: t }); },
    createTextNode(t) { return { textContent: t }; },
    addEventListener(t, fn, cap) { (doc.listeners[t] = doc.listeners[t] || []).push(fn); },
    listeners: {},
  };
  ["fwf-list", "fwf-list-col", "fwf-panel", "fwf-filters", "fwf-count", "fwf-list-empty",
   "fwf-sort-key", "fwf-sort-dir", "fwf-toolbar", "fwf-top-bar"].forEach((id) => el(id));
  el("fwf-search", { tag: "input" });
  return { doc, els };
}

function boot(opts = {}) {
  const focused = [];
  const { doc, els } = makeDom(focused);
  if (opts.setup) opts.setup(doc, els);
  const store = () => { const m = new Map(); return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => m.set(k, v), removeItem: (k) => m.delete(k) }; };
  const win = {
    document: doc, console, URL, URLSearchParams, Set, Map, Date, JSON, Math,
    location: { pathname: "/flags", search: opts.search || "", hash: opts.hash || "", href: "http://x/flags" + (opts.search || "") + (opts.hash || "") },
    history: { state: null, replaced: [], replaceState(_s, _t, url) { this.replaced.push(url); }, pushState() {} },
    matchMedia: () => ({ matches: !!opts.narrow, addEventListener() {} }),
    localStorage: store(), sessionStorage: store(),
    setTimeout, clearTimeout, fetch: () => new Promise(() => {}),
    listeners: {},
    addEventListener(t, fn) { (win.listeners[t] = win.listeners[t] || []).push(fn); },
    scrollTo() {},
    navigator: {},
  };
  win.self = win;
  win.window = win;
  vm.createContext(win);
  for (const f of ["shortcuts.js", "flags_core.js", "flags.js"]) vm.runInContext(src(f), win, { filename: f });
  return { focused, doc, els, win };
}

test("flags.js boots in the stub (the test is meaningful)", () => {
  const { win } = boot();
  assert.equal(typeof win.FwfCore, "object");
  assert.equal(typeof win.FwfShortcuts, "object");
});

test("nothing is focused on load, on wide screens or narrow", () => {
  const { focused } = boot();
  assert.deepEqual(focused, []);
});

test("so the first keystroke reaches the shortcuts: ? opens the sheet, not the search box", () => {
  const { doc } = boot();
  let prevented = false;
  const ev = { key: "?", ctrlKey: false, metaKey: false, altKey: false, target: doc.activeElement, defaultPrevented: false, isComposing: false, preventDefault() { prevented = true; } };
  (doc.listeners.keydown || []).forEach((fn) => fn(ev));
  assert.equal(prevented, true, "? was handled by the shortcuts");
  assert.ok(doc.getElementById("fwf-search").value === "", "nothing was typed into search");
});

test("/ focuses the search (it is the only way in)", () => {
  const { doc, focused } = boot();
  const ev = { key: "/", ctrlKey: false, metaKey: false, altKey: false, target: doc.activeElement, defaultPrevented: false, isComposing: false, preventDefault() {} };
  (doc.listeners.keydown || []).forEach((fn) => fn(ev));
  assert.deepEqual(focused, ["fwf-search"]);
});

// Round 9: the percentage form sends a percent with percent_unit=percent and
// the server converts. No script may rewrite its values (a partial JS
// failure or a bfcache restore must never change what is sent).
test("no client-side percent conversion is left in any script", () => {
  for (const f of ["flags.js", "flags_core.js", "shortcuts.js", "theme.js", "confirm.js"]) {
    const s = src(f);
    assert.doesNotMatch(s, /percentToFraction/, f);
    assert.doesNotMatch(s, /percent_value|data-fwf-percent|percent_unit/, f);
  }
  const { win } = boot();
  assert.equal(win.FwfCore.percentToFraction, undefined);
});

test("submitting the percentage form leaves its values exactly as typed", () => {
  const { doc } = boot();
  const fields = {
    percent_value: { name: "percent_value", value: "0.5", type: "text" },
    percent_unit: { name: "percent_unit", value: "percent", type: "hidden" },
    percent_type: { name: "percent_type", value: "time", type: "radio" },
  };
  const form = {
    tagName: "FORM",
    attrs: { id: "fwf-percentage-form", action: "/flags/f/percentage", method: "post" },
    getAttribute(n) { return n in this.attrs ? this.attrs[n] : null; },
    hasAttribute(n) { return n in this.attrs; },
    querySelector(sel) {
      const m = /name="?([\w]+)"?/.exec(sel);
      return m && fields[m[1]] ? fields[m[1]] : null;
    },
    querySelectorAll() { return Object.values(fields); },
    closest() { return null; },
  };
  const ev = { type: "submit", target: form, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
  (doc.listeners.submit || []).forEach((fn) => fn(ev));
  assert.ok((doc.listeners.submit || []).length > 0, "flags.js has submit listeners (the restore point)");
  assert.equal(ev.defaultPrevented, false);
  assert.deepEqual(Object.values(fields).map((f) => [f.name, f.value, f.type]), [
    ["percent_value", "0.5", "text"], ["percent_unit", "percent", "hidden"], ["percent_type", "time", "radio"]
  ]);
});

// Round 13: a gate edit redirects to /flags/:name#actor_<id>. The browser's
// fragment jump scrolled the clipped root (scrollTop 141 measured), hiding
// the header with no way back. On wide screens the landing is handled in
// the panel column and the root stays at 0, even when the browser jumps
// after the script has run.
function landing(narrow) {
  return boot({
    hash: "#actor_workspace%3A9999",
    narrow,
    setup(doc, els) {
      const panel = els["fwf-panel"];
      const target = { id: "actor_workspace:9999", closest: () => null, scrollIntoView() { this.scrolledIntoView = true; },
        // 2400px down a panel column whose box is 120..900 in the viewport.
        getBoundingClientRect: () => ({ top: 2400 - panel.scrollTop, bottom: 2432 - panel.scrollTop, height: 32 }) };
      panel.getBoundingClientRect = () => ({ top: 120, bottom: 900, height: 780 });
      panel.contains = (el) => el === target;
      els[target.id] = target;
      // What the browser's own fragment jump did before the fix.
      doc.documentElement.scrollTop = 141;
      doc.scrollingElement = doc.documentElement;
      doc.target = target;
    },
  });
}

test("landing on #actor_x at two columns: root back at 0, the panel column scrolled to the row", () => {
  const { doc, els } = landing(false);
  assert.equal(doc.documentElement.scrollTop, 0, "root scrollTop");
  assert.equal(doc.body.scrollTop, 0, "body scrollTop");
  const panel = els["fwf-panel"];
  // centred: row top 2400 - scrollTop lands at 120 + (780 - 32) / 2
  assert.equal(panel.scrollTop, 2400 - 120 - (780 - 32) / 2);
  assert.equal(doc.target.scrolledIntoView, undefined, "no scrollIntoView (it scrolls the root too)");
});

test("a fragment jump after boot (at load, or a later scroll of the root) is undone", () => {
  const { doc, win } = landing(false);
  doc.documentElement.scrollTop = 99; // the browser jumps again after the script ran
  (win.listeners.scroll || []).forEach((fn) => fn({}));
  assert.equal(doc.documentElement.scrollTop, 0, "after a window scroll event");
  doc.documentElement.scrollTop = 141;
  (win.listeners.load || []).forEach((fn) => fn({}));
  assert.equal(doc.documentElement.scrollTop, 0, "after load");
});

test("one column (phones): the window keeps scrolling normally", () => {
  const { doc, win } = landing(true);
  assert.equal(doc.documentElement.scrollTop, 141, "the browser's jump is left alone");
  (win.listeners.scroll || []).forEach((fn) => fn({}));
  assert.equal(doc.documentElement.scrollTop, 141);
});
