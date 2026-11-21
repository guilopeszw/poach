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
  let overlay, selectionBanner, selection, recording, result, selectionRefresh;

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

  // Adapted from AnyPoach by Miguel Mochizuki (Apache-2.0); see NOTICE.
  // Keep only the 40 largest visible descendants while traversing, then restore DOM order.
  function measureComponents(root) {
    if (!root.isConnected || root.closest(excludedText)) return [];
    const [rootX, rootY, rootWidth, rootHeight] = rect(root);
    const kept = [];
    let order = 0;
    const rank = (a, b) => b.area - a.area || Number(Boolean(b.text)) - Number(Boolean(a.text)) || a.order - b.order;
    const visit = (parent, depth) => {
      for (const element of parent.children) {
        if (element.matches(excludedText)) continue;
        const computed = getComputedStyle(element);
        // Boxless wrappers and visibility:hidden can contain visible descendants.
        // display:none, content-visibility:hidden and opacity:0 cannot be overridden by children.
        if (computed.display === "none" || computed.contentVisibility === "hidden" || Number(computed.opacity) === 0) continue;
        const visible = element.checkVisibility({ opacityProperty: true, visibilityProperty: true });
        const box = rect(element);
        const width = Math.min(box[0] + box[2], rootX + rootWidth) - Math.max(box[0], rootX);
        const height = Math.min(box[1] + box[3], rootY + rootHeight) - Math.max(box[1], rootY);
        if (visible && box[2] > 0 && box[3] > 0 && width > 0 && height > 0) {
          const text = limit([...element.childNodes].filter(node => node.nodeType === Node.TEXT_NODE).map(node => node.textContent.trim()).filter(Boolean).join(" "), 80);
          kept.push({ element, box, text, area: width * height, order: order++ });
          kept.sort(rank);
          if (kept.length > 40) kept.pop();
        }
        if (depth < 6) visit(element, depth + 1);
      }
    };
    visit(root, 1);
    kept.sort((a, b) => a.order - b.order);
    const indexOf = new Map(kept.map((item, index) => [item.element, index]));
    const round = value => Math.round(value * 10) / 10;
    return kept.map(({ element, box, text }, id) => {
      let ancestor = element.parentElement;
      while (ancestor && ancestor !== root && !indexOf.has(ancestor)) ancestor = ancestor.parentElement;
      return { id, parent: ancestor && ancestor !== root ? indexOf.get(ancestor) : -1, target: describe(element),
        rect: [round(box[0] - rootX), round(box[1] - rootY), box[2], box[3]], styles: styles(element), text };
    });
  }

  // Inspector adapted from AnyPoach by Miguel Mochizuki (Apache-2.0); see NOTICE.
  const round = value => Math.round(value * 10) / 10;
  const cardWidth = 260;
  const number = value => String(round(value));

  let colorContext;

  // Red, green, blue and alpha of any computed CSS color; rgb() is read directly, other syntaxes (oklch, color-mix...) through a canvas.
  function channels(color) {
    const match = /^rgba?\(([^)]+)\)$/.exec(color);
    const parts = match?.[1].split(/[\s,/]+/).filter(Boolean).map(Number);
    if (parts && parts.length >= 3 && !parts.some(Number.isNaN)) return [parts[0], parts[1], parts[2], parts.length > 3 ? parts[3] : 1];
    colorContext ??= Object.assign(document.createElement("canvas"), { width: 1, height: 1 }).getContext("2d", { willReadFrequently: true });
    colorContext.clearRect(0, 0, 1, 1);
    colorContext.fillStyle = "#000";
    colorContext.fillStyle = color;
    colorContext.fillRect(0, 0, 1, 1);
    const [red, green, blue, alpha] = colorContext.getImageData(0, 0, 1, 1).data;
    return [red, green, blue, alpha / 255];
  }

  function toHex(color) {
    const [red, green, blue, alpha] = channels(color);
    if (alpha <= 0) return null;
    const hex = [red, green, blue].map(part => Math.round(part).toString(16).padStart(2, "0")).join("");
    return ("#" + hex + (alpha < 1 ? Math.round(alpha * 255).toString(16).padStart(2, "0") : "")).toUpperCase();
  }

  function cardModel(element) {
    const computed = getComputedStyle(element);
    const [, , width, height] = rect(element);
    const family = (computed.fontFamily.split(",")[0] ?? "").trim().replace(/^["']|["']$/g, "");
    const px = value => (value.endsWith("px") ? number(parseFloat(value)) : value);
    const firstClass = (element.getAttribute("class") ?? "").trim().split(/\s+/)[0];
    const colors = [{ label: "Text", hex: toHex(computed.color) }, { label: "Background", hex: toHex(computed.backgroundColor) }];
    if (parseFloat(computed.borderTopWidth) > 0 && computed.borderTopStyle !== "none") {
      colors.push({ label: "Border", hex: toHex(computed.borderTopColor) });
    }
    const extras = [];
    if (parseFloat(computed.borderTopLeftRadius) > 0) extras.push("radius " + limit(computed.borderTopLeftRadius, 24));
    if (computed.opacity !== "1") extras.push("opacity " + limit(computed.opacity, 12));
    if (computed.transform !== "none") extras.push("transform " + limit(computed.transform, 48));
    if (computed.boxShadow !== "none") extras.push("shadow");
    const animations = element.getAnimations().filter(animation => animation.playState === "running").flatMap(animation => {
      const timing = animation.effect?.getTiming();
      return timing && Number.isFinite(timing.duration) ? [number(timing.duration) + "ms " + limit(timing.easing, 60)] : [];
    });
    return {
      name: element.localName + (firstClass ? "." + limit(firstClass, 24) : ""), size: number(width) + " × " + number(height),
      font: [family, px(computed.fontSize) + "/" + px(computed.lineHeight), computed.fontWeight].join(" · "),
      colors, extras, animations,
    };
  }

  // Where the card goes: right of the target, else left, else below, else above, always 8 px inside the viewport.
  function placeCard([x, y, width, height], [cardW, cardH], [viewW, viewH]) {
    const margin = 8, gap = 12;
    const clamp = (value, high) => Math.max(margin, Math.min(value, high));
    const top = clamp(y, viewH - cardH - margin), left = clamp(x, viewW - cardW - margin);
    if (x + width + gap + cardW <= viewW - margin) return [x + width + gap, top];
    if (x - gap - cardW >= margin) return [x - gap - cardW, top];
    if (y + height + gap + cardH <= viewH - margin) return [left, y + height + gap];
    if (y - gap - cardH >= margin) return [left, y - gap - cardH];
    return [left, top];
  }

  let cardHost, cardShadow, cardFrame, cardKey, cardElement;

  function renderCard(model) {
    const shadow = cardShadow;
    const make = (tag, text, css) => {
      const node = document.createElement(tag);
      if (text !== undefined) node.textContent = text;
      if (css) node.style.cssText = css;
      return node;
    };
    const box = make("div", undefined, `width: min(${cardWidth}px, calc(100vw - 16px)); max-height: calc(100vh - 16px); overflow: auto; box-sizing: border-box; padding: 12px; background: #FAFAF8; color: #292927;
      border: 1px solid #D8D8D3; border-radius: 14px; box-shadow: 0 8px 26px rgba(0,0,0,.18); font: 12px/16px system-ui, sans-serif`);
    const title = make("div", undefined, "display: flex; justify-content: space-between; gap: 8px; margin-bottom: 2px");
    title.append(make("b", model.name, "font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap"),
                 make("span", model.size, "color: #6b6b66; white-space: nowrap"));
    box.append(title, make("div", model.font, "color: #6b6b66; margin-bottom: 8px"));
    const swatches = make("div", undefined, "display: flex; gap: 10px; margin-bottom: 8px");
    for (const { label, hex } of model.colors) {
      const cell = make("div", undefined, "text-align: center");
      const pill = make("span", undefined, `display: block; width: 44px; height: 18px; border-radius: 10px; border: 3px solid #EDEDEB;
        box-shadow: 0 0 0 1px #D8D8D3; background: ${hex ?? "repeating-conic-gradient(#e5e5e0 0 25%, #fff 0 50%) 0 0 / 8px 8px"}`);
      cell.append(pill, make("div", hex ?? "transparent", "font: 10px/14px ui-monospace, monospace; color: #6b6b66"), make("div", label, "font-size: 10px; color: #6b6b66"));
      swatches.append(cell);
    }
    box.append(swatches);
    const notes = [...model.extras, ...model.animations];
    if (notes.length) box.append(make("div", notes.join(" · "), "background: #EDEDEB; border-radius: 8px; padding: 6px 8px; margin-bottom: 8px"));
    box.append(make("div", "Click to pin · ↑ parent · Esc cancel", "background: #292927; color: #fff; text-align: center; border-radius: 9px; padding: 6px; font-weight: 600"));
    shadow.replaceChildren(box);
    return box;
  }

  function showCard(element) {
    cardElement = element;
    if (!cardHost) {
      cardHost = document.createElement("div");
      cardHost.setAttribute("data-poach-inspector", "");
      cardHost.setAttribute("aria-hidden", "true");
      Object.assign(cardHost.style, { position: "fixed", left: "0", top: "0", pointerEvents: "none", zIndex: "2147483647" });
      cardShadow = cardHost.attachShadow({ mode: "closed" });
      document.documentElement.append(cardHost);
    }
    const model = cardModel(element);
    const key = JSON.stringify(model);
    if (key !== cardKey) {
      cardKey = key;
      renderCard(model);
    }
    const box = cardShadow.firstElementChild;
    const [left, top] = placeCard(rect(element), [box.offsetWidth, box.offsetHeight], [innerWidth, innerHeight]);
    Object.assign(cardHost.style, { left: left + "px", top: top + "px" });

  }

  function hideCard() {
    cancelAnimationFrame(cardFrame);
    cardHost?.remove();
    cardHost = cardShadow = cardKey = cardElement = undefined;
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
      components: recording.components, componentsAtEnd: recording.componentsAtEnd,
      durationMs: relativeTime(), events, states, animations, targetRemoved: !root.isConnected,
    };
  }

  function sendEvidence(evidence, final) {
    return chrome.runtime.sendMessage({ poachBridge: "capture", evidence, final });
  }

  function finish(send = true) {
    if (!recording) return result;
    sample();
    recording.componentsAtEnd = measureComponents(recording.root);
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
      root, abort, target: describe(root), startedAtEpochMs: now(), components: measureComponents(root),
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
    hideCard();
    clearInterval(selectionRefresh);
    selectionRefresh = undefined;
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
      const changed = candidate !== element;
      candidate = element;
      const [left, top, width, height] = rect(element);
      Object.assign(overlay.style, {
        left: left + "px", top: top + "px", width: width + "px", height: height + "px",
      });
      showCard(element);
      if (changed) {
        const model = cardModel(element);
        selectionBanner.textContent = `Poach · ${model.name}: ${model.size}, ${model.font} · Click or Enter to pin · ↑ Parent · Esc cancel`;
      }
    }
    if (candidate) highlight(candidate);
    selectionRefresh = setInterval(() => {
      if (!candidate) return;
      if (!candidate.isConnected) { endSelection(); phase = "idle"; return; }
      highlight(candidate);
    }, 100);
    window.addEventListener("pagehide", () => { endSelection(); phase = "idle"; }, { once: true, signal: selection.signal });
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
