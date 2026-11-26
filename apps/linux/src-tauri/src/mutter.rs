//! GNOME-only recording path through `org.gnome.Mutter.ScreenCast`.
//!
//! RecordArea makes Mutter paint the stage again off-screen, which lets the
//! Poach Capture extension (apps/linux/gnome-extension) keep the recording
//! controls out of the video. The extension also reports which monitor to
//! record. Without it, callers fall back to the ScreenCast portal.

use std::collections::HashMap;

use futures_util::StreamExt;
use zbus::{Connection, OwnedObjectPath, Variant};

/// Embed the cursor in the frames, as the portal path does.
const CURSOR_EMBEDDED: u32 = 1;

#[zbus::proxy(
    interface = "io.github.poach.Shell",
    default_service = "org.gnome.Shell",
    default_path = "/io/github/poach/Shell"
)]
trait PoachShell {
    fn get_version(&self) -> zbus::Result<u32>;
    fn get_capture_monitor(&self) -> zbus::Result<(i32, i32, i32, i32)>;
}

#[zbus::proxy(
    interface = "org.gnome.Mutter.ScreenCast",
    default_service = "org.gnome.Mutter.ScreenCast",
    default_path = "/org/gnome/Mutter/ScreenCast"
)]
trait ScreenCast {
    fn create_session(&self, properties: HashMap<&str, Variant<'_>>) -> zbus::Result<OwnedObjectPath>;
}

#[zbus::proxy(interface = "org.gnome.Mutter.ScreenCast.Session", default_service = "org.gnome.Mutter.ScreenCast")]
trait ScreenCastSession {
    fn record_area(
        &self,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        properties: HashMap<&str, Variant<'_>>,
    ) -> zbus::Result<OwnedObjectPath>;
    fn start(&self) -> zbus::Result<()>;
    fn stop(&self) -> zbus::Result<()>;
}

#[zbus::proxy(interface = "org.gnome.Mutter.ScreenCast.Stream", default_service = "org.gnome.Mutter.ScreenCast")]
trait ScreenCastStream {
    #[zbus(signal)]
    fn pipe_wire_stream_added(&self, node_id: u32) -> zbus::Result<()>;
}

/// A running Mutter screen cast. Mutter ends it when `stop` is called or when
/// this D-Bus connection closes.
pub struct AreaCast {
    session: ScreenCastSessionProxy<'static>,
    pub node_id: u32,
    pub size: (i32, i32),
}

impl AreaCast {
    pub async fn stop(&self) {
        let _ = self.session.stop().await;
    }
}

/// API version of the Poach Capture extension, when it is enabled.
pub async fn extension_version() -> Option<u32> {
    let connection = Connection::session().await.ok()?;
    PoachShellProxy::new(&connection).await.ok()?.get_version().await.ok()
}

/// The monitor to record, when the Poach Capture extension is enabled.
pub async fn capture_monitor() -> Option<(i32, i32, i32, i32)> {
    let connection = Connection::session().await.ok()?;
    let shell = PoachShellProxy::new(&connection).await.ok()?;
    shell.get_version().await.ok()?;
    shell.get_capture_monitor().await.ok()
}

pub async fn record_area((x, y, width, height): (i32, i32, i32, i32)) -> Result<AreaCast, String> {
    let error = |error: zbus::Error| format!("GNOME refused the screen recording: {error}");
    let connection = Connection::session().await.map_err(error)?;
    let path = ScreenCastProxy::new(&connection).await.map_err(error)?.create_session(HashMap::new()).await.map_err(error)?;
    let session = ScreenCastSessionProxy::builder(&connection).path(path).build().await.map_err(error)?;
    let properties = HashMap::from([("cursor-mode", Variant::from(CURSOR_EMBEDDED)), ("is-recording", Variant::from(true))]);
    let stream_path = session.record_area(x, y, width, height, properties).await.map_err(error)?;
    let stream = ScreenCastStreamProxy::builder(&connection).path(stream_path).build().await.map_err(error)?;
    // Subscribe before starting so the signal cannot be missed.
    let mut added = stream.receive_pipe_wire_stream_added().await.map_err(error)?;
    session.start().await.map_err(error)?;
    let signal = tokio::time::timeout(std::time::Duration::from_secs(5), added.next())
        .await
        .ok()
        .flatten()
        .ok_or("GNOME did not provide the recording stream.")?;
    let node_id = signal.args().map_err(error)?.node_id;
    Ok(AreaCast { session, node_id, size: (width, height) })
}
