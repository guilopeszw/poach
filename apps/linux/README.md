# Poach for Linux (preview)

A Tauri client that captures through xdg-desktop-portal and hands briefs to the
same MCP connector as the Mac app. It runs `@poach/core` with the system Node.js,
so analysis, briefs and `poach_read_moment` behave the same on both platforms.

## Status

| Feature | Linux |
| --- | --- |
| Record a screen or window (PipeWire → GStreamer, H.264 MP4) | ✅ |
| Recording controls (timer and Stop) that stay out of the video | ✅ windows always; screens with the GNOME extension |
| Screenshot (Screenshot portal) | ✅ |
| Open an existing image or video | ✅ |
| Keyframes, palette, timing (`@poach/core`) | ✅ |
| Timestamped notes and instructions | ✅ |
| Handoff to Claude Code / Codex via MCP | ✅ |
| Record a free-form area | ⏳ portals only offer screens and windows; crop afterwards |
| Pointer trace | ⏳ planned via `CursorMode::METADATA` (positions only; Wayland does not expose button state) |
| Top bar menu (Open, New Screenshot, New Recording, Quit) | ✅ with the GNOME extension |
| Global shortcut to start and stop a screen recording | ✅ Super+Shift+P, with the GNOME extension |
| Keeps running when its window closes; one instance at a time | ✅ closing hides it when the top bar item exists, otherwise quits |
| Installable package with an app menu entry | ✅ `.rpm` and `.deb` release downloads |
| Font matching, favorites, Chrome companion, palette overrides | ⏳ |
| Excluding Poach's own window from recordings | ✅ Poach hides while capturing |

## Requirements (Fedora)

```sh
sudo dnf install webkit2gtk4.1-devel libsoup3-devel javascriptcoregtk4.1-devel \
  openssl-devel librsvg2-devel gcc pkgconf-pkg-config \
  pipewire-gstreamer gstreamer1-plugin-openh264 gstreamer1-plugins-bad-free \
  ffmpeg-free nodejs
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Debian/Ubuntu: `libwebkit2gtk-4.1-dev build-essential libssl-dev librsvg2-dev
gstreamer1.0-tools gstreamer1.0-pipewire gstreamer1.0-plugins-bad ffmpeg nodejs`.

## GNOME extension

Wayland cannot exclude a window from a capture. On GNOME, Poach records screens
through Mutter's `RecordArea`, which paints the stage again off-screen, and the
**Poach Capture** extension skips the recording controls in those paints. The
controls stay visible on your monitor and never reach the video. The extension
also keeps the controls above other windows and tells Poach which monitor to
record (the one under the pointer).

```sh
apps/linux/gnome-extension/install.sh   # then log out and back in
```

Without the extension, screen recordings use the ScreenCast portal and the
controls may appear in the video. Window recordings never include them.

## Install

Download the [`.rpm`](https://github.com/guilopeszw/poach/releases/latest/download/Poach-x86_64.rpm)
or [`.deb`](https://github.com/guilopeszw/poach/releases/latest/download/Poach-amd64.deb)
from the latest release, or build the package from the repository root, then
install it:

```sh
pnpm install
pnpm --filter @poach/linux app:build --bundles rpm
sudo dnf install apps/linux/src-tauri/target/release/bundle/rpm/Poach-*.rpm
```

The package carries the analysis engine, a self-contained MCP connector in
`/usr/lib/Poach/mcp/server.mjs` and the GNOME extension; it depends on the
system's Node.js, FFmpeg and GStreamer. Turn the extension on once with
`gnome-extensions enable poach-capture@brunocostaar.github.io`, then log out and
back in. Use `--bundles deb` on Debian and Ubuntu.

While Poach runs, the extension shows the pouch in the top bar with **Open
Poach**, **New Screenshot**, **New Recording** and **Quit Poach**, and
**Super+Shift+P** starts a screen recording or stops the current one. Change
the shortcut with `gsettings --schemadir <extension>/schemas set
org.gnome.shell.extensions.poach-capture toggle-recording "['<Super><Alt>p']"`.
Closing the window keeps Poach in the top bar, like the macOS app in the menu
bar; without the extension, closing the window quits.

## Run from source

```sh
pnpm install
pnpm build                     # builds @poach/core, the MCP server and this UI
pnpm --filter @poach/linux app:dev
```

`POACH_CORE_ENTRY` points Poach at another `packages/core/dist/index.js` and
`POACH_NODE` at another Node binary.

## Connect your assistant

Click **No assistant connected** in Poach and choose **Copy Claude Code
command** or **Copy Codex command**. Run the copied command once, then open a
new session. For an installed package the commands are:

```sh
claude mcp add --scope user poach -- node /usr/lib/Poach/mcp/server.mjs
codex mcp add poach -- node /usr/lib/Poach/mcp/server.mjs
```

From a checkout, replace the path with
`"$PWD/packages/mcp-server/dist/index.js"` after `pnpm build`.

Poach shows **Assistant connected** once a session has the connector running.

## Data

Everything stays in `$XDG_CACHE_HOME/poach` (default `~/.cache/poach`, mode 700):
recordings and screenshots in `captures/`, keyframes in `frames/`, briefs in
`active-brief.json` and `briefs/`. Briefs expire after 24 hours, as on macOS.
At launch and after each share, Poach removes expired brief archives and
deletes its own recordings, screenshots and keyframes older than 24 hours
unless an unexpired brief still references them. Files you open from elsewhere
are never touched.
