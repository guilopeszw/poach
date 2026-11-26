//! Poach's presence on the session bus.
//!
//! Owning `io.github.poach.App` keeps Poach to a single instance (a second
//! launch asks the first to open its window, then exits) and lets the Poach
//! Capture GNOME extension drive it from its top bar menu and global shortcut,
//! like the menu bar item and ⌘⇧P of the macOS app.

use tauri::{AppHandle, Emitter, Manager};
use zbus::{fdo::RequestNameFlags, Connection};

use crate::capture;

pub const BUS_NAME: &str = "io.github.poach.App";
pub const OBJECT_PATH: &str = "/io/github/poach/App";

#[zbus::proxy(interface = "io.github.poach.App", default_service = "io.github.poach.App", default_path = "/io/github/poach/App")]
trait RunningPoach {
    fn open(&self) -> zbus::Result<()>;
}

/// The bus connection that owns Poach's name, kept for the app's lifetime.
/// `None` when there is no session bus; Poach then runs without the extension.
pub struct Bus(pub Option<Connection>);

pub enum Claim {
    Owner(Bus),
    /// Another Poach owns the name and was asked to open its window.
    AlreadyRunning,
}

/// Claim Poach's bus name, or hand over to the Poach that already owns it.
pub fn claim() -> Claim {
    tauri::async_runtime::block_on(async {
        let Ok(connection) = Connection::session().await else { return Claim::Owner(Bus(None)) };
        match connection.request_name_with_flags(BUS_NAME, RequestNameFlags::DO_NOT_QUEUE).await {
            Err(zbus::Error::NameTaken) => {
                if let Ok(running) = RunningPoachProxy::new(&connection).await {
                    let _ = running.open().await;
                }
                Claim::AlreadyRunning
            }
            Ok(_) => Claim::Owner(Bus(Some(connection))),
            Err(_) => Claim::Owner(Bus(None)),
        }
    })
}

struct PoachApp {
    app: AppHandle,
}

/// Bring the main window back and switch it to the capture screen.
pub fn show_main(app: &AppHandle) {
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.show();
        let _ = main.unminimize();
        let _ = main.set_focus();
    }
}

#[zbus::interface(name = "io.github.poach.App")]
impl PoachApp {
    /// Show Poach's window.
    async fn open(&self) {
        show_main(&self.app);
    }

    /// Take a screenshot through the system dialog, then show the editor.
    async fn new_screenshot(&self) {
        show_main(&self.app);
        let _ = self.app.emit_to("main", "menu-action", "screenshot");
    }

    /// Show the capture screen to pick what to record.
    async fn new_recording(&self) {
        show_main(&self.app);
        let _ = self.app.emit_to("main", "menu-action", "new-recording");
    }

    /// Stop the current recording, or start recording the screen.
    async fn toggle_recording(&self) {
        if capture::is_recording(&self.app).await {
            capture::stop(&self.app).await;
        } else {
            let _ = self.app.emit_to("main", "menu-action", "record-screen");
        }
    }

    /// Finish any recording and quit.
    async fn quit(&self) {
        if capture::is_recording(&self.app).await {
            capture::stop(&self.app).await;
        }
        self.app.exit(0);
    }

    #[zbus(property)]
    async fn recording(&self) -> bool {
        capture::is_recording(&self.app).await
    }
}

/// Serve the interface once the app exists.
pub async fn serve(app: &AppHandle) {
    let Some(connection) = app.state::<Bus>().0.clone() else { return };
    let _ = connection.object_server().at(OBJECT_PATH, PoachApp { app: app.clone() }).await;
}

/// Tell the extension whether Poach is recording, so its icon can show it.
pub async fn announce_recording(app: &AppHandle) {
    let Some(connection) = app.try_state::<Bus>().and_then(|bus| bus.0.clone()) else { return };
    if let Ok(iface) = connection.object_server().interface::<_, PoachApp>(OBJECT_PATH).await {
        // Emits PropertiesChanged for `Recording`, which the extension watches.
        let _ = iface.get().await.recording_changed(iface.signal_emitter()).await;
    }
}

/// True when the Poach Capture extension can show Poach in the top bar, so
/// closing the window may leave Poach running.
pub async fn has_top_bar_item() -> bool {
    crate::mutter::extension_version().await.is_some_and(|version| version >= 2)
}
