(function () {
  "use strict";

  var clock = document.getElementById("clock");
  var date = document.getElementById("date");
  var status = document.getElementById("status");
  var dateFormatter = new Intl.DateTimeFormat("zh-CN", {
    weekday: "long",
    year: "numeric",
    month: "long",
    day: "numeric"
  });

  function pad(value) {
    return String(value).padStart(2, "0");
  }

  function updateClock() {
    var now = new Date();
    var hours = pad(now.getHours());
    var minutes = pad(now.getMinutes());
    var seconds = pad(now.getSeconds());
    var iso = now.toISOString();

    clock.textContent = hours + ":" + minutes + ":" + seconds;
    clock.dateTime = iso;
    date.textContent = dateFormatter.format(now);
  }

  function reportReady() {
    document.documentElement.dataset.wallpaperReady = "true";
    status.setAttribute("aria-label", "本地网页壁纸已加载");
  }

  updateClock();
  window.setInterval(updateClock, 1000);
  window.requestAnimationFrame(reportReady);
}());
