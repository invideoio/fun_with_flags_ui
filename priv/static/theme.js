// Theme switcher for settings page
(function() {
  var select = document.getElementById("fwf-theme-select");
  if (!select) return;

  // Set the dropdown to reflect current preference
  var saved = null;
  try { saved = localStorage.getItem("fwf-theme"); } catch(e) {}
  if (saved === "dark" || saved === "light") {
    select.value = saved;
  } else {
    select.value = "system";
  }

  select.addEventListener("change", function() {
    var value = select.value;
    var theme;

    if (value === "system") {
      try { localStorage.removeItem("fwf-theme"); } catch(e) {}
      theme = (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) ? "dark" : "light";
    } else {
      try { localStorage.setItem("fwf-theme", value); } catch(e) {}
      theme = value;
    }

    document.documentElement.setAttribute("data-theme", theme);
  });

  // Listen for OS theme changes when set to "system"
  if (window.matchMedia) {
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function(e) {
      var current = null;
      try { current = localStorage.getItem("fwf-theme"); } catch(err) {}
      if (!current) {
        document.documentElement.setAttribute("data-theme", e.matches ? "dark" : "light");
      }
    });
  }
})();
