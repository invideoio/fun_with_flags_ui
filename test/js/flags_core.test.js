// Tests for priv/static/flags_core.js, the pure logic behind the flags page.
// Run with: node --test test/js
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const Core = require(path.join(__dirname, "../../priv/static/flags_core.js"));

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.parse("2026-10-07T12:00:00Z");

function flag(name, opts = {}) {
  const targets = []
    .concat((opts.actors || []).map((v) => ({ kind: "actor", value: v, lower: v.toLowerCase() })))
    .concat((opts.groups || []).map((v) => ({ kind: "group", value: v, lower: v.toLowerCase() })));
  return {
    name,
    nameLower: name.toLowerCase(),
    status: opts.status || "off",
    types: opts.types || ["boolean"],
    created: opts.created === undefined ? null : opts.created,
    targets,
  };
}

const state = (over = {}) => Object.assign(Core.emptyState(), over);
const ctx = (over = {}) => Object.assign({ pins: new Set(), now: NOW, viewer: "" }, over);

test("parseTerms lowercases and splits on whitespace", () => {
  assert.deepEqual(Core.parseTerms("  Foo   BAR "), ["foo", "bar"]);
  assert.deepEqual(Core.parseTerms(""), []);
  assert.deepEqual(Core.parseTerms(null), []);
});

test("matchFlag: no terms matches everything", () => {
  assert.deepEqual(Core.matchFlag(flag("a"), []), { match: true, ranges: [], hits: [] });
});

test("matchFlag: case-insensitive substring on the name, with highlight ranges", () => {
  const m = Core.matchFlag(flag("New_Checkout_Flow"), Core.parseTerms("checkout"));
  assert.equal(m.match, true);
  assert.deepEqual(m.ranges, [[4, 12]]);
  assert.deepEqual(m.hits, []);
});

test("matchFlag: all occurrences are highlighted and overlapping ranges merge", () => {
  const m = Core.matchFlag(flag("aaa_aa"), ["aa"]);
  assert.deepEqual(m.ranges, [[0, 3], [4, 6]]);
});

test("matchFlag: multiple terms are ANDed", () => {
  const f = flag("export_v2_beta");
  assert.equal(Core.matchFlag(f, ["export", "beta"]).match, true);
  assert.equal(Core.matchFlag(f, ["export", "gamma"]).match, false);
  assert.deepEqual(Core.matchFlag(f, ["beta", "export"]).ranges, [[0, 6], [10, 14]]);
});

test("matchFlag: a term can match a gate target (actor id or group)", () => {
  const f = flag("new_editor", { actors: ["workspace:123", "user:9"], groups: ["beta"] });
  const m = Core.matchFlag(f, ["workspace:123"]);
  assert.equal(m.match, true);
  assert.deepEqual(m.ranges, []);
  assert.deepEqual(m.hits.map((h) => [h.kind, h.value]), [["actor", "workspace:123"]]);

  const g = Core.matchFlag(f, Core.parseTerms("BETA"));
  assert.deepEqual(g.hits.map((h) => [h.kind, h.value]), [["group", "beta"]]);
});

test("matchFlag: name terms and target terms combine; hits only list target-only terms", () => {
  const f = flag("new_editor", { actors: ["email:ana@example.com"] });
  const m = Core.matchFlag(f, ["editor", "ana@"]);
  assert.equal(m.match, true);
  assert.deepEqual(m.ranges, [[4, 10]]);
  assert.deepEqual(m.hits.map((h) => h.value), ["email:ana@example.com"]);
  assert.equal(Core.describeHits(m.hits), "actor email:ana@example.com");
});

test("matchFlag: the same target matched by two terms is reported once", () => {
  const f = flag("x", { actors: ["workspace:123"] });
  assert.equal(Core.matchFlag(f, ["workspace", "123"]).hits.length, 1);
});

