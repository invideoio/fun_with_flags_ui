// Keyboard shortcuts for every page, and the "?" sheet that lists them.
//
// One table (BINDINGS) drives both the key handler and the sheet, so they
// can't drift. resolve() is pure: (key event facts, context) -> action, and
// is tested in test/js/shortcuts.test.js.
//
// Rules:
// - No shortcut ever changes a flag. They navigate, filter, focus and copy.
// - Nothing fires while typing in a field or with Ctrl/Cmd/Alt held, except
//   the explicit Cmd+K / Ctrl+K, and Esc / ↓ in the flag search box.
// - Page actions are registered by the page's script (flags.js) through
//   FwfShortcuts.register(name, fn); a binding whose action isn't
//   registered on this page does nothing (and isn't listed on the sheet).
//
(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.FwfShortcuts = api;
    if (root.document) api.install(root.document, root);
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // keys: what the sheet shows. match: the KeyboardEvent.key values (a
  // "g f" style chord is two steps). where: "search" also fires while typing
  // in the flag search box; "any" fires even in other fields (only Mod+K).
  var BINDINGS = [
    { group: "Navigate", action: "focusSearch", label: "Search flags", keys: ["/"], match: ["/"] },
    { group: "Navigate", action: "focusSearch", label: "Search flags", keys: ["⌘K", "Ctrl K"], match: ["k"], mod: true, where: "any", hideOnSheet: true },
    { group: "Navigate", action: "next", label: "Next flag in the list", keys: ["j", "↓"], match: ["j", "ArrowDown"] },
    { group: "Navigate", action: "nextFromSearch", label: "From search to the list", keys: ["↓"], match: ["ArrowDown"], where: "search-only", hideOnSheet: true },
    { group: "Navigate", action: "prev", label: "Previous flag in the list", keys: ["k", "↑"], match: ["k", "ArrowUp"] },
    { group: "Navigate", action: "open", label: "Open the focused flag", keys: ["Enter", "o"], match: ["o"] },
    { group: "Navigate", action: "prevFlag", label: "Previous flag (panel open)", keys: ["["], match: ["["] },
    { group: "Navigate", action: "nextFlag", label: "Next flag (panel open)", keys: ["]"], match: ["]"] },
    { group: "Navigate", action: "escape", label: "Clear search · leave it · close the flag", keys: ["Esc"], match: ["Escape"], where: "search" },
    { group: "Go to", action: "goFlags", label: "Flags", keys: ["g", "f"], chord: "g", match: ["f"] },
    { group: "Go to", action: "goAudit", label: "Audit log", keys: ["g", "a"], chord: "g", match: ["a"] },
    { group: "Go to", action: "goSettings", label: "Settings", keys: ["g", "s"], chord: "g", match: ["s"] },
    { group: "Go to", action: "newFlag", label: "New flag", keys: ["n"], match: ["n"] },
    { group: "Filter", action: "statusAll", label: "Status: All", keys: ["1"], match: ["1"] },
    { group: "Filter", action: "statusOn", label: "Status: On", keys: ["2"], match: ["2"] },
    { group: "Filter", action: "statusPartial", label: "Status: Partial", keys: ["3"], match: ["3"] },
    { group: "Filter", action: "statusOff", label: "Status: Off", keys: ["4"], match: ["4"] },
    { group: "Filter", action: "toggleMine", label: "Only mine", keys: ["m"], match: ["m"] },
    { group: "Flag", action: "pin", label: "Pin / unpin the focused flag", keys: ["p"], match: ["p"] },
    { group: "Flag", action: "copy", label: "Copy the open flag's name", keys: ["c"], match: ["c"] },
    { group: "Flag", action: "addActor", label: "Add an actor to the open flag", keys: ["a"], match: ["a"] },
    { group: "Help", action: "help", label: "Show this sheet", keys: ["?"], match: ["?"] }
  ];

  var CHORD_TIMEOUT_MS = 1500;

  // ev: {key, ctrlKey, metaKey, altKey, target: "search" | "field" | "other"}
  // ctx: {pending: "g" | null}
  // -> {action: name | null, pending: "g" | null, consume: bool}
  //
  function resolve(ev, ctx) {
    var pending = ctx && ctx.pending ? ctx.pending : null;
    var mod = !!(ev.ctrlKey || ev.metaKey);
    var target = ev.target || "other";
    var key = ev.key;

    // Explicit modifier shortcuts (Cmd/Ctrl+K), anywhere.
    if (mod && !ev.altKey) {
      for (var m = 0; m < BINDINGS.length; m++) {
        var bm = BINDINGS[m];
        if (bm.mod && bm.match.indexOf(String(key).toLowerCase()) !== -1) {
          return { action: bm.action, pending: null, consume: true };
        }
      }
      return { action: null, pending: null, consume: false };
    }
    if (mod || ev.altKey) return { action: null, pending: null, consume: false };

    // In a field: only bindings that explicitly allow it.
    if (target !== "other") {
      for (var f = 0; f < BINDINGS.length; f++) {
        var bf = BINDINGS[f];
        if (bf.mod || bf.chord) continue;
        var allowed = (bf.where === "search" || bf.where === "search-only") ? target === "search" : bf.where === "any";
        if (allowed && bf.match.indexOf(key) !== -1) {
          return { action: bf.action, pending: null, consume: true };
        }
      }
      return { action: null, pending: null, consume: false };
    }

    // Second key of a chord.
    if (pending) {
      for (var c = 0; c < BINDINGS.length; c++) {
        var bc = BINDINGS[c];
        if (bc.chord === pending && bc.match.indexOf(key) !== -1) {
          return { action: bc.action, pending: null, consume: true };
        }
      }
      // Not a chord continuation: drop the chord and treat the key normally.
      pending = null;
    }

    // First key of a chord.
    for (var s = 0; s < BINDINGS.length; s++) {
      if (BINDINGS[s].chord === key) return { action: null, pending: key, consume: true };
    }

    for (var i = 0; i < BINDINGS.length; i++) {
      var b = BINDINGS[i];
      if (b.mod || b.chord || b.where === "search-only") continue;
      if (b.match.indexOf(key) !== -1) return { action: b.action, pending: null, consume: true };
    }
    return { action: null, pending: null, consume: false };
  }

  // Sheet rows for the actions available on this page, grouped.
  function sheetGroups(available) {
    var groups = [];
    var byName = {};
    BINDINGS.forEach(function (b) {
      if (b.hideOnSheet || !available(b.action)) return;
      if (!byName[b.group]) {
        byName[b.group] = { title: b.group, rows: [] };
        groups.push(byName[b.group]);
      }
      byName[b.group].rows.push({ label: b.label, keys: b.keys, chord: !!b.chord });
    });
    return groups;
  }

  // --- browser -------------------------------------------------------------

  var actions = {};

  function register(name, fn) {
    actions[name] = fn;
  }

  function targetKind(el) {
    if (!el || !el.tagName) return "other";
    if (el.id === "fwf-search") return "search";
    var tag = el.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || el.isContentEditable) return "field";
    return "other";
  }

  function install(doc, win) {
    if (doc.__fwfShortcutsInstalled) return;
    doc.__fwfShortcutsInstalled = true;
    if (doc.documentElement && doc.documentElement.classList) doc.documentElement.classList.add("fwf-js");

    function navHref(name) {
      var a = doc.querySelector('[data-nav="' + name + '"]');
      return a ? a.getAttribute("href") : null;
    }
    function go(name) {
      return function () {
        var href = navHref(name);
        if (href) win.location.href = href;
      };
    }

    // Available on every page; flags.js overrides focusSearch on its page.
    register("goFlags", go("flags"));
    register("goAudit", go("audit"));
    register("goSettings", go("settings"));
    register("newFlag", go("new"));
    // A page with its own search box (the audit log) focuses it; elsewhere
    // "/" goes to the flags page. flags.js overrides this on its page.
    register("focusSearch", function () {
      var box = doc.querySelector("[data-page-search]");
      if (box) {
        box.focus();
        if (box.select) box.select();
      } else {
        go("flags")();
      }
    });
    register("help", openSheet);

    var state = { pending: null, timer: null };

    doc.addEventListener("keydown", function (e) {
      if (e.defaultPrevented || e.isComposing) return;
      var sheet = doc.getElementById("fwf-shortcuts");
      if (sheet && sheet.open) return; // the dialog handles its own Esc
      var r = resolve({
        key: e.key, ctrlKey: e.ctrlKey, metaKey: e.metaKey, altKey: e.altKey,
        target: targetKind(e.target)
      }, state);

      win.clearTimeout(state.timer);
      state.pending = r.pending;
      if (r.pending) state.timer = win.setTimeout(function () { state.pending = null; }, CHORD_TIMEOUT_MS);

      if (r.action && actions[r.action]) {
        var handled = actions[r.action](e);
        if (handled !== false) e.preventDefault();
      } else if (r.pending) {
        e.preventDefault();
      }
    });

    doc.addEventListener("click", function (e) {
      var t = e.target && e.target.closest ? e.target.closest("[data-shortcuts-open]") : null;
      if (t) openSheet();
    });

    function openSheet() {
      var sheet = doc.getElementById("fwf-shortcuts") || buildSheet();
      if (typeof sheet.showModal === "function") sheet.showModal();
      else sheet.setAttribute("open", "");
    }

    // Built from BINDINGS with text nodes (no HTML strings).
    function buildSheet() {
      var d = doc.createElement("dialog");
      d.id = "fwf-shortcuts";
      d.className = "fwf-sheet";
      d.setAttribute("aria-labelledby", "fwf-shortcuts-title");

      var head = el("div", "fwf-sheet-head");
      var h = el("h2", null, "Keyboard shortcuts");
      h.id = "fwf-shortcuts-title";
      var close = el("button", "fwf-icon-btn");
      var header = doc.getElementById("fwf-top-bar");
      var NS = "http://www.w3.org/2000/svg";
      var svg = doc.createElementNS(NS, "svg");
      svg.setAttribute("class", "fwf-icon");
      svg.setAttribute("aria-hidden", "true");
      var use = doc.createElementNS(NS, "use");
      use.setAttribute("href", (header ? header.getAttribute("data-icons") : "") + "#hi-cancel");
      svg.appendChild(use);
      close.appendChild(svg);
      close.type = "button";
      close.setAttribute("aria-label", "Close");
      close.addEventListener("click", function () { d.close(); });
      head.appendChild(h);
      head.appendChild(close);
      d.appendChild(head);

      var body = el("div", "fwf-sheet-body");
      sheetGroups(function (name) { return !!actions[name]; }).forEach(function (g) {
        var section = el("section", "fwf-sheet-group");
        section.appendChild(el("h3", null, g.title));
        g.rows.forEach(function (row) {
          var line = el("div", "fwf-sheet-row");
          line.appendChild(el("span", null, row.label));
          var keys = el("span", "fwf-sheet-keys");
          row.keys.forEach(function (k, i) {
            if (i > 0) keys.appendChild(doc.createTextNode(row.chord ? " then " : " or "));
            keys.appendChild(el("kbd", null, k));
          });
          line.appendChild(keys);
          section.appendChild(line);
        });
        body.appendChild(section);
      });
      d.appendChild(body);
      d.appendChild(el("p", "fwf-sheet-foot", "Shortcuts never change a flag. They are off while you type in a field."));
      d.addEventListener("click", function (e) { if (e.target === d) d.close(); });
      doc.body.appendChild(d);
      return d;
    }

    function el(tag, cls, text) {
      var n = doc.createElement(tag);
      if (cls) n.className = cls;
      if (text !== undefined && text !== null) n.textContent = text;
      return n;
    }
  }

  return {
    BINDINGS: BINDINGS,
    resolve: resolve,
    sheetGroups: sheetGroups,
    register: register,
    install: install
  };
});
