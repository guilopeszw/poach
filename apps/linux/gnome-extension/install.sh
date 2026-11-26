#!/usr/bin/env bash
# Install or update the Poach Capture GNOME Shell extension for this user.
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
uuid="$(sed -n 's/.*"uuid": *"\([^"]*\)".*/\1/p' "$source_dir/metadata.json")"
target="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$uuid"

mkdir -p "$target/schemas" "$target/icons"
install -m 0644 "$source_dir/metadata.json" "$source_dir/extension.js" "$target/"
install -m 0644 "$source_dir"/schemas/*.gschema.xml "$target/schemas/"
install -m 0644 "$source_dir"/icons/*.svg "$target/icons/"
glib-compile-schemas "$target/schemas"

if gnome-extensions info "$uuid" >/dev/null 2>&1; then
  gnome-extensions enable "$uuid"
  echo "Updated $uuid. Log out and back in to load the new version."
else
  # GNOME on Wayland only discovers new extensions at login.
  gsettings set org.gnome.shell enabled-extensions \
    "$(python3 -c 'import ast,sys; e=ast.literal_eval(sys.argv[1] or "[]"); e.append(sys.argv[2]) if sys.argv[2] not in e else None; print(e)' \
      "$(gsettings get org.gnome.shell enabled-extensions | sed 's/^@as //')" "$uuid")"
  echo "Installed $uuid. Log out and back in to enable it."
fi