test("hitLabel: the full matched target(s), never shortened; empty when nothing matched on a target", () => {
  const f = flag("analytics_hd_export", { actors: ["workspace:2809", "email:ana@example.com"], groups: ["beta"] });
  assert.equal(Core.hitLabel(Core.matchFlag(f, Core.parseTerms("workspace:2809")).hits), "matches actor workspace:2809");
  assert.equal(Core.hitLabel(Core.matchFlag(f, Core.parseTerms("ana@example beta")).hits), "matches actor email:ana@example.com · group beta");
  assert.equal(Core.hitLabel(Core.matchFlag(f, Core.parseTerms("analytics")).hits), "");
  assert.equal(Core.hitLabel([]), "");
  const long = "email:" + "x".repeat(200) + "@example.com";
  assert.equal(Core.hitLabel([{ kind: "actor", value: long }]), "matches actor " + long);
});

test("splitByRanges builds text segments for highlighting", () => {
  assert.deepEqual(Core.splitByRanges("abcdef", [[1, 3]]), [
    { text: "a", hit: false },
    { text: "bc", hit: true },
    { text: "def", hit: false },
  ]);
  assert.deepEqual(Core.splitByRanges("abc", []), [{ text: "abc", hit: false }]);
  assert.deepEqual(Core.splitByRanges("abc", [[0, 3]]), [{ text: "abc", hit: true }]);
  // Names are never interpreted as markup: segments are plain text.
  assert.deepEqual(Core.splitByRanges("<b>x</b>", [[3, 4]])[1], { text: "x", hit: true });
});

test("breakAfterUnderscores splits after each run of underscores and loses nothing", () => {
  assert.deepEqual(Core.breakAfterUnderscores("analytics_trial_rollout"), ["analytics_", "trial_", "rollout"]);
  assert.deepEqual(Core.breakAfterUnderscores("abc"), ["abc"]);
  assert.deepEqual(Core.breakAfterUnderscores("a__b"), ["a__", "b"]);
  assert.deepEqual(Core.breakAfterUnderscores("_lead"), ["_", "lead"]);
  assert.deepEqual(Core.breakAfterUnderscores("trail_"), ["trail_"]);
  assert.deepEqual(Core.breakAfterUnderscores(""), []);
  for (const name of ["analytics_trial_extension_rollout", "Ook? <b>Ook!</b>", "a_<b>_c", "__init__", "x"]) {
    assert.equal(Core.breakAfterUnderscores(name).join(""), name);
  }
});

test("highlight segments broken at underscores rebuild the exact name", () => {
  const name = "analytics_trial_extension_rollout";
  const m = Core.matchFlag(flag(name), Core.parseTerms("trial_ext"));
  const segs = Core.splitByRanges(name, m.ranges);
  assert.deepEqual(segs.map((s) => [s.text, s.hit]), [["analytics_", false], ["trial_ext", true], ["ension_rollout", false]]);
  const pieces = segs.map((s) => Core.breakAfterUnderscores(s.text));
  assert.deepEqual(pieces, [["analytics_"], ["trial_", "ext"], ["ension_", "rollout"]]);
  assert.equal(pieces.flat().join(""), name);
});

test("passesFilters: status", () => {
  const on = flag("a", { status: "on" });
  assert.equal(Core.passesFilters(on, state({ status: "on" }), ctx()), true);
  assert.equal(Core.passesFilters(on, state({ status: "partial" }), ctx()), false);
  assert.equal(Core.passesFilters(on, state(), ctx()), true);
});

test("passesFilters: gate types match if the flag has any selected type", () => {
  const f = flag("a", { types: ["boolean", "group"] });
  assert.equal(Core.passesFilters(f, state({ types: ["actor", "group"] }), ctx()), true);
  assert.equal(Core.passesFilters(f, state({ types: ["actor", "percentage"] }), ctx()), false);
});

test("passesFilters: pinned", () => {
  const f = flag("a");
  assert.equal(Core.passesFilters(f, state({ pinned: true }), ctx({ pins: new Set(["a"]) })), true);
  assert.equal(Core.passesFilters(f, state({ pinned: true }), ctx()), false);
});

test("passesFilters: new means created in the last 14 days", () => {
  assert.equal(Core.passesFilters(flag("a", { created: NOW - 3 * DAY }), state({ new: true }), ctx()), true);
  assert.equal(Core.passesFilters(flag("a", { created: NOW - 14 * DAY }), state({ new: true }), ctx()), true);
  assert.equal(Core.passesFilters(flag("a", { created: NOW - 15 * DAY }), state({ new: true }), ctx()), false);
  assert.equal(Core.passesFilters(flag("a"), state({ new: true }), ctx()), false);
});

