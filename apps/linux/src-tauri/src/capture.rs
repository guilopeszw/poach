//! Screen capture on Wayland.
//!
//! Recordings are encoded by a `gst-launch-1.0` child from a PipeWire stream
//! (H.264 via openh264, which ships with Fedora). The stream comes from one of:
//!
//! - Mutter's RecordArea, for whole screens on GNOME with the Poach Capture
//!   extension enabled. The extension keeps the recording controls out of
//!   the video (see `mutter.rs`).
//! - The ScreenCast portal, for windows and as the fallback for screens. A
//!   window recording never includes the separate controls window.
//!
//! While recording, the main window hides and a small controls window shows
//! the elapsed time and a Stop button. Results reach the main window through
//! the `recording-finished` and `recording-failed` events.

use std::{
    io::Read,
    os::{
        fd::{AsRawFd, OwnedFd},
        unix::process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

use ashpd::desktop::{
    screencast::{CursorMode, Screencast, SelectSourcesOptions, SourceType},
    screenshot::Screenshot,
    PersistMode, ResponseError, Session,
};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use tokio::sync::Mutex;

use crate::{mutter, paths};

/// Native recordings are capped like the macOS client.
pub const MAX_RECORDING_SECONDS: u64 = 30;
/// File descriptor number the portal's PipeWire remote gets inside the encoder.
const CHILD_PIPEWIRE_FD: i32 = 3;
/// Time for the compositor to remove or place windows before a capture.
const HIDE_SETTLE: Duration = Duration::from_millis(350);
const MAIN_WINDOW: &str = "main";
const CONTROLS_WINDOW: &str = "recording";
/// The Poach Capture extension recognizes the controls by this title.
const CONTROLS_TITLE: &str = "Poach Recording";

#[derive(Default)]
pub struct Recorder(Mutex<Option<ActiveRecording>>);

enum StreamSource {
    Portal {
        session: Session<Screencast>,
        // The PipeWire remote must outlive the encoder.
        _remote: OwnedFd,
    },
    Mutter(mutter::AreaCast),
}

impl StreamSource {
    async fn close(self) {
        match self {
            StreamSource::Portal { session, _remote } => {
                let _ = session.close().await;
            }
            StreamSource::Mutter(cast) => cast.stop().await,
        }
    }
}

pub struct ActiveRecording {
    id: uuid::Uuid,
    encoder: Child,
    output: PathBuf,
    started: Instant,
    size: Option<(i32, i32)>,
    source: StreamSource,
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum CaptureSource {
    Monitor,
    Window,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingStarted {
    max_seconds: u64,
    /// False when a screen recording may include the controls window.
    controls_hidden_from_video: bool,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Recording {
    path: PathBuf,
    duration_ms: u128,
    width: Option<i32>,
    height: Option<i32>,
}

fn portal_error(error: ashpd::Error) -> String {
    match error {
        ashpd::Error::Response(ResponseError::Cancelled) => "Capture was cancelled.".into(),
        other => format!("The desktop portal refused the request: {other}"),
    }
}

/// A PipeWire stream ready to encode: how to reach it and its size.
struct OpenedStream {
    source: StreamSource,
    target: String,
    size: Option<(i32, i32)>,
}

async fn open_portal_stream(source: CaptureSource) -> Result<OpenedStream, String> {
    let proxy = Screencast::new().await.map_err(portal_error)?;
    let cursor = match proxy.available_cursor_modes().await {
        Ok(modes) if modes.contains(CursorMode::EMBEDDED) => CursorMode::EMBEDDED,
        _ => CursorMode::HIDDEN,
    };
    let sources = match source {
        CaptureSource::Monitor => SourceType::MONITOR,
        CaptureSource::Window => SourceType::WINDOW,
    };
    let session = proxy.create_session(Default::default()).await.map_err(portal_error)?;
    proxy
        .select_sources(
            &session,
            SelectSourcesOptions::default()
                .set_cursor_mode(cursor)
                .set_sources(sources)
                .set_multiple(false)
                .set_persist_mode(PersistMode::DoNot),
        )
        .await
        .map_err(portal_error)?
        .response()
        .map_err(portal_error)?;
    let streams = proxy
        .start(&session, None, Default::default())
        .await
        .map_err(portal_error)?
        .response()
        .map_err(portal_error)?;
    let stream = streams.streams().first().ok_or("Nothing was selected for sharing.")?;
    let target = match stream.pipewire_serial() {
        Some(serial) => format!("fd={CHILD_PIPEWIRE_FD} target-object={serial}"),
        None => format!("fd={CHILD_PIPEWIRE_FD} path={}", stream.pipe_wire_node_id()),
    };
    let size = stream.size();
    let remote = proxy
        .open_pipe_wire_remote(&session, Default::default())
        .await
        .map_err(portal_error)?;
    Ok(OpenedStream { source: StreamSource::Portal { session, _remote: remote }, target, size })
}

async fn open_mutter_stream(monitor: (i32, i32, i32, i32)) -> Result<OpenedStream, String> {
    let cast = mutter::record_area(monitor).await?;
    // Mutter streams live on the user's default PipeWire daemon.
    let target = format!("path={}", cast.node_id);
    let size = Some(cast.size);
    Ok(OpenedStream { source: StreamSource::Mutter(cast), target, size })
}

#[tauri::command]
pub async fn start_recording(
    app: AppHandle,
    source: CaptureSource,
    recorder: State<'_, Recorder>,
) -> Result<RecordingStarted, String> {
    let mut slot = recorder.0.lock().await;
    if slot.is_some() {
        return Err("A recording is already in progress.".into());
    }
    let main = app.get_webview_window(MAIN_WINDOW).ok_or("Poach's window is missing.")?;

    // Window recordings use the portal picker while Poach is still visible.
    let monitor = match source {
        CaptureSource::Monitor => mutter::capture_monitor().await,
        CaptureSource::Window => None,
    };
    let portal = match monitor {
        None => Some(open_portal_stream(source).await?),
        Some(_) => None,
    };

    main.hide().map_err(|error| format!("Could not hide Poach: {error}"))?;
    let controls = match open_controls(&app) {
        Ok(controls) => controls,
        Err(error) => {
            let _ = main.show();
            if let Some(stream) = portal {
                stream.source.close().await;
            }
            return Err(error);
        }
    };
    // Let the compositor unmap Poach and place the controls before recording.
    tokio::time::sleep(HIDE_SETTLE).await;

    let opened = match (portal, monitor) {
        (Some(stream), _) => Ok(stream),
        (None, Some(monitor)) => open_mutter_stream(monitor).await,
        (None, None) => unreachable!("either the portal or Mutter provides the stream"),
    };
    let started = async {
        let OpenedStream { source: stream_source, target, size } = opened?;
        let output = paths::private_dir("captures")?.join(format!("recording-{}.mp4", uuid::Uuid::new_v4()));
        let remote = match &stream_source {
            StreamSource::Portal { _remote, .. } => Some(_remote.as_raw_fd()),
            StreamSource::Mutter(_) => None,
        };
        let mut encoder = match spawn_encoder(remote, &target, &output) {
            Ok(encoder) => encoder,
            Err(error) => {
                stream_source.close().await;
                return Err(error);
            }
        };
        // A missing GStreamer plugin makes the encoder exit right away.
        tokio::time::sleep(Duration::from_millis(400)).await;
        if let Ok(Some(status)) = encoder.try_wait() {
            stream_source.close().await;
            return Err(format!("The recorder stopped immediately ({status}). {}", read_stderr(&mut encoder)));
        }
        Ok(ActiveRecording {
            id: uuid::Uuid::new_v4(),
            encoder,
            output,
            started: Instant::now(),
            size,
            source: stream_source,
        })
    }
    .await;

    let active = match started {
        Ok(active) => active,
        Err(error) => {
            let _ = controls.close();
            let _ = main.show();
            return Err(error);
        }
    };
    let id = active.id;
    *slot = Some(active);
    drop(slot);

    crate::app_service::announce_recording(&app).await;
    let timer_app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(MAX_RECORDING_SECONDS)).await;
        finish(&timer_app, Some(id)).await;
    });
    Ok(RecordingStarted { max_seconds: MAX_RECORDING_SECONDS, controls_hidden_from_video: monitor.is_some() || matches!(source, CaptureSource::Window) })
}

fn open_controls(app: &AppHandle) -> Result<WebviewWindow, String> {
    if let Some(existing) = app.get_webview_window(CONTROLS_WINDOW) {
        let _ = existing.close();
    }
    WebviewWindowBuilder::new(app, CONTROLS_WINDOW, WebviewUrl::App("overlay.html".into()))
        .title(CONTROLS_TITLE)
        .inner_size(248.0, 56.0)
        .resizable(false)
        .decorations(false)
        .transparent(true)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .build()
        .map_err(|error| format!("Could not show the recording controls: {error}"))
}

fn spawn_encoder(remote: Option<i32>, target: &str, output: &Path) -> Result<Child, String> {
    let pipeline = format!(
        "pipewiresrc {target} do-timestamp=true keepalive-time=1000 always-copy=true \
         ! videorate ! video/x-raw,framerate=30/1 \
         ! videoconvert ! video/x-raw,format=I420 \
         ! openh264enc usage-type=screen rate-control=bitrate bitrate=12000000 \
         ! h264parse ! mp4mux ! filesink location=\"{}\"",
        output.display()
    );
    let mut command = Command::new("gst-launch-1.0");
    command
        .arg("-q")
        .arg("-e") // Turn SIGINT into end-of-stream so mp4mux writes its index.
        .args(pipeline.split_whitespace())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    if let Some(raw) = remote {
        // SAFETY: only async-signal-safe libc calls run between fork and exec.
        unsafe {
            command.pre_exec(move || {
                if raw == CHILD_PIPEWIRE_FD {
                    let flags = libc::fcntl(raw, libc::F_GETFD);
                    if flags < 0 || libc::fcntl(raw, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                } else if libc::dup2(raw, CHILD_PIPEWIRE_FD) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    command
        .spawn()
        .map_err(|error| format!("Could not start gst-launch-1.0 ({error}). Install GStreamer and its PipeWire plugin."))
}

fn read_stderr(child: &mut Child) -> String {
    let mut text = String::new();
    if let Some(mut stderr) = child.stderr.take() {
        let _ = stderr.read_to_string(&mut text);
    }
    text.trim().to_string()
}

/// Stop the encoder and return the saved file.
async fn stop_active(active: ActiveRecording) -> Result<Recording, String> {
    let ActiveRecording { mut encoder, output, started, size, source, .. } = active;
    let duration_ms = started.elapsed().as_millis();

    // SAFETY: plain signal to our own child process.
    unsafe { libc::kill(encoder.id() as libc::pid_t, libc::SIGINT) };
    let (status, stderr) = tokio::task::spawn_blocking(move || {
        let deadline = Instant::now() + Duration::from_secs(10);
        let status = loop {
            match encoder.try_wait() {
                Ok(Some(status)) => break Some(status),
                Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
                _ => {
                    let _ = encoder.kill();
                    let _ = encoder.wait();
                    break None;
                }
            }
        };
        (status, read_stderr(&mut encoder))
    })
    .await
    .map_err(|error| format!("The recorder could not be stopped: {error}"))?;
    source.close().await;

    match status {
        Some(status) if status.success() && output.is_file() => Ok(Recording {
            path: output,
            duration_ms,
            width: size.map(|(width, _)| width),
            height: size.map(|(_, height)| height),
        }),
        Some(status) => Err(format!("The recording could not be saved ({status}). {stderr}")),
        None => Err("The recorder did not finish in time and was stopped.".into()),
    }
}

/// Finish the active recording (or only `expected`, for the time limit), close
/// the controls, bring Poach back and tell it the result.
async fn finish(app: &AppHandle, expected: Option<uuid::Uuid>) {
    let recorder = app.state::<Recorder>();
    let active = {
        let mut slot = recorder.0.lock().await;
        match (slot.as_ref(), expected) {
            (Some(active), Some(id)) if active.id != id => return,
            (None, _) => return,
            _ => slot.take(),
        }
    };
    let Some(active) = active else { return };
    let result = stop_active(active).await;
    crate::app_service::announce_recording(app).await;

    if let Some(controls) = app.get_webview_window(CONTROLS_WINDOW) {
        let _ = controls.close();
    }
    if let Some(main) = app.get_webview_window(MAIN_WINDOW) {
        let _ = main.show();
        let _ = main.set_focus();
    }
    let _ = match result {
        Ok(recording) => app.emit_to(MAIN_WINDOW, "recording-finished", recording),
        Err(error) => app.emit_to(MAIN_WINDOW, "recording-failed", error),
    };
}

pub async fn is_recording(app: &AppHandle) -> bool {
    app.state::<Recorder>().0.lock().await.is_some()
}

pub async fn stop(app: &AppHandle) {
    finish(app, None).await;
}

#[tauri::command]
pub async fn stop_recording(app: AppHandle) -> Result<(), String> {
    finish(&app, None).await;
    Ok(())
}

/// Wayland offers no way to exclude a window from a screenshot, so Poach hides
/// itself while the portal captures and comes back afterwards.
#[tauri::command]
pub async fn take_screenshot(window: WebviewWindow) -> Result<PathBuf, String> {
    window.hide().map_err(|error| format!("Could not hide Poach: {error}"))?;
    tokio::time::sleep(HIDE_SETTLE).await;
    let result = request_screenshot().await;
    let _ = window.show();
    let _ = window.set_focus();
    result
}

async fn request_screenshot() -> Result<PathBuf, String> {
    let response = Screenshot::request()
        .interactive(true)
        .send()
        .await
        .map_err(portal_error)?
        .response()
        .map_err(portal_error)?;
    let source = url::Url::parse(response.uri().as_str())
        .ok()
        .and_then(|uri| uri.to_file_path().ok())
        .ok_or("The portal returned a screenshot location Poach cannot read.")?;
    let extension = source.extension().and_then(|value| value.to_str()).unwrap_or("png").to_lowercase();
    let destination = paths::private_dir("captures")?.join(format!("screenshot-{}.{extension}", uuid::Uuid::new_v4()));
    std::fs::copy(&source, &destination).map_err(|error| format!("Could not keep the screenshot: {error}"))?;
    Ok(destination)
}
