//! The held-modifier combination that opens the microphone, and the state
//! machine that decides press/release from raw modifier bits.
//!
//! Modifiers only, by design: the hotkey watches modifier transitions rather
//! than key codes, so the chord cannot collide with a shortcut the focused app
//! already owns and nothing is typed while you hold it.

use serde::{Deserialize, Serialize};

pub const SHIFT: u32 = 1 << 0;
pub const CONTROL: u32 = 1 << 1;
pub const ALT: u32 = 1 << 2;
pub const WIN: u32 = 1 << 3;

/// Caps Lock is deliberately absent: it latches, so "held" has no meaning.
pub const ALLOWED_MASK: u32 = SHIFT | CONTROL | ALT | WIN;

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ModifierChord {
    mask: u32,
}

impl Default for ModifierChord {
    /// Control-Shift.
    ///
    /// It is the only two-modifier combination on Windows that does *nothing*
    /// on its own. Alt alone activates the focused window's menu bar and Win
    /// alone opens Start, so a chord containing either fires a system response
    /// every time you let go -- see [`ModifierChord::is_collision_prone`].
    fn default() -> Self {
        ModifierChord::new(CONTROL | SHIFT)
    }
}

impl ModifierChord {
    pub fn new(mask: u32) -> Self {
        ModifierChord {
            mask: mask & ALLOWED_MASK,
        }
    }

    pub fn mask(self) -> u32 {
        self.mask
    }

    pub fn count(self) -> u32 {
        self.mask.count_ones()
    }

    /// A single modifier fires the moment you reach for any ordinary shortcut,
    /// so one is never enough. Two is the floor the UI enforces.
    pub fn is_usable(self) -> bool {
        self.count() >= 2
    }

    /// Alt and Win are *self-acting*: pressing and releasing either one alone
    /// is itself a command to Windows (menu bar, Start menu). A chord built
    /// from them works for dictation, but every utterance also pops something
    /// up, so the UI warns.
    ///
    /// Shift and Control are not on this list even though they prefix plenty of
    /// shortcuts, because a keystroke arriving while the chord is held cancels
    /// the recording (see [`ChordTracker::interrupt`]) -- so Ctrl+Shift+T is a
    /// reopened tab and nothing else.
    pub fn is_collision_prone(self) -> bool {
        self.mask & (ALT | WIN) != 0
    }

    /// "Ctrl+Shift". Windows order: Ctrl, Alt, Shift, Win.
    pub fn label(self) -> String {
        Self::ORDERED
            .iter()
            .filter(|(bit, _)| self.mask & bit != 0)
            .map(|(_, name)| *name)
            .collect::<Vec<_>>()
            .join("+")
    }

    const ORDERED: [(u32, &'static str); 4] = [
        (CONTROL, "Ctrl"),
        (ALT, "Alt"),
        (SHIFT, "Shift"),
        (WIN, "Win"),
    ];
}

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Transition {
    None,
    Pressed,
    Released,
    /// The chord was held but an ordinary key arrived, so this was a keyboard
    /// shortcut and not an utterance. Whatever was captured is discarded.
    Cancelled,
}

/// Decides press/release for a held modifier chord from raw flag bitmasks.
///
/// Deliberately *state-reconciling* rather than event-counting: every caller
/// passes the current modifier state and gets back what changed. A dropped
/// event therefore corrects itself on the next update instead of inverting the
/// hotkey for the rest of the session -- the bug that made the macOS client's
/// push-to-talk behave like a toggle.
#[derive(Debug)]
pub struct ChordTracker {
    mask: u32,
    engaged: bool,
    /// Set by `interrupt`, cleared only when the chord is no longer held.
    /// Without it, holding Ctrl+Shift and pressing T would cancel and then
    /// immediately re-arm, because the chord is still down.
    blocked: bool,
}

impl ChordTracker {
    pub fn new(mask: u32) -> Self {
        ChordTracker {
            mask,
            engaged: false,
            blocked: false,
        }
    }

