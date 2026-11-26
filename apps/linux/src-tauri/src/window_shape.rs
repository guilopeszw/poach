//! Match the page's bottom corners to the system's window shape.
//!
//! macOS and Windows clip native windows themselves, so the page stays square
//! there. On Linux, GTK 3 cannot clip the WebKitGTK view to the themed frame,
//! so the window is transparent (see `tauri.linux.conf.json`) and the page
//! rounds its own bottom corners with the radius the GTK theme gives window
//! decorations. Maximized, tiled and fullscreen windows are square.

use std::sync::atomic::{AtomicU32, Ordering};

use tauri::{AppHandle, Emitter, Manager};

#[derive(Default)]
pub struct WindowShape(AtomicU32);

/// Bottom corner radius, in CSS pixels, for the page to apply.
#[tauri::command]
pub fn window_radius(shape: tauri::State<'_, WindowShape>) -> u32 {
    shape.0.load(Ordering::Relaxed)
}

#[cfg(target_os = "linux")]
pub fn track(app: &AppHandle) {
    use gtk::{gdk::WindowState, prelude::*};

    let Some(window) = app.get_webview_window("main") else { return };
    let Ok(gtk_window) = window.gtk_window() else { return };
    let themed = theme_radius(&gtk_window);
    let square = WindowState::MAXIMIZED | WindowState::FULLSCREEN | WindowState::TILED
        | WindowState::TOP_TILED | WindowState::BOTTOM_TILED | WindowState::LEFT_TILED | WindowState::RIGHT_TILED;

    let publish = {
        let app = app.clone();
        move |radius: u32| {
            let shape = app.state::<WindowShape>();
            if shape.0.swap(radius, Ordering::Relaxed) != radius {
                let _ = app.emit_to("main", "window-radius", radius);
            }
        }
    };
    publish(themed);
    gtk_window.connect_window_state_event(move |_, event| {
        publish(if event.new_window_state().intersects(square) { 0 } else { themed });
        gtk::glib::Propagation::Proceed
    });

    /// GTK 3 only exposes the top-left radius, so render the themed window
    /// background off-screen and measure how far the bottom-left corner is cut.
    fn theme_radius(window: &gtk::ApplicationWindow) -> u32 {
        use gtk::cairo::{Context, Format, ImageSurface};
        const SIZE: i32 = 128;
        let Ok(mut surface) = ImageSurface::create(Format::ARgb32, SIZE, SIZE) else { return 0 };
        {
            let Ok(cr) = Context::new(&surface) else { return 0 };
            gtk::render_background(&window.style_context(), &cr, 0.0, 0.0, SIZE as f64, SIZE as f64);
        }
        surface.flush();
        let stride = surface.stride() as usize;
        let Ok(data) = surface.data() else { return 0 };
        // ARGB32 is native-endian; on little-endian machines alpha is byte 3.
        let alpha = |x: usize, y: usize| data[y * stride + x * 4 + 3];
        let half = SIZE as usize / 2;
        if alpha(half, half) < 32 {
            return 0; // The theme paints no window background to measure.
        }
        let inset = (0..half).find(|&i| alpha(i, SIZE as usize - 1 - i) > 128).unwrap_or(0);
        // A circular corner of radius r is cut r·(1 − 1/√2) along the diagonal.
        ((inset as f64) / (1.0 - std::f64::consts::FRAC_1_SQRT_2)).round().clamp(0.0, 48.0) as u32
    }
}

#[cfg(not(target_os = "linux"))]
pub fn track(_app: &AppHandle) {}
