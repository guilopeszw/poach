import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

const chrome = process.env.CHROME_BIN ?? (process.platform === "darwin" ? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" : undefined);
const browser = await chromium.launch({ ...(chrome ? { executablePath: chrome } : {}), headless: true });
const source = (await readFile(new URL("../capture.js", import.meta.url), "utf8")).replace('  chrome.runtime.onMessage.addListener', '  globalThis.__poachTest = { measureComponents, start, finish, sample, snapshot, select };\n  chrome.runtime.onMessage.addListener');

test.after(() => browser.close());
async function pageWithCapture(html) {
  const page = await browser.newPage();
  await page.setContent(html);
  await page.evaluate(() => { globalThis.chrome = { runtime: { id: "test", onMessage: { addListener() {} }, sendMessage: async () => ({ ok: true }) } }; });
  await page.addScriptTag({ content: source });
  return page;
}

test("component snapshots retain hierarchy and exclude private or hidden descendants", async () => {
  const page = await pageWithCapture(`<section id="root" style="width:500px;height:500px"><div><span>Hello</span></div><input value="secret"><div contenteditable><span>private</span></div><div hidden>hidden</div><div style="opacity:0">transparent</div></section>`);
  try {
    const result = await page.evaluate(() => __poachTest.measureComponents(document.querySelector("#root")));
    assert.deepEqual(result.map(item => item.text), ["", "Hello"]);
    assert.deepEqual(result.map(item => item.parent), [-1, 0]);
    assert.ok(result.every(item => item.rect.length === 4 && item.styles.fontSize));
    const bounded = await page.evaluate(() => {
      const root = document.querySelector("#root"); root.style.height = "10000px";
      root.innerHTML = Array.from({ length: 50 }, (_, i) => `<div style="width:${i + 10}px;height:10px">${i}</div>`).join("");
      return __poachTest.measureComponents(root);
    });
    assert.equal(bounded.length, 40);
    assert.deepEqual(bounded.map(item => item.text), Array.from({ length: 40 }, (_, i) => String(i + 10)));
    assert.ok(bounded.every((item, i) => item.id === i && item.parent === -1));
    const snapshots = await page.evaluate(() => {
      const root = document.querySelector("#root"); __poachTest.start(root);
      root.lastElementChild.textContent = "Changed";
      return __poachTest.finish(false);
    });
    assert.equal(snapshots.components.length, 40);
    assert.equal(snapshots.componentsAtEnd.length, 40);
    assert.equal(snapshots.componentsAtEnd.at(-1).text, "Changed");
    assert.equal(snapshots.components.at(-1).text, "49");
  } finally { await page.close(); }
});

test("scrolling alone does not consume browser state slots", async () => {
  const page = await pageWithCapture('<div style="height:3000px"><section id="root" style="margin-top:100px;width:200px;height:100px">Ready</section></div>');
  try {
    const count = await page.evaluate(() => {
      __poachTest.start(document.querySelector("#root"));
      scrollTo(0, 200); __poachTest.sample();
      return __poachTest.finish(false).states.length;
    });
    assert.equal(count, 1);
  } finally { await page.close(); }
});

test("visible descendants survive boxless wrappers and visibility overrides", async () => {
  const page = await pageWithCapture(`<section id="root" style="width:500px;height:500px"><div style="display:contents"><button>Boxless child</button></div><div style="visibility:hidden"><button style="visibility:visible">Visible override</button></div><div style="opacity:0"><button>Private transparent subtree</button></div><div contenteditable><button>Editable subtree</button></div><div style="display:none"><button style="display:block">Not rendered</button></div></section>`);
  try {
    const components = await page.evaluate(() => __poachTest.measureComponents(document.querySelector("#root")));
    assert.deepEqual(components.map(item => item.text), ["Boxless child", "Visible override"]);
    assert.ok(components.every(item => item.parent === -1));
  } finally { await page.close(); }
});
