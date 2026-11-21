const base = "http://127.0.0.1:47831/v1";
const queues = new Map();

async function send(path, code, options = {}) {
  try {
    const response = await fetch(base + path, {
      ...options,
      headers: { Authorization: "Bearer " + code, ...options.headers },
      signal: AbortSignal.timeout(2500),
    });
    if (response.ok) return { ok: true };
    if (response.status === 401) return { error: "The pairing code changed. Pair again from Poach." };
    return { error: "Poach couldn’t accept this capture." };
  } catch {
    return { error: "Open Poach on your Mac and try again." };
  }
}

async function handle(message) {
  if (message.poachBridge === "pair") {
    const code = message.code?.trim().toUpperCase();
    if (!/^[A-F0-9]{8}(?:-[A-F0-9]{4}){3}-[A-F0-9]{12}$/.test(code ?? "")) {
      return { error: "Paste the pairing code from Poach." };
    }
    const result = await send("/pair", code);
    if (result.ok) await chrome.storage.local.set({ pairingCode: code });
    return result;
  }

  const { pairingCode } = await chrome.storage.local.get("pairingCode");
  if (!pairingCode) return { needsPairing: true, error: "Pair with Poach first." };
  if (message.poachBridge === "ping") return send("/pair", pairingCode);
  if (message.poachBridge === "openCapture") return send("/open-capture", pairingCode, { method: "POST" });
  let body = JSON.stringify(message.evidence);
  if (new Blob([body]).size > 256 * 1024 && message.evidence.componentsAtEnd) {
    const { componentsAtEnd, ...withoutEnd } = message.evidence;
    body = JSON.stringify(withoutEnd);
  }
  if (new Blob([body]).size > 256 * 1024) return { error: "This capture exceeds Poach’s evidence limit." };
  return send("/capture", pairingCode, {
    method: "POST",
    body,
    headers: { "Content-Type": "application/json", "X-Poach-Final": message.final ? "1" : "0" },
  });
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || !["pair", "ping", "openCapture", "capture"].includes(message?.poachBridge)) return;
  if (message.poachBridge === "capture" && !message.evidence) return;
  const key = message.evidence?.startedAtEpochMs ?? 0;
  const pending = queues.get(key);
  // A slow connection can drop intermediate snapshots. The final snapshot contains all evidence.
  if (pending && message.poachBridge === "capture" && !message.final) {
    respond({ ok: true });
    return;
  }
  const request = (pending ?? Promise.resolve()).then(() => handle(message));
  queues.set(key, request);
  request.then(respond, () => respond({ error: "Couldn’t reach Poach." })).finally(() => {
    if (queues.get(key) === request) queues.delete(key);
  });
  return true;
});
