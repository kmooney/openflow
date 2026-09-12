//! General settings, the vocabulary pane, and the model manager.

use eframe::egui;

use crate::kit::chord::ChordRecorder;
use crate::kit::models::{human_bytes, CATALOG};
use crate::kit::tone::Tone;
use crate::kit::vocabulary::{estimated_prompt_tokens, PROMPT_TOKEN_BUDGET};
use crate::ui::{warning, OpenFlow};
use crate::win::browser_history::{self, Source};
use crate::win::hotkey::current_modifiers;

pub fn general(app: &mut OpenFlow, ui: &mut egui::Ui) {
    egui::ScrollArea::vertical().show(ui, |ui| {
        ui.heading("Push to talk");
        ui.label(
            egui::RichText::new(
                "Hold the chord, speak, release. The text is pasted into whatever has focus.",
            )
            .weak()
            .size(11.0),
        );
        ui.add_space(4.0);
        chord_field(app, ui);

        ui.add_space(4.0);
        arm_delay(app, ui);

        ui.add_space(12.0);
        ui.heading("Audio");
        let mut noise = app.app.settings.noise_suppression;
        if ui.checkbox(&mut noise, "Noise suppression").changed() {
            app.app.set_noise_suppression(noise);
        }
        ui.label(
            egui::RichText::new(
                "Spectral noise reduction for steady background noise \u{2014} aircraft, fans, air conditioning. It leaves a clean recording untouched.",
            )
            .weak()
            .size(11.0),
        );

        let mut high_pass = app.app.settings.high_pass;
        if ui.checkbox(&mut high_pass, "Cut low-frequency rumble").changed() {
            app.app.set_high_pass(high_pass);
        }

        let mut reject = app.app.settings.reject_non_speech;
        if ui
            .checkbox(&mut reject, "Refuse to transcribe background noise")
            .changed()
        {
            app.app.set_reject_non_speech(reject);
        }
        ui.label(
            egui::RichText::new(
                "Whisper invents fluent sentences out of steady noise. Turning this off means anything captured is transcribed, however unpromising.",
            )
            .weak()
            .size(11.0),
        );

        let mut keep = app.app.settings.keep_audio;
        if ui.checkbox(&mut keep, "Keep audio for debugging").changed() {
            app.app.set_keep_audio(keep);
        }
        ui.label(
            egui::RichText::new(
                "Store each recording on disk so you can replay it from the history. Off by default: the standing rule is transcribe and discard.",
            )
            .weak()
            .size(11.0),
        );
        if let Some(device) = app.app.input_device() {
            ui.label(egui::RichText::new(format!("Microphone: {device}")).weak().size(11.0));
        }

        ui.add_space(12.0);
        ui.heading("Remembered tones");
        ui.label(
            egui::RichText::new("Set by picking a tone while that program has focus.")
                .weak()
                .size(11.0),
        );
        remembered_tones(app, ui);

        ui.add_space(12.0);
        ui.heading("Where things are");
        ui.label(
            egui::RichText::new(app.app.support.to_string_lossy())
                .weak()
                .size(11.0),
        );
        ui.label(
            egui::RichText::new(
                "Everything runs on this machine: the model, the history and the vocabulary never leave it. The only thing that touches the network is downloading a model.",
            )
            .weak()
            .size(11.0),
        );
        ui.label(
            egui::RichText::new(
                "To dictate into a program running as administrator, OpenFlow has to be running as administrator too \u{2014} Windows will not let a normal program send keystrokes to an elevated one.",
            )
            .weak()
            .size(11.0),
        );
    });
}

