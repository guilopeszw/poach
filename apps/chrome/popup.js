const action = document.querySelector("#action");
const cancel = document.querySelector("#cancel");
const status = document.querySelector("#status");
const pairing = document.querySelector("#pairing");
const reconnect = document.querySelector("#reconnect");
const code = document.querySelector("#code");
const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
let phase = "idle";

function tabMessage(command) {
  return chrome.tabs.sendMessage(tab.id, { poach: command });
}

function bridge(command, details = {}) {
  return chrome.runtime.sendMessage({ poachBridge: command, ...details });
}

function showPairing(detail) {
  pairing.hidden = false;
  action.hidden = cancel.hidden = reconnect.hidden = true;
  status.textContent = detail ?? "In Poach, open Chrome setup from Welcome or Settings and copy the pairing code.";
}

function render(next, detail) {
  phase = next;
  pairing.hidden = true;
  action.hidden = false;
  action.disabled = next === "unavailable";
  reconnect.hidden = false;
  cancel.hidden = !["selecting", "recording", "finished"].includes(next);
  action.textContent = {
    idle: "Choose a component",
    selecting: "Return to page",
    recording: "Finish and send",
    finished: "Send again",
    sent: "Choose another component",
    unavailable: "Choose a component",
  }[next];
  status.textContent = detail ?? {
    idle: "Choose a component here, then record it in Poach.",
    selecting: "Click a component. Press ↑ to select its parent, Enter to confirm, or Esc to cancel.",
    recording: "Poach is receiving browser details. Finish after the interaction settles.",
    finished: "Send the capture to Poach to attach it to the matching recording.",
    sent: "Sent to Poach. Open the matching recording to see its Chrome evidence.",
    unavailable: "Open an HTTP or HTTPS page to choose a component.",
  }[next];
}

async function inspectTab() {
  if (tab?.id === undefined || !/^https?:/.test(tab.url ?? "")) {
    render("unavailable");
    return;
  }
  const current = await tabMessage("status").catch(() => ({ phase: "idle" }));
  render(current.phase);
}

pairing.addEventListener("submit", async event => {
  event.preventDefault();
  const submit = pairing.querySelector("button");
  submit.disabled = true;
  const result = await bridge("pair", { code: code.value }).catch(() => ({ error: "Couldn’t connect to Poach." }));
  submit.disabled = false;
  if (result.ok) {
    code.value = "";
    await inspectTab();
  } else {
    showPairing(result.error);
  }
});

action.addEventListener("click", async () => {
  action.disabled = cancel.disabled = true;
  try {
    if (phase === "idle" || phase === "sent") {
      const connection = await bridge("ping");
      if (!connection.ok) {
        showPairing(connection.error);
        return;
      }
      await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["capture.js"] });
      if (phase === "sent") await tabMessage("cancel");
      await tabMessage("select");
      window.close();
    } else if (phase === "selecting") {
      window.close();
    } else {
      const { evidence } = await tabMessage("finish");
      const result = await bridge("capture", { evidence, final: true });
      if (result.ok) await tabMessage("sent").catch(() => {});
      render(result.ok ? "sent" : "finished", result.error);
    }
  } catch {
    render(phase, "Couldn’t finish this action. Open Poach and try again.");
  } finally {
    cancel.disabled = false;
    action.disabled = phase === "unavailable";
  }
});

cancel.addEventListener("click", async () => {
  await tabMessage("cancel").catch(() => {});
  render("idle");
});
reconnect.addEventListener("click", () => showPairing());

const connection = await bridge("ping").catch(() => ({ error: "Couldn’t connect to Poach." }));
if (connection.needsPairing) showPairing();
else {
  await inspectTab();
  if (!connection.ok) status.textContent = connection.error;
}
