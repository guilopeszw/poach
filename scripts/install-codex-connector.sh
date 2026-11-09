#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
market="$HOME/Library/Application Support/Poach/Codex/marketplace"
plugin="$market/plugins/poach"
for app in "/Applications/Poach.app" "$HOME/Applications/Poach.app"; do
  if [[ -x "$app/Contents/Resources/runtime/bin/node" ]]; then
    export PATH="$app/Contents/Resources/runtime/bin:$PATH"
    break
  fi
done
export PATH="$PATH:/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin:/Applications/Codex.app/Contents/Resources"
command -v codex >/dev/null || { echo "Open or install Codex first, then run this installer again." >&2; exit 1; }
mkdir -p "$market"
ditto "$source_dir/marketplace" "$market"
# plutil quotes the destination path correctly, including spaces and Unicode.
plutil -replace mcpServers.poach.args -json '[]' "$plugin/.mcp.json"
plutil -insert mcpServers.poach.args.0 -string "$plugin/launch-connector.sh" "$plugin/.mcp.json"
plutil -convert json "$plugin/.mcp.json"
# Codex rejects an existing marketplace name when the registered source changes.
# Only migrate Poach's local registration. Leave remote and unrelated sources alone.
old_source="$(codex plugin marketplace list --json | node -e '
  const list = JSON.parse(require("node:fs").readFileSync(0, "utf8")).marketplaces;
  const entry = list.find(item => item.name === "poach-local");
  if (entry && entry.marketplaceSource?.sourceType !== "local") {
    throw Error("poach-local already refers to a non-local marketplace.");
  }
  if (entry) process.stdout.write(entry.marketplaceSource.source);
')"
migrated=false
# Codex resolves aliases such as /var to /private/var. Compare directory identity.
if [[ -n "$old_source" && ! "$old_source" -ef "$market" ]]; then
  codex plugin marketplace remove poach-local
  migrated=true
fi
if codex plugin marketplace add "$market" && codex plugin add poach@poach-local; then
  exit 0
fi
if "$migrated"; then
  echo "Upgrade failed. Restoring the previous Poach marketplace." >&2
  codex plugin marketplace remove poach-local || true
  codex plugin marketplace add "$old_source" && codex plugin add poach@poach-local
fi
exit 1
