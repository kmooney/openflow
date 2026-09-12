//! The window: the review surface the spec asks for (notes/spec.md 7), plus
//! settings.
//!
//! macOS puts history and preferences in two windows because that is what a Mac
//! app does. Windows convention is one window with tabs, and it also suits a
//! tray app better: there is one thing to restore from the notification area,
//! not two.
//!
//! The window is hidden rather than closed. Quitting is an explicit choice in
//! the tray menu -- closing the last window of a dictation app should not turn
//! the hotkey off.

mod history;
mod settings;

use eframe::egui;

use crate::app::App;
use crate::kit::chord::ChordRecorder;
use crate::kit::tone::Tone;
use crate::win::tray::{self, MenuState, Tray};

/// How often a hidden OpenFlow wakes up. It matches the foreground poll in
/// `app`, which is the only thing left that needs a clock rather than an event.
const FOREGROUND_POLL_MS: u64 = 500;

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Tab {
    History,
    General,
    Vocabulary,
    Models,
}

pub struct OpenFlow {
    pub app: App,
    tray: Option<Tray>,
    tab: Tab,
    visible: bool,
    quitting: bool,
    /// Present while the user is holding a new push-to-talk chord.
    pub chord_recorder: Option<ChordRecorder>,
    pub seeding: Option<settings::Seeding>,
    pub confirm_delete_all: bool,
    /// Rows currently showing the raw transcript instead of the formatted text.
    pub showing_original: std::collections::HashSet<i64>,
}

impl OpenFlow {
    pub fn new(app: App, show_window: bool, tab: Tab) -> OpenFlow {
        OpenFlow {
            app,
            tray: None,
            tab,
            visible: show_window,
            quitting: false,
            chord_recorder: None,
            seeding: None,
            confirm_delete_all: false,
            showing_original: Default::default(),
        }
    }

    fn menu_state(&self) -> MenuState {
        let s = self.app.stats;
        MenuState {
            spoken_words: s.spoken_words,
            today_words: s.today_words,
            utterances: s.utterances,
            minutes_spoken: (s.seconds_spoken / 60.0) as i64,
            chord_label: self.app.settings.chord.label(),
            hotkey_ready: self.app.hotkey_ready(),
            tone: self.app.tone,
            tone_explanation: self.app.tone_explanation(),
            tone_is_remembered: self.app.tone_is_remembered(),
            context_label: self.app.context.label(),
            model_name: self.app.active_model_name().to_string(),
        }
    }

    fn show(&mut self, ctx: &egui::Context, tab: Tab) {
        self.tab = tab;
        self.visible = true;
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
        ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
    }

    fn hide(&mut self, ctx: &egui::Context) {
        self.visible = false;
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
    }

    fn handle_tray(&mut self, ctx: &egui::Context) {
        let Some(tray) = self.tray.as_ref() else {
            return;
        };
        for command in tray.poll() {
            match command {
                tray::Command::Open => self.show(ctx, Tab::History),
                tray::Command::Settings => self.show(ctx, Tab::General),
                tray::Command::Models => self.show(ctx, Tab::Models),
                tray::Command::EditVocabulary => self.app.edit_vocabulary(),
                tray::Command::EditDictionary => self.app.edit_dictionary(),
                tray::Command::PickTone(t) => self.app.choose_tone(t),
                tray::Command::ForgetTone => self.app.forget_tone(None),
                tray::Command::Quit => {
                    self.quitting = true;
                    self.app.shutdown();
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            }
        }
    }
}

impl eframe::App for OpenFlow {
    /// Runs even while the window is hidden, which is what makes a tray-only
    /// app possible: the hotkey, the engine and the tray all get serviced here
    /// whether or not anything is on screen.
    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if self.tray.is_none() {
            // Built on the first tick rather than at construction: tray-icon
            // needs a running Win32 message loop on this thread, and eframe has
            // one only once the event loop is going.
            self.tray = Tray::new(&self.menu_state());
            if !self.visible {
                // `ViewportBuilder::with_visible(false)` is a hint the window
                // is created with, and the window manager shows it anyway once
                // the event loop starts. Saying so again, from inside the loop,
                // is what actually keeps a tray-only launch out of the way.
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
            }
        }

