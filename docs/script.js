(function () {
  "use strict";

  var header = document.querySelector("[data-header]");
  var nav = document.querySelector("[data-nav]");
  var navToggle = document.querySelector("[data-nav-toggle]");

  function updateHeader() {
    if (header) {
      header.classList.toggle("is-scrolled", window.scrollY > 20);
    }
  }

  updateHeader();
  window.addEventListener("scroll", updateHeader, { passive: true });

  if (nav && navToggle) {
    function closeNav(returnFocus) {
      navToggle.setAttribute("aria-expanded", "false");
      nav.classList.remove("is-open");
      navToggle.querySelector(".sr-only").textContent = "Open navigation";
      if (returnFocus) navToggle.focus();
    }

    navToggle.addEventListener("click", function () {
      var open = navToggle.getAttribute("aria-expanded") === "true";
      navToggle.setAttribute("aria-expanded", String(!open));
      nav.classList.toggle("is-open", !open);
      navToggle.querySelector(".sr-only").textContent = open ? "Open navigation" : "Close navigation";
    });

    nav.addEventListener("click", function (event) {
      if (event.target.closest("a")) {
        closeNav(false);
      }
    });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && navToggle.getAttribute("aria-expanded") === "true") {
        closeNav(true);
      }
    });
  }

  var revealItems = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -8%", threshold: 0.08 });

    revealItems.forEach(function (item) {
      observer.observe(item);
    });
  } else {
    revealItems.forEach(function (item) {
      item.classList.add("is-visible");
    });
  }

  var routeLab = document.querySelector("[data-route-lab]");
  if (routeLab) {
    var tabs = Array.prototype.slice.call(routeLab.querySelectorAll("[role='tab']"));
    var panels = Array.prototype.slice.call(routeLab.querySelectorAll("[data-route-panel]"));
    routeLab.classList.add("is-interactive");

    function activateRoute(name, moveFocus) {
      tabs.forEach(function (tab) {
        var selected = tab.getAttribute("data-route") === name;
        tab.setAttribute("aria-selected", String(selected));
        tab.setAttribute("tabindex", selected ? "0" : "-1");
        if (selected && moveFocus) tab.focus();
      });

      panels.forEach(function (panel) {
        var selected = panel.getAttribute("data-route-panel") === name;
        panel.hidden = !selected;
        panel.setAttribute("data-active", String(selected));
      });
    }

    tabs.forEach(function (tab, index) {
      tab.addEventListener("click", function () {
        activateRoute(tab.getAttribute("data-route"), false);
      });

      tab.addEventListener("keydown", function (event) {
        var nextIndex = null;
        if (event.key === "ArrowRight" || event.key === "ArrowDown") {
          nextIndex = (index + 1) % tabs.length;
        } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
          nextIndex = (index - 1 + tabs.length) % tabs.length;
        } else if (event.key === "Home") {
          nextIndex = 0;
        } else if (event.key === "End") {
          nextIndex = tabs.length - 1;
        }

        if (nextIndex !== null) {
          event.preventDefault();
          activateRoute(tabs[nextIndex].getAttribute("data-route"), true);
        }
      });
    });

    activateRoute("finish", false);
  }

  var copyButton = document.querySelector("[data-copy-command]");
  if (copyButton) {
    var copyStatus = document.querySelector("[data-copy-status]");
    var commands = [
      "git clone https://github.com/EthanSK/VoiceInkPlusPlus.git",
      "cd VoiceInkPlusPlus",
      "make local",
      "open ~/Downloads/VoiceInkPlusPlus.app"
    ].join("\n");

    copyButton.addEventListener("click", function () {
      var original = "Copy commands";

      function showResult(label) {
        copyButton.textContent = label;
        if (copyStatus) copyStatus.textContent = label;
        window.setTimeout(function () {
          copyButton.textContent = original;
          if (copyStatus) copyStatus.textContent = "";
        }, 1800);
      }

      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(commands).then(function () {
          showResult("Copied");
        }).catch(function () {
          showResult("Copy failed");
        });
      } else {
        var textarea = document.createElement("textarea");
        textarea.value = commands;
        textarea.setAttribute("readonly", "");
        textarea.style.position = "fixed";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.select();
        var copied = document.execCommand("copy");
        textarea.remove();
        showResult(copied ? "Copied" : "Copy failed");
      }
    });
  }

  window.voiceInkSiteReady = true;
}());
