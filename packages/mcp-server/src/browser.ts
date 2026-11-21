import { z } from "zod";

const styleNames = ["fontFamily", "fontSize", "fontWeight", "fontStyle", "lineHeight", "letterSpacing", "width", "height", "borderRadius", "opacity", "transform", "color", "backgroundColor", "boxShadow", "display", "visibility", "overflow"] as const;
const styles = z.record(z.enum(styleNames), z.string().max(240));
const rect = z.array(z.number().finite()).length(4);
const target = z.object({ tag: z.string().max(120), role: z.string().max(120).optional(), classes: z.string().max(240).optional() });
const timestamp = z.number().finite().min(0).max(90_000);
export const browserSchema = z.object({
  videoOffsetMs: z.number().finite().optional(),
  devicePixelRatio: z.number().positive().max(16).optional(),
  viewport: z.object({ width: z.number().positive(), height: z.number().positive() }).optional(),
  events: z.array(z.object({ atMs: timestamp, type: z.string().max(40), target, point: z.array(z.number().finite()).length(2).optional() })).max(96).default([]),
  states: z.array(z.object({ atMs: timestamp, text: z.string().max(480), rect: rect.optional(), styles: styles.optional() })).max(48).default([]),
  animations: z.array(z.object({ atMs: timestamp, target, durationMs: z.number().finite(), delayMs: z.number().finite(), easing: z.string().max(120), keyframes: z.array(z.object({ offset: z.number().finite(), easing: z.string().max(120), styles })).max(8) })).max(16).default([]),
});

/** Browser values are measurements; their video timestamps are estimates. */
export function nearbyBrowser(value: unknown, timeMs: number) {
  const parsed = browserSchema.safeParse(value);
  if (!parsed.success || parsed.data.videoOffsetMs === undefined) return { page: undefined, items: [] };
  const browser = parsed.data;
  const offset = browser.videoOffsetMs!;
  const items = [...browser.events, ...browser.states, ...browser.animations].map(({ atMs, ...item }) => ({ ...item, estimatedVideoMs: atMs + offset }));
  const near = items.filter(item => Math.abs(item.estimatedVideoMs - timeMs) <= 500).sort((a, b) => a.estimatedVideoMs - b.estimatedVideoMs).slice(0, 12);
  const baseline = items.filter(item => "text" in item && item.estimatedVideoMs < timeMs - 500).sort((a, b) => b.estimatedVideoMs - a.estimatedVideoMs)[0];
  if (baseline && !near.some(item => "text" in item && item.estimatedVideoMs <= timeMs)) near.unshift({ ...baseline });
  return { page: { devicePixelRatio: browser.devicePixelRatio, viewport: browser.viewport }, items: near.slice(0, 12) };
}
