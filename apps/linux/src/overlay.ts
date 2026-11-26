import "@fontsource-variable/bricolage-grotesque/standard.css";
import "./overlay.css";
import { invoke } from "@tauri-apps/api/core";

const elapsed = document.getElementById("elapsed");
const stop = document.getElementById("stop");
if (!(elapsed instanceof HTMLElement) || !(stop instanceof HTMLButtonElement)) throw new Error("Missing controls");

const started = performance.now();
window.setInterval(() => {
  elapsed.textContent = `${((performance.now() - started) / 1000).toFixed(1)} s`;
}, 100);

function finish(): void {
  if (stop instanceof HTMLButtonElement && !stop.disabled) {
    stop.disabled = true;
    stop.textContent = "Saving…";
    void invoke("stop_recording");
  }
}

stop.addEventListener("click", finish);
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") finish();
});
