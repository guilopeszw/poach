//! Writes briefs in the format `packages/mcp-server` reads (see
//! `apps/macos/Sources/App/PoachHandoff.swift`).

use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::Path,
    time::Duration,
};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{
    paths,
    storage::{self, now_seconds, BRIEF_LIFETIME_SECONDS},
};

const CONNECTION_LEASE: Duration = Duration::from_secs(15);

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Annotation {
    time_ms: u64,
    text: String,
}

fn write_private(path: &Path, data: &[u8]) -> Result<(), String> {
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, data)
        .and_then(|_| fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600)))
        .and_then(|_| fs::rename(&temporary, path))
        .map_err(|error| format!("Could not write {}: {error}", path.display()))
}

/// Keep the previous brief readable by its ID before replacing it.
fn archive_active(active: &Path, archive: &Path) -> Result<(), String> {
    let Ok(data) = fs::read(active) else { return Ok(()) };
    let Ok(brief) = serde_json::from_slice::<Value>(&data) else { return Ok(()) };
    let (Some(id), Some(shared_at)) = (brief["briefId"].as_str(), brief["sharedAt"].as_f64()) else { return Ok(()) };
    if now_seconds() - shared_at > BRIEF_LIFETIME_SECONDS {
        return Ok(());
    }
    let destination = archive.join(format!("{}.json", id.to_lowercase()));
    if destination.exists() {
        return Ok(());
    }
    write_private(&destination, &data)
}

#[tauri::command]
pub fn share_handoff(inspection: Value, context: String, annotations: Vec<Annotation>) -> Result<String, String> {
    let Value::Object(mut evidence) = inspection else {
        return Err("Analyze a capture before sharing it.".into());
    };
    let is_image = evidence.get("mediaType").and_then(Value::as_str) == Some("image");
    evidence.insert("annotations".into(), serde_json::to_value(annotations).map_err(|error| error.to_string())?);

    let id = uuid::Uuid::new_v4().to_string();
    let instruction = if is_image {
        "Recreate the visible UI using the screenshot and palette. Ask about behavior the screenshot does not show."
    } else {
        "Recreate this UI in the current project. Inspect the keyframes, preserve observed behavior and colors, and treat timing estimates as approximate. Ask about ambiguous behavior."
    };
    let brief = json!({
        "briefId": id,
        "version": 1,
        "sharedAt": now_seconds(),
        "context": context,
        "instruction": instruction,
        "evidence": evidence,
    });
    let data = serde_json::to_vec(&brief).map_err(|error| error.to_string())?;

    let cache = paths::private_dir("")?;
    let archive = paths::private_dir("briefs")?;
    let active = cache.join("active-brief.json");
    archive_active(&active, &archive)?;
    write_private(&archive.join(format!("{id}.json")), &data)?;
    write_private(&active, &data)?;
    std::thread::spawn(storage::prune_cache);
    Ok(id)
}

/// True when an MCP client has the Poach connector running (see the
/// presence files written by `packages/mcp-server`).
#[tauri::command]
pub fn connector_connected() -> bool {
    let Ok(entries) = fs::read_dir(paths::cache_dir().join("connections")) else { return false };
    entries.flatten().any(|entry| {
        let Some(pid) = entry.file_name().to_str().and_then(|name| name.parse::<libc::pid_t>().ok()) else { return false };
        let fresh = entry
            .metadata()
            .and_then(|meta| meta.modified())
            .ok()
            .and_then(|modified| modified.elapsed().ok())
            .is_some_and(|age| age < CONNECTION_LEASE);
        // SAFETY: signal 0 only checks that the process exists.
        pid > 0 && fresh && unsafe { libc::kill(pid, 0) } == 0
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Assistant {
    Claude,
    Codex,
}

/// Command that registers Poach's MCP connector with Claude Code or Codex.
/// Installed builds ship a bundled connector; development runs use the
/// workspace build.
#[tauri::command]
pub fn connector_command(app: tauri::AppHandle, assistant: Assistant) -> String {
    use tauri::Manager;
    let bundled = app.path().resource_dir().ok().map(|dir| dir.join("mcp/server.mjs")).filter(|path| path.is_file());
    let server = bundled.unwrap_or_else(|| {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../packages/mcp-server/dist/index.js")
    });
    let server = server.canonicalize().unwrap_or(server);
    let server = server.display();
    match assistant {
        Assistant::Claude => format!("claude mcp add --scope user poach -- node '{server}'"),
        Assistant::Codex => format!("codex mcp add poach -- node '{server}'"),
    }
}
