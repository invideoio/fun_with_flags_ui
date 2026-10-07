// Theme: light / dark / system, saved in localStorage["fwf-theme"]
// ("light" | "dark", absent = system). The inline script in the page head
// applies it before first paint; this file wires the controls:
// - the header's theme button (every page) cycles system → light → dark;
// - the settings page's System / Light / Dark radios.
(function () {
  "use strict";

  var root = document.documentElement;
  root.classList.add("fwf-js");
  var media = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
  var ORDER = ["system", "light", "dark"];
  var LABELS = { system: "Theme: system", light: "Theme: light", dark: "Theme: dark" };

  function saved() {
    try {
      var v = localStorage.getItem("fwf-theme");
      return v === "dark" || v === "light" ? v : "system";
    } catch (e) {
      return "system";
    }
  }

  function apply(choice) {
    try {
      if (choice === "system") localStorage.removeItem("fwf-theme");
      else localStorage.setItem("fwf-theme", choice);
    } catch (e) { /* private mode: still apply for this page */ }
    var theme = choice === "system" ? (media && media.matches ? "dark" : "light") : choice;
    root.setAttribute("data-theme", theme);
    sync(choice);
  }

  var ICONS = { system: "computer", light: "sun", dark: "moon" };

  function sync(choice) {
    document.querySelectorAll("[data-theme-toggle]").forEach(function (b) {
      b.setAttribute("aria-label", LABELS[choice] + " (click to change)");
      b.title = LABELS[choice];
      var use = b.querySelector("use");
      if (use) use.setAttribute("href", use.getAttribute("href").replace(/#hi-[\w-]+$/, "#hi-" + ICONS[choice]));
    });
    document.querySelectorAll('input[name="fwf-theme"]').forEach(function (r) {
      r.checked = r.value === choice;
    });
  }

  document.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest("[data-theme-toggle]");
    if (!b) return;
    var next = ORDER[(ORDER.indexOf(saved()) + 1) % ORDER.length];
    apply(next);
  });

  document.addEventListener("change", function (e) {
    if (e.target && e.target.name === "fwf-theme") apply(e.target.value);
  });

  if (media && media.addEventListener) {
    media.addEventListener("change", function (e) {
      if (saved() === "system") root.setAttribute("data-theme", e.matches ? "dark" : "light");
    });
  }

  sync(saved());
})();
