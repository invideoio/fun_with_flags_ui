// Checks over priv/static/style.css that keep layout regressions from
// coming back (no CSS engine: a small brace parser with media-query context).
// Run: node --test 'test/js/*.test.js'
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const CSS = fs.readFileSync(path.join(__dirname, "../../priv/static/style.css"), "utf8");
const FLAGS_JS = fs.readFileSync(path.join(__dirname, "../../priv/static/flags.js"), "utf8");

// -> [{selectors: [..], decls: {prop: value}, media: ["(max-width: 959.98px)", ...], index}]
function parse(css) {
  const src = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const rules = [];
  let i = 0;
  function block(media) {
    while (i < src.length) {
      const open = src.indexOf("{", i);
      const close = src.indexOf("}", i);
      if (close !== -1 && (open === -1 || close < open)) { i = close + 1; return; }
      if (open === -1) { i = src.length; return; }
      const prelude = src.slice(i, open).trim();
      i = open + 1;
      if (prelude.startsWith("@media") || prelude.startsWith("@supports")) {
        block(media.concat([prelude]));
      } else if (prelude.startsWith("@")) {
        // @font-face, @keyframes: skip their body
        let depth = 1;
        while (depth > 0 && i < src.length) {
          if (src[i] === "{") depth++;
          if (src[i] === "}") depth--;
          i++;
        }
      } else {
        const end = src.indexOf("}", i);
        const body = src.slice(i, end);
        i = end + 1;
        const decls = {};
        body.split(";").forEach((d) => {
          const c = d.indexOf(":");
          if (c > 0) decls[d.slice(0, c).trim()] = d.slice(c + 1).trim();
        });
        rules.push({ selectors: prelude.split(",").map((s) => s.trim()), decls, media, index: rules.length });
      }
    }
  }
  block([]);
  return rules;
}

// Rough specificity: ids, then classes/attributes/pseudo-classes, then elements.
function specificity(sel) {
  const ids = (sel.match(/#[\w-]+/g) || []).length;
  const classes = (sel.match(/\.[\w-]+|\[[^\]]+\]|:(?!:)[\w-]+/g) || []).length;
  const elements = (sel.replace(/\[[^\]]+\]/g, "").match(/(^|[\s>+~])[a-z][\w-]*/gi) || []).length;
  return ids * 10000 + classes * 100 + elements;
}

const RULES = parse(CSS);
const targets = (sel, cls) => new RegExp("\\." + cls + "(?![\\w-])[^\\s>+~]*$").test(sel);
const NARROW = "(max-width: 959.98px)";

test("the parser sees the stylesheet", () => {
  assert.ok(RULES.length > 200);
  assert.ok(RULES.some((r) => r.media.some((m) => m.includes(NARROW))));
});

test("'All flags' (.fwf-back) is hidden except in the one-column layout", () => {
  const backRules = RULES.flatMap((r) => r.selectors.filter((s) => targets(s, "fwf-back")).map((s) => ({ s, r })))
    .filter(({ r }) => "display" in r.decls);

  const outside = backRules.filter(({ r }) => !r.media.some((m) => m.includes(NARROW)));
  assert.ok(outside.length >= 1, "a base rule hides it");
  for (const { s, r } of outside) {
    assert.equal(r.decls.display, "none", `outside the one-column query "${s}" sets display: ${r.decls.display} (rule #${r.index})`);
  }

  const inside = backRules.filter(({ r }) => r.media.some((m) => m.includes(NARROW)));
  assert.ok(inside.length >= 1, "the one-column query shows it");
  const base = Math.max(...outside.map(({ s }) => specificity(s)));
  for (const { s, r } of inside) {
    assert.notEqual(r.decls.display, "none");
    // wins regardless of source order
    assert.ok(specificity(s) > base, `"${s}" must out-rank the base .fwf-back rule`);
  }
});

test("the one-column breakpoint in CSS is the one flags.js uses", () => {
  const m = /NARROW_QUERY = "([^"]+)"/.exec(FLAGS_JS);
  assert.ok(m);
  assert.equal(m[1], NARROW);
  assert.ok(RULES.some((r) => r.media.some((q) => q.includes("(min-width: 960px)"))));
});

