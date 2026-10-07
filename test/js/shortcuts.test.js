// Tests for priv/static/shortcuts.js: the key -> action table, its guards,
// and the "?" sheet built from the same table. Run: node --test 'test/js/*.test.js'
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const K = require(path.join(__dirname, "../../priv/static/shortcuts.js"));

const press = (key, extra = {}, ctx = { pending: null }) =>
  K.resolve(Object.assign({ key, ctrlKey: false, metaKey: false, altKey: false, target: "other" }, extra), ctx);
const action = (key, extra, ctx) => press(key, extra, ctx).action;

test("the full shortcut table maps keys to actions", () => {
  const cases = {
    "/": "focusSearch", j: "next", ArrowDown: "next", k: "prev", ArrowUp: "prev", o: "open",
    "[": "prevFlag", "]": "nextFlag", Escape: "escape", n: "newFlag",
    "1": "statusAll", "2": "statusOn", "3": "statusPartial", "4": "statusOff",
    m: "toggleMine", p: "pin", c: "copy", a: "addActor", "?": "help"
  };
  for (const [key, expected] of Object.entries(cases)) assert.equal(action(key), expected, key);
});

test("Cmd+K and Ctrl+K focus search, even while typing in a field", () => {
  assert.equal(action("k", { metaKey: true }), "focusSearch");
  assert.equal(action("k", { ctrlKey: true }), "focusSearch");
  assert.equal(action("K", { ctrlKey: true }), "focusSearch");
  assert.equal(action("k", { metaKey: true, target: "field" }), "focusSearch");
  assert.equal(action("k", { metaKey: true, target: "search" }), "focusSearch");
});

test("no other shortcut fires with Ctrl, Cmd or Alt held", () => {
  for (const key of ["/", "j", "k", "c", "p", "1", "?", "g", "n", "a"]) {
    if (key === "k") continue;
    assert.equal(action(key, { ctrlKey: true }), null, "ctrl+" + key);
    assert.equal(action(key, { metaKey: true }), null, "cmd+" + key);
    assert.equal(action(key, { altKey: true }), null, "alt+" + key);
  }
  assert.equal(action("k", { altKey: true }), null);
  assert.equal(action("k", { metaKey: true, altKey: true }), null);
  // Cmd+C / Ctrl+C stay the browser's copy, not "copy flag name"
  assert.equal(press("c", { metaKey: true }).consume, false);
});

test("nothing fires while typing in a field, except the explicit ones", () => {
  for (const key of ["/", "j", "k", "c", "p", "1", "?", "g", "n", "a", "m", "o", "[", "]", "Escape", "ArrowDown"]) {
    const r = press(key, { target: "field" });
    assert.equal(r.action, null, "field: " + key);
    assert.equal(r.consume, false, "field: " + key);
  }
});

test("in the flag search box only Esc and ↓ act; letters type", () => {
  assert.equal(action("Escape", { target: "search" }), "escape");
  assert.equal(action("ArrowDown", { target: "search" }), "nextFromSearch");
  for (const key of ["j", "k", "/", "1", "?", "c", "p", "g", "a"]) {
    assert.equal(action(key, { target: "search" }), null, key);
  }
});

test("g then f / a / s go to a page; the chord expires into a normal key", () => {
  const first = press("g");
  assert.equal(first.action, null);
  assert.equal(first.pending, "g");
  assert.equal(first.consume, true);
  assert.equal(action("f", {}, { pending: "g" }), "goFlags");
  assert.equal(action("a", {}, { pending: "g" }), "goAudit");
  assert.equal(action("s", {}, { pending: "g" }), "goSettings");
  // not a chord key: the chord is dropped and the key acts normally
  assert.equal(action("j", {}, { pending: "g" }), "next");
  // without the chord, a is "add actor", not "audit"
  assert.equal(action("a"), "addActor");
});

test("no shortcut changes a flag", () => {
  const navigateFilterFocusCopy = new Set([
    "focusSearch", "next", "nextFromSearch", "prev", "open", "prevFlag", "nextFlag", "escape",
    "goFlags", "goAudit", "goSettings", "newFlag", "statusAll", "statusOn", "statusPartial", "statusOff",
    "toggleMine", "pin", "copy", "addActor", "help"
  ]);
  for (const b of K.BINDINGS) {
    assert.ok(navigateFilterFocusCopy.has(b.action), "unexpected action " + b.action);
    assert.doesNotMatch(b.action, /enable|disable|clear|delete|remove|toggleGate|submit/i);
  }
  // "pin" is a per-browser bookmark (localStorage), "newFlag" only opens the form.
});

test("unknown keys do nothing and aren't swallowed", () => {
  for (const key of ["x", "z", "Enter", " ", "Tab", "F5", "0", "5"]) {
    const r = press(key);
    assert.equal(r.action, null, key);
    assert.equal(r.consume, false, key);
  }
});

test("the sheet is built from the same table, only for actions this page has", () => {
  const all = K.sheetGroups(() => true);
  const listed = all.flatMap((g) => g.rows.map((r) => r.label));
  for (const b of K.BINDINGS.filter((b) => !b.hideOnSheet)) assert.ok(listed.includes(b.label), b.label);
  assert.deepEqual(all.map((g) => g.title), ["Navigate", "Go to", "Filter", "Flag", "Help"]);

  const otherPage = K.sheetGroups((a) => ["goFlags", "goAudit", "goSettings", "newFlag", "focusSearch", "help"].includes(a));
  const otherLabels = otherPage.flatMap((g) => g.rows.map((r) => r.label));
  assert.ok(!otherLabels.includes("Pin / unpin the focused flag"));
  assert.ok(otherLabels.includes("Audit log"));

  const chord = all.find((g) => g.title === "Go to").rows.find((r) => r.label === "Audit log");
  assert.deepEqual(chord.keys, ["g", "a"]);
  assert.equal(chord.chord, true);
});
