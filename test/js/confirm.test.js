// Tests for priv/static/confirm.js: the confirmation on Delete Flag and every
// Clear button. No DOM library: a hand-rolled document/event stub, enough
// for addEventListener + capture-phase click dispatch + closest().
// Run with: node --test 'test/js/*.test.js'
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const STATIC = path.join(__dirname, "../../priv/static/");
const CONFIRM_SRC = fs.readFileSync(STATIC + "confirm.js", "utf8");
const FLAGS_SRC = fs.readFileSync(STATIC + "flags.js", "utf8");

// --- stub DOM ----------------------------------------------------------

// An element in a parent chain; closest() supports "[data-confirm]" and
// plain tag/attribute-free selectors we don't need beyond that.
function el(tag, attrs = {}, parent = null) {
  return {
    tagName: tag.toUpperCase(),
    parent,
    attrs,
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null; },
    hasAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name); },
    closest(selector) {
      const m = /^\[([\w-]+)\]$/.exec(selector);
      if (!m) throw new Error("stub closest() only supports [attr]: " + selector);
      for (let node = this; node; node = node.parent) if (node.hasAttribute(m[1])) return node;
      return null;
    },
  };
}

function stubDocument() {
  const listeners = [];
  return {
    listeners,
    addEventListener(type, fn, capture) { listeners.push({ type, fn, capture: !!capture }); },
    // Capture-phase listeners on the document run first; a listener calling
    // stopImmediatePropagation stops the rest; returns the event.
    dispatch(type, target) {
      const ev = {
        type,
        target,
        defaultPrevented: false,
        stopped: false,
        preventDefault() { this.defaultPrevented = true; },
        stopImmediatePropagation() { this.stopped = true; },
      };
      const ordered = listeners.filter((l) => l.type === type && l.capture)
        .concat(listeners.filter((l) => l.type === type && !l.capture));
      for (const l of ordered) {
        if (ev.stopped) break;
        l.fn(ev);
      }
      return ev;
    },
  };
}

function stubWindow(answer) {
  const asked = [];
  return { asked, confirm(q) { asked.push(q); return answer; } };
}

// A "Clear" button inside its form, like rows/_actor.html.eex renders.
function clearButton() {
  const form = el("form", { action: "/flags/foo/actors/user:1" });
  const button = el("button", { type: "submit", "data-confirm": "Remove user:1 from f?" }, form);
  const label = el("span", {}, button); // a click can land on a child node
  return { form, button, label };
}

const Confirm = require(STATIC + "confirm.js");

// --- the guard itself ----------------------------------------------------

test("a declined confirm blocks the click (so the form never submits)", () => {
  const doc = stubDocument();
  const win = stubWindow(false);
  Confirm.install(doc, win);
  const ev = doc.dispatch("click", clearButton().button);
  assert.deepEqual(win.asked, ["Remove user:1 from f?"]);
  assert.equal(ev.defaultPrevented, true);
  assert.equal(ev.stopped, true, "and no later click handler sees it");
});

test("an accepted confirm lets the click through", () => {
  const doc = stubDocument();
  const win = stubWindow(true);
  Confirm.install(doc, win);
  const ev = doc.dispatch("click", clearButton().button);
  assert.equal(win.asked.length, 1);
  assert.equal(ev.defaultPrevented, false);
  assert.equal(ev.stopped, false);
});

test("a click on a child of the button is guarded too", () => {
  const doc = stubDocument();
  const win = stubWindow(false);
  Confirm.install(doc, win);
  assert.equal(doc.dispatch("click", clearButton().label).defaultPrevented, true);
});

test("clicks on anything without data-confirm are left alone, without asking", () => {
  const doc = stubDocument();
  const win = stubWindow(false);
  Confirm.install(doc, win);
  const plain = el("button", { type: "submit" }, el("form"));
  const ev = doc.dispatch("click", plain);
  assert.equal(win.asked.length, 0);
  assert.equal(ev.defaultPrevented, false);
  assert.equal(doc.dispatch("click", null).defaultPrevented, false);
});

test("it listens in the capture phase and runs before other click handlers", () => {
  const doc = stubDocument();
  const win = stubWindow(false);
  let laterHandlerRan = false;
  doc.addEventListener("click", () => { laterHandlerRan = true; }); // e.g. flags.js's panel handler
  Confirm.install(doc, win);
  doc.dispatch("click", clearButton().button);
  assert.equal(doc.listeners.find((l) => l.type === "click" && l.capture) !== undefined, true);
  assert.equal(laterHandlerRan, false);
});

test("installing twice registers one listener (one dialog per click)", () => {
  const doc = stubDocument();
  const win = stubWindow(false);
  assert.equal(Confirm.install(doc, win), true);
  assert.equal(Confirm.install(doc, win), false);
  doc.dispatch("click", clearButton().button);
  assert.equal(win.asked.length, 1);
});

// --- independence from the other scripts ---------------------------------
// Load the files the way the browser does: plain scripts sharing one global.

function browserContext(answer, body) {
  const doc = stubDocument();
  doc.body = body;
  doc.documentElement = { classList: { add() {} } };
  doc.getElementById = () => null;
  doc.querySelector = () => null;
  const win = stubWindow(answer);
  const sandbox = { document: doc, confirm: win.confirm, console };
  sandbox.self = sandbox;
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  return { doc, win, sandbox };
}

const pageBody = { getAttribute: () => null, hasAttribute: () => false, classList: { toggle() {} } };

test("in the browser it installs itself from the script tag, needing nothing else", () => {
  const { doc, win, sandbox } = browserContext(false, pageBody);
  vm.runInContext(CONFIRM_SRC, sandbox);
  assert.equal(sandbox.FwfCore, undefined, "flags_core.js never loaded");
  assert.equal(doc.dispatch("click", clearButton().button).defaultPrevented, true);
  assert.equal(win.asked.length, 1, "it asked through the page's window.confirm");
});

test("with flags_core.js missing (404, partial deploy), Delete/Clear still ask", () => {
  const { doc, sandbox } = browserContext(false, pageBody);
  let asked = 0;
  sandbox.confirm = () => { asked++; return false; };
  vm.runInContext(CONFIRM_SRC, sandbox);
  vm.runInContext(FLAGS_SRC, sandbox); // FwfCore undefined: flags.js bails out early
  const ev = doc.dispatch("click", clearButton().button);
  assert.equal(asked, 1);
  assert.equal(ev.defaultPrevented, true);
});

test("with flags.js throwing during setup, Delete/Clear still ask", () => {
  const { doc, sandbox } = browserContext(false, null); // document.body null: flags.js throws
  let asked = 0;
  sandbox.confirm = () => { asked++; return false; };
  vm.runInContext(CONFIRM_SRC, sandbox);
  assert.throws(() => vm.runInContext(FLAGS_SRC, sandbox));
  const ev = doc.dispatch("click", clearButton().button);
  assert.equal(asked, 1);
  assert.equal(ev.defaultPrevented, true);
});

test("flags.js no longer handles data-confirm itself (no second dialog)", () => {
  assert.equal(/closest\(\s*["']\[data-confirm\]["']\s*\)/.test(FLAGS_SRC), false);
  assert.equal(/window\.confirm\s*\(/.test(FLAGS_SRC), false);
});