test("placeholders are Inter, typed identifiers stay mono", () => {
  const mono = RULES.find((r) => r.selectors.includes(".fwf-input--mono") && r.media.length === 0);
  assert.equal(mono.decls["font-family"], "var(--mono)");
  const ph = RULES.find((r) => r.selectors.includes(".fwf-input--mono::placeholder"));
  assert.ok(ph, "a placeholder rule exists");
  assert.equal(ph.decls["font-family"], "var(--font)");
  assert.ok(ph.index > mono.index);
});

test("Add and 'Add as off' are one unit that doesn't wrap apart", () => {
  const actions = RULES.find((r) => r.selectors.includes(".fwf-add-actions"));
  assert.ok(actions);
  assert.equal(actions.decls.display, "inline-flex");
  assert.equal(actions.decls.flex, "none");
  const input = RULES.filter((r) => r.selectors.includes(".fwf-add .fwf-input")).pop();
  assert.equal(input.decls.flex, "1 1 120px");
});

test("no pill / stadium shapes (one small radius everywhere)", () => {
  for (const r of RULES) {
    const radius = r.decls["border-radius"];
    if (!radius) continue;
    assert.doesNotMatch(radius, /999px|50%/, r.selectors.join(", "));
  }
});

// Round 8: the toolbar's controls are fills, not outlines.
test("toolbar controls have no border (the fill carries the boundary)", () => {
  const controls = [".fwf-search", ".fwf-seg", ".fwf-seg > button", ".fwf-chip", ".fwf-select", ".fwf-sort-dir", ".fwf-filters-toggle", ".fwf-new-flag"];
  const setsBorderWidth = (r) => ["border", "border-width", "border-top", "border-bottom", "border-left", "border-right"].some((p) => p in r.decls);
  const zero = (v) => /^(0|none|0px)(\s|$)/.test(v);
  const endsWith = (sel, c) => sel === c || sel.endsWith(" " + c) || sel.endsWith(">" + c.replace(/^\S+ > /, " > "));

  for (const c of controls) {
    const toolbarSel = ".fwf-toolbar " + c;
    const own = RULES.filter((r) => r.selectors.includes(toolbarSel) && r.media.length === 0 && "border" in r.decls);
    assert.ok(own.length > 0, `${toolbarSel} sets border`);
    own.forEach((r) => assert.ok(zero(r.decls.border), `${toolbarSel} border: ${r.decls.border}`));
    const mine = Math.max(...own.map(() => specificity(toolbarSel)));

    // nothing that also reaches this control may put a border width back
    for (const r of RULES) {
      if (!setsBorderWidth(r)) continue;
      for (const s of r.selectors) {
        const base = s.replace(/:(hover|focus|focus-visible|active)$/, "").replace(/\[aria-[^\]]+\]$/, "");
        const reaches = base === c || base.endsWith(" " + c) || (c.includes(" > ") && base.endsWith(c));
        if (!reaches) continue;
        const values = ["border", "border-width", "border-top", "border-bottom", "border-left", "border-right"].filter((p) => p in r.decls).map((p) => r.decls[p]);
        if (values.every(zero)) continue;
        const inToolbar = s.includes(".fwf-toolbar");
        assert.ok(!inToolbar, `toolbar rule "${s}" adds a border to ${c}`);
        assert.ok(specificity(s) < mine || r.index < own[own.length - 1].index && specificity(s) <= mine,
          `"${s}" (rule #${r.index}) would out-rank "${toolbarSel} { border: 0 }"`);
      }
    }
  }
});