    pub fn mask(&self) -> u32 {
        self.mask
    }

    pub fn update(&mut self, flags: u32) -> Transition {
        let held = (flags & self.mask) == self.mask;
        if !held {
            self.blocked = false;
        }
        if held && !self.engaged {
            if self.blocked {
                return Transition::None;
            }
            self.engaged = true;
            return Transition::Pressed;
        }
        if !held && self.engaged {
            self.engaged = false;
            return Transition::Released;
        }
        Transition::None
    }

    /// An ordinary key was pressed while the chord was down. That is a
    /// shortcut, not speech.
    pub fn interrupt(&mut self) -> Transition {
        if !self.engaged {
            return Transition::None;
        }
        self.engaged = false;
        self.blocked = true;
        Transition::Cancelled
    }
}

/// Choosing a chord by holding it, rather than picking from a list.
///
/// Committing on *release* is the whole subtlety: pressing Ctrl and then Shift
/// passes through "Ctrl alone", so committing the instant a key goes down would
/// store a one-modifier chord that fires on every ordinary shortcut. This keeps
/// the widest combination seen during the hold and commits that when everything
/// is up again.
#[derive(Debug, Default)]
pub struct ChordRecorder {
    held: u32,
    widest: u32,
}

impl ChordRecorder {
    /// Feed the current modifier state. Returns the chosen chord once every key
    /// has been released.
    pub fn update(&mut self, flags: u32) -> Option<ModifierChord> {
        let flags = flags & ALLOWED_MASK;
        self.held = flags;
        if flags.count_ones() > self.widest.count_ones() {
            self.widest = flags;
        }
        if flags != 0 {
            return None;
        }
        let chosen = ModifierChord::new(std::mem::take(&mut self.widest));
        // One modifier is not a chord; keep listening rather than storing
        // something that would fire constantly.
        chosen.is_usable().then_some(chosen)
    }

