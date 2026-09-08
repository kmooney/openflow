//! Register for the finished text. A per-utterance choice, not a setting --
//! you dictate a work email and a text to your partner minutes apart.

use serde::{Deserialize, Serialize};

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Tone {
    Formal,
    Casual,
    VeryCasual,
}

impl Default for Tone {
    fn default() -> Self {
        Tone::Formal
    }
}

impl Tone {
    pub const ALL: [Tone; 3] = [Tone::Formal, Tone::Casual, Tone::VeryCasual];

    pub fn name(self) -> &'static str {
        match self {
            Tone::Formal => "Formal",
            Tone::Casual => "Casual",
            Tone::VeryCasual => "Very casual",
        }
    }

    /// The wire value the Rust core uses. Kept identical to the Swift clients'
    /// `Tone.rawValue` so a history row means the same thing on every platform.
    pub fn raw(self) -> u32 {
        match self {
            Tone::Formal => 0,
            Tone::Casual => 1,
            Tone::VeryCasual => 2,
        }
    }

    pub fn from_raw(v: u32) -> Tone {
        match v {
            1 => Tone::Casual,
            2 => Tone::VeryCasual,
            _ => Tone::Formal,
        }
    }

    pub fn core(self) -> openflow_core::Tone {
        match self {
            Tone::Formal => openflow_core::Tone::Formal,
            Tone::Casual => openflow_core::Tone::Casual,
            Tone::VeryCasual => openflow_core::Tone::VeryCasual,
        }
    }
}
