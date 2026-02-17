// Convert UTC timestamps to local timezone
document.querySelectorAll(".fwf-utc-timestamp").forEach(function(el) {
  var utc = el.getAttribute("data-utc");
  if (utc) {
    var date = new Date(utc + "Z");
    if (!isNaN(date.getTime())) {
      el.textContent = date.toLocaleString();
    }
  }
});
