<p align="center"><img src="apps/macos/Assets/PoachIcon.png" width="88" alt="Poach pouch icon"></p>
<h1 align="center">Poach</h1>
<p align="center">A lightweight Mac app for the UI you wish you’d made.</p>
<p align="center"><strong><a href="https://github.com/guilopeszw/poach/releases/download/v0.1.0-beta.4/Poach-arm64.zip">Download for Apple silicon</a></strong> · <a href="docs/media/poach-demo.mp4">Watch the demo</a> · <a href="docs/media/MUSIC-CREDITS.md">Music credits</a></p>

<p align="center"><a href="docs/media/poach-editor.png"><img src="docs/media/poach-editor.png" width="800" alt="Poach's interaction brief with a recorded recommendation card, a timestamped comment, a detected click, its palette, and build instructions."></a></p>

## What does Poach do?

Record how an interface responds to a click, hover, or drag. Poach keeps a local, timestamped pointer trace during native screen recordings, then lets you add notes directly to the video timeline. Share the capture with Codex or Claude so your assistant can inspect the frames, sample-derived click/drag candidates, and your notes while recreating the interaction. The pointer sampler can miss brief actions, and the trace alone cannot confirm what an action did.

## From screen to chat

1. **Capture the interaction.** Record a screen area, a window, or a full display. For a selected area, Poach dims the outside and adds a soft edge shadow while recording, so the capture boundary stays clear. The overlay is click-through and Poach’s controls stay out of the video. Press **⌘⇧P** to select an area, then press it again to stop. You can also drop in an existing video or still image.
2. **Mark the details.** Pause the video and click the comment icon to label what happened at the playhead. Click a comment to return to its frame. Native recordings include a bounded pointer trace with button transitions and drag samples. Adjust the extracted palette and add any instructions that apply to the whole capture.
3. **Build with your assistant.** Choose **Copy handoff for chat** and paste it into your connected conversation. The MCP connector lets the assistant read your notes, see representative frames, and request a frame at a specific timestamp. Poach needs no separate AI API key.

In **Settings → Storage**, see how much space Poach uses and choose **Clear unused captures** to remove old recordings and extracted frames. Poach keeps the open edit, the active handoff, and your imported originals.

## Install on your Mac

Download the Apple silicon build above, unzip it, and move **Poach.app** to Applications. Choose the connector for your assistant, then open a new chat.

| Assistant | Install the MCP connector |
| --- | --- |
| [Codex installer](https://github.com/guilopeszw/poach/releases/download/v0.1.0-beta.4/Poach-Codex.zip) | Unzip and double-click **Install Codex.command**. |
| [Claude Desktop extension](https://github.com/guilopeszw/poach/releases/download/v0.1.0-beta.4/Poach.mcpb) | Open **Settings → Extensions → Advanced settings → Install Extension**. Select the downloaded file and enable Poach. |

**Beta requirements.** Screen recording requires macOS 15 or later. On macOS 14 you can import images and videos. Clips can be up to 30 seconds long. Poach records the screen without audio.

<details>
<summary>Download and first-launch help</summary>

Sign in to a GitHub account with access to the private beta. The app includes its runtime and video tools.

This beta is signed with Poach’s local development certificate and is not notarized by Apple. On first launch, macOS may block it:

1. Try to open **Poach.app** once, then dismiss the warning.
2. Open **System Settings → Privacy & Security**, scroll to Security, and click **Open Anyway** for Poach.
3. Confirm **Open** in the follow-up alert.

After Poach opens, allow it under **Screen & System Audio Recording**, then quit and reopen the app. If capture is refused even though Poach is enabled, first confirm the running copy is in Applications and restart it. Local builds without an Apple Team ID may lose Screen Recording approval after rebuilds; see [Contributing](CONTRIBUTING.md#screen-recording-signing). Apple’s [Open Anyway instructions](https://support.apple.com/en-gb/102445) explain this one-time Gatekeeper override.

Keep Poach in Applications so the connector can find it. If the handoff button is disabled, open a new chat with the connector enabled. For manual setup, open Poach’s **Settings** and choose **Copy Codex MCP** for the Terminal command or **Copy Claude MCP** for the Claude Desktop configuration.

</details>

<details>
<summary>What does my assistant receive?</summary>

Poach analyzes the media on your Mac. During an explicit native screen recording, it samples pointer position and mouse-button state at a nominal 120 Hz; the trace is capped at 5,000 events and reports how many samples fell inside the capture bounds and observed a held button. It does not capture keyboard input or scroll events. Samples outside the captured bounds are marked and clamped to the edge, so off-capture coordinates are not shared. The trace stays local until you explicitly share a handoff. When your assistant reads it, it receives your instructions, timestamped notes, pointer trace, derived click/drag summaries when button events were sampled, palette, and requested frames. If no button events were observed, the copied handoff tells the assistant not to assume clicks or drags. Match action coordinates to frames to identify targets; the trace alone cannot establish what an interaction did. Motion timing and easing are estimates from sampled frames. A new handoff replaces the previous one, and each handoff expires after 24 hours.

</details>

[Contributing and local development](CONTRIBUTING.md) · [License](LICENSE)
