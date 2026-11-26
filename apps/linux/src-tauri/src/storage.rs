//! Bounded retention for captures and keyframes in the cache, mirroring
//! `apps/macos/Sources/App/CaptureStorage.swift`: media referenced by an
//! unexpired brief stays, everything else Poach wrote goes once it is older
//! than a brief's lifetime.

use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde_json::Value;

use crate::paths;

/// Briefs stay readable for 24 hours, as on macOS.
pub const BRIEF_LIFETIME_SECONDS: f64 = 86_400.0;
/// Media younger than this stays, so a capture that is open but not yet shared survives.
const MEDIA_MIN_AGE: Duration = Duration::from_secs(86_400);

pub fn now_seconds() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|time| time.as_secs_f64()).unwrap_or_default()
}

/// Remove expired brief archives and old media no unexpired brief references.
/// Failures are reported on stderr; retention never blocks capture or sharing.
pub fn prune_cache() {
    prune(&paths::cache_dir());
}

fn prune(cache: &Path) {
    let protected = protected_media(cache);
    for dir in ["captures", "frames"] {
        if let Err(error) = prune_media(&cache.join(dir), &protected, dir == "frames") {
            eprintln!("Poach could not clean {dir}: {error}");
        }
    }
}

fn canonical(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

/// Paths referenced by `active-brief.json` and unexpired archives. Expired
/// archives are deleted; only sharing replaces the active brief.
fn protected_media(cache: &Path) -> HashSet<PathBuf> {
    let mut briefs = vec![(cache.join("active-brief.json"), false)];
    if let Ok(entries) = fs::read_dir(cache.join("briefs")) {
        briefs.extend(
            entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
                .map(|path| (path, true)),
        );
    }
    let mut protected = HashSet::new();
    for (file, archived) in briefs {
        let Ok(meta) = fs::symlink_metadata(&file) else { continue };
        if !meta.is_file() {
            continue;
        }
        let Some(brief) = fs::read(&file).ok().and_then(|data| serde_json::from_slice::<Value>(&data).ok()) else { continue };
        let fresh = brief["sharedAt"].as_f64().is_some_and(|shared| now_seconds() - shared <= BRIEF_LIFETIME_SECONDS);
        if !fresh {
            if archived {
                let _ = fs::remove_file(&file);
            }
            continue;
        }
        let evidence = &brief["evidence"];
        let keyframes = evidence["keyframes"].as_array().into_iter().flatten().map(|frame| &frame["imagePath"]);
        for path in std::iter::once(&evidence["sourcePath"]).chain(keyframes).filter_map(Value::as_str) {
            if !path.is_empty() {
                protected.insert(canonical(Path::new(path)));
            }
        }
    }
    protected
}

fn is_old(meta: &fs::Metadata) -> bool {
    meta.modified().ok().and_then(|time| time.elapsed().ok()).is_some_and(|age| age >= MEDIA_MIN_AGE)
}

/// `captures/` holds `recording-<uuid>.mp4` and `screenshot-<uuid>.<ext>`;
/// `frames/` holds one `<uuid>/` folder of PNGs per analysis.
fn prune_media(dir: &Path, protected: &HashSet<PathBuf>, nested: bool) -> std::io::Result<()> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = fs::symlink_metadata(&path) else { continue };
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if nested {
            if !meta.is_dir() || uuid::Uuid::parse_str(name).is_err() {
                continue;
            }
            prune_media(&path, protected, false)?;
            // Only succeeds once the folder is empty.
            let _ = fs::remove_dir(&path);
        } else if meta.is_file() && is_poach_media(dir, name) && is_old(&meta) && !protected.contains(&canonical(&path)) {
            fs::remove_file(&path)?;
        }
    }
    Ok(())
}

fn is_poach_media(dir: &Path, name: &str) -> bool {
    if dir.file_name().is_some_and(|parent| parent == "captures") {
        let stem = name.rsplit_once('.').map_or(name, |(stem, _)| stem);
        let id = stem.strip_prefix("recording-").or_else(|| stem.strip_prefix("screenshot-"));
        id.is_some_and(|id| uuid::Uuid::parse_str(id).is_ok())
    } else {
        name.ends_with(".png")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn age(path: &Path, days: u64) {
        let file = fs::File::options().write(true).open(path).unwrap();
        file.set_modified(SystemTime::now() - Duration::from_secs(days * 86_400)).unwrap();
    }

    #[test]
    fn keeps_recent_and_referenced_media_only() {
        let cache = std::env::temp_dir().join(format!("poach-storage-{}", uuid::Uuid::new_v4()));
        let captures = cache.join("captures");
        let frames = cache.join("frames").join(uuid::Uuid::new_v4().to_string());
        let old_frames = cache.join("frames").join(uuid::Uuid::new_v4().to_string());
        for dir in [&captures, &frames, &old_frames, &cache.join("briefs")] {
            fs::create_dir_all(dir).unwrap();
        }
        let file = |path: PathBuf, days: u64| {
            fs::write(&path, b"x").unwrap();
            age(&path, days);
            path
        };
        let shared = file(captures.join(format!("recording-{}.mp4", uuid::Uuid::new_v4())), 2);
        let shared_frame = file(frames.join("a-start-0ms.png"), 2);
        let stale = file(captures.join(format!("screenshot-{}.png", uuid::Uuid::new_v4())), 2);
        let stale_frame = file(old_frames.join("b-start-0ms.png"), 2);
        let recent = file(captures.join(format!("recording-{}.mp4", uuid::Uuid::new_v4())), 0);
        let foreign = file(captures.join("notes.txt"), 2);

        let brief = |shared_at: f64, source: &Path, frame: &Path| {
            serde_json::json!({
                "sharedAt": shared_at,
                "evidence": { "sourcePath": source, "keyframes": [{ "imagePath": frame }] }
            })
            .to_string()
        };
        fs::write(cache.join("active-brief.json"), brief(now_seconds(), &shared, &shared_frame)).unwrap();
        let expired = cache.join("briefs").join("old.json");
        fs::write(&expired, brief(now_seconds() - 2.0 * BRIEF_LIFETIME_SECONDS, &stale, &stale_frame)).unwrap();

        prune(&cache);

        for kept in [&shared, &shared_frame, &recent, &foreign] {
            assert!(kept.exists(), "{} was removed", kept.display());
        }
        for removed in [&stale, &stale_frame, &old_frames, &expired] {
            assert!(!removed.exists(), "{} was kept", removed.display());
        }
        fs::remove_dir_all(cache).unwrap();
    }
}