test("passesFilters: mine means an actor gate that is the viewer's email or ends in ':' + email", () => {
  const f = flag("a", { actors: ["email:Ana@Example.com"], groups: ["ana@example.com"] });
  assert.equal(Core.passesFilters(f, state({ mine: true }), ctx({ viewer: "ana@example.com" })), true);
  assert.equal(Core.passesFilters(f, state({ mine: true }), ctx({ viewer: "bo@example.com" })), false);
  assert.equal(Core.passesFilters(f, state({ mine: true }), ctx({ viewer: "" })), false);
  // Groups don't count.
  const g = flag("b", { groups: ["ana@example.com"] });
  assert.equal(Core.passesFilters(g, state({ mine: true }), ctx({ viewer: "ana@example.com" })), false);
});

test("hasAnyCreated", () => {
  assert.equal(Core.hasAnyCreated([flag("a"), flag("b")]), false);
  assert.equal(Core.hasAnyCreated([flag("a"), flag("b", { created: NOW })]), true);
});

test("parseSort accepts the values the old list page stored", () => {
  assert.deepEqual(Core.parseSort("name_asc"), { key: "name", dir: "asc" });
  assert.deepEqual(Core.parseSort("status_desc"), { key: "status", dir: "desc" });
  assert.deepEqual(Core.parseSort("created_asc"), { key: "created", dir: "asc" });
  assert.deepEqual(Core.parseSort("bogus"), { key: "name", dir: "asc" });
  assert.deepEqual(Core.parseSort(null), { key: "name", dir: "asc" });
  assert.equal(Core.sortValue({ key: "created", dir: "desc" }), "created_desc");
});

test("sortFlags by name", () => {
  const flags = [flag("b"), flag("a"), flag("c")];
  assert.deepEqual(Core.sortFlags(flags, { key: "name", dir: "asc" }).map((f) => f.name), ["a", "b", "c"]);
  assert.deepEqual(Core.sortFlags(flags, { key: "name", dir: "desc" }).map((f) => f.name), ["c", "b", "a"]);
  assert.deepEqual(flags.map((f) => f.name), ["b", "a", "c"], "does not mutate its input");
});

test("sortFlags by status: on, partial, off; ties by name", () => {
  const flags = [flag("z", { status: "off" }), flag("b", { status: "on" }), flag("a", { status: "partial" }), flag("a2", { status: "on" })];
  assert.deepEqual(Core.sortFlags(flags, { key: "status", dir: "asc" }).map((f) => f.name), ["a2", "b", "a", "z"]);
  assert.deepEqual(Core.sortFlags(flags, { key: "status", dir: "desc" }).map((f) => f.name), ["z", "a", "a2", "b"]);
});

test("sortFlags by created: flags without a date go last in both directions", () => {
  const flags = [flag("none"), flag("old", { created: NOW - 100 * DAY }), flag("new", { created: NOW - DAY }), flag("also_none")];
  assert.deepEqual(Core.sortFlags(flags, { key: "created", dir: "asc" }).map((f) => f.name), ["old", "new", "also_none", "none"]);
  assert.deepEqual(Core.sortFlags(flags, { key: "created", dir: "desc" }).map((f) => f.name), ["new", "old", "also_none", "none"]);
});

test("query string round-trip", () => {
  const s = state({ q: "workspace:1 beta", status: "partial", types: ["actor", "percentage"], pinned: true, mine: true, sort: "created_desc" });
  const qs = Core.buildQuery(s);
  assert.equal(qs, "?q=workspace%3A1+beta&status=partial&type=actor%2Cpercentage&pinned=1&mine=1&sort=created_desc");
  assert.deepEqual(Core.parseQuery(qs), s);
});

