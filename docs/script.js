(function () {
  "use strict";

  document.documentElement.classList.add("js");

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
    navToggle.addEventListener("click", function () {
      var open = navToggle.getAttribute("aria-expanded") === "true";
      navToggle.setAttribute("aria-expanded", String(!open));
      nav.classList.toggle("is-open", !open);
      navToggle.querySelector(".sr-only").textContent = open ? "Open navigation" : "Close navigation";
    });

    nav.addEventListener("click", function (event) {
      if (event.target.closest("a")) {
        navToggle.setAttribute("aria-expanded", "false");
        nav.classList.remove("is-open");
        navToggle.querySelector(".sr-only").textContent = "Open navigation";
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

  var routes = {
    finish: {
      kicker: "Normal stop · focused at stop",
      title: "End wherever the thought belongs.",
      copy: "Start in one app, move while talking, then use your normal recording button. VoiceInk++ locks the exact editable input focused when you stop.",
      steps: [
        "Start recording in Codex.",
        "Move to Terminal while speaking.",
        "Stop normally. The transcript lands in Terminal."
      ],
      start: { icon: "C", label: "START", app: "Codex input" },
      target: { icon: "›_", label: "FOCUSED AT STOP", app: "Terminal input", result: "PASTE + RETURN" },
      action: "NORMAL STOP",
      speech: "“ship the idea…”"
    },
    return: {
      kicker: "Next button during recording · recording start",
      title: "Send it back to where you began.",
      copy: "Move anywhere while dictating, then stop with the Next button. VoiceInk++ restores the input captured at recording start, delivers there, and returns you to the workspace you were using.",
      steps: [
        "Start recording in the Codex composer.",
        "Keep working in VS Code while you speak.",
        "Press the Next button. The result returns to Codex."
      ],
      start: { icon: "C", label: "RECORDING START", app: "Codex input" },
      target: { icon: "V", label: "CURRENTLY FOCUSED", app: "VS Code", result: "WORKSPACE RESTORED" },
      action: "NEXT BUTTON",
      speech: "“send this back…”"
    },
    retarget: {
      kicker: "Next button while transcribing · second chance",
      title: "Latch a new input, then leave again.",
      copy: "If you stopped normally but changed your mind while transcription is loading, focus a new editable input and press the Next button once. That field and its app-specific auto-send become the pending destination.",
      steps: [
        "Stop normally and let transcription begin.",
        "Focus a new ChatGPT or agent input; press the Next button.",
        "Move on. VoiceInk++ pastes, sends, and restores you later."
      ],
      start: { icon: "›_", label: "OLD STOP TARGET", app: "Terminal input" },
      target: { icon: "C", label: "NEW LOCKED INPUT", app: "ChatGPT input", result: "PASTE + APP AUTO-SEND" },
      action: "NEXT DURING LOAD",
      speech: "“changed my mind…”"
    }
  };

  var routeLab = document.querySelector("[data-route-lab]");
  if (routeLab) {
    var tabs = Array.prototype.slice.call(routeLab.querySelectorAll("[role='tab']"));
    var panel = routeLab.querySelector("[role='tabpanel']");
    var stage = routeLab.querySelector(".route-stage");
    var startNode = routeLab.querySelector(".start-node");
    var targetNode = routeLab.querySelector(".target-node");

    function setNode(node, data) {
      node.querySelector(".node-icon").textContent = data.icon;
      node.querySelector("small").textContent = data.label;
      node.querySelector("strong").textContent = data.app;
      var result = node.querySelector("em");
      if (result && data.result) {
        result.textContent = data.result;
      }
    }

    function activateRoute(name, moveFocus) {
      var route = routes[name];
      if (!route) return;

      tabs.forEach(function (tab) {
        var selected = tab.getAttribute("data-route") === name;
        tab.setAttribute("aria-selected", String(selected));
        tab.setAttribute("tabindex", selected ? "0" : "-1");
        if (selected && moveFocus) tab.focus();
      });

      var activeTab = tabs.find(function (tab) {
        return tab.getAttribute("data-route") === name;
      });

      panel.setAttribute("aria-labelledby", activeTab.id);
      stage.setAttribute("data-route-stage", name);
      routeLab.querySelector("[data-route-kicker]").textContent = route.kicker;
      routeLab.querySelector("[data-route-title]").textContent = route.title;
      routeLab.querySelector("[data-route-copy]").textContent = route.copy;
      routeLab.querySelector(".route-action").textContent = route.action;
      routeLab.querySelector(".speech-packet").textContent = route.speech;
      setNode(startNode, route.start);
      setNode(targetNode, route.target);

      var stepList = routeLab.querySelector("[data-route-steps]");
      stepList.replaceChildren();
      route.steps.forEach(function (step) {
        var item = document.createElement("li");
        item.textContent = step;
        stepList.appendChild(item);
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
  }

  var copyButton = document.querySelector("[data-copy-command]");
  if (copyButton) {
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
        window.setTimeout(function () {
          copyButton.textContent = original;
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
}());
