// The flags page: client-side search / filter / sort of the server-rendered
// list, and swapping the right-hand panel without a full page load.
// Everything here is progressive: with JS off, rows are plain links to
// /flags/:name, which renders the same page with that flag's panel.
//
// Pure logic lives in flags_core.js (window.FwfCore).
//
(function () {
  "use strict";

  var Core = window.FwfCore;
  var body = document.body;
  var base = body.getAttribute("data-base");
  var viewer = body.getAttribute("data-viewer") || "";
  var list = document.getElementById("fwf-list");
  var listCol = document.getElementById("fwf-list-col");
  var panel = document.getElementById("fwf-panel");
  var search = document.getElementById("fwf-search");
  var filters = document.getElementById("fwf-filters");
  var countEl = document.getElementById("fwf-count");
  var emptyEl = document.getElementById("fwf-list-empty");
  var sortKeyEl = document.getElementById("fwf-sort-key");
  var sortDirEl = document.getElementById("fwf-sort-dir");
  var emptyTemplate = document.getElementById("fwf-panel-empty-template");
  var toolbar = document.getElementById("fwf-toolbar");
  var filtersToggle = document.getElementById("fwf-filters-toggle");
  var filtersCount = document.getElementById("fwf-filters-count");
  var activeFilters = document.getElementById("fwf-active-filters");
  var clearFiltersBtn = document.getElementById("fwf-clear-filters");
  var emptyText = document.getElementById("fwf-list-empty-text");
  var emptyClear = document.getElementById("fwf-list-empty-clear");
  if (!Core || !list || !panel) return;
  document.documentElement.classList.add("fwf-js");

  var SORT_STORAGE_KEY = "fwf-sort"; // shared with the previous list page
  var PINS_STORAGE_KEY = "fwf-pins:" + base;
  var RESTORE_KEY = "fwf-restore:" + base;
  // The flag the server rendered the page for (null: the list). Not read from
  // the URL: a validation error renders the page at the POST URL.
  var selectedName = body.hasAttribute("data-selected") ? body.getAttribute("data-selected") : null;
  // The one-column layout; keep in sync with the media queries in style.css.
  var NARROW_QUERY = "(max-width: 959.98px)";

  // A Hugeicons sprite icon (the sprite URL comes from the header, which
  // builds it through the mount path).
  function iconEl(name) {
    var header = document.getElementById("fwf-top-bar");
    var sprite = header ? header.getAttribute("data-icons") : "";
    var NS = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(NS, "svg");
    svg.setAttribute("class", "fwf-icon");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("focusable", "false");
    var use = document.createElementNS(NS, "use");
    use.setAttribute("href", sprite + "#hi-" + name);
    svg.appendChild(use);
    return svg;
  }

  // --- storage helpers (private mode / blocked storage must not break the page)

  function readStorage(store, key) {
    try { return window[store].getItem(key); } catch (e) { return null; }
  }
  function writeStorage(store, key, value) {
    try {
      if (value === null) window[store].removeItem(key);
      else window[store].setItem(key, value);
    } catch (e) { /* ignore */ }
  }

  function loadPins() {
    return Core.parsePins(readStorage("localStorage", PINS_STORAGE_KEY));
  }
  function savePins() {
    writeStorage("localStorage", PINS_STORAGE_KEY, Core.serializePins(pins));
  }

  // --- read the rows once ---------------------------------------------

  function splitTargets(value, kind) {
    if (!value) return [];
    return value.split("\n").filter(Boolean).map(function (v) {
      return { kind: kind, value: v, lower: v.toLowerCase() };
    });
  }

  var rows = Array.prototype.map.call(list.querySelectorAll("li.fwf-row"), function (li) {
    var d = li.dataset;
    var created = d.created ? Date.parse(d.created) : NaN;
    return {
      el: li,
      link: li.querySelector(".fwf-row-link"),
      nameEl: li.querySelector(".fwf-row-name"),
      hitEl: null, // created on the first target-only match
      pinEl: li.querySelector(".fwf-pin"),
      name: d.name,
      nameLower: d.name.toLowerCase(),
      status: d.status,
      types: d.types ? d.types.split(" ") : [],
      created: isNaN(created) ? null : created,
      targets: splitTargets(d.actors, "actor").concat(splitTargets(d.groups, "group")),
      highlighted: false
    };
  });

  // The invisible row that keeps the list's column widths stable while
  // filters hide rows (see .fwf-row-sizer in style.css).
  var sizer = list.querySelector("li.fwf-row-sizer");

  var pins = loadPins();
  var state = Core.emptyState();

  // --- rendering the list ---------------------------------------------

  function renderName(row, ranges) {
    if (!ranges.length && !row.highlighted) return;
    var name = row.nameEl;
    while (name.firstChild) name.removeChild(name.firstChild);
    Core.splitByRanges(row.name, ranges).forEach(function (seg) {
      var target = name;
      if (seg.hit) {
        target = document.createElement("mark");
        name.appendChild(target);
      }
      appendBreakable(target, seg.text);
    });
    row.highlighted = ranges.length > 0;
  }

  // Text nodes with a <wbr> after each underscore, like the server renders.
  function appendBreakable(parent, text) {
    Core.breakAfterUnderscores(text).forEach(function (piece) {
      parent.appendChild(document.createTextNode(piece));
      if (piece.charAt(piece.length - 1) === "_") parent.appendChild(document.createElement("wbr"));
    });
  }

  function renderHits(row, hits) {
    var label = Core.hitLabel(hits);
    if (label) {
      if (!row.hitEl) {
        // Its own grid item in the row link: a line of its own under the
        // name, spanning name through gate summary (see .fwf-row-hit in
        // style.css), so the matched target isn't clamped to the name column.
        row.hitEl = document.createElement("span");
        row.hitEl.className = "fwf-row-hit";
        row.link.appendChild(row.hitEl);
      }
      row.hitEl.textContent = label;
      row.hitEl.title = label;
      row.hitEl.hidden = false;
    } else if (row.hitEl && !row.hitEl.hidden) {
      row.hitEl.textContent = "";
      row.hitEl.title = "";
      row.hitEl.hidden = true;
    }
  }

  function applyView() {
    var terms = Core.parseTerms(state.q);
    var ctx = { pins: pins, now: Date.now(), viewer: viewer };
    var sort = Core.parseSort(state.sort || readStorage("localStorage", SORT_STORAGE_KEY));
    var visible = 0;

    Core.sortFlags(rows, sort).forEach(function (row) {
      var m = Core.matchFlag(row, terms);
      var show = m.match && Core.passesFilters(row, state, ctx);
      row.el.hidden = !show;
      if (show) {
        visible++;
        renderName(row, m.ranges);
        renderHits(row, m.hits);
      }
      list.appendChild(row.el); // re-appending in order sorts the list
    });
    if (sizer) list.appendChild(sizer); // stays last, after the sorted rows

    countEl.textContent = Core.countLabel(visible, rows.length);
    emptyEl.hidden = visible > 0;
    if (emptyText) {
      var described = Core.describeFilters(state);
      emptyText.textContent = described ? "No flags match " + described + "." : "No flags match.";
    }
    renderControls(sort);
  }

  function renderControls(sort) {
    if (document.activeElement !== search && search.value !== state.q) search.value = state.q;
    filters.querySelectorAll("[data-status]").forEach(function (b) {
      b.setAttribute("aria-pressed", String(b.getAttribute("data-status") === state.status));
    });
    filters.querySelectorAll("[data-type]").forEach(function (b) {
      b.setAttribute("aria-pressed", String(state.types.indexOf(b.getAttribute("data-type")) !== -1));
    });
    filters.querySelectorAll("[data-chip]").forEach(function (b) {
      b.setAttribute("aria-pressed", String(!!state[b.getAttribute("data-chip")]));
    });
    var active = Core.activeFilterCount(state);
    if (activeFilters) activeFilters.hidden = active === 0;
    if (clearFiltersBtn) clearFiltersBtn.textContent = active === 1 ? "Clear filter" : "Clear " + active + " filters";
    if (filtersCount) {
      filtersCount.hidden = active === 0;
      filtersCount.textContent = String(active);
    }
    sortKeyEl.value = sort.key;
    sortDirEl.setAttribute("data-dir", sort.dir);
    if (sortDirEl.getAttribute("data-dir-shown") !== sort.dir) {
      sortDirEl.textContent = "";
      sortDirEl.appendChild(iconEl(sort.dir === "asc" ? "arrow-up" : "arrow-down"));
      sortDirEl.setAttribute("data-dir-shown", sort.dir);
    }
    sortDirEl.setAttribute("aria-label", "Sort direction: " + (sort.dir === "asc" ? "ascending" : "descending"));
  }

  function renderPins() {
    rows.forEach(function (row) {
      var pinned = pins.has(row.name);
      if (!row.pinEl.firstChild) row.pinEl.appendChild(iconEl("star"));
      row.pinEl.setAttribute("aria-pressed", String(pinned));
      row.el.classList.toggle("is-pinned", pinned);
    });
  }

  // The filters live in the query string, so a filtered view is shareable.
  // replaceState: typing in the search box must not add history entries.
  //
  function syncUrl() {
    var url = location.pathname + Core.buildQuery(state) + location.hash;
    if (url !== location.pathname + location.search + location.hash) {
      history.replaceState(history.state, "", url);
    }
  }

  function update() {
    applyView();
    syncUrl();
  }

  // --- filter controls ------------------------------------------------

  var searchTimer = null;
  search.addEventListener("input", function () {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(function () {
      state.q = search.value;
      update();
    }, 60);
  });

  filters.addEventListener("click", function (e) {
    var b = e.target.closest("button");
    if (!b) return;
    if (b.hasAttribute("data-status")) {
      state.status = b.getAttribute("data-status");
    } else if (b.hasAttribute("data-type")) {
      var t = b.getAttribute("data-type");
      var i = state.types.indexOf(t);
      if (i === -1) state.types.push(t); else state.types.splice(i, 1);
    } else if (b.hasAttribute("data-chip")) {
      var chip = b.getAttribute("data-chip");
      state[chip] = !state[chip];
    } else if (b === sortDirEl) {
      var s = Core.parseSort(state.sort || readStorage("localStorage", SORT_STORAGE_KEY));
      setSort({ key: s.key, dir: s.dir === "asc" ? "desc" : "asc" });
      return;
    } else {
      return;
    }
    update();
  });

  if (clearFiltersBtn) {
    clearFiltersBtn.addEventListener("click", function () {
      state = Core.clearedState(state, false);
      update();
    });
  }

  if (emptyClear) {
    emptyClear.addEventListener("click", function () {
      state = Core.clearedState(state, true);
      search.value = "";
      update();
      search.focus();
    });
  }

  // Phones: the filters sit behind one "Filters" button.
  if (filtersToggle) {
    filtersToggle.addEventListener("click", function () {
      var open = !toolbar.classList.contains("is-filters-open");
      toolbar.classList.toggle("is-filters-open", open);
      filtersToggle.setAttribute("aria-expanded", String(open));
    });
  }

  sortKeyEl.addEventListener("change", function () {
    var s = Core.parseSort(state.sort || readStorage("localStorage", SORT_STORAGE_KEY));
    setSort({ key: sortKeyEl.value, dir: s.dir });
  });

  function setSort(sort) {
    var value = Core.sortValue(sort);
    writeStorage("localStorage", SORT_STORAGE_KEY, value);
    state.sort = value;
    update();
  }

  list.addEventListener("click", function (e) {
    var pin = e.target.closest(".fwf-pin");
    if (pin) {
      var name = pin.closest("li.fwf-row").dataset.name;
      Core.togglePin(pins, name);
      savePins();
      renderPins();
      if (state.pinned) update();
      return;
    }

    var link = e.target.closest("a.fwf-row-link");
    if (!link || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    openFlag(link.closest("li.fwf-row").dataset.name, { push: true });
  });

  // --- the panel ------------------------------------------------------

  var panelRequest = 0;
  var currentName = selectedName;
  var listScrollBeforeOpen = 0; // narrow screens: the list and the panel take turns

  function markSelected(name) {
    rows.forEach(function (row) {
      var selected = row.name === name;
      row.el.classList.toggle("is-selected", selected);
      if (selected) row.link.setAttribute("aria-current", "page");
      else row.link.removeAttribute("aria-current");
    });
    body.classList.toggle("fwf-has-selection", name !== null);
  }

  function setPanelHtml(html) {
    panel.innerHTML = html; // server-rendered and escaped; never built from names here
    panel.scrollTop = 0;
    enhancePanel(panel);
    var titled = panel.querySelector("[data-title]");
    document.title = "FunWithFlags - " + (titled ? titled.getAttribute("data-title") : "List");
  }

  function showEmptyPanel() {
    panelRequest++;
    var wasOpen = currentName !== null;
    currentName = null;
    markSelected(null);
    setPanelHtml(emptyTemplate ? emptyTemplate.innerHTML : "");
    if (isNarrow() && wasOpen) window.scrollTo(0, listScrollBeforeOpen);
  }

  function loadPanel(name, query) {
    var token = ++panelRequest;
    var url = Core.flagPath(base, name) + "/panel" + (query || "");
    panel.setAttribute("aria-busy", "true");
    return fetch(url, { credentials: "same-origin", headers: { Accept: "text/html" } })
      .then(function (resp) {
        return resp.text().then(function (text) {
          if (resp.status !== 200 && resp.status !== 404) throw new Error("HTTP " + resp.status);
          return text;
        });
      })
      .then(function (html) {
        if (token !== panelRequest) return;
        setPanelHtml(html);
      })
      .catch(function () {
        // Fall back to a full page load of the same view.
        if (token === panelRequest) location.href = Core.flagPath(base, name) + location.search;
      })
      .then(function () {
        if (token === panelRequest) panel.removeAttribute("aria-busy");
      });
  }

  function openFlag(name, opts) {
    if (isNarrow() && currentName === null) listScrollBeforeOpen = window.scrollY;
    currentName = name;
    markSelected(name);
    var path = Core.flagPath(base, name);
    if (opts.push && path !== location.pathname) {
      history.pushState({ fwf: true }, "", path + Core.buildQuery(state));
    }
    if (isNarrow()) window.scrollTo(0, 0);
    return loadPanel(name, "");
  }

  window.addEventListener("popstate", function () {
    state = Core.parseQuery(location.search);
    applyView();
    var name = Core.nameFromPath(location.pathname, base);
    if (name === currentName) return; // e.g. only the #fragment changed
    if (name === null) showEmptyPanel();
    else openFlag(name, { push: false });
  });

  panel.addEventListener("click", function (e) {
    // data-confirm (Delete Flag, Clear) is handled by confirm.js, which
    // doesn't depend on this file.

    var copy = e.target.closest(".fwf-copy");
    if (copy) {
      copyText(copy.getAttribute("data-copy"), copy);
      return;
    }

    var back = e.target.closest("a.fwf-back");
    if (back && e.button === 0 && !e.metaKey && !e.ctrlKey) {
      e.preventDefault();
      history.pushState({ fwf: true }, "", base + Core.buildQuery(state));
      showEmptyPanel();
      return;
    }

    // Audit log pagination inside the panel: swap the panel, keep the list.
    var pageLink = e.target.closest(".pagination a.page-link");
    var current = panel.querySelector(".fwf-panel[data-name]");
    if (pageLink && current && e.button === 0 && !e.metaKey && !e.ctrlKey) {
      var auditPage = new URL(pageLink.href, location.href).searchParams.get("audit_page");
      if (auditPage) {
        e.preventDefault();
        loadPanel(current.getAttribute("data-name"), "?audit_page=" + encodeURIComponent(auditPage));
      }
    }
  });

  // "Filter actors" box of a long gate section: hide rows that don't match,
  // and open the collapsed tail ("Show all N") while filtering.
  panel.addEventListener("input", function (e) {
    var box = e.target.closest && e.target.closest("[data-gate-filter]");
    if (!box) return;
    var section = box.closest("[data-gate-section]");
    var term = box.value.trim().toLowerCase();
    section.querySelectorAll("li.fwf-gate").forEach(function (li) {
      var id = li.querySelector(".fwf-gate-id");
      li.hidden = term !== "" && (id ? id.textContent.toLowerCase() : "").indexOf(term) === -1;
    });
    var more = section.querySelector("[data-gate-more]");
    if (more && term !== "") more.open = true;
  });

  function copyText(text, button) {
    var done = function () {
      var label = button.lastChild;
      var icon = button.querySelector("use");
      var before = label.textContent;
      var beforeIcon = icon && icon.getAttribute("href");
      label.textContent = "Copied";
      if (icon) icon.setAttribute("href", beforeIcon.replace(/#hi-[\w-]+$/, "#hi-tick"));
      setTimeout(function () {
        label.textContent = before;
        if (icon) icon.setAttribute("href", beforeIcon);
      }, 1200);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () {});
    }
  }

  // --- keeping state across a gate edit (POST -> 302 -> full reload) ----

  function saveRestorePoint(e) {
    var form = e.target;
    var methodInput = form.querySelector && form.querySelector('input[name="_method"]');
    var method = methodInput ? methodInput.value : (form.getAttribute("method") || "get");
    var actionPath = new URL(form.getAttribute("action") || location.href, location.href).pathname;
    var expect = Core.expectedLanding(method, actionPath, base, currentName);
    writeStorage("sessionStorage", RESTORE_KEY,
      Core.makeRestorePoint(Date.now(), Core.buildQuery(state), listScrollTop(), expect));
  }

  document.addEventListener("submit", saveRestorePoint, true);

  function listScrollTop() {
    return isNarrow() ? window.scrollY : listCol.scrollTop;
  }

  function setListScrollTop(y) {
    if (isNarrow()) window.scrollTo(0, y);
    else listCol.scrollTop = y;
  }

  function isNarrow() {
    return window.matchMedia(NARROW_QUERY).matches;
  }

  // Scroll a list row into view inside the list column only. (On wide
  // screens the page itself must never scroll: scrollIntoView would also
  // scroll the overflow:hidden body and push the header off screen.)
  function revealRow(el, center) {
    if (isNarrow()) {
      el.scrollIntoView({ block: center ? "center" : "nearest" });
      return;
    }
    var colRect = listCol.getBoundingClientRect();
    var r = el.getBoundingClientRect();
    if (center) {
      listCol.scrollTop += r.top - colRect.top - (colRect.height - r.height) / 2;
    } else if (r.top < colRect.top) {
      listCol.scrollTop -= colRect.top - r.top;
    } else if (r.bottom > colRect.bottom) {
      listCol.scrollTop += r.bottom - colRect.bottom;
    }
  }

  // The same for something inside the panel column.
  function revealInPanel(el) {
    if (isNarrow()) {
      el.scrollIntoView({ block: "center" });
      return;
    }
    var colRect = panel.getBoundingClientRect();
    var r = el.getBoundingClientRect();
    panel.scrollTop += r.top - colRect.top - (colRect.height - r.height) / 2;
  }

  // Taken once: read and removed, whatever page this is.
  function takeRestorePoint() {
    var raw = readStorage("sessionStorage", RESTORE_KEY);
    writeStorage("sessionStorage", RESTORE_KEY, null);
    return raw ? Core.parseRestorePoint(raw, Date.now(), selectedName) : null;
  }

  // --- keyboard (bindings live in shortcuts.js) -------------------------

  // In the order shown (sorting re-orders the DOM, not `rows`).
  function visibleRows() {
    var out = [];
    var lis = list.querySelectorAll("li.fwf-row");
    for (var i = 0; i < lis.length; i++) {
      if (!lis[i].hidden) out.push(rowByEl(lis[i]));
    }
    return out;
  }

  function rowByEl(li) {
    for (var i = 0; i < rows.length; i++) if (rows[i].el === li) return rows[i];
    return null;
  }

  function focusedRow() {
    var li = document.activeElement && document.activeElement.closest && document.activeElement.closest("li.fwf-row");
    return li ? rowByEl(li) : null;
  }

  function focusRow(row) {
    row.link.focus({ preventScroll: true });
    revealRow(row.el, false);
  }

  function moveFocus(step) {
    var vis = visibleRows();
    if (!vis.length) return false;
    var from = focusedRow() || rows.filter(function (r) { return r.name === currentName; })[0];
    var i = from ? vis.indexOf(from) : -1;
    if (i === -1) {
      focusRow(step > 0 ? vis[0] : vis[vis.length - 1]);
      return true;
    }
    var next = vis[i + step];
    if (next) focusRow(next);
    else if (step < 0) search.focus();
    return true;
  }

  function setStatus(status) {
    return function () {
      state.status = status;
      update();
    };
  }

  function backToList() {
    history.pushState({ fwf: true }, "", base + Core.buildQuery(state));
    showEmptyPanel();
  }

  var Keys = window.FwfShortcuts;
  if (Keys) {
    Keys.register("focusSearch", function () {
      if (isNarrow() && currentName !== null) backToList();
      search.focus();
      search.select();
    });
    Keys.register("nextFromSearch", function () {
      var vis = visibleRows();
      if (!vis.length) return false;
      focusRow(vis[0]);
    });
    Keys.register("next", function () { return moveFocus(1); });
    Keys.register("prev", function () { return moveFocus(-1); });
    Keys.register("open", function () {
      var row = focusedRow();
      if (!row) return false;
      openFlag(row.name, { push: true });
    });
    Keys.register("prevFlag", function () { return stepFlag(-1); });
    Keys.register("nextFlag", function () { return stepFlag(1); });
    Keys.register("escape", function () {
      if (document.activeElement === search) {
        if (search.value) {
          search.value = "";
          state.q = "";
          update();
        } else {
          search.blur();
        }
        return;
      }
      if (currentName !== null) {
        var row = rows.filter(function (r) { return r.name === currentName; })[0];
        backToList();
        if (row && !row.el.hidden) focusRow(row);
        return;
      }
      return false;
    });
    Keys.register("statusAll", setStatus(""));
    Keys.register("statusOn", setStatus("on"));
    Keys.register("statusPartial", setStatus("partial"));
    Keys.register("statusOff", setStatus("off"));
    if (filters.querySelector('[data-chip="mine"]')) {
      Keys.register("toggleMine", function () {
        state.mine = !state.mine;
        update();
      });
    }
    Keys.register("pin", function () {
      var row = focusedRow() || rows.filter(function (r) { return r.name === currentName; })[0];
      if (!row) return false;
      Core.togglePin(pins, row.name);
      savePins();
      renderPins();
      if (state.pinned) update();
    });
    Keys.register("copy", function () {
      var btn = panel.querySelector(".fwf-copy");
      if (!btn) return false;
      copyText(btn.getAttribute("data-copy"), btn);
    });
    Keys.register("addActor", function () {
      var input = panel.querySelector("#fwf-add-actor-input");
      if (!input) return false;
      input.focus({ preventScroll: true });
      revealInPanel(input);
    });
  }

  // [ and ]: the previous / next flag in the visible order, while one is open.
  function stepFlag(step) {
    if (currentName === null) return false;
    var name = Core.neighborName(visibleRows().map(function (r) { return r.name; }), currentName, step);
    if (name === null) return false;
    openFlag(name, { push: true });
    var row = rows.filter(function (r) { return r.name === name; })[0];
    if (row && !row.el.hidden) revealRow(row.el, false);
  }

  // --- timestamps -----------------------------------------------------

  var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  function pad(n) { return n < 10 ? "0" + n : String(n); }

  function localAbsolute(d) {
    return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear() + " " +
      pad(d.getHours()) + ":" + pad(d.getMinutes());
  }

  function formatRowDates() {
    var now = Date.now();
    rows.forEach(function (row) {
      var el = row.created !== null && row.el.querySelector("time.fwf-row-created");
      if (!el) return;
      el.setAttribute("datetime", row.el.dataset.created);
      el.textContent = Core.relativeTime(row.created, now);
      el.title = localAbsolute(new Date(row.created));
    });
  }

  // Audit log timestamps: the panel's activity list reads relative ("3 days
  // ago", absolute local time on hover); elsewhere absolute local time.
  function formatTimestamps(root) {
    var now = Date.now();
    root.querySelectorAll(".fwf-utc-timestamp").forEach(function (el) {
      var date = new Date(el.getAttribute("data-utc") + "Z");
      if (isNaN(date.getTime())) return;
      if (el.classList.contains("fwf-relative")) {
        el.setAttribute("datetime", date.toISOString());
        el.textContent = Core.relativeTime(date.getTime(), now);
        el.title = localAbsolute(date);
        return;
      }
      var h = date.getHours();
      var ampm = h >= 12 ? "PM" : "AM";
      h = h % 12 || 12;
      el.textContent = date.getDate() + " " + MONTHS[date.getMonth()] + " " + date.getFullYear() + " " +
        h + ":" + pad(date.getMinutes()) + ":" + pad(date.getSeconds()) + " " + ampm;
    });
  }

  // Things the server-rendered panel needs once it is in the page (on boot
  // and after every swap).
  function enhancePanel(root) {
    formatTimestamps(root);
    // The percentage form is left alone: it says which unit it sends and
    // the server converts (see Router, POST /flags/:name/percentage).
  }

  // --- boot -----------------------------------------------------------

  var restore = takeRestorePoint();
  // After a validation error the address bar shows the POST URL; put the
  // page's own GET URL there, so reload and back/forward work.
  var bootPath = Core.canonicalPath(location.pathname, base, selectedName) || location.pathname;
  var bootQuery = restore && !Core.hasViewState(location.search) ? restore.query : location.search;
  if (bootPath + bootQuery !== location.pathname + location.search) {
    history.replaceState(history.state, "", bootPath + bootQuery + location.hash);
  }
  state = Core.parseQuery(location.search);

  var flashClose = document.getElementById("fwf-flash-close");
  if (flashClose) {
    flashClose.addEventListener("click", function () {
      var flash = document.getElementById("fwf-flash");
      if (flash) flash.hidden = true;
    });
  }

  renderPins();
  formatRowDates();
  enhancePanel(panel);
  applyView();

  // Nothing is focused on load: a focused search box would swallow the
  // first keystroke (?, j, 1…), and the shortcuts are how this page is
  // driven. / and Cmd/Ctrl+K focus the search.

  if (restore) {
    if (Core.shouldRestoreListScroll(isNarrow(), selectedName)) setListScrollTop(restore.scroll);
  } else {
    var selected = list.querySelector("li.is-selected");
    if (selected && !isNarrow()) revealRow(selected, true);
  }

  // After a gate edit the redirect lands on #actor_x etc. Two columns: the
  // page itself never scrolls (the root is clipped, so the user could not
  // scroll it back and the header would stay hidden). The browser's own
  // fragment jump scrolls every ancestor of the target, the root included,
  // so take the landing over: put the root back at 0 whenever anything
  // scrolls it, and scroll the panel column to the target ourselves. A row
  // past the first few sits in the collapsed "Show all" tail, where the
  // browser can't scroll to it: open the tail first. One column: the window
  // scrolls as usual (only the tail case needs help).
  function pinRoot() {
    if (isNarrow()) return;
    var root = document.scrollingElement || document.documentElement;
    if (root.scrollTop !== 0) root.scrollTop = 0;
    if (body.scrollTop !== 0) body.scrollTop = 0;
  }

  function revealHashTarget() {
    var targetId = location.hash ? Core.decodeHash(location.hash) : null;
    var target = targetId && document.getElementById(targetId);
    if (!target || !panel.contains(target)) return;
    var more = target.closest("details");
    if (more && !more.open) more.open = true;
    if ((more && isNarrow()) || !isNarrow()) revealInPanel(target);
    pinRoot();
  }

  window.addEventListener("scroll", pinRoot);
  window.addEventListener("hashchange", revealHashTarget);
  // The browser may do its fragment jump after this script (at load).
  window.addEventListener("load", revealHashTarget);
  revealHashTarget();
  pinRoot();
})();
