(() => {
  if (globalThis.poachCaptureInstalled) return;
  globalThis.poachCaptureInstalled = true;

  const maxDurationMs = 90_000;
  const eventTypes = [
    "pointerdown", "pointerup", "click", "dragstart", "dragenter",
    "dragover", "dragleave", "drop", "dragend", "transitionrun", "animationstart",
  ];
  const styleNames = [
    "opacity", "transform", "display", "visibility", "color", "backgroundColor",
    "borderRadius", "width", "height", "overflow", "boxShadow",
    "fontFamily", "fontSize", "fontWeight", "fontStyle", "lineHeight", "letterSpacing",
  ];
  const excludedText = "input, textarea, select, [contenteditable], [hidden], [aria-hidden=true], script, style";
  let phase = "idle";
  let overlay, selectionBanner, selection, recording, result;

  const limit = (value, length = 120) => String(value ?? "").trim().slice(0, length);
  const now = () => Math.round(performance.timeOrigin + performance.now());
  const relativeTime = () => Math.min(maxDurationMs, Math.max(0, now() - recording.startedAtEpochMs));

  function describe(element) {
    return {
      tag: element.localName,
      role: limit(element.getAttribute("role"), 40),
      classes: limit(element.getAttribute("class")),
    };
  }

  function rect(element) {
    const { x, y, width, height } = element.getBoundingClientRect();
    return [x, y, width, height].map(value => Math.round(value * 10) / 10);
  }

  function styles(element) {
    const computed = getComputedStyle(element);
    return Object.fromEntries(styleNames.map(name => [
      name, limit(computed[name], name === "fontFamily" ? 240 : 90),
    ]));
  }

  function visibleText(element) {
    if (element.closest(excludedText)) return "";
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    const parts = [];
    let total = 0;
    for (let count = 0; count < 80 && total < 220; count++) {
      const node = walker.nextNode();
      if (!node) break;
      const parent = node.parentElement;
      if (!parent || parent.closest(excludedText) || parent.getClientRects().length === 0 ||
          !parent.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
      const value = limit(node.textContent, 220 - total);
      if (!value) continue;
      total += value.length + 1;
      parts.push(value);
    }
    return parts.join(" ");
  }

  function sample() {
    if (!recording || !recording.root.isConnected) return;
    const { root, states, animations, seenAnimations } = recording;
    const selector = "progress, [role=progressbar], [aria-live]";
    const indicators = (root.matches(selector) ? [root] : [...root.querySelectorAll(selector)]).slice(0, 4)
      .map(element => ({
        target: describe(element),
        rect: rect(element),
        value: element instanceof HTMLProgressElement ? String(element.value) : limit(element.getAttribute("aria-valuenow")),
      }));
    // Keep viewport geometry at its observation time and a stable document-space anchor.
    const onPage = ([x, y, width, height]) => [x + scrollX, y + scrollY, width, height];
    const viewportRect = rect(root);
    const state = { rect: viewportRect, pageRect: onPage(viewportRect), styles: styles(root), text: visibleText(root), indicators };
    const key = JSON.stringify({ ...state, rect: onPage(state.rect), indicators: indicators.map(item => ({ ...item, rect: onPage(item.rect) })) });
    if (key !== recording.lastState) {
      recording.lastState = key;
      if (states.length >= 48) states.splice(1, 1);
      states.push({ atMs: relativeTime(), ...state });
    }
    for (const animation of root.getAnimations({ subtree: true })) {
      if (animations.length >= 16) break;
      if (seenAnimations.has(animation)) continue;
      const effect = animation.effect;
      if (!(effect instanceof KeyframeEffect) || !(effect.target instanceof Element)) continue;
      const timing = effect.getTiming();
      if (typeof timing.duration !== "number" || !Number.isFinite(timing.duration)) continue;
      seenAnimations.add(animation);
      animations.push({
        atMs: relativeTime(),
        target: describe(effect.target),
        durationMs: timing.duration,
        delayMs: timing.delay,
        easing: limit(timing.easing, 80),
        keyframes: effect.getKeyframes().slice(0, 8).map(frame => ({
          offset: frame.computedOffset,
          easing: limit(frame.easing, 80),
          styles: Object.fromEntries(Object.entries(frame)
            .filter(([name]) => styleNames.includes(name))
            .map(([name, value]) => [name, limit(value, 90)])),
        })),
      });
    }
  }

  function observe(event) {
    if (!event.isTrusted) return;
    const target = event.composedPath().find(node => node instanceof Element);
    if (!recording || !target || !recording.root.isConnected) return;
    const insideTarget = recording.root.contains(target);
    const point = event instanceof MouseEvent
      ? [Math.round(event.clientX), Math.round(event.clientY)] : undefined;
    if (!insideTarget) {
      // Pointer capture can send a release to a dragged sibling over the chosen component.
      if (event.type !== "pointerup" || !point) return;
      const bounds = recording.root.getBoundingClientRect();
      if (point[0] < bounds.left || point[0] > bounds.right || point[1] < bounds.top || point[1] > bounds.bottom) return;
    }
    const atMs = relativeTime();
    if (event.type === "dragover" && atMs - recording.lastDragOver < 120) return;
    if (event.type === "dragover") recording.lastDragOver = atMs;
    const { events } = recording;
    if (events.length >= 96) {
      const dragOver = events.findIndex(item => item.type === "dragover");
      if (dragOver >= 0) events.splice(dragOver, 1);
      else if (event.type === "dragover") return;
      else events.shift();
    }
    events.push({ atMs, type: event.type, target: describe(target), point, insideTarget });
    if (event.type === "transitionrun" || event.type === "animationstart") requestAnimationFrame(sample);
  }

  function snapshot() {
    const { root, target, startedAtEpochMs, events, states, animations } = recording;
    return {
      version: 1, origin: location.origin, target, startedAtEpochMs,
      devicePixelRatio, viewport: { width: innerWidth, height: innerHeight },
      durationMs: relativeTime(), events, states, animations, targetRemoved: !root.isConnected,
    };
  }

  function sendEvidence(evidence, final) {
    return chrome.runtime.sendMessage({ poachBridge: "capture", evidence, final });
  }

  function finish(send = true) {
    if (!recording) return result;
    sample();
    result = snapshot();
    const { abort, interval, stream, timeout } = recording;
    abort.abort();
    clearInterval(interval);
    clearInterval(stream);
    clearTimeout(timeout);
    recording = undefined;
    phase = "finished";
    const completed = result;
    if (send) {
      sendEvidence(completed, true).then(reply => {
        if (reply?.ok && result === completed) phase = "sent";
      }).catch(() => {});
    }
    return result;
  }

  function start(root) {
    const abort = new AbortController();
    recording = {
      root, abort, target: describe(root), startedAtEpochMs: now(),
      events: [], states: [], animations: [], seenAnimations: new WeakSet(), lastDragOver: -Infinity,
      interval: setInterval(sample, 100),
      stream: setInterval(() => { sendEvidence(snapshot(), false).catch(() => {}); }, 1000),
      timeout: setTimeout(finish, maxDurationMs),
    };
    phase = "recording";
    for (const type of eventTypes) {
      document.addEventListener(type, observe, { capture: true, passive: true, signal: abort.signal });
    }
    sample();
  }

  function endSelection() {
    selection?.abort();
    selection = undefined;
    overlay?.remove();
    overlay = undefined;
    selectionBanner?.remove();
    selectionBanner = undefined;
  }

  function select() {
    if (phase !== "idle") return;
    phase = "selecting";
    selection = new AbortController();
    const options = { capture: true, signal: selection.signal };
    overlay = document.createElement("div");
    overlay.setAttribute("aria-hidden", "true");
    Object.assign(overlay.style, {
      position: "fixed", pointerEvents: "none", zIndex: "2147483647",
      outline: "2px solid #2378ff", borderRadius: "3px", boxSizing: "border-box",
    });
    document.documentElement.append(overlay);
    selectionBanner = document.createElement("div");
    selectionBanner.setAttribute("role", "status");
    selectionBanner.textContent = "Poach · Click or Tab to select · ↑ Parent · Enter to confirm · Esc to cancel";
    Object.assign(selectionBanner.style, {
      position: "fixed", top: "12px", left: "50%", transform: "translateX(-50%)",
      pointerEvents: "none", zIndex: "2147483647", borderRadius: "8px", padding: "8px 12px",
      background: "#171717", color: "#fff", font: "13px system-ui, sans-serif",
    });
    document.documentElement.append(selectionBanner);
    let candidate = document.activeElement instanceof Element && document.activeElement !== document.body
      ? document.activeElement : null;
    function highlight(element) {
      candidate = element;
      const [left, top, width, height] = rect(element);
      Object.assign(overlay.style, {
        left: left + "px", top: top + "px", width: width + "px", height: height + "px",
      });
    }
    if (candidate) highlight(candidate);
    document.addEventListener("pointermove", event => {
      if (event.isTrusted && event.target instanceof Element) highlight(event.target);
    }, options);
    document.addEventListener("focusin", event => {
      if (event.isTrusted && event.target instanceof Element) highlight(event.target);
    }, options);
    for (const type of ["pointerdown", "pointerup"]) {
      document.addEventListener(type, event => {
        if (event.isTrusted) event.stopImmediatePropagation();
      }, options);
    }
    document.addEventListener("click", event => {
      if (!event.isTrusted || !(event.target instanceof Element)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      endSelection();
      start(event.target);
    }, options);
    document.addEventListener("keydown", event => {
      if (!event.isTrusted || !["Escape", "ArrowUp", "Enter"].includes(event.key)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      if (event.key === "Escape") {
        endSelection();
        phase = "idle";
      } else if (event.key === "ArrowUp" && candidate?.parentElement) {
        highlight(candidate.parentElement);
      } else if (event.key === "Enter" && candidate) {
        endSelection();
        start(candidate);
      }
    }, options);
  }

  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id !== chrome.runtime.id || !message?.poach) return;
    if (message.poach === "select") select();
    if (message.poach === "cancel") {
      endSelection();
      finish(false);
      result = undefined;
      phase = "idle";
    }
    if (message.poach === "finish") finish(false);
    if (message.poach === "sent" && phase === "finished") phase = "sent";
    respond({ phase, evidence: message.poach === "finish" ? result : undefined });
  });
})();