test("selected toolbar toggles are a fill, not an outline", () => {
  const sel = RULES.find((r) => r.selectors.includes('.fwf-toolbar .fwf-chip[aria-pressed="true"]'));
  assert.ok(sel);
  assert.equal(sel.decls.background, "var(--toggle-on-bg)");
  assert.ok(!("border" in sel.decls) && !("outline" in sel.decls));
  const base = RULES.find((r) => r.selectors.includes(".fwf-toolbar .fwf-chip") && "box-shadow" in r.decls);
  assert.equal(base.decls["box-shadow"], "none");
  const ring = RULES.find((r) => r.selectors.includes(".fwf-toolbar .fwf-chip:focus-visible"));
  assert.ok(ring && /2px solid/.test(ring.decls.outline), "keyboard focus ring kept");
});

// Round 11: primary actions are a Dusk-derived blue with white ink.
function luminance(hex) {
  const v = hex.replace("#", "");
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(v.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}
const tokens = (selector) => RULES.find((r) => r.selectors.includes(selector) && r.media.length === 0).decls;

test("primary blue: same in both themes, white ink at AA or better", () => {
  const light = tokens(":root");
  const dark = tokens('[data-theme="dark"]');
  for (const t of [light, dark]) {
    assert.equal(t["--primary"], "#1a73bd");
    assert.equal(t["--primary-hover"], "#1665a8");
    assert.equal(t["--primary-active"], "#135a96");
    assert.equal(t["--on-primary"], "#ffffff");
    assert.ok(contrast(t["--on-primary"], t["--primary"]) >= 4.5, "white on primary " + contrast(t["--on-primary"], t["--primary"]).toFixed(2));
    assert.ok(contrast(t["--on-primary"], t["--primary-hover"]) >= contrast(t["--on-primary"], t["--primary"]));
    assert.ok(contrast(t["--on-primary"], t["--primary-active"]) >= contrast(t["--on-primary"], t["--primary-hover"]));
    // the button stays distinct from the page in both themes (non-text 3:1)
    assert.ok(contrast(t["--primary"], t["--bg"]) >= 3, "primary vs bg " + contrast(t["--primary"], t["--bg"]).toFixed(2));
  }
});

test("every primary fill uses the primary pair; no Dusk fill or Black-hole ink on blue is left", () => {
  assert.doesNotMatch(CSS, /--dusk|--on-dusk/);
  for (const sel of [".fwf-btn--primary", '.fwf-chip[aria-pressed="true"]', ".fwf-chip-count"]) {
    const r = RULES.find((x) => x.selectors.includes(sel) && x.media.length === 0);
    assert.equal(r.decls.background, "var(--primary)", sel);
    assert.equal(r.decls.color, "var(--on-primary)", sel);
  }
  const hover = RULES.find((x) => x.selectors.includes(".fwf-btn--primary:hover"));
  assert.equal(hover.decls.background, "var(--primary-hover)");
  const active = RULES.find((x) => x.selectors.includes(".fwf-btn--primary:active"));
  assert.equal(active.decls.background, "var(--primary-active)");
  // the n key cap: white at low opacity on the blue
  const kbd = RULES.filter((x) => x.selectors.includes(".fwf-toolbar .fwf-new-flag .fwf-btn-kbd") && x.media.length === 0).pop();
  assert.match(kbd.decls.background, /^rgba\(255, 255, 255, 0\.\d+\)$/);
  assert.equal(kbd.decls.color, "#ffffff");
});

// Round 12: no outlines on controls anywhere (panel, New flag, Audit log,
// Settings, the sheet, the phone Filters). Fills carry the boundary;
// containers (card, list, table, sections) may keep hairline separators.
const CONTROLS = [
  "fwf-input", "fwf-select", "fwf-btn", "fwf-icon-btn", "fwf-seg", "fwf-seg-item",
  "fwf-chip", "fwf-sort-dir", "fwf-switch", "fwf-switch-track", "fwf-radio-card",
  "fwf-file", "fwf-kbd", "fwf-app-badge", "fwf-banner", "fwf-filters-toggle", "fwf-new-flag",
];
const BORDER_PROPS = ["border", "border-width", "border-top", "border-bottom", "border-left", "border-right", "border-color", "outline"];
const noBorder = (v) => /^(0|none|0px|transparent)(\s|$)/.test(v);
// the element a selector styles: its last compound, e.g. ".fwf-seg > label:has(x)" -> "label:has(x)" (parent ".fwf-seg")
function subject(sel) {
  const parts = sel.replace(/:has\([^)]*\)/g, "").split(/\s*[>+~]\s*|\s+/).filter(Boolean);
  return { last: parts[parts.length - 1], parent: parts[parts.length - 2] || "" };
}
function controlOf(sel) {
  const { last, parent } = subject(sel);
  if (/^kbd\b/.test(last)) return "kbd";
  // .fwf-seg > label / > button are the segments
  if (/^(label|button)\b/.test(last) && /\.fwf-seg\b/.test(parent)) return "fwf-seg > " + last.split(/[:[]/)[0];
  return CONTROLS.find((c) => new RegExp("\\." + c + "(?![\\w-])").test(last)) || null;
}

test("no control has an outline: no border, ring or box-shadow outline outside :focus", () => {
  let checked = 0;
  for (const r of RULES) {
    for (const s of r.selectors) {
      const c = controlOf(s);
      if (!c) continue;
      checked++;
      const focus = /:focus(-visible)?|:has\([^)]*focus/.test(s);
      for (const p of BORDER_PROPS) {
        if (!(p in r.decls)) continue;
        if (p === "outline" && focus) continue; // the focus ring is the one allowed line
        assert.ok(noBorder(r.decls[p]), `"${s}" (rule #${r.index}) sets ${p}: ${r.decls[p]} on control ${c}`);
      }
      const shadow = r.decls["box-shadow"];
      if (shadow && !focus) {
        // a ring drawn with box-shadow (0 0 0 1px / inset 0 0 0 1px) is an outline too
        assert.doesNotMatch(shadow, /(^|,\s*)(inset\s+)?0\s+0\s+0\s+[1-9]/, `"${s}" (rule #${r.index}) draws a ring: ${shadow}`);
      }
    }
  }
  assert.ok(checked > 40, "the control selectors were found (" + checked + ")");
});

test("the outline guard catches an outline coming back (mutation check)", () => {
  const mutated = parse(CSS + "\n.fwf-panel .fwf-add .fwf-input { border: 1px solid var(--border); }\n.fwf-seg > label { box-shadow: 0 0 0 1px red; }");
  const bad = mutated.filter((r) => r.selectors.some(controlOf))
    .filter((r) => ("border" in r.decls && !noBorder(r.decls.border)) || /(^|,\s*)0\s+0\s+0\s+[1-9]/.test(r.decls["box-shadow"] || ""));
  assert.equal(bad.length, 2);
  assert.ok(!RULES.some((r) => r.selectors.some(controlOf) && "border" in r.decls && !noBorder(r.decls.border)));
});

test("base controls are fills: inputs on --field, secondary buttons on --btn", () => {
  const base = (sel) => RULES.filter((r) => r.selectors.includes(sel) && r.media.length === 0);
  assert.ok(base(".fwf-input").some((r) => r.decls["background-color"] === "var(--field)"));
  assert.ok(base(".fwf-btn").some((r) => r.decls.background === "var(--btn)" && r.decls.border === "0"));
  assert.ok(base(".fwf-seg").some((r) => r.decls.background === "var(--field)" && r.decls.border === "0"));
  // focus: the 2px ring, only on focus
  const focus = base(".fwf-input:focus");
  assert.ok(focus.length && focus.every((r) => /^2px solid var\(--focus\)/.test(r.decls.outline)));
});

test("the selected segment is unmistakable: an inverse fill, not a tint", () => {
  for (const sel of ['.fwf-seg [aria-pressed="true"]', ".fwf-seg .is-current", ".fwf-seg > label:has(input:checked)"]) {
    const r = RULES.find((x) => x.selectors.includes(sel));
    assert.ok(r, sel);
    assert.equal(r.decls.background, "var(--toggle-on-bg)", sel);
    assert.equal(r.decls.color, "var(--toggle-on-ink)", sel);
  }
  for (const t of [tokens(":root"), tokens('[data-theme="dark"]')]) {
    assert.ok(contrast(t["--toggle-on-ink"], t["--toggle-on-bg"]) >= 4.5);
    assert.ok(contrast(t["--toggle-on-bg"], t["--field"]) >= 3, "selected vs track");
  }
});

test("fills keep text at AA in both themes; buttons read a step stronger than fields", () => {
  for (const t of [tokens(":root"), tokens('[data-theme="dark"]')]) {
    for (const f of ["--field", "--btn"]) {
      assert.ok(contrast(t["--text"], t[f]) >= 4.5, f);
      assert.ok(contrast(t["--text-2"], t[f]) >= 4.5, "text-2 on " + f);
    }
    assert.ok(contrast(t["--field"], t["--surface"]) >= 1.2, "field visible on the card " + contrast(t["--field"], t["--surface"]).toFixed(2));
    assert.ok(contrast(t["--btn"], t["--surface"]) > contrast(t["--field"], t["--surface"]));
    // the switch: on is a calm green at 3:1 against the card; the knob is light
    assert.ok(contrast(t["--switch-on"], t["--surface"]) >= 3, "switch on vs surface");
    assert.ok(luminance(t["--switch-knob"]) > 0.8);
    // the selected list row keeps its secondary text at AA
    assert.ok(contrast(t["--text-2"], t["--selected"]) >= 4.5);
  }
  const ph = RULES.find((r) => r.selectors.includes(".fwf-input::placeholder"));
  assert.equal(ph.decls.color, "var(--text-2)");
});

test("switches are quiet: no visible On/Off word, no ring, the track carries state", () => {
  const label = RULES.filter((r) => r.selectors.includes(".fwf-switch-label")).pop();
  assert.equal(label.decls.position, "absolute");
  assert.equal(label.decls.width, "1px");
  const on = RULES.find((r) => r.selectors.includes('.fwf-switch[aria-checked="true"] .fwf-switch-track'));
  assert.equal(on.decls.background, "var(--switch-on)");
  assert.ok(!RULES.some((r) => r.selectors.includes('.fwf-switch[aria-checked="true"]') && "color" in r.decls), "no green word");
});

test("the selected list row is more than a tint: bar, stronger fill, semibold name", () => {
  const row = RULES.find((r) => r.selectors.includes(".fwf-row.is-selected"));
  assert.equal(row.decls.background, "var(--selected)");
  assert.match(row.decls["box-shadow"], /inset 3px 0 0 var\(--selected-bar\)/);
  const name = RULES.find((r) => r.selectors.includes(".fwf-row.is-selected .fwf-row-name"));
  assert.equal(name.decls["font-weight"], "600");
  for (const t of [tokens(":root"), tokens('[data-theme="dark"]')]) {
    assert.ok(contrast(t["--selected"], t["--surface"]) >= 1.25, "selected tint vs row " + contrast(t["--selected"], t["--surface"]).toFixed(2));
  }
});

// Round 13: hidden radios (position: absolute) whose containing block sat
// outside the panel column escaped its clipping and made the clipped root
// 96px taller than the viewport, so a #actor_x landing scrolled the root
// and hid the header. Each scroll column is the containing block of its
// absolute descendants, and so is every segmented-control label.
test("two-column scroll columns and segment labels contain their absolute descendants", () => {
  const rules = parse(CSS);
  const wide = (r) => r.media.some((m) => /min-width:\s*960px/.test(m));
  for (const sel of [".fwf-list-col", ".fwf-panel-col"]) {
    const r = rules.find((r) => wide(r) && r.selectors.includes(sel) && r.decls["overflow-y"] === "auto");
    assert.ok(r, sel + " scrolls at two columns");
    assert.equal(r.decls.position, "relative", sel);
  }
  const absInSeg = rules.filter((r) => r.selectors.some((s) => /^\.fwf-seg > label input$/.test(s)) && r.decls.position === "absolute");
  assert.ok(absInSeg.length > 0, "the hidden segment radio is absolute (the guard is meaningful)");
  assert.ok(rules.some((r) => r.selectors.includes(".fwf-seg > label") && r.decls.position === "relative"), ".fwf-seg > label is relative");
});
