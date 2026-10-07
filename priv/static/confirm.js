// Confirmation for destructive buttons (Delete Flag, every Clear): a click
// on an element with data-confirm="question" only goes through if the user
// accepts window.confirm(question).
//
// Deliberately its own file with no dependencies, loaded before every other
// script on the page: these buttons change production flags, so the guard
// must not depend on flags_core.js loading or on flags.js setting up
// without errors. It listens on the document in the capture phase, so it
// also covers buttons inside panels swapped in later.
//
// Exercised by test/js/confirm.test.js (`node --test`).
//
(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else if (root.document) {
    api.install(root.document, root);
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  function onClick(win) {
    return function (e) {
      var target = e.target;
      var el = target && target.closest ? target.closest("[data-confirm]") : null;
      if (!el) return;
      if (!win.confirm(el.getAttribute("data-confirm"))) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    };
  }

  function install(doc, win) {
    if (doc.__fwfConfirmInstalled) return false;
    doc.__fwfConfirmInstalled = true;
    doc.addEventListener("click", onClick(win), true);
    return true;
  }

  return { install: install };
});
