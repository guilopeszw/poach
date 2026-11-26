use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};

/// `$XDG_CACHE_HOME/poach`, matching `packages/mcp-server/src/paths.ts`.
pub fn cache_dir() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home().join(".cache"))
        .join("poach")
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

/// Create `child` inside the cache, keeping every level private to the user.
pub fn private_dir(child: impl AsRef<Path>) -> Result<PathBuf, String> {
    let root = cache_dir();
    let path = root.join(child);
    fs::create_dir_all(&path).map_err(|error| format!("Could not create {}: {error}", path.display()))?;
    for dir in path.ancestors().take_while(|dir| dir.starts_with(&root)) {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
            .map_err(|error| format!("Could not protect {}: {error}", dir.display()))?;
    }
    Ok(path)
}
