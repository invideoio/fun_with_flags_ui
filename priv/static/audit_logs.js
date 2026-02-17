// Convert UTC timestamps to local timezone
document.querySelectorAll(".fwf-utc-timestamp").forEach(function(el) {
  var utc = el.getAttribute("data-utc");
  if (utc) {
    var date = new Date(utc + "Z");
    if (!isNaN(date.getTime())) {
      var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
      var d = date.getDate();
      var mon = months[date.getMonth()];
      var y = date.getFullYear();
      var h = date.getHours();
      var m = date.getMinutes();
      var s = date.getSeconds();
      var ampm = h >= 12 ? "PM" : "AM";
      h = h % 12 || 12;
      var pad = function(n) { return n < 10 ? "0" + n : n; };
      el.textContent = d + " " + mon + " " + y + " " + h + ":" + pad(m) + ":" + pad(s) + " " + ampm;
    }
  }
});