fn chord_field(app: &mut OpenFlow, ui: &mut egui::Ui) {
    ui.horizontal(|ui| {
        match app.chord_recorder.as_mut() {
            Some(recorder) => {
                let held = recorder.held();
                let chosen = recorder.update(current_modifiers());
                ui.label(
                    egui::RichText::new(if held.count() == 0 {
                        "Hold a chord\u{2026}".to_string()
                    } else {
                        held.label()
                    })
                    .size(14.0),
                );
                if let Some(chord) = chosen {
                    app.app.set_chord(chord);
                    app.chord_recorder = None;
                }
                if ui.button("Cancel").clicked() {
                    app.chord_recorder = None;
                }
            }
            None => {
                ui.label(egui::RichText::new(app.app.settings.chord.label()).size(14.0));
                if ui.button("Change\u{2026}").clicked() {
                    app.chord_recorder = Some(ChordRecorder::default());
                }
                if app.app.settings.chord != Default::default()
                    && ui.button("Reset to Ctrl+Shift").clicked()
                {
                    app.app.set_chord(Default::default());
                }
            }
        }
    });

    if app.chord_recorder.is_some() {
        ui.label(
            egui::RichText::new("Two modifiers at least. It is committed when you let go.")
                .weak()
                .size(11.0),
        );
    } else if app.app.settings.chord.is_collision_prone() {
        // Alt and Win are self-acting: pressing and releasing either one alone
        // is itself a command to Windows.
        warning(
            ui,
            "Alt on its own opens the menu bar and Win on its own opens Start, so this chord will also do that every time you dictate.",
        );
    }
}

fn arm_delay(app: &mut OpenFlow, ui: &mut egui::Ui) {
    let mut ms = app.app.settings.arm_delay_ms;
    ui.horizontal(|ui| {
        ui.label("Open the microphone after");
        if ui
            .add(egui::Slider::new(&mut ms, 0..=600).suffix(" ms"))
            .changed()
        {
            app.app.set_arm_delay(ms);
        }
    });
    ui.label(
        egui::RichText::new(
            "Ctrl+Shift is also the start of real shortcuts \u{2014} Ctrl+Shift+T, Ctrl+Shift+Arrow. Waiting a moment keeps the microphone out of them. Set it to 0 to open instantly. Either way, pressing an ordinary key while the chord is held cancels the recording.",
        )
        .weak()
        .size(11.0),
    );
}

fn remembered_tones(app: &mut OpenFlow, ui: &mut egui::Ui) {
    let rules = app.app.memory.all();
    if rules.is_empty() {
        ui.label(
            egui::RichText::new("Nothing yet \u{2014} OpenFlow is using its suggestions.")
                .weak()
                .size(11.0),
        );
        return;
    }
    for rule in &rules {
        ui.horizontal(|ui| {
            ui.label(&rule.label);
            let mut picked = rule.tone;
            egui::ComboBox::from_id_salt(format!("tone-{}", rule.key))
                .selected_text(picked.name())
                .show_ui(ui, |ui| {
                    for t in Tone::ALL {
                        ui.selectable_value(&mut picked, t, t.name());
                    }
                });
            if picked != rule.tone {
                app.app.remember_tone_for_key(picked, &rule.key);
            }
            if ui.small_button("Forget").clicked() {
                app.app.forget_tone(Some(&rule.key));
            }
        });
    }
    if ui.button("Forget all").clicked() {
        app.app.forget_all_tones();
    }
}

