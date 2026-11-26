//! Runs `@poach/core` in Node, exactly like the macOS client does.

use std::{path::PathBuf, process::Stdio};

use serde_json::Value;
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};

use crate::paths;

const STAGES: [&str; 3] = ["motion", "frames", "palette"];

const SCRIPT: &str = r#"
import { inspectImage, inspectVideo, inspectRecording } from __ENGINE__;
const [path, mode, outputDirectory] = process.argv.slice(1);
const inspect = /\.(png|jpe?g|webp|tiff?|bmp)$/i.test(path) ? inspectImage : (mode === "recording" ? inspectRecording : inspectVideo);
try {
  const result = await inspect(path, { outputDirectory, onProgress: stage => console.log(stage) });
  process.stdout.write(JSON.stringify(result));
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
"#;

/// Built core entry point: `POACH_CORE_ENTRY`, then the copy bundled with an
/// installed Poach, then the workspace build used in development.
fn core_entry(app: &AppHandle) -> Result<PathBuf, String> {
    use tauri::Manager;
    let bundled = app.path().resource_dir().ok().map(|dir| dir.join("core/index.js"));
    let path = std::env::var_os("POACH_CORE_ENTRY")
        .map(PathBuf::from)
        .or(bundled.filter(|path| path.is_file()))
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../packages/core/dist/index.js"));
    path.canonicalize()
        .map_err(|_| format!("Poach's analysis engine is missing at {}. Reinstall Poach, or run `pnpm build` in a checkout.", path.display()))
}

#[tauri::command]
pub async fn inspect(app: AppHandle, path: PathBuf, is_recording: bool) -> Result<Value, String> {
    let engine = url::Url::from_file_path(core_entry(&app)?)
        .map_err(|_| "Invalid analysis engine path.".to_string())?
        .to_string();
    let frames = paths::private_dir(PathBuf::from("frames").join(uuid::Uuid::new_v4().to_string()))?;
    let node = std::env::var_os("POACH_NODE").unwrap_or_else(|| "node".into());

    let mut child = tokio::process::Command::new(node)
        .arg("--input-type=module")
        .arg("-e")
        .arg(SCRIPT.replace("__ENGINE__", &serde_json::to_string(&engine).unwrap_or_default()))
        .arg(&path)
        .arg(if is_recording { "recording" } else { "import" })
        .arg(&frames)
        .current_dir(std::env::temp_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| format!("Could not start Node.js ({error}). Install Node 20 or newer."))?;

    let mut stderr = child.stderr.take().ok_or("Missing analysis error stream.")?;
    let stderr_task = tokio::spawn(async move {
        let mut text = String::new();
        let _ = stderr.read_to_string(&mut text).await;
        text
    });

    let mut lines = BufReader::new(child.stdout.take().ok_or("Missing analysis output.")?).lines();
    let mut result = String::new();
    while let Some(line) = lines.next_line().await.map_err(|error| error.to_string())? {
        if STAGES.contains(&line.as_str()) {
            let _ = app.emit("inspect-progress", &line);
        } else {
            result.push_str(&line);
        }
    }

    let status = child.wait().await.map_err(|error| error.to_string())?;
    let errors = stderr_task.await.unwrap_or_default();
    if !status.success() {
        let details = errors.trim();
        return Err(if details.is_empty() {
            format!("Analysis exited with {status}. Check that ffmpeg and ffprobe are installed.")
        } else {
            details.to_string()
        });
    }
    serde_json::from_str(&result).map_err(|error| format!("Poach returned an unreadable analysis result: {error}"))
}
