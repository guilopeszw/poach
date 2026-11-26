mod analysis;
mod app_service;
mod capture;
mod handoff;
mod mutter;
mod paths;
mod storage;
mod window_shape;

use tauri::Manager;

fn main() {
    let bus = match app_service::claim() {
        app_service::Claim::Owner(bus) => bus,
        // The running Poach was asked to show its window.
        app_service::Claim::AlreadyRunning => return,
    };
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .manage(capture::Recorder::default())
        .manage(window_shape::WindowShape::default())
        .manage(bus)
        .setup(|app| {
            window_shape::track(app.handle());
            std::thread::spawn(storage::prune_cache);
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move { app_service::serve(&handle).await });
            Ok(())
        })
        .on_window_event(|window, event| {
            // Like the macOS app, closing the window keeps Poach in the top bar,
            // but only when the extension can show it there; otherwise quit.
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let window = window.clone();
                    tauri::async_runtime::spawn(async move {
                        if app_service::has_top_bar_item().await {
                            let _ = window.hide();
                        } else {
                            if capture::is_recording(window.app_handle()).await {
                                capture::stop(window.app_handle()).await;
                            }
                            window.app_handle().exit(0);
                        }
                    });
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            capture::start_recording,
            capture::stop_recording,
            capture::take_screenshot,
            analysis::inspect,
            handoff::share_handoff,
            handoff::connector_connected,
            handoff::connector_command,
            window_shape::window_radius,
        ])
        .run(tauri::generate_context!())
        .expect("Poach could not start");
}