pub fn vocabulary(app: &mut OpenFlow, ui: &mut egui::Ui) {
    egui::ScrollArea::vertical().show(ui, |ui| {
        ui.heading("In effect right now");
        ui.horizontal(|ui| {
            ui.label("Last dictated into:");
            match app.app.context.app_id.as_deref() {
                Some(id) => {
                    ui.label(egui::RichText::new(id).monospace());
                    if ui.small_button("Copy").clicked() {
                        let id = id.to_string();
                        app.app.copy(&id);
                    }
                }
                None => {
                    ui.label(
                        egui::RichText::new("Dictate somewhere and its name appears here.")
                            .weak()
                            .size(11.0),
                    );
                }
            }
        });
        // The program name is the one thing the file cannot tell you and a
        // [section] header needs.
        let here = app.app.vocabulary_here();
        ui.label(
            egui::RichText::new(format!(
                "{} terms apply here \u{b7} about {} of {PROMPT_TOKEN_BUDGET} prompt tokens",
                here.len(),
                estimated_prompt_tokens(&here)
            ))
            .weak()
            .size(11.0),
        );
        if !here.is_empty() {
            let preview: Vec<&str> = here.iter().take(12).map(|s| s.as_str()).collect();
            ui.label(
                egui::RichText::new(preview.join(", "))
                    .weak()
                    .size(11.0),
            );
        }

        ui.add_space(12.0);
        ui.heading("The file");
        ui.label(
            egui::RichText::new(
                "Terms above any [section] apply everywhere. A [program.exe] header starts a list used only while that program has focus \u{2014} which is how you get \"git status\" in a terminal instead of \"get status\".",
            )
            .weak()
            .size(11.0),
        );
        let apps = app.app.vocabulary.apps();
        if !apps.is_empty() {
            ui.label(
                egui::RichText::new(format!("Sections: {}", apps.join(", ")))
                    .weak()
                    .size(11.0),
            );
        }
        ui.horizontal(|ui| {
            if ui.button("Edit vocabulary\u{2026}").clicked() {
                app.app.edit_vocabulary();
            }
            if ui.button("Reload").clicked() {
                app.app.reload_vocabulary();
                let n = app.app.vocabulary_here().len();
                app.app.set_status(&format!("{n} terms apply here"));
            }
            if ui.button("Seed from browser history\u{2026}").clicked() {
                app.seeding = Some(Seeding::new());
            }
        });

        if app.seeding.is_some() {
            ui.add_space(8.0);
            seeding_sheet(app, ui);
        }

        ui.add_space(16.0);
        ui.heading("Dictionary");
        ui.label(
            egui::RichText::new(
                "Say the phrase, get the text: \"my email = you@example.com\", one entry per line. This runs at the end of the pipeline, after the polish model \u{2014} so what you typed is exactly what gets pasted. Vocabulary is the opposite end: it steers what is heard.",
            )
            .weak()
            .size(11.0),
        );
        let entries = app.app.dictionary_entries();
        ui.label(
            egui::RichText::new(if entries.len() == 1 {
                "1 shortcut".to_string()
            } else {
                format!("{} shortcuts", entries.len())
            })
            .weak()
            .size(11.0),
        );
        for entry in entries.iter().take(6) {
            ui.label(
                egui::RichText::new(format!(
                    "{} \u{2192} {}",
                    entry.phrase,
                    entry.replacement.replace('\n', " \u{23ce} ")
                ))
                .weak()
                .size(11.0),
            );
        }
        ui.horizontal(|ui| {
            if ui.button("Edit dictionary\u{2026}").clicked() {
                app.app.edit_dictionary();
            }
            if ui.button("Reload dictionary").clicked() {
                app.app.reload_dictionary();
                let n = app.app.dictionary_entries().len();
                app.app.set_status(&format!("{n} shortcuts loaded"));
            }
        });
    });
}

/// Seeding the vocabulary from the domains you actually visit.
///
/// Nothing is read until the user presses the button, nothing but hostnames
/// ever leaves the reader, and nothing is written until they have seen the list.
pub struct Seeding {
    sources: Vec<Source>,
    selected: usize,
    domains: Vec<(String, i64)>,
    /// What the target section already holds, so hand-written terms survive.
    existing: Vec<String>,
    limit: usize,
    error: Option<String>,
    loaded_from: Option<String>,
}

impl Seeding {
    pub fn new() -> Seeding {
        Seeding {
            sources: browser_history::available(),
            selected: 0,
            domains: Vec::new(),
            existing: Vec::new(),
            limit: 40,
            error: None,
            loaded_from: None,
        }
    }
}

