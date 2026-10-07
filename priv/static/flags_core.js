// Pure search / filter / sort logic for the flags page. No DOM access in
// here: flags.js reads the rows into plain objects and calls these.
// Exercised by test/js/flags_core.test.js (`node --test test/js`).
//
// A flag, as read from a list row:
//   {name, nameLower, status: "on"|"partial"|"off", types: ["boolean", ...],
//    created: <ms since epoch> | null,
//    targets: [{kind: "actor"|"group", value, lower}]}
//
// The view state, which lives in the query string:
//   {q, status: ""|"on"|"partial"|"off", types: [...],
//    pinned: bool, new: bool, mine: bool, sort: "name_asc" | ... | null}
//
(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.FwfCore = api;
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var STATUSES = ["on", "partial", "off"];
  var TYPES = ["boolean", "actor", "group", "percentage"];
  var CHIPS = ["pinned", "new", "mine"];
  var SORT_KEYS = ["name", "created", "status"];
  var STATUS_ORDER = { on: 0, partial: 1, off: 2 };
  var DEFAULT_SORT = "name_asc";
  var NEW_DAYS = 14;
  var DAY_MS = 24 * 60 * 60 * 1000;

  // --- search ---------------------------------------------------------

  function parseTerms(q) {
    return String(q || "").toLowerCase().split(/\s+/).filter(Boolean);
  }

  function occurrences(haystack, needle) {
    var out = [];
    var from = 0;
    var idx;
    while ((idx = haystack.indexOf(needle, from)) !== -1) {
      out.push([idx, idx + needle.length]);
      from = idx + 1;
    }
    return out;
  }

  function mergeRanges(ranges) {
    var sorted = ranges.slice().sort(function (a, b) { return a[0] - b[0] || a[1] - b[1]; });
    var out = [];
    sorted.forEach(function (r) {
      var last = out[out.length - 1];
      if (last && r[0] <= last[1]) {
        last[1] = Math.max(last[1], r[1]);
      } else {
        out.push([r[0], r[1]]);
      }
    });
    return out;
  }

  // Every term must match, either in the name or in a gate target
  // (actor ID, group name). Case-insensitive substring.
  //
  // Returns {match, ranges, hits}: `ranges` are the [start, end) spans of
  // the name to highlight; `hits` are the targets that matched terms not
  // found in the name.
  //
  function matchFlag(flag, terms) {
    if (!terms.length) return { match: true, ranges: [], hits: [] };

    var ranges = [];
    var hits = [];

    for (var i = 0; i < terms.length; i++) {
      var term = terms[i];
      var inName = occurrences(flag.nameLower, term);
      if (inName.length) {
        ranges = ranges.concat(inName);
        continue;
      }

      var hit = null;
      for (var j = 0; j < flag.targets.length; j++) {
        if (flag.targets[j].lower.indexOf(term) !== -1) {
          hit = flag.targets[j];
          break;
        }
      }
      if (!hit) return { match: false, ranges: [], hits: [] };
      if (hits.indexOf(hit) === -1) hits.push(hit);
    }

    return { match: true, ranges: mergeRanges(ranges), hits: hits };
  }

  // Splits `text` into [{text, hit}] segments, for building highlighted
  // markup with text nodes (never HTML strings).
  //
  function splitByRanges(text, ranges) {
    var out = [];
    var pos = 0;
    ranges.forEach(function (r) {
      if (r[0] > pos) out.push({ text: text.slice(pos, r[0]), hit: false });
      out.push({ text: text.slice(r[0], r[1]), hit: true });
      pos = r[1];
    });
    if (pos < text.length) out.push({ text: text.slice(pos), hit: false });
    return out;
  }

  // "a_b_c" -> ["a_", "b_", "c"]: the pieces between line-break
  // opportunities. The server renders a <wbr> after every underscore in a
  // name; the DOM code puts one between these pieces when it rebuilds a
  // highlighted name. Joining the pieces gives the text back unchanged.
  //
  function breakAfterUnderscores(text) {
    return text.match(/[^_]*_+|[^_]+$/g) || [];
  }

  function describeHits(hits) {
    return hits.map(function (h) { return h.kind + " " + h.value; }).join(" · ");
  }

  // The line under a row that matched on a gate target only, e.g.
  // "matches actor workspace:2809". "" when there is nothing to show.
  //
  function hitLabel(hits) {
    return hits.length ? "matches " + describeHits(hits) : "";
  }

  // --- filters --------------------------------------------------------

  function isNew(created, now) {
    return created !== null && created !== undefined && now - created <= NEW_DAYS * DAY_MS;
  }

  // An actor gate whose ID is the viewer's email, or ends in ":" + email
  // ("email:ana@example.com", "user:ana@example.com"). Case-insensitive.
  // Not a substring match: "a@x.io" must not match "email:ba@x.io".
  //
  function isMine(flag, viewer) {
    if (!viewer) return false;
    var email = viewer.toLowerCase();
    var suffix = ":" + email;
    return flag.targets.some(function (t) {
      if (t.kind !== "actor") return false;
      return t.lower === email ||
        (t.lower.length > suffix.length && t.lower.slice(-suffix.length) === suffix);
    });
  }

  // ctx: {pins: Set of names, now: ms, viewer: string}
  //
  function passesFilters(flag, state, ctx) {
    if (state.status && flag.status !== state.status) return false;
    if (state.types.length && !state.types.some(function (t) { return flag.types.indexOf(t) !== -1; })) return false;
    if (state.pinned && !ctx.pins.has(flag.name)) return false;
    if (state.new && !isNew(flag.created, ctx.now)) return false;
    if (state.mine && !isMine(flag, ctx.viewer)) return false;
    return true;
  }

  function hasAnyCreated(flags) {
    return flags.some(function (f) { return f.created !== null && f.created !== undefined; });
  }

  // --- pins (localStorage, a JSON array of names) ----------------------

  // A Set, not a plain object: flag names like "constructor", "toString"
  // or "__proto__" must behave like any other name. Junk reads as no pins.
  //
  function parsePins(raw) {
    var pins = new Set();
    try {
      var arr = JSON.parse(raw || "[]");
      if (Array.isArray(arr)) {
        arr.forEach(function (n) { if (typeof n === "string") pins.add(n); });
      }
    } catch (e) { /* junk: no pins */ }
    return pins;
  }

  function serializePins(pins) {
    return JSON.stringify(Array.from(pins).sort());
  }

  // Returns whether `name` is pinned afterwards.
  function togglePin(pins, name) {
    if (pins.has(name)) {
      pins.delete(name);
      return false;
    }
    pins.add(name);
    return true;
  }

  // --- sorting --------------------------------------------------------

  // Accepts the values the previous inline sort script stored in
  // localStorage["fwf-sort"]: "name_asc", "status_desc", "created_asc", ...
  //
  function parseSort(value) {
    var m = /^(name|created|status)_(asc|desc)$/.exec(String(value || ""));
    if (!m) return { key: "name", dir: "asc" };
    return { key: m[1], dir: m[2] };
  }

  function sortValue(sort) {
    return sort.key + "_" + sort.dir;
  }

  function compareNames(a, b) {
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
  }

  function comparator(sort) {
    var sign = sort.dir === "desc" ? -1 : 1;
    if (sort.key === "status") {
      return function (a, b) {
        return sign * (STATUS_ORDER[a.status] - STATUS_ORDER[b.status]) || compareNames(a, b);
      };
    }
    if (sort.key === "created") {
      // Flags without a creation date go last in both directions.
      return function (a, b) {
        var ca = a.created, cb = b.created;
        var na = ca === null || ca === undefined, nb = cb === null || cb === undefined;
        if (na && nb) return compareNames(a, b);
        if (na) return 1;
        if (nb) return -1;
        return sign * (ca - cb) || compareNames(a, b);
      };
    }
    return function (a, b) { return sign * compareNames(a, b); };
  }

  function sortFlags(flags, sort) {
    return flags.slice().sort(comparator(sort));
  }

  // --- view state <-> query string -------------------------------------

  function emptyState() {
    return { q: "", status: "", types: [], pinned: false, new: false, mine: false, sort: null };
  }

  function parseQuery(search) {
    var params = new URLSearchParams(search || "");
    var state = emptyState();
    state.q = params.get("q") || "";
    var status = params.get("status");
    if (STATUSES.indexOf(status) !== -1) state.status = status;
    state.types = (params.get("type") || "").split(",").filter(function (t) { return TYPES.indexOf(t) !== -1; });
    CHIPS.forEach(function (chip) { state[chip] = params.get(chip) === "1"; });
    var sort = params.get("sort");
    if (sort && parseSort(sort).key + "_" + parseSort(sort).dir === sort) state.sort = sort;
    return state;
  }

  // Only non-default values go in the URL; "" when nothing is set.
  // Keys that are not ours (e.g. audit_page) are not carried over.
  //
  function buildQuery(state) {
    var params = new URLSearchParams();
    if (state.q) params.set("q", state.q);
    if (state.status) params.set("status", state.status);
    if (state.types.length) params.set("type", state.types.join(","));
    CHIPS.forEach(function (chip) { if (state[chip]) params.set(chip, "1"); });
    if (state.sort && state.sort !== DEFAULT_SORT) params.set("sort", state.sort);
    var qs = params.toString();
    return qs ? "?" + qs : "";
  }

  function hasViewState(search) {
    return buildQuery(parseQuery(search)) !== "";
  }

  // "/ns/flags/foo%3F" with base "/ns/flags" -> "foo?"; "/ns/flags" -> null.
  //
  function nameFromPath(pathname, base) {
    var prefix = base.replace(/\/+$/, "") + "/";
    if (pathname.indexOf(prefix) !== 0) return null;
    var rest = pathname.slice(prefix.length);
    if (!rest || rest.indexOf("/") !== -1) return null;
    try {
      return decodeURIComponent(rest);
    } catch (e) {
      return null;
    }
  }

  function flagPath(base, name) {
    return base.replace(/\/+$/, "") + "/" + encodeURIComponent(name);
  }

  // The page's own GET URL, when the address bar shows something else.
  // A validation error (400) renders the page at the POST URL
  // (/flags/foo/actors); replaceState-ing view state onto that URL would make
  // reload a GET of a route that doesn't exist. `selected` is the flag the
  // server rendered (body[data-selected]), or null for the list.
  // Returns the path to replaceState to, or null when the path is fine.
  //
  function canonicalPath(pathname, base, selected) {
    var trimmedBase = base.replace(/\/+$/, "");
    if (selected === null || selected === undefined) {
      return pathname.replace(/\/+$/, "") === trimmedBase ? null : trimmedBase;
    }
    return nameFromPath(pathname, base) === selected ? null : flagPath(base, selected);
  }

  // --- keeping state across a gate edit -------------------------------

  var RESTORE_MAX_AGE_MS = 60 * 1000;

  // Which page a form post lands on: deleting the whole flag (DELETE to the
  // flag's own URL) redirects to the list (null); every other form in the
  // panel redirects back to that flag (or re-renders it with a 400).
  //
  function expectedLanding(method, actionPath, base, currentName) {
    if (currentName === null || currentName === undefined) return null;
    var deletesFlag = String(method).toUpperCase() === "DELETE" &&
      nameFromPath(actionPath, base) === currentName;
    return deletesFlag ? null : currentName;
  }

  function makeRestorePoint(now, query, scroll, expect) {
    return JSON.stringify({ at: now, query: query, scroll: scroll, expect: expect });
  }

  // The restore point, if it is valid, fresh, and meant for the page we
  // landed on (`landing`: the server-selected flag, or null for the list).
  // A submit that never reached a flags page (CSRF error, network drop)
  // leaves a point behind; it must not apply to some later, unrelated visit.
  //
  function parseRestorePoint(raw, now, landing) {
    var point;
    try { point = JSON.parse(raw); } catch (e) { return null; }
    if (!point || typeof point !== "object") return null;
    if (typeof point.at !== "number" || now - point.at < 0 || now - point.at > RESTORE_MAX_AGE_MS) return null;
    if (typeof point.query !== "string" || (point.query !== "" && point.query.charAt(0) !== "?")) return null;
    var expect = point.expect === undefined ? null : point.expect;
    if (expect !== (landing === undefined ? null : landing)) return null;
    var scroll = typeof point.scroll === "number" && point.scroll > 0 ? point.scroll : 0;
    return { query: point.query, scroll: scroll };
  }

  // Narrow (one-column) layout: the list and the panel share the window
  // scroll. After a gate edit we land on the panel, scrolled by the browser
  // to #actor_x; restoring the list's old window scroll there would override
  // that. So on narrow screens only restore when we land on the list.
  //
  function shouldRestoreListScroll(narrow, landing) {
    return !narrow || landing === null || landing === undefined;
  }

  // "#actor_x%20y" -> "actor_x y"; null for no hash or a malformed one
  // (a hand-typed "#%" makes decodeURIComponent throw).
  //
  function decodeHash(hash) {
    if (!hash || hash.length < 2) return null;
    try {
      return decodeURIComponent(hash.slice(1));
    } catch (e) {
      return null;
    }
  }

  // --- filter bar -----------------------------------------------------

  // How many filters narrow the list (search excluded: it has its own box).
  function activeFilterCount(state) {
    return (state.status ? 1 : 0) + state.types.length +
      CHIPS.filter(function (c) { return state[c]; }).length;
  }

  var STATUS_LABELS = { on: "On", partial: "Partial", off: "Off" };
  var TYPE_LABELS = { boolean: "boolean", actor: "actor", group: "group", percentage: "%" };
  var CHIP_LABELS = { pinned: "pinned", new: "new", mine: "mine" };

  // For the no-results state: "“gpu” · status Partial · gates actor, % · mine"
  function describeFilters(state) {
    var parts = [];
    if (state.q) parts.push("“" + state.q + "”");
    if (state.status) parts.push("status " + STATUS_LABELS[state.status]);
    if (state.types.length) parts.push("gates " + state.types.map(function (t) { return TYPE_LABELS[t]; }).join(", "));
    CHIPS.forEach(function (c) { if (state[c]) parts.push(CHIP_LABELS[c]); });
    return parts.join(" · ");
  }

  // Clear filters (and, with `search`, the search box); sort stays.
  function clearedState(state, search) {
    var next = emptyState();
    next.sort = state.sort;
    if (!search) next.q = state.q;
    return next;
  }

  // The previous/next name in the visible order, for [ and ].
  // Without a current flag (or one filtered out): the first/last.
  function neighborName(names, current, step) {
    if (!names.length) return null;
    var i = names.indexOf(current);
    if (i === -1) return step > 0 ? names[0] : names[names.length - 1];
    var j = i + step;
    return j >= 0 && j < names.length ? names[j] : null;
  }

  // --- display --------------------------------------------------------

  function relativeTime(then, now) {
    var s = Math.round((now - then) / 1000);
    if (s < 0) s = 0;
    if (s < 60) return "just now";
    var m = Math.round(s / 60);
    if (m < 60) return m + " min ago";
    var h = Math.round(m / 60);
    if (h < 24) return h + " h ago";
    var d = Math.round(h / 24);
    if (d < 31) return d === 1 ? "yesterday" : d + " days ago";
    var mo = Math.round(d / 30.44);
    if (mo < 12) return mo === 1 ? "1 month ago" : mo + " months ago";
    var y = Math.round(d / 365.25);
    return y === 1 ? "1 year ago" : y + " years ago";
  }

  function countLabel(visible, total) {
    var noun = total === 1 ? "flag" : "flags";
    return visible === total ? total + " " + noun : visible + " of " + total + " " + noun;
  }

  return {
    STATUSES: STATUSES,
    TYPES: TYPES,
    CHIPS: CHIPS,
    SORT_KEYS: SORT_KEYS,
    DEFAULT_SORT: DEFAULT_SORT,
    NEW_DAYS: NEW_DAYS,
    parseTerms: parseTerms,
    mergeRanges: mergeRanges,
    matchFlag: matchFlag,
    splitByRanges: splitByRanges,
    breakAfterUnderscores: breakAfterUnderscores,
    describeHits: describeHits,
    hitLabel: hitLabel,
    isNew: isNew,
    parsePins: parsePins,
    serializePins: serializePins,
    togglePin: togglePin,
    canonicalPath: canonicalPath,
    expectedLanding: expectedLanding,
    makeRestorePoint: makeRestorePoint,
    parseRestorePoint: parseRestorePoint,
    shouldRestoreListScroll: shouldRestoreListScroll,
    decodeHash: decodeHash,
    isMine: isMine,
    passesFilters: passesFilters,
    hasAnyCreated: hasAnyCreated,
    parseSort: parseSort,
    sortValue: sortValue,
    sortFlags: sortFlags,
    emptyState: emptyState,
    parseQuery: parseQuery,
    buildQuery: buildQuery,
    hasViewState: hasViewState,
    nameFromPath: nameFromPath,
    flagPath: flagPath,
    relativeTime: relativeTime,
    countLabel: countLabel,
    activeFilterCount: activeFilterCount,
    describeFilters: describeFilters,
    clearedState: clearedState,
    neighborName: neighborName
  };
});
