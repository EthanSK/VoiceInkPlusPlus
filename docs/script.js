(function () {
  "use strict";

  var reduceMotion = window.matchMedia
    ? window.matchMedia("(prefers-reduced-motion: reduce)")
    : null;

  // Real-time context demo. index.html already contains the finished example, so
  // the page is complete without JavaScript. This only hides those existing parts
  // and reveals them at their data-at times (ms). It must never hold demo or route
  // copy of its own. One pass lasts about four seconds and then stops, so the
  // moving content stays under WCAG 2.2.2's five-second limit; Replay restarts it.
  // The Mac screen's TextEdit selection is one of these parts: CSS withholds only
  // its cyan wash, so the highlight lands just before the recorder's Selected Text
  // cue. The rest of that scene is static and needs no script.
  var root = document.querySelector("[data-demo-root]");
  if (root) {
    var parts = Array.prototype.slice.call(root.querySelectorAll("[data-at]"));
    var replay = root.querySelector("[data-demo-replay]");
    var demo = root.querySelector("[data-demo]") || root;
    var stopAt = Number(root.getAttribute("data-stop-at")) || 0;
    var endAt = parts.reduce(function (latest, part) {
      return Math.max(latest, Number(part.getAttribute("data-at")) || 0);
    }, stopAt) + 350;
    var timers = [];

    var clearTimers = function () {
      timers.forEach(function (timer) {
        window.clearTimeout(timer);
      });
      timers = [];
    };

    var finish = function () {
      clearTimers();
      root.classList.remove("is-playing", "is-recording", "is-stopped");
      parts.forEach(function (part) {
        part.classList.remove("is-shown");
      });
    };

    // Hide every part without starting the clock (an empty recorder).
    var arm = function () {
      clearTimers();
      parts.forEach(function (part) {
        part.classList.remove("is-shown");
      });
      root.classList.remove("is-recording", "is-stopped");
      root.classList.add("is-playing");
      document.documentElement.classList.remove("demo-armed");
    };

    var play = function () {
      arm();
      root.classList.add("is-recording");

      parts.forEach(function (part) {
        var at = Number(part.getAttribute("data-at")) || 0;
        timers.push(window.setTimeout(function () {
          part.classList.add("is-shown");
        }, at));
      });
      timers.push(window.setTimeout(function () {
        root.classList.remove("is-recording");
        root.classList.add("is-stopped");
      }, stopAt));
      timers.push(window.setTimeout(finish, endAt));
    };

    window.voiceInkDemoReady = true;

    if (replay) {
      replay.hidden = false;
      replay.addEventListener("click", play);
    }

    // Autoplay once, only when motion is welcome. Off screen, keep the recorder
    // empty until it scrolls into view so the reset never happens in sight.
    if (reduceMotion && reduceMotion.matches) {
      document.documentElement.classList.remove("demo-armed");
    } else {
      var rect = demo.getBoundingClientRect();
      var onScreen = rect.top < window.innerHeight * 0.8 && rect.bottom > 0;

      if (onScreen || !("IntersectionObserver" in window)) {
        play();
      } else {
        arm();
        var observer = new IntersectionObserver(function (entries) {
          var visible = entries.some(function (entry) {
            return entry.isIntersecting;
          });
          if (visible) {
            observer.disconnect();
            play();
          }
        }, { threshold: 0.4 });
        observer.observe(demo);
      }
    }
  }

  // Copy the build commands from the visible code block, not from a second copy.
  var copyButton = document.querySelector("[data-copy]");
  var copySource = document.querySelector("[data-copy-source]");
  if (copyButton && copySource) {
    var copyBar = document.querySelector("[data-copy-bar]");
    var copyStatus = document.querySelector("[data-copy-status]");
    var copyLabel = copyButton.textContent;
    var resetTimer = null;

    var showResult = function (label) {
      copyButton.textContent = label;
      if (copyStatus) copyStatus.textContent = label;
      window.clearTimeout(resetTimer);
      resetTimer = window.setTimeout(function () {
        copyButton.textContent = copyLabel;
        if (copyStatus) copyStatus.textContent = "";
      }, 1800);
    };

    var fallbackCopy = function (text) {
      var field = document.createElement("textarea");
      field.value = text;
      field.setAttribute("readonly", "");
      field.style.position = "fixed";
      field.style.opacity = "0";
      document.body.appendChild(field);
      field.select();
      var copied = false;
      try {
        copied = document.execCommand("copy");
      } catch (error) {
        copied = false;
      }
      field.remove();
      return copied;
    };

    if (copyBar) copyBar.hidden = false;

    copyButton.addEventListener("click", function () {
      var text = copySource.textContent.trim();
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(function () {
          showResult("Copied");
        }, function () {
          showResult(fallbackCopy(text) ? "Copied" : "Failed to copy");
        });
      } else {
        showResult(fallbackCopy(text) ? "Copied" : "Failed to copy");
      }
    });
  }
}());
