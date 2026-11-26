import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

/**
 * Directory shared by the native client and this server for handoffs and
 * connection presence. macOS keeps its historical location; other platforms
 * follow the XDG Base Directory specification.
 */
export function poachCacheDirectory(platform: NodeJS.Platform = process.platform, env: NodeJS.ProcessEnv = process.env): string {
  if (platform === "darwin") return join(homedir(), "Library/Caches/Poach");
  const xdg = env.XDG_CACHE_HOME;
  const base = xdg && isAbsolute(xdg) ? xdg : join(homedir(), ".cache");
  return join(base, "poach");
}
