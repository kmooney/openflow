//! The notification-area icon and its menu -- the Windows counterpart of the
//! macOS menu bar.
//!
//! Like the Mac's, it is a *view of the model*: it holds no state of its own,
//! and it is rebuilt whenever the thing it displays changes, so the tone shown
//! here and the tone in the window cannot disagree.
//!
//! It must be created on a thread that pumps Win32 messages, which is the UI
//! thread. That is also why the menu is rebuilt rather than mutated: a menu
//! item's text cannot be changed on this platform without going through the
//! same rebuild anyway.

use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

use crate::kit::tone::Tone;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    Open,
    Settings,
    Models,
    EditVocabulary,
    EditDictionary,
    PickTone(Tone),
    ForgetTone,
    Quit,
}

/// Everything the menu shows. Compared against the last one so the menu is only
/// rebuilt when something a user could see has actually changed -- rebuilding
/// it while it is open closes it under the pointer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MenuState {
    pub spoken_words: i64,
    pub today_words: i64,
    pub utterances: i64,
    pub minutes_spoken: i64,
    pub chord_label: String,
    pub hotkey_ready: bool,
    pub tone: Tone,
    pub tone_explanation: String,
    pub tone_is_remembered: bool,
    pub context_label: String,
    pub model_name: String,
}

pub struct Tray {
    icon: TrayIcon,
    rendered: Option<MenuState>,
    recording: bool,
    idle_icon: Icon,
    recording_icon: Icon,
}

impl Tray {
    pub fn new(state: &MenuState) -> Option<Tray> {
        let idle_icon = make_icon(false)?;
        let recording_icon = make_icon(true)?;
        let icon = TrayIconBuilder::new()
            .with_menu(Box::new(build_menu(state)))
            .with_tooltip(tooltip(state, false, 0.0))
            .with_icon(idle_icon.clone())
            .with_menu_on_left_click(true)
            .build()
            .ok()?;
        Some(Tray {
            icon,
            rendered: Some(state.clone()),
            recording: false,
            idle_icon,
            recording_icon,
        })
    }

    pub fn update(&mut self, state: &MenuState, recording: bool, seconds: f64) {
        if self.rendered.as_ref() != Some(state) {
            self.icon.set_menu(Some(Box::new(build_menu(state))));
            self.rendered = Some(state.clone());
        }
        if self.recording != recording {
            self.recording = recording;
            let icon = if recording {
                self.recording_icon.clone()
            } else {
                self.idle_icon.clone()
            };
            let _ = self.icon.set_icon(Some(icon));
        }
        // The tooltip is the Windows answer to the Mac's counting-up menu bar
        // title: there is nowhere to put text beside a tray icon, so the length
        // of what you are about to send lives here.
        let _ = self.icon.set_tooltip(Some(tooltip(state, recording, seconds)));
    }

    /// Menu clicks that have arrived since the last call.
    pub fn poll(&self) -> Vec<Command> {
        let mut out = Vec::new();
        while let Ok(event) = MenuEvent::receiver().try_recv() {
            if let Some(c) = command_for(event.id.as_ref()) {
                out.push(c);
            }
        }
        out
    }
}

fn command_for(id: &str) -> Option<Command> {
    match id {
        "open" => Some(Command::Open),
        "settings" => Some(Command::Settings),
        "models" => Some(Command::Models),
        "vocab" => Some(Command::EditVocabulary),
        "dictionary" => Some(Command::EditDictionary),
        "forget" => Some(Command::ForgetTone),
        "quit" => Some(Command::Quit),
        other => other
            .strip_prefix("tone:")
            .and_then(|n| n.parse::<u32>().ok())
            .map(|raw| Command::PickTone(Tone::from_raw(raw))),
    }
}

fn build_menu(state: &MenuState) -> Menu {
    let menu = Menu::new();
    let separator = PredefinedMenuItem::separator();

    let open = MenuItem::with_id("open", "Open OpenFlow", true, None);
    let words = header(&format!(
        "{} words spoken \u{b7} {} today",
        state.spoken_words, state.today_words
    ));
    let sessions = header(&format!(
        "{} utterances \u{b7} {} min of speech",
        state.utterances, state.minutes_spoken
    ));
    let hint = if state.hotkey_ready {
        header(&format!(
            "Hold {} to talk, release to paste",
            state.chord_label
        ))
    } else {
        MenuItem::with_id("settings", "\u{26a0} The hotkey is not running\u{2026}", true, None)
    };

    let explanation = header(&state.tone_explanation);
    let tones: Vec<CheckMenuItem> = Tone::ALL
        .iter()
        .map(|t| {
            CheckMenuItem::with_id(
                format!("tone:{}", t.raw()),
                t.name(),
                true,
                *t == state.tone,
                None,
            )
        })
        .collect();

    let forget = MenuItem::with_id(
        "forget",
        format!("Forget tone for {}", state.context_label),
        true,
        None,
    );
    let settings = MenuItem::with_id("settings", "Settings\u{2026}", true, None);
    let models = MenuItem::with_id(
        "models",
        format!("Speech model: {}\u{2026}", state.model_name),
        true,
        None,
    );
    let vocab = MenuItem::with_id("vocab", "Edit vocabulary\u{2026}", true, None);
    let dictionary = MenuItem::with_id("dictionary", "Edit dictionary\u{2026}", true, None);
    let quit = MenuItem::with_id("quit", "Quit OpenFlow", true, None);

    let mut items: Vec<&dyn tray_icon::menu::IsMenuItem> =
        vec![&open, &separator, &words, &sessions, &separator, &hint, &separator, &explanation];
    for t in &tones {
        items.push(t);
    }
    if state.tone_is_remembered {
        items.push(&forget);
    }
    items.push(&separator);
    items.push(&settings);
    items.push(&models);
    items.push(&vocab);
    items.push(&dictionary);
    items.push(&separator);
    items.push(&quit);

    let _ = menu.append_items(&items);
    menu
}