test("buildQuery omits defaults and returns an empty string for the default view", () => {
  assert.equal(Core.buildQuery(state()), "");
  assert.equal(Core.buildQuery(state({ sort: "name_asc" })), "");
  assert.equal(Core.hasViewState(""), false);
  assert.equal(Core.hasViewState("?audit_page=2"), false);
  assert.equal(Core.hasViewState("?q=x"), true);
});

test("parseQuery ignores unknown or invalid values", () => {
  const s = Core.parseQuery("?status=maybe&type=actor,nope&pinned=yes&sort=size_asc&audit_page=3");
  assert.deepEqual(s, state({ types: ["actor"] }));
});

test("nameFromPath decodes the flag name under the base path", () => {
  assert.equal(Core.nameFromPath("/ns/flags/foo", "/ns/flags"), "foo");
  assert.equal(Core.nameFromPath("/ns/flags/Ook%3F%20Ook!", "/ns/flags"), "Ook? Ook!");
  assert.equal(Core.nameFromPath("/ns/flags/a%2Fb", "/ns/flags"), "a/b");
  assert.equal(Core.nameFromPath("/ns/flags", "/ns/flags"), null);
  assert.equal(Core.nameFromPath("/ns/flags/", "/ns/flags"), null);
  assert.equal(Core.nameFromPath("/ns/flags/foo/panel", "/ns/flags"), null);
  assert.equal(Core.nameFromPath("/other/foo", "/ns/flags"), null);
  assert.equal(Core.nameFromPath("/ns/flags/%E0%A4%A", "/ns/flags"), null);
});

test("flagPath encodes the name as one path segment", () => {
  assert.equal(Core.flagPath("/ns/flags", "Ook? Ook!"), "/ns/flags/Ook%3F%20Ook!");
  assert.equal(Core.flagPath("/flags", "a/b#c"), "/flags/a%2Fb%23c");
  assert.equal(Core.nameFromPath(Core.flagPath("/flags", "a/b#c?"), "/flags"), "a/b#c?");
});

test("relativeTime", () => {
  assert.equal(Core.relativeTime(NOW - 10 * 1000, NOW), "just now");
  assert.equal(Core.relativeTime(NOW - 5 * 60 * 1000, NOW), "5 min ago");
  assert.equal(Core.relativeTime(NOW - 3 * 3600 * 1000, NOW), "3 h ago");
  assert.equal(Core.relativeTime(NOW - DAY, NOW), "yesterday");
  assert.equal(Core.relativeTime(NOW - 9 * DAY, NOW), "9 days ago");
  assert.equal(Core.relativeTime(NOW - 65 * DAY, NOW), "2 months ago");
  assert.equal(Core.relativeTime(NOW - 400 * DAY, NOW), "1 year ago");
  assert.equal(Core.relativeTime(NOW - 800 * DAY, NOW), "2 years ago");
  assert.equal(Core.relativeTime(NOW + DAY, NOW), "just now");
});

test("countLabel", () => {
  assert.equal(Core.countLabel(310, 310), "310 flags");
  assert.equal(Core.countLabel(42, 310), "42 of 310 flags");
  assert.equal(Core.countLabel(1, 1), "1 flag");
  assert.equal(Core.countLabel(0, 0), "0 flags");
});


// --- Round 5 (review findings) ---------------------------------------

test("isMine: exact email or ':' + email suffix, case-insensitive; never a substring", () => {
  const mine = (actors, viewer) => Core.isMine(flag("x", { actors }), viewer);
  assert.equal(mine(["email:ana@example.com"], "ana@example.com"), true);
  assert.equal(mine(["user:Ana@Example.COM"], "ana@example.com"), true);
  assert.equal(mine(["ana@example.com"], "ANA@example.com"), true);
  // the reviewer's case: a@x.io must not match ba@x.io
  assert.equal(mine(["email:ba@x.io"], "a@x.io"), false);
  assert.equal(mine(["email:a@x.io.evil"], "a@x.io"), false);
  assert.equal(mine(["workspace:123"], "a@x.io"), false);
  assert.equal(mine([":a@x.io"], "a@x.io"), false); // no prefix before the colon
  assert.equal(mine(["email:a@x.io"], ""), false);
  assert.equal(Core.isMine(flag("x", { groups: ["a@x.io"] }), "a@x.io"), false);
});