        self.app.tick();
        self.handle_tray(ctx);

        if ctx.input(|i| i.viewport().close_requested()) && !self.quitting {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            self.hide(ctx);
        }

        let menu = self.menu_state();
        let (recording, seconds) = (self.app.is_recording(), self.app.live_seconds());
        if let Some(tray) = self.tray.as_mut() {
            tray.update(&menu, recording, seconds);
        }

        // Keep ticking whether or not anything is painted, but only as fast as
        // there is something to see.
        //
        // Nothing time-critical rides on this any more: the hotkey, the engine
        // and any download wake the loop themselves (`kit::wake`), so this is
        // the foreground poll and the status-message timeout. Sitting in the
        // notification area at 10 Hz cost 6% of a core to do nothing.
        let interval = if self.app.is_recording() {
            33 // the meter and the clock are moving
        } else if self.visible {
            100 // someone is looking at it
        } else {
            FOREGROUND_POLL_MS
        };
        ctx.request_repaint_after(std::time::Duration::from_millis(interval));
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        egui::Frame::central_panel(ui.style()).show(ui, |ui| {
            self.header(ui);
            ui.add_space(4.0);
            self.tab_bar(ui);
            ui.separator();
            match self.tab {
                Tab::History => history::pane(self, ui),
                Tab::General => settings::general(self, ui),
                Tab::Vocabulary => settings::vocabulary(self, ui),
                Tab::Models => settings::models(self, ui),
            }
        });
    }

    fn on_exit(&mut self) {
        self.app.shutdown();
    }
}

impl OpenFlow {
    fn header(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            let recording = self.app.is_recording();
            let label = if recording { "Stop" } else { "Listen" };
            let button = egui::Button::new(egui::RichText::new(label).size(14.0))
                .min_size(egui::vec2(88.0, 30.0));
            if ui.add_enabled(!self.app.needs_model(), button).clicked() {
                self.app.toggle_listen();
            }

            ui.vertical(|ui| {
                if recording {
                    ui.label(
                        egui::RichText::new(format!("{:.1}s", self.app.live_seconds()))
                            .size(15.0)
                            .monospace(),
                    );
                    level_meter(ui, self.app.input_db());
                } else {
                    let s = self.app.stats;
                    ui.label(
                        egui::RichText::new(format!("{} words spoken", s.spoken_words)).size(15.0),
                    );
                    ui.label(
                        egui::RichText::new(format!(
                            "{} today \u{b7} {} utterances",
                            s.today_words, s.utterances
                        ))
                        .weak()
                        .size(11.0),
                    );
                }
            });

            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                self.tone_picker(ui);
            });
        });

        // The Listen button copies; the hotkey pastes. Saying so here saves
        // the user discovering it by having a sentence land in this window.
        ui.add_space(2.0);
        if self.app.needs_model() {
            warning(
                ui,
                "No speech model yet. Download one under Models before dictating.",
            );
        } else if !self.app.hotkey_ready() {
            warning(
                ui,
                "The push-to-talk hotkey is not running, so only the Listen button works.",
            );
        } else {
            ui.label(
                egui::RichText::new(format!(
                    "Hold {} anywhere to dictate into the focused app. Listen copies to the clipboard instead.",
                    self.app.settings.chord.label()
                ))
                .weak()
                .size(11.0),
            );
        }

        if self.app.history_is_ephemeral {
            warning(
                ui,
                "The history database could not be opened, so history will be lost when OpenFlow quits.",
            );
        }
        if !self.app.status.is_empty() {
            ui.label(egui::RichText::new(&self.app.status).size(11.0));
        }
    }

    fn tone_picker(&mut self, ui: &mut egui::Ui) {
        ui.vertical(|ui| {
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let mut picked = self.app.tone;
                egui::ComboBox::from_id_salt("tone")
                    .selected_text(picked.name())
                    .show_ui(ui, |ui| {
                        for t in Tone::ALL {
                            ui.selectable_value(&mut picked, t, t.name());
                        }
                    });
                if picked != self.app.tone {
                    self.app.choose_tone(picked);
                }
            });
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if self.app.tone_is_remembered() {
                    if ui.small_button("Forget").clicked() {
                        self.app.forget_tone(None);
                    }
                } else if self.app.context.app_id.is_some()
                    && ui
                        .small_button(format!("Pin to {}", self.app.context.label()))
                        .clicked()
                {
                    let tone = self.app.tone;
                    self.app.choose_tone(tone);
                }
                ui.label(
                    egui::RichText::new(self.app.tone_explanation())
                        .weak()
                        .size(10.0),
                );
            });
        });
    }

    fn tab_bar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            for (tab, label) in [
                (Tab::History, "History"),
                (Tab::General, "General"),
                (Tab::Vocabulary, "Vocabulary"),
                (Tab::Models, "Models"),
            ] {
                if ui.selectable_label(self.tab == tab, label).clicked() {
                    self.tab = tab;
                }
            }
        });
    }
}