/// A disabled item, which is how both platforms render a line of text in a menu.
fn header(text: &str) -> MenuItem {
    MenuItem::new(text, false, None)
}

fn tooltip(state: &MenuState, recording: bool, seconds: f64) -> String {
    if recording {
        format!("OpenFlow \u{2014} listening, {seconds:.1}s")
    } else if state.hotkey_ready {
        format!("OpenFlow \u{2014} hold {} to talk", state.chord_label)
    } else {
        "OpenFlow \u{2014} the hotkey is not running".into()
    }
}

/// A microphone, drawn rather than shipped as a resource file.
///
/// Two 32x32 icons is not worth an image decoder, a build step and a pair of
/// binary blobs in the repository; the shape is a capsule and two strokes.
fn make_icon(recording: bool) -> Option<Icon> {
    const SIZE: i32 = 32;
    let s = SIZE as f32;
    let (r, g, b) = if recording {
        (232, 62, 52) // the same red the Mac tints its icon while listening
    } else {
        (240, 240, 240) // light, because the notification area is dark by default
    };

    // The OpenFlow mark: a ring with a waveform inside it. Proportions are
    // `tools/icon.swift`'s, which is also what the Mac menu bar and the iOS
    // Live Activity draw -- one mark everywhere. Change it in one place and
    // change it in all of them.
    let (cx, cy) = (s / 2.0, s / 2.0);
    let radius = 0.355 * s;
    let stroke = 0.085 * s; // heavier at this size, or the ring greys out
    let bar_w = 0.055 * s;
    let pitch = bar_w + 0.038 * s;
    let halves = [0.085, 0.150, 0.215, 0.150, 0.085];
    let start_x = cx - pitch * 2.0;

    // Drawn from signed distances rather than filled spans, so the edges are
    // antialiased. At 32 pixels a hard-edged ring this thin looks broken.
    let mut rgba = vec![0u8; (SIZE * SIZE * 4) as usize];
    for py in 0..SIZE {
        for px in 0..SIZE {
            let x = px as f32 + 0.5;
            let y = py as f32 + 0.5;

            let (dx, dy) = (x - cx, y - cy);
            let mut d = ((dx * dx + dy * dy).sqrt() - radius).abs() - stroke / 2.0;

            for (i, half) in halves.iter().enumerate() {
                let bx = start_x + pitch * i as f32;
                // A vertical capsule: distance to the segment, less its radius.
                let reach = (half * s - bar_w / 2.0).max(0.0);
                let qy = ((y - cy).abs() - reach).max(0.0);
                let qx = x - bx;
                d = d.min((qx * qx + qy * qy).sqrt() - bar_w / 2.0);
            }

            // One pixel of coverage either side of the edge.
            let alpha = (0.5 - d).clamp(0.0, 1.0);
            let i = ((py * SIZE + px) * 4) as usize;
            rgba[i] = r;
            rgba[i + 1] = g;
            rgba[i + 2] = b;
            rgba[i + 3] = (alpha * 255.0).round() as u8;
        }
    }

    Icon::from_rgba(rgba, SIZE as u32, SIZE as u32).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> MenuState {
        MenuState {
            spoken_words: 120,
            today_words: 12,
            utterances: 4,
            minutes_spoken: 2,
            chord_label: "Ctrl+Shift".into(),
            hotkey_ready: true,
            tone: Tone::Formal,
            tone_explanation: "Default".into(),
            tone_is_remembered: false,
            context_label: "chrome.exe".into(),
            model_name: "Small (English)".into(),
        }
    }

    #[test]
    fn menu_ids_map_back_to_commands() {
        assert_eq!(command_for("open"), Some(Command::Open));
        assert_eq!(command_for("quit"), Some(Command::Quit));
        assert_eq!(command_for("tone:1"), Some(Command::PickTone(Tone::Casual)));
        assert_eq!(
            command_for("tone:2"),
            Some(Command::PickTone(Tone::VeryCasual))
        );
        assert_eq!(command_for("nonsense"), None);
        assert_eq!(command_for("tone:notanumber"), None);
    }

    /// A tone id that no longer exists must not select something arbitrary --
    /// it falls back the same way the stored setting does.
    #[test]
    fn an_unknown_tone_id_falls_back_to_formal() {
        assert_eq!(command_for("tone:99"), Some(Command::PickTone(Tone::Formal)));
    }

    #[test]
    fn the_tooltip_says_what_is_happening() {
        let s = state();
        assert!(tooltip(&s, false, 0.0).contains("hold Ctrl+Shift"));
        assert!(tooltip(&s, true, 1.25).contains("1.2s"));

        let mut broken = state();
        broken.hotkey_ready = false;
        assert!(tooltip(&broken, false, 0.0).contains("not running"));
    }

    #[test]
    fn both_icons_are_drawable() {
        assert!(make_icon(false).is_some());
        assert!(make_icon(true).is_some());
    }
}