test("pins: a Set, so Object.prototype names are ordinary flag names", () => {
  const pins = Core.parsePins("[]");
  for (const name of ["constructor", "toString", "valueOf", "hasOwnProperty", "__proto__"]) {
    assert.equal(pins.has(name), false, name + " starts unpinned");
    assert.equal(Core.togglePin(pins, name), true, name + " pins");
    assert.equal(pins.has(name), true);
  }
  assert.equal(Core.togglePin(pins, "constructor"), false, "constructor unpins");
  assert.equal(pins.has("constructor"), false);
  const restored = Core.parsePins(Core.serializePins(pins));
  assert.deepEqual(Array.from(restored).sort(), ["__proto__", "hasOwnProperty", "toString", "valueOf"]);
  assert.equal(restored.has("constructor"), false);
});

test("pins: filtering by Pinned with prototype-named flags", () => {
  const pins = Core.parsePins('["__proto__"]');
  assert.equal(Core.passesFilters(flag("__proto__"), state({ pinned: true }), ctx({ pins })), true);
  assert.equal(Core.passesFilters(flag("constructor"), state({ pinned: true }), ctx({ pins })), false);
  assert.equal(Core.passesFilters(flag("toString"), state({ pinned: true }), ctx({ pins })), false);
});

test("pins: junk in storage reads as no pins; non-strings are dropped", () => {
  for (const raw of [null, "", "not json", "{}", '{"a":true}', "42", '"a"']) {
    assert.equal(Core.parsePins(raw).size, 0, String(raw));
  }
  assert.deepEqual(Array.from(Core.parsePins('["a", 1, null, {"x":1}, "b"]')), ["a", "b"]);
});

test("canonicalPath: after a 400 at the POST URL, the page's own GET URL", () => {
  const base = "/ns/flags";
  assert.equal(Core.canonicalPath("/ns/flags/foo/actors", base, "foo"), "/ns/flags/foo");
  assert.equal(Core.canonicalPath("/ns/flags/foo/percentage", base, "foo"), "/ns/flags/foo");
  assert.equal(Core.canonicalPath("/ns/flags/Ook%3F%20Ook!/groups", base, "Ook? Ook!"), "/ns/flags/Ook%3F%20Ook!");
  assert.equal(Core.canonicalPath("/ns/flags/foo", base, "foo"), null);
  assert.equal(Core.canonicalPath("/ns/flags/Ook%3F%20Ook!", base, "Ook? Ook!"), null);
  assert.equal(Core.canonicalPath("/ns/flags", base, null), null);
  assert.equal(Core.canonicalPath("/ns/flags/", base, null), null);
  // POST /flags (create) failing renders `new`, not this page; but a list
  // page at any other URL is put back on the list URL
  assert.equal(Core.canonicalPath("/ns/flags/foo/actors", base, null), "/ns/flags");
});

test("expectedLanding: Delete Flag lands on the list, every other panel form on the flag", () => {
  const base = "/ns/flags";
  assert.equal(Core.expectedLanding("DELETE", "/ns/flags/foo", base, "foo"), null);
  assert.equal(Core.expectedLanding("delete", "/ns/flags/foo", base, "foo"), null);
  assert.equal(Core.expectedLanding("DELETE", "/ns/flags/foo/actors/user:1", base, "foo"), "foo");
  assert.equal(Core.expectedLanding("PATCH", "/ns/flags/foo/boolean", base, "foo"), "foo");
  assert.equal(Core.expectedLanding("post", "/ns/flags/foo/actors", base, "foo"), "foo");
  assert.equal(Core.expectedLanding("DELETE", "/ns/flags/foo/actors", base, "foo"), "foo");
  assert.equal(Core.expectedLanding("post", "/ns/flags/foo", base, null), null);
});

