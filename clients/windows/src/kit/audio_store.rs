//! Optional on-disk audio, for working out *why* a transcript came back wrong.
//!
//! Off by default and deliberately so: audio is the most sensitive thing this
//! app touches, and the standing rule is transcribe-and-discard. This exists
//! because "it misheard me" is otherwise unfalsifiable.

use std::path::{Path, PathBuf};

pub fn directory(support: &Path) -> PathBuf {
    support.join("audio")
}

/// 16 kHz mono, 16-bit -- a plain WAV any player on the machine can open,
/// including the one the history list uses.
pub fn write(samples: &[f32], id: &str, support: &Path) -> std::io::Result<PathBuf> {
    let dir = directory(support);
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{id}.wav"));

    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: 16_000,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(&path, spec)
        .map_err(|e| std::io::Error::other(e.to_string()))?;
    for s in samples {
        let v = (s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
        writer
            .write_sample(v)
            .map_err(|e| std::io::Error::other(e.to_string()))?;
    }
    writer
        .finalize()
        .map_err(|e| std::io::Error::other(e.to_string()))?;
    Ok(path)
}

/// Remove a clip. Called on every delete: a hard delete must take the audio
/// with it, or "delete means delete" is a lie.
pub fn remove(path: Option<&str>) {
    if let Some(p) = path.filter(|p| !p.is_empty()) {
        let _ = std::fs::remove_file(p);
    }
}

pub fn total_bytes(support: &Path) -> i64 {
    let Ok(items) = std::fs::read_dir(directory(support)) else {
        return 0;
    };
    items
        .flatten()
        .filter_map(|e| e.metadata().ok())
        .filter(|m| m.is_file())
        .map(|m| m.len() as i64)
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clip_is_written_read_back_and_hard_deleted() {
        let dir = std::env::temp_dir().join(format!("of-audio-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let samples: Vec<f32> = (0..16_000)
            .map(|i| (i as f32 * 0.01).sin() * 0.5)
            .collect();
        let path = write(&samples, "clip", &dir).unwrap();
        assert!(path.exists());
        assert!(total_bytes(&dir) > 30_000, "16k mono 16-bit for a second");

        let mut reader = hound::WavReader::open(&path).unwrap();
        assert_eq!(reader.spec().sample_rate, 16_000);
        assert_eq!(reader.spec().channels, 1);
        assert_eq!(reader.samples::<i16>().count(), samples.len());

        remove(Some(path.to_str().unwrap()));
        assert!(!path.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn removing_nothing_is_not_an_error() {
        remove(None);
        remove(Some(""));
        remove(Some("C:/nope/does-not-exist.wav"));
    }
}
