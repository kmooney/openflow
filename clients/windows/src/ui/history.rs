//! Searchable history with per-row copy, replay and hard delete.
//!
//! A dictation app you cannot inspect is hard to trust, which is why this
//! arrives with the first build rather than later. Two rules from the macOS
//! client are load-bearing:
//!
//! - **Every row carries its ledger**, and *Show original* reveals what was
//!   said before formatting. The promise that changes are visible is worth
//!   little if there is no screen on which to see them.
//! - **Failures are rows too.** A recording that produced nothing is exactly
//!   the one worth investigating.

use eframe::egui;

use crate::kit::models::human_bytes;
use crate::ui::{relative_time, OpenFlow};

pub fn pane(app: &mut OpenFlow, ui: &mut egui::Ui) {
    ui.horizontal(|ui| {
        ui.label("Search");
        let response = ui.add(
            egui::TextEdit::singleline(&mut app.app.query)
                .desired_width(240.0)
                .hint_text("raw or formatted text"),
        );
        if response.changed() {
            app.app.reload_history();
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if app.confirm_delete_all {
                ui.label(
                    egui::RichText::new("Delete everything permanently?")
                        .size(11.0)
                        .color(egui::Color32::from_rgb(214, 138, 40)),
                );
                if ui.button("Delete").clicked() {
                    app.app.delete_all();
                    app.confirm_delete_all = false;
                }
                if ui.button("Cancel").clicked() {
                    app.confirm_delete_all = false;
                }
            } else if ui.button("Delete all\u{2026}").clicked() {
                app.confirm_delete_all = true;
            }
        });
    });

    ui.add_space(4.0);
    ui.horizontal(|ui| {
        ui.label(
            egui::RichText::new(format!("{} shown", app.app.history.len()))
                .weak()
                .size(10.0),
        );
        let audio = app.app.audio_on_disk();
        if audio > 0 {
            ui.label(
                egui::RichText::new(format!("{} of audio kept", human_bytes(audio)))
                    .weak()
                    .size(10.0),
            );
        }
    });
    ui.add_space(4.0);

    if app.app.history.is_empty() {
        ui.vertical_centered(|ui| {
            ui.add_space(40.0);
            ui.label(if app.app.query.is_empty() {
                "Nothing dictated yet."
            } else {
                "Nothing matches that search."
            });
        });
        return;
    }

    // Actions are always laid out and revealed on hover rather than inserted,
    // so a row does not change height and make the list jump under the pointer.
    egui::ScrollArea::vertical().show(ui, |ui| {
        let rows: Vec<_> = app.app.history.clone();
        for u in &rows {
            row(app, ui, u);
            ui.separator();
        }
    });
}

fn row(app: &mut OpenFlow, ui: &mut egui::Ui, u: &crate::kit::store::Utterance) {
    let failed = u.outcome != "ok";
    let showing_original = app.showing_original.contains(&u.id);

    ui.horizontal(|ui| {
        ui.label(
            egui::RichText::new(relative_time(u.created_at))
                .weak()
                .size(10.0),
        );
        if !failed {
            ui.label(egui::RichText::new(&u.tone).weak().size(10.0));
            ui.label(
                egui::RichText::new(format!("{} words \u{b7} {}ms", u.spoken_words, u.latency_ms))
                    .weak()
                    .size(10.0),
            );
            if !u.guardrail_passed {
                ui.label(
                    egui::RichText::new("formatting rolled back")
                        .size(10.0)
                        .color(egui::Color32::from_rgb(214, 138, 40)),
                );
            }
        }

        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui.small_button("Delete").clicked() {
                app.app.delete(u.id, u.audio_path.as_deref());
            }
            if !failed {
                if ui.small_button("Copy").clicked() {
                    app.app.copy(&u.final_text);
                }
                let label = if showing_original {
                    "Show formatted"
                } else {
                    "Show original"
                };
                if ui.small_button(label).clicked() {
                    if showing_original {
                        app.showing_original.remove(&u.id);
                    } else {
                        app.showing_original.insert(u.id);
                    }
                }
            }
            if u.audio_path.is_some() {
                let playing = app.app.playback.playing() == u.audio_path.as_deref();
                if ui
                    .small_button(if playing { "Stop" } else { "Play" })
                    .clicked()
                {
                    app.app.playback.toggle(u.audio_path.as_deref());
                }
            }
        });
    });

    if failed {
        // Discarding failures destroys the only evidence of why the product
        // disappointed someone, so they are shown, labelled, and playable.
        // The length is the useful part: "5.2s of background noise" says
        // something happened, "0.2s" says the chord was tapped by accident.
        let reason = match u.outcome.as_str() {
            "silence" => "Heard nothing",
            "steadyNoise" => "Background noise only",
            _ => "Nothing came back",
        };
        ui.label(
            egui::RichText::new(format!(
                "{reason} \u{2014} {:.1}s, not transcribed",
                u.duration_ms as f64 / 1000.0
            ))
            .weak()
            .italics(),
        );
        return;
    }

    let text = if showing_original {
        &u.raw_text
    } else {
        &u.final_text
    };
    ui.label(text);

    if showing_original {
        ui.label(
            egui::RichText::new("showing what you said, before formatting")
                .weak()
                .size(10.0),
        );
        for entry in app.app.ledger(u) {
            ui.label(egui::RichText::new(entry.description()).weak().size(10.0));
        }
    }
}