pub fn warning(ui: &mut egui::Ui, text: &str) {
    ui.label(
        egui::RichText::new(format!("\u{26a0} {text}"))
            .size(11.0)
            .color(egui::Color32::from_rgb(214, 138, 40)),
    );
}

/// A live input meter. "No signal" while you are talking directly into the
/// microphone can only mean the capture graph is dead -- that observation is
/// what located the silent-capture bug on macOS, so the meter earns its place.
fn level_meter(ui: &mut egui::Ui, db: f32) {
    let fraction = ((db + 60.0) / 60.0).clamp(0.0, 1.0);
    let (rect, _) = ui.allocate_exact_size(egui::vec2(160.0, 6.0), egui::Sense::hover());
    let painter = ui.painter();
    painter.rect_filled(rect, 3.0, ui.visuals().extreme_bg_color);
    if fraction > 0.0 {
        let mut filled = rect;
        filled.set_width(rect.width() * fraction);
        let colour = if db < -55.0 {
            egui::Color32::from_rgb(150, 150, 150)
        } else {
            egui::Color32::from_rgb(80, 180, 110)
        };
        painter.rect_filled(filled, 3.0, colour);
    }
    ui.label(
        egui::RichText::new(if db < -90.0 { "no signal" } else { "listening" })
            .weak()
            .size(10.0),
    );
}

/// Seconds-since-the-epoch to something a person reads. Deliberately relative
/// and deliberately coarse: the history list answers "was that the one I just
/// said", not "at what time".
pub fn relative_time(created_at: f64) -> String {
    let age = crate::kit::store::now() - created_at;
    let age = age.max(0.0);
    if age < 60.0 {
        "just now".into()
    } else if age < 3_600.0 {
        format!("{} min ago", (age / 60.0) as i64)
    } else if age < 86_400.0 {
        let hours = (age / 3_600.0) as i64;
        format!("{hours} hour{} ago", plural(hours))
    } else {
        let days = (age / 86_400.0) as i64;
        format!("{days} day{} ago", plural(days))
    }
}

fn plural(n: i64) -> &'static str {
    if n == 1 {
        ""
    } else {
        "s"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kit::store::now;

    #[test]
    fn relative_times_read_like_speech() {
        let n = now();
        assert_eq!(relative_time(n), "just now");
        assert_eq!(relative_time(n - 120.0), "2 min ago");
        assert_eq!(relative_time(n - 3_700.0), "1 hour ago");
        assert_eq!(relative_time(n - 7_400.0), "2 hours ago");
        assert_eq!(relative_time(n - 90_000.0), "1 day ago");
    }

    /// Clock skew or a row written by another machine must not produce
    /// "-3 min ago".
    #[test]
    fn a_row_from_the_future_reads_as_just_now() {
        assert_eq!(relative_time(now() + 500.0), "just now");
    }
}