/// `existing` first, then anything from `fresh` not already there. Duplicates
/// are matched case-insensitively, so seeding twice does not double the file.
fn merge(existing: &[String], fresh: &[String]) -> Vec<String> {
    let mut seen: std::collections::HashSet<String> =
        existing.iter().map(|t| t.to_lowercase()).collect();
    let mut out = existing.to_vec();
    for term in fresh {
        if seen.insert(term.to_lowercase()) {
            out.push(term.clone());
        }
    }
    out
}

fn seeding_sheet(app: &mut OpenFlow, ui: &mut egui::Ui) {
    let mut close = false;
    let mut load = false;
    let mut write: Option<(Vec<String>, String)> = None;

    if let Some(seeding) = app.seeding.as_mut() {
        egui::Frame::group(ui.style()).show(ui, |ui| {
            ui.heading("Seed from browser history");
            ui.label(
                egui::RichText::new(
                    "Reads a copy of the browser's history, keeps only the host names, and writes them into that browser's section. Nothing else leaves the database \u{2014} no paths, no titles, no times.",
                )
                .weak()
                .size(11.0),
            );

            if seeding.sources.is_empty() {
                ui.label("No browser history OpenFlow can read was found.");
                if ui.button("Close").clicked() {
                    close = true;
                }
                return;
            }

            ui.horizontal(|ui| {
                let selected_name = seeding.sources[seeding.selected].name.clone();
                egui::ComboBox::from_id_salt("seed-source")
                    .selected_text(selected_name)
                    .show_ui(ui, |ui| {
                        for (i, s) in seeding.sources.iter().enumerate() {
                            ui.selectable_value(&mut seeding.selected, i, &s.name);
                        }
                    });
                ui.add(egui::Slider::new(&mut seeding.limit, 5..=120).text("terms"));
                if ui.button("Read history").clicked() {
                    load = true;
                }
            });

            if let Some(e) = &seeding.error {
                ui.label(
                    egui::RichText::new(e)
                        .size(11.0)
                        .color(egui::Color32::from_rgb(214, 138, 40)),
                );
            }

            if !seeding.domains.is_empty() {
                let chosen: Vec<String> = seeding
                    .domains
                    .iter()
                    .take(seeding.limit)
                    .map(|(d, _)| d.clone())
                    .collect();
                // Anything hand-added to that section stays, and stays first:
                // the file is the user's, and a convenience feature must not
                // quietly drop words they typed themselves.
                let chosen = merge(&seeding.existing, &chosen);
                let tokens = estimated_prompt_tokens(&chosen);
                ui.label(
                    egui::RichText::new(format!(
                        "{} domains \u{b7} about {tokens} of {PROMPT_TOKEN_BUDGET} prompt tokens",
                        chosen.len()
                    ))
                    .weak()
                    .size(11.0),
                );
                if tokens > PROMPT_TOKEN_BUDGET {
                    warning(
                        ui,
                        "That is more than whisper will accept; the tail will be silently dropped. Use fewer terms.",
                    );
                }
                egui::ScrollArea::vertical()
                    .max_height(120.0)
                    .id_salt("seed-list")
                    .show(ui, |ui| {
                        ui.label(egui::RichText::new(chosen.join(", ")).size(11.0));
                    });

                let app_id = seeding
                    .loaded_from
                    .clone()
                    .unwrap_or_else(|| seeding.sources[seeding.selected].app_id.clone());
                ui.horizontal(|ui| {
                    if ui.button(format!("Write into [{app_id}]")).clicked() {
                        write = Some((chosen.clone(), app_id.clone()));
                    }
                    if ui.button("Close").clicked() {
                        close = true;
                    }
                });
            } else if ui.button("Close").clicked() {
                close = true;
            }
        });
    }

    if load {
        let existing = app
            .seeding
            .as_ref()
            .map(|s| {
                crate::kit::vocabulary::file::section(
                    &app.app.vocabulary_text(),
                    &s.sources[s.selected].app_id,
                )
            })
            .unwrap_or_default();
        if let Some(seeding) = app.seeding.as_mut() {
            let source = seeding.sources[seeding.selected].clone();
            match browser_history::domains_from(&source, 400) {
                Ok(domains) => {
                    seeding.domains = domains;
                    seeding.existing = existing;
                    seeding.error = None;
                    seeding.loaded_from = Some(source.app_id.clone());
                }
                Err(e) => {
                    seeding.domains.clear();
                    seeding.error = Some(e);
                }
            }
        }
    }
    if let Some((terms, app_id)) = write {
        app.app.seed_vocabulary(&terms, &app_id);
    }
    if close {
        app.seeding = None;
    }
}