    /// What is held right now, for the "hold a chord..." prompt.
    pub fn held(&self) -> ModifierChord {
        ModifierChord::new(self.held)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chord() -> u32 {
        CONTROL | SHIFT
    }

    #[test]
    fn the_default_is_control_shift() {
        let d = ModifierChord::default();
        assert_eq!(d.label(), "Ctrl+Shift");
        assert!(d.is_usable());
        assert!(!d.is_collision_prone());
    }

    #[test]
    fn one_modifier_is_not_a_chord() {
        assert!(!ModifierChord::new(CONTROL).is_usable());
        assert!(!ModifierChord::new(0).is_usable());
        assert!(ModifierChord::new(CONTROL | SHIFT).is_usable());
    }

    #[test]
    fn alt_and_win_are_flagged_as_self_acting() {
        assert!(ModifierChord::new(CONTROL | ALT).is_collision_prone());
        assert!(ModifierChord::new(WIN | SHIFT).is_collision_prone());
        assert!(!ModifierChord::new(CONTROL | SHIFT).is_collision_prone());
    }

    #[test]
    fn labels_use_windows_order_whatever_order_the_bits_arrive() {
        let all = ModifierChord::new(WIN | SHIFT | ALT | CONTROL);
        assert_eq!(all.label(), "Ctrl+Alt+Shift+Win");
    }

    #[test]
    fn stray_bits_are_discarded_on_the_way_in() {
        let caps_lock = 1 << 20;
        let c = ModifierChord::new(CONTROL | SHIFT | caps_lock | (1 << 30));
        assert_eq!(c, ModifierChord::default());
        assert_eq!(c.count(), 2);
    }

    #[test]
    fn it_survives_being_stored_and_read_back() {
        let c = ModifierChord::new(CONTROL | ALT);
        let json = serde_json::to_string(&c).unwrap();
        assert_eq!(serde_json::from_str::<ModifierChord>(&json).unwrap(), c);
    }

    #[test]
    fn hold_and_release() {
        let mut t = ChordTracker::new(chord());
        assert_eq!(t.update(CONTROL), Transition::None, "half the chord is not the chord");
        assert_eq!(t.update(chord()), Transition::Pressed);
        assert_eq!(t.update(chord()), Transition::None, "still held is not a new press");
        assert_eq!(t.update(CONTROL), Transition::Released, "letting go of either key releases");
        assert_eq!(t.update(0), Transition::None);
    }

    /// The bug that made it behave like a toggle: a release event goes missing,
    /// so the next press is swallowed and every press after that is inverted.
    #[test]
    fn a_recovered_missed_release_does_not_invert_the_hotkey() {
        let mut t = ChordTracker::new(chord());
        assert_eq!(t.update(chord()), Transition::Pressed);
        assert_eq!(t.update(0), Transition::Released);
        assert_eq!(t.update(chord()), Transition::Pressed, "the next hold must still work");
        assert_eq!(t.update(0), Transition::Released);
    }

    #[test]
    fn extra_modifiers_do_not_break_the_chord() {
        let mut t = ChordTracker::new(chord());
        assert_eq!(t.update(chord() | ALT), Transition::Pressed);
        assert_eq!(t.update(chord()), Transition::None);
    }

    #[test]
    fn a_keystroke_cancels_and_does_not_re_arm_until_the_chord_is_released() {
        let mut t = ChordTracker::new(chord());
        assert_eq!(t.update(chord()), Transition::Pressed);
        assert_eq!(t.interrupt(), Transition::Cancelled, "Ctrl+Shift+T is a shortcut");
        // Still physically held: this must NOT start a new recording.
        assert_eq!(t.update(chord()), Transition::None);
        assert_eq!(t.update(chord()), Transition::None);
        // Let go, hold again: back to normal.
        assert_eq!(t.update(0), Transition::None, "there was nothing to release");
        assert_eq!(t.update(chord()), Transition::Pressed);
    }

    #[test]
    fn an_interrupt_while_idle_is_nothing() {
        let mut t = ChordTracker::new(chord());
        assert_eq!(t.interrupt(), Transition::None);
        assert_eq!(t.update(chord()), Transition::Pressed);
    }

    /// Pressing Ctrl then Shift passes through "Ctrl alone". Committing on the
    /// way down would store that, and a one-modifier chord fires the moment you
    /// reach for any shortcut.
    #[test]
    fn the_recorder_commits_the_widest_combination_on_release() {
        let mut r = ChordRecorder::default();
        assert_eq!(r.update(CONTROL), None, "not yet -- they are still reaching");
        assert_eq!(r.update(CONTROL | SHIFT), None);
        assert_eq!(r.update(CONTROL), None, "letting go one at a time");
        assert_eq!(
            r.update(0),
            Some(ModifierChord::new(CONTROL | SHIFT)),
            "the whole chord, not what happened to be down last"
        );
    }

    #[test]
    fn the_recorder_refuses_a_single_modifier_and_keeps_listening() {
        let mut r = ChordRecorder::default();
        assert_eq!(r.update(SHIFT), None);
        assert_eq!(r.update(0), None, "one modifier is not a chord");
        // Still armed for a real one.
        assert_eq!(r.update(CONTROL | ALT), None);
        assert_eq!(r.update(0), Some(ModifierChord::new(CONTROL | ALT)));
    }

    #[test]
    fn the_recorder_reports_what_is_held_for_the_prompt() {
        let mut r = ChordRecorder::default();
        r.update(CONTROL | SHIFT);
        assert_eq!(r.held().label(), "Ctrl+Shift");
    }

    #[test]
    fn never_toggles() {
        // Whatever sequence arrives, pressed and released must alternate.
        let mut t = ChordTracker::new(chord());
        let mut last = Transition::Released;
        for flags in [chord(), chord(), 0, 0, chord(), CONTROL, chord(), 0, chord(), 0] {
            let r = t.update(flags);
            if r != Transition::None {
                assert_ne!(r, last, "two {:?} in a row -- that is a toggle, not push-to-talk", r);
                last = r;
            }
        }
    }
}
