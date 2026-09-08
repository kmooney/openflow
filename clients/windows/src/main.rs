//! The executable. Everything it does lives in the library beside it; this is
//! the launch decision and the event loop.

// No console window. The whole app lives in the notification area, and a stray
// black rectangle behind it looks like something went wrong.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Arc;

use openflow_windows::app::App;
use openflow_windows::kit::wake::Wake;
use openflow_windows::ui::{OpenFlow, Tab};

use std::time::Duration;

fn main() -> eframe::Result {
    // The background threads start inside `App::new`, before there is a UI for
    // them to wake, so the handle they hold is filled in afterwards.
    let wake = Arc::new(Wake::default());
    let app = App::new(wake.clone());

    // Open on the screen that fixes it rather than failing at the first press
    // of the hotkey, and introduce the app on a first run. Otherwise start in
    // the notification area, which is where a dictation app belongs.
    let (show_window, tab) = if app.needs_model() {
        (true, Tab::Models)
    } else if !app.settings.launched_before {
        (true, Tab::History)
    } else {
        (false, Tab::History)
    };
    if !app.settings.launched_before {
        let mut settings = app.settings.clone();
        settings.launched_before = true;
        settings.save(&app.support);
    }

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("OpenFlow")
            .with_inner_size([760.0, 560.0])
            .with_min_inner_size([560.0, 360.0])
            .with_visible(show_window),
        ..Default::default()
    };

    eframe::run_native(
        "OpenFlow",
        options,
        Box::new(move |cc| {
            // eframe repaints on demand, and while the window is hidden there
            // is no demand at all -- so nothing would service the hotkey. A
            // metronome on its own thread keeps `logic` running whatever is on
            // screen. It is a wake-up, not a repaint: with the window hidden
            // eframe runs no egui pass for it.
            let ctx = cc.egui_ctx.clone();
            std::thread::Builder::new()
                .name("openflow.tick".into())
                .spawn(move || loop {
                    std::thread::sleep(Duration::from_millis(100));
                    ctx.request_repaint();
                })
                .ok();

            Ok(Box::new(OpenFlow::new(app, show_window, tab)))
        }),
    )
}