pub fn models(app: &mut OpenFlow, ui: &mut egui::Ui) {
    egui::ScrollArea::vertical().show(ui, |ui| {
        ui.label(
            egui::RichText::new(
                "Models run entirely on this machine. Larger ones are more accurate and slower; the notes below are what M0 measured, not what the model cards claim.",
            )
            .weak()
            .size(11.0),
        );
        if let Some(e) = &app.app.models.last_error {
            ui.label(
                egui::RichText::new(e)
                    .size(11.0)
                    .color(egui::Color32::from_rgb(214, 138, 40)),
            );
        }
        ui.add_space(6.0);

        let mut select: Option<String> = None;
        let mut download: Option<String> = None;
        let mut cancel: Option<String> = None;
        let mut delete: Option<String> = None;

        for model in CATALOG {
            let installed = app.app.models.is_installed(model.id);
            let active = app.app.models.selected_id == model.id;
            let progress = app.app.models.progress(model.id);

            egui::Frame::group(ui.style()).show(ui, |ui| {
                ui.horizontal(|ui| {
                    // Reserve the buttons' width before the text claims it.
                    // Left to itself the description takes the whole row and
                    // the buttons are drawn on top of the last line of it.
                    const ACTIONS: f32 = 160.0;
                    let text_width = (ui.available_width() - ACTIONS).max(160.0);
                    ui.allocate_ui_with_layout(
                        egui::vec2(text_width, 0.0),
                        egui::Layout::top_down(egui::Align::LEFT),
                        |ui| {
                            ui.set_max_width(text_width);
                            ui.horizontal(|ui| {
                                ui.label(egui::RichText::new(model.display_name).strong());
                                ui.label(
                                    egui::RichText::new(model.size_description())
                                        .weak()
                                        .size(10.0),
                                );
                                if active {
                                    ui.label(egui::RichText::new("in use").size(10.0));
                                }
                            });
                            ui.add(
                                egui::Label::new(
                                    egui::RichText::new(model.note).weak().size(11.0),
                                )
                                .wrap(),
                            );
                            if let Some(p) = progress {
                                ui.add(
                                    egui::ProgressBar::new(p.fraction as f32)
                                        .desired_width(220.0),
                                );
                                ui.label(
                                    egui::RichText::new(format!(
                                        "{} of {}",
                                        human_bytes(p.received),
                                        human_bytes(p.total)
                                    ))
                                    .weak()
                                    .size(10.0),
                                );
                            }
                        },
                    );

                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if progress.is_some() {
                            if ui.button("Cancel").clicked() {
                                cancel = Some(model.id.to_string());
                            }
                        } else if installed {
                            if !active && ui.button("Use").clicked() {
                                select = Some(model.id.to_string());
                            }
                            if ui.button("Delete").clicked() {
                                delete = Some(model.id.to_string());
                            }
                        } else if ui.button("Download").clicked() {
                            download = Some(model.id.to_string());
                        }
                    });
                });
            });
        }

        if let Some(id) = select {
            app.app.select_model(&id);
        }
        if let Some(id) = download {
            app.app.models.download(&id);
        }
        if let Some(id) = cancel {
            app.app.models.cancel_download(&id);
        }
        if let Some(id) = delete {
            app.app.delete_model(&id);
        }

        ui.add_space(6.0);
        ui.label(
            egui::RichText::new(format!(
                "{} on disk",
                human_bytes(app.app.models.disk_usage())
            ))
            .weak()
            .size(10.0),
        );
    });
}
