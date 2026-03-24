use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconEvent,
    AppHandle, Manager,
};

/// Set up the system tray with context menu and click handler.
pub fn setup_tray(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let show_item = MenuItem::with_id(app, "show", "Show Window", true, None::<&str>)?;
    let settings_item = MenuItem::with_id(app, "settings", "Settings", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit TokenBox", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;

    let menu = Menu::with_items(app, &[&show_item, &settings_item, &separator, &quit_item])?;

    if let Some(tray) = app.tray_by_id("main") {
        tray.set_menu(Some(menu))?;
        tray.set_tooltip(Some("TokenBox"))?;

        tray.on_menu_event(move |app, event| match event.id().as_ref() {
            "show" => {
                show_main_window(app);
            }
            "settings" => {
                open_settings_window(app);
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        });

        tray.on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { .. } = event {
                show_main_window(tray.app_handle());
            }
        });
    }

    Ok(())
}

/// Show and focus the main window.
fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// Open settings as a separate window (created on demand).
fn open_settings_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }

    let _ = tauri::WebviewWindowBuilder::new(
        app,
        "settings",
        tauri::WebviewUrl::App("settings.html".into()),
    )
    .title("TokenBox Settings")
    .inner_size(520.0, 400.0)
    .resizable(false)
    .center()
    .build();
}

/// Update tray tooltip with current token count.
#[tauri::command]
pub fn update_tray_state(
    app: AppHandle,
    count: i64,
    is_streaming: bool,
) {
    if let Some(tray) = app.tray_by_id("main") {
        let status = if is_streaming { " (streaming)" } else { "" };
        let tooltip = format!("TokenBox — {}{}", format_tray_tokens(count), status);
        let _ = tray.set_tooltip(Some(&tooltip));
    }
}

/// Format token count for tray tooltip display.
fn format_tray_tokens(count: i64) -> String {
    if count < 1_000 {
        format!("{}", count)
    } else if count < 1_000_000 {
        format!("{:.2}K", count as f64 / 1_000.0)
    } else if count < 1_000_000_000 {
        format!("{:.2}M", count as f64 / 1_000_000.0)
    } else {
        format!("{:.2}B", count as f64 / 1_000_000_000.0)
    }
}
