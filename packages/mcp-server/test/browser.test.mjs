import assert from "node:assert/strict";
import test from "node:test";
import { nearbyBrowser, browserSchema, componentSummary } from "../dist/browser.js";

test("moment retains full measured styles, animation data and a held baseline", () => {
  const value = { videoOffsetMs: -100, devicePixelRatio: 2, viewport: { width: 1000, height: 800 }, states: [{ atMs: 0, text: "Ready", rect: [1, 2, 30, 40], pageRect: [1, 202, 30, 40], styles: { backgroundColor: "red", borderRadius: "8px", transform: "none" } }], animations: [{ atMs: 2100, target: { tag: "div" }, durationMs: 200, delayMs: 10, easing: "ease", keyframes: [{ offset: 0, easing: "linear", styles: { opacity: "0" } }] }] };
  const result = nearbyBrowser(value, 2000);
  assert.equal(result.page.devicePixelRatio, 2);
  assert.equal(result.items[0].text, "Ready");
  assert.equal(result.items[0].baseline, true);
  assert.deepEqual(result.items[0].pageRect, [1, 202, 30, 40]);
  assert.deepEqual(result.items[0].rect, [1, 2, 30, 40]);
  assert.equal(result.items[0].styles.borderRadius, "8px");
  assert.equal(result.items[1].durationMs, 200);
  assert.equal(result.items[1].estimatedVideoMs, 2000);
  assert.equal(result.items[1].keyframes[0].styles.opacity, "0");
  assert.deepEqual(nearbyBrowser({ ...value, states: [{ ...value.states[0], rect: [1] }] }, 2000).items, []);
  assert.deepEqual(nearbyBrowser({}, 0).items, []);
});

test("child components are optional, bounded and ordered after parents", () => {
  const component = id => ({ id, parent: id - 1, target: { tag: "div" }, rect: [0, 0, 100, 50], text: "Child", styles: { fontSize: "12px" } });
  const value = { components: Array.from({ length: 40 }, (_, id) => component(id)), componentsAtEnd: [component(0)] };
  assert.ok(browserSchema.safeParse(value).success);
  assert.match(componentSummary(value), /40 measured at pin time/);
  assert.equal(componentSummary({}), undefined);
  assert.ok(!browserSchema.safeParse({ components: [...value.components, component(40)] }).success);
  assert.ok(!browserSchema.safeParse({ components: [{ ...component(0), parent: 0 }] }).success);
  assert.ok(!browserSchema.safeParse({ components: [{ ...component(0), text: "x".repeat(81) }] }).success);
});