test("parseRestorePoint: only a fresh, well-formed point meant for this page", () => {
  const now = NOW;
  const point = (o) => JSON.stringify(Object.assign({ at: now - 1000, query: "?q=gpu", scroll: 120, expect: "foo" }, o));
  assert.deepEqual(Core.parseRestorePoint(point({}), now, "foo"), { query: "?q=gpu", scroll: 120 });
  assert.deepEqual(Core.parseRestorePoint(Core.makeRestorePoint(now, "", 0, null), now, null), { query: "", scroll: 0 });
  // stale
  assert.equal(Core.parseRestorePoint(point({ at: now - 61 * 1000 }), now, "foo"), null);
  assert.equal(Core.parseRestorePoint(point({ at: now + 5000 }), now, "foo"), null);
  // meant for another page: a submit that never landed, then a later visit
  assert.equal(Core.parseRestorePoint(point({}), now, null), null);
  assert.equal(Core.parseRestorePoint(point({}), now, "bar"), null);
  assert.equal(Core.parseRestorePoint(point({ expect: null }), now, "foo"), null);
  // junk
  for (const q of [42, null, { a: 1 }, ["?q"], "q=no-question-mark", "/elsewhere"]) {
    assert.equal(Core.parseRestorePoint(point({ query: q }), now, "foo"), null, JSON.stringify(q));
  }
  assert.equal(Core.parseRestorePoint("not json", now, "foo"), null);
  assert.equal(Core.parseRestorePoint("null", now, "foo"), null);
  assert.equal(Core.parseRestorePoint(point({ at: "yesterday" }), now, "foo"), null);
  assert.deepEqual(Core.parseRestorePoint(point({ scroll: "lots" }), now, "foo"), { query: "?q=gpu", scroll: 0 });
});

test("shouldRestoreListScroll: on narrow screens only when landing on the list", () => {
  assert.equal(Core.shouldRestoreListScroll(false, "foo"), true);
  assert.equal(Core.shouldRestoreListScroll(false, null), true);
  assert.equal(Core.shouldRestoreListScroll(true, null), true);
  assert.equal(Core.shouldRestoreListScroll(true, "foo"), false);
});

test("decodeHash: malformed hashes don't throw", () => {
  assert.equal(Core.decodeHash("#actor_user%3A1"), "actor_user:1");
  assert.equal(Core.decodeHash("#actor_a%20b"), "actor_a b");
  assert.equal(Core.decodeHash("#%"), null);
  assert.equal(Core.decodeHash("#%E0%A4%A"), null);
  assert.equal(Core.decodeHash("#"), null);
  assert.equal(Core.decodeHash(""), null);
});


// --- Round 6: filter bar, [ ], percentage input ------------------------

test("activeFilterCount counts status, gate types and quick filters, not the search", () => {
  assert.equal(Core.activeFilterCount(state()), 0);
  assert.equal(Core.activeFilterCount(state({ q: "gpu" })), 0);
  assert.equal(Core.activeFilterCount(state({ status: "on", types: ["actor", "group"], pinned: true, mine: true })), 5);
});

test("describeFilters says what is filtering, for the no-results state", () => {
  assert.equal(Core.describeFilters(state()), "");
  assert.equal(
    Core.describeFilters(state({ q: "gpu", status: "partial", types: ["actor", "percentage"], mine: true })),
    "“gpu” · status Partial · gates actor, % · mine"
  );
  assert.equal(Core.describeFilters(state({ pinned: true, new: true })), "pinned · new");
});

test("clearedState keeps the sort, and the search unless asked", () => {
  const s = state({ q: "gpu", status: "on", types: ["actor"], pinned: true, sort: "created_desc" });
  assert.deepEqual(Core.clearedState(s, false), state({ q: "gpu", sort: "created_desc" }));
  assert.deepEqual(Core.clearedState(s, true), state({ sort: "created_desc" }));
});

test("neighborName: [ and ] step through the visible order", () => {
  const names = ["a", "b", "c"];
  assert.equal(Core.neighborName(names, "b", 1), "c");
  assert.equal(Core.neighborName(names, "b", -1), "a");
  assert.equal(Core.neighborName(names, "c", 1), null);
  assert.equal(Core.neighborName(names, "a", -1), null);
  assert.equal(Core.neighborName(names, "hidden", 1), "a");
  assert.equal(Core.neighborName(names, "hidden", -1), "c");
  assert.equal(Core.neighborName([], "a", 1), null);
});
