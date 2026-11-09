const get = id => document.getElementById(id);
const zone = get("zone");
const prompt = zone.querySelector(".prompt");
const result = zone.querySelector(".result");
const files = [...document.querySelectorAll(".file")];
let timer;
let feedbackTimer;
let active;

function reset() {
  clearInterval(timer);
  clearTimeout(feedbackTimer);
  if (active) endDrag();
  zone.className = "";
  prompt.hidden = false;
  result.hidden = true;
  get("uploaded").hidden = true;
  files.forEach(file => file.style.visibility = "");
  get("hint").textContent = "Drag a file here";
  get("announcement").textContent = "";
}

function showFile(file) {
  reset();
  const {name, size} = file.dataset;
  if (Number(size) > 5) {
    zone.classList.add("rejected");
    get("hint").textContent = "Too big — up to 5 MB";
    get("announcement").textContent = name + " exceeds the file limit.";
    feedbackTimer = setTimeout(reset, 1250);
    return;
  }
  file.style.visibility = "hidden";
  zone.classList.add("compact");
  prompt.hidden = true;
  result.hidden = false;
  get("name").textContent = name;
  const progress = get("progress");
  progress.value = 0;
  get("status").textContent = size + " MB · 0%";
  get("announcement").textContent = "Demo upload started.";
  const start = performance.now();
  timer = setInterval(() => {
    const percent = Math.min(100, Math.floor((performance.now() - start) / 35));
    progress.value = percent;
    get("status").textContent = size + " MB · " + (percent === 100 ? "Uploaded" : percent + "%");
    if (percent === 100) {
      clearInterval(timer);
      get("uploaded").hidden = false;
      get("announcement").textContent = "Demo upload complete.";
    }
  }, 35);
}

function inside(event) {
  const r = zone.getBoundingClientRect();
  return event.clientX >= r.left && event.clientX <= r.right && event.clientY >= r.top && event.clientY <= r.bottom;
}

function endDrag() {
  const {file, pointer} = active;
  active = null;
  file.classList.remove("dragging");
  file.style.transform = "";
  if (file.hasPointerCapture(pointer)) file.releasePointerCapture(pointer);
  zone.classList.remove("over");
  get("hint").textContent = "Drag a file here";
}

for (const file of files) {
  file.addEventListener("pointerdown", event => {
    if (event.button !== 0 || active || event.isPrimary === false) return;
    if (zone.classList.contains("rejected")) reset();
    active = {file, x:event.clientX, y:event.clientY, pointer:event.pointerId};
    file.setPointerCapture(event.pointerId);
    file.classList.add("dragging");
  });
  file.addEventListener("pointermove", event => {
    if (active?.file !== file || event.pointerId !== active.pointer) return;
    file.style.transform = 'translate(' + (event.clientX-active.x) + 'px,' + (event.clientY-active.y) + 'px) rotate(-4deg)';
    const over = inside(event);
    zone.classList.toggle("over", over);
    get("hint").textContent = over ? "Drop to upload" : "Drag a file here";
  });
  file.addEventListener("pointerup", event => {
    if (active?.file !== file || event.pointerId !== active.pointer) return;
    const accepted = inside(event);
    endDrag();
    if (accepted) showFile(file);
  });
  file.addEventListener("lostpointercapture", () => { if (active?.file === file) endDrag(); });
  file.addEventListener("click", event => { if (event.detail === 0) showFile(file); });
}
document.addEventListener("keydown", event => { if (event.key === "Escape" && active) endDrag(); });
get("reset").addEventListener("click", reset);
