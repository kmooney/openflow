//! M0 spike: the tier-1 deterministic formatter, `normalize()`, and the
//! round-trip guardrail. Throwaway code whose findings feed `openflow-core`.

// ---------------------------------------------------------------- config

#[derive(Clone, Debug)]
pub struct Config {
    /// Single-token disfluencies. Conservative by default: every word here is
    /// one that is almost never meaningful. `ah` and `like` are deliberately
    /// absent (see NOTES.md).
    pub fillers: Vec<&'static str>,
    /// Riskier multi-word fillers, off by default.
    pub phrase_fillers: Vec<&'static str>,
    /// Spoken commands that produce structure.
    pub structure_commands: bool,
    /// Spoken commands that produce punctuation ("period", "comma"). Off by
    /// default: Whisper already punctuates, so these mostly fire on people
    /// saying the literal word.
    pub punctuation_commands: bool,
    pub collapse_stutters: bool,
    /// Spoken quote markers become real quotation marks.
    pub quote_commands: bool,
    /// Spoken enumerations become numbered lists.
    pub lists: bool,
    /// Spoken corrections ("scratch that", "no no no") erase what preceded.
    pub corrections: bool,
    /// Rebuild web and email addresses that were transcribed as words.
    pub addresses: bool,
    /// How many consecutive enumerators before it counts as a list. Three is
    /// conservative: two ("One, X. Two, Y.") is a real construction but a much
    /// weaker signal, and a false positive mangles ordinary prose.
    pub min_list_items: usize,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            fillers: vec![
                "uh", "um", "uhm", "erm", "er", "mm", "mmm", "hmm", "uhh", "umm",
            ],
            phrase_fillers: vec![],
            structure_commands: true,
            punctuation_commands: false,
            collapse_stutters: true,
            quote_commands: true,
            lists: true,
            corrections: true,
            addresses: true,
            min_list_items: 3,
        }
    }
}

impl Config {
    /// Everything on, including the risky sets. Used to measure how much the
    /// aggressive options actually buy.
    pub fn aggressive() -> Self {
        let mut c = Config::default();
        c.phrase_fillers = vec!["you know", "i mean", "sort of", "kind of"];
        c.punctuation_commands = true;
        c
    }
}

/// Phrases the structure commands consume. The guardrail must know about these
/// (see `normalize`) because substituting them *deletes words on purpose*.
pub const STRUCTURE_PHRASES: &[(&str, &str)] = &[
    ("new paragraph", "\n\n"),
    ("new line", "\n"),
    ("bullet point", "\n- "),
    ("next bullet", "\n- "),
];

pub const PUNCT_PHRASES: &[(&str, &str)] = &[
    ("question mark", "?"),
    ("exclamation point", "!"),
    ("semicolon", ";"),
    ("period", "."),
    ("comma", ","),
    ("colon", ":"),
];

/// Immediate doubles that are legitimate English and must not be collapsed.
const LEGIT_DOUBLES: &[&str] = &["had", "that", "is", "no", "very", "really"];

// ------------------------------------------------------------- the rules

pub fn format(raw: &str, cfg: &Config) -> String {
    let mut s = raw.to_string();

    // First, before anything can rewrite the words it keys on. The
    // punctuation-command table would turn a spoken "dot" into "." and destroy
    // the pattern this pass exists to recognise.
    if cfg.addresses {
        s = apply_addresses(&s);
    }

    if cfg.quote_commands {
        s = apply_quotes(&s);
    }
    if cfg.structure_commands {
        s = replace_phrases(&s, STRUCTURE_PHRASES);
    }
    if cfg.punctuation_commands {
        s = replace_phrases(&s, PUNCT_PHRASES);
    }
    for p in &cfg.phrase_fillers {
        s = remove_phrase(&s, p);
    }

    s = strip_fillers(&s, &cfg.fillers);
    if cfg.collapse_stutters {
        s = collapse_stutters(&s);
    }
    if cfg.lists {
        let before = s.clone();
        s = apply_lists(&s, cfg.min_list_items);
        if s == before {
            s = apply_unordered_lists(&s, cfg.min_list_items);
        }
    }
    tidy(&s)
}

/// Case-insensitive phrase → replacement, on word boundaries.
fn replace_phrases(s: &str, table: &[(&str, &str)]) -> String {
    let mut out = s.to_string();
    for (phrase, rep) in table {
        loop {
            match find_phrase(&out, phrase) {
                Some((a, b)) => out = format!("{}{}{}", &out[..a], rep, &out[b..]),
                None => break,
            }
        }
    }
    out
}

fn remove_phrase(s: &str, phrase: &str) -> String {
    let mut out = s.to_string();
    while let Some((a, b)) = find_phrase(&out, phrase) {
        out = format!("{} {}", &out[..a], &out[b..]);
    }
    out
}

/// Locate `phrase` in `hay` case-insensitively, respecting word boundaries.
fn find_phrase(hay: &str, phrase: &str) -> Option<(usize, usize)> {
    let h = hay.to_lowercase();
    let mut from = 0usize;
    while let Some(rel) = h[from..].find(phrase) {
        let a = from + rel;
        let b = a + phrase.len();
        let left_ok = a == 0 || !h.as_bytes()[a - 1].is_ascii_alphanumeric();
        let right_ok = b >= h.len() || !h.as_bytes()[b].is_ascii_alphanumeric();
        if left_ok && right_ok {
            return Some((a, b));
        }
        from = a + 1;
        if from >= h.len() {
            break;
        }
    }
    None
}

fn strip_fillers(s: &str, fillers: &[&str]) -> String {
    let mut out = String::with_capacity(s.len());
    for line in s.split_inclusive('\n') {
        for tok in line.split_inclusive(|c: char| c == ' ') {
            let core = tok.trim();
            let bare: String = core
                .chars()
                .filter(|c| c.is_alphanumeric() || *c == '\'')
                .collect::<String>()
                .to_lowercase();
            // Only drop a filler token when it carries no sentence-ending
            // punctuation we would lose with it.
            let is_filler = fillers.contains(&bare.as_str());
            if is_filler {
                if core.ends_with(['.', '?', '!']) {
                    out.push_str(". ");
                }
                continue;
            }
            out.push_str(tok);
        }
    }
    out
}

fn collapse_stutters(s: &str) -> String {
    // Per line: `split_whitespace` would otherwise eat the newlines that the
    // structure commands just inserted.
    s.split('\n')
        .map(collapse_stutters_line)
        .collect::<Vec<_>>()
        .join("\n")
}

fn collapse_stutters_line(s: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    for tok in s.split_whitespace() {
        let bare: String = tok
            .chars()
            .filter(|c| c.is_alphanumeric())
            .collect::<String>()
            .to_lowercase();
        if let Some(prev) = out.last() {
            let prev_bare: String = prev
                .chars()
                .filter(|c| c.is_alphanumeric())
                .collect::<String>()
                .to_lowercase();
            if !bare.is_empty()
                && bare == prev_bare
                && !LEGIT_DOUBLES.contains(&bare.as_str())
                && !prev.ends_with(['.', ',', '?', '!', ';', ':'])
            {
                // keep whichever token carries punctuation
                if tok.len() > prev.len() {
                    out.pop();
                    out.push(tok.to_string());
                }
                continue;
            }
        }
        out.push(tok.to_string());
    }
    out.join(" ")
}

/// Whitespace, stray punctuation, and sentence capitalization.
fn tidy(s: &str) -> String {
    let mut t = s.to_string();
    // space before punctuation
    for p in [".", ",", "?", "!", ";", ":"] {
        t = t.replace(&format!(" {}", p), p);
    }
    // duplicated terminals left behind by filler removal
    while t.contains(". .") {
        t = t.replace(". .", ".");
    }
    while t.contains("..") && !t.contains("...") {
        t = t.replace("..", ".");
    }
    while t.contains(",,") {
        t = t.replace(",,", ",");
    }
    // collapse runs of spaces without touching newlines
    let mut lines: Vec<String> = Vec::new();
    for line in t.split('\n') {
        lines.push(line.split_whitespace().collect::<Vec<_>>().join(" "));
    }
    t = lines.join("\n");
    while t.contains("\n\n\n") {
        t = t.replace("\n\n\n", "\n\n");
    }
    t = t.trim().to_string();
    // A command phrase sitting between two sentences ("...node. New paragraph.
    // Let's...") leaves its trailing punctuation stranded at the start of the
    // new line. Strip leading punctuation per line, not just once globally.
    t = t
        .split('\n')
        .map(|line| {
            let mut l = line.trim_start();
            while let Some(r) = l.strip_prefix(['.', ',', ';', ':', '!', '?']) {
                l = r.trim_start();
            }
            l.to_string()
        })
        .collect::<Vec<_>>()
        .join("\n");
    capitalize_sentences(&t)
}

fn capitalize_sentences(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut at_start = true;
    // A full stop only ends a sentence if a space follows it. Without that
    // test, the dot in a rebuilt address is a sentence boundary and
    // `https://kevin-mooney.com` comes back as `https://kevin-mooney.Com`.
    let mut pending = false;
    for ch in s.chars() {
        // List markers sit between the line start and the first word; they must
        // not consume the sentence-start state. (The ordered case only worked
        // by accident: its "." happened to re-trigger it.)
        if at_start && matches!(ch, '-' | '*' | '.' | ')' | '0'..='9') {
            out.push(ch);
            continue;
        }
        if at_start && ch.is_alphabetic() {
            out.extend(ch.to_uppercase());
            at_start = false;
            pending = false;
        } else {
            out.push(ch);
            if ch == '\n' {
                at_start = true;
                pending = false;
            } else if matches!(ch, '.' | '?' | '!') {
                pending = true;
            } else if ch.is_whitespace() {
                at_start = pending || at_start;
                pending = false;
            } else {
                at_start = false;
                pending = false;
            }
        }
    }
    out
}

// ------------------------------------------------------------- normalize

/// Canonical form for the guardrail. Everything this erases is a hole in the
/// guardrail — see NOTES.md.
pub fn normalize(s: &str, cfg: &Config) -> Vec<String> {
    let mut t = s.to_lowercase();

    // Command phrases delete words *on purpose*, so they must be erased from
    // both sides or the rules formatter can never pass its own guardrail.
    if cfg.structure_commands {
        for (p, _) in STRUCTURE_PHRASES {
            t = remove_phrase(&t, p);
        }
    }
    if cfg.punctuation_commands {
        for (p, _) in PUNCT_PHRASES {
            t = remove_phrase(&t, p);
        }
    }
    if cfg.quote_commands {
        // Quoting deletes the marker words on purpose, so they must vanish
        // from both sides -- same enumerable hole as the structure commands.
        for p in [
            "quote unquote",
            "open quote",
            "close quote",
            "end quote",
            "quote",
            "unquote",
        ] {
            t = remove_phrase(&t, p);
        }
    }
    for p in &cfg.phrase_fillers {
        t = remove_phrase(&t, p);
    }

    // strip list markers at line starts
    let mut lines: Vec<String> = Vec::new();
    for line in t.split('\n') {
        let l = line.trim_start();
        let l = l
            .strip_prefix("- ")
            .or_else(|| l.strip_prefix("* "))
            .unwrap_or(l);
        let l = keep_leading_number(l);
        lines.push(l);
    }
    t = lines.join(" ");

    // punctuation and apostrophes out; canonicalize symbols to words first
    t = t.replace('%', " percent ").replace('$', " dollars ");
    let cleaned: String = t
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect();

    let mut toks: Vec<String> = Vec::new();
    for w in cleaned.split_whitespace() {
        if cfg.fillers.contains(&w) {
            continue;
        }
        toks.push(w.to_string());
    }

    let toks = canonicalize_numbers(&toks);

    // collapse immediate repeats on both sides
    let mut out: Vec<String> = Vec::new();
    for w in toks {
        if out.last().map(|p| p == &w).unwrap_or(false) {
            continue;
        }
        out.push(w);
    }
    out
}

/// `1. do this` -> `1 do this`. The marker's number is kept as a token so it
/// can match the ordinal word ("first") that a formatter replaced with it.
fn keep_leading_number(l: &str) -> String {
    let b = l.as_bytes();
    let mut i = 0;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    if i > 0 && i < b.len() && (b[i] == b'.' || b[i] == b')') {
        return format!("{} {}", &l[..i], l[i + 1..].trim_start());
    }
    l.to_string()
}

const ORDINALS: &[(&str, u64)] = &[
    ("first", 1),
    ("second", 2),
    ("third", 3),
    ("fourth", 4),
    ("fifth", 5),
    ("sixth", 6),
    ("seventh", 7),
    ("eighth", 8),
    ("ninth", 9),
    ("tenth", 10),
];

const UNITS: &[(&str, u64)] = &[
    ("zero", 0),
    ("one", 1),
    ("two", 2),
    ("three", 3),
    ("four", 4),
    ("five", 5),
    ("six", 6),
    ("seven", 7),
    ("eight", 8),
    ("nine", 9),
    ("ten", 10),
    ("eleven", 11),
    ("twelve", 12),
    ("thirteen", 13),
    ("fourteen", 14),
    ("fifteen", 15),
    ("sixteen", 16),
    ("seventeen", 17),
    ("eighteen", 18),
    ("nineteen", 19),
];
const TENS: &[(&str, u64)] = &[
    ("twenty", 20),
    ("thirty", 30),
    ("forty", 40),
    ("fifty", 50),
    ("sixty", 60),
    ("seventy", 70),
    ("eighty", 80),
    ("ninety", 90),
];

fn word_val(w: &str) -> Option<u64> {
    UNITS
        .iter()
        .chain(TENS.iter())
        .find(|(k, _)| *k == w)
        .map(|(_, v)| *v)
}

fn ordinal_val(w: &str) -> Option<u64> {
    ORDINALS.iter().find(|(k, _)| *k == w).map(|(_, v)| *v)
}

/// `twenty five` ≡ `25`, `one hundred` ≡ `100`. Deliberately small: a bigger
/// parser means a bigger hole in the guardrail.
fn canonicalize_numbers(toks: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut i = 0;
    while i < toks.len() {
        let w = toks[i].as_str();
        if let Some(v) = ordinal_val(w) {
            out.push(v.to_string());
            i += 1;
            continue;
        }
        if let Some(v) = word_val(w) {
            let mut val = v;
            let mut j = i + 1;
            // tens + units
            if TENS.iter().any(|(k, _)| *k == w) && j < toks.len() {
                if let Some(u) = word_val(&toks[j]) {
                    if u < 10 {
                        val += u;
                        j += 1;
                    }
                }
            }
            // N hundred [and] M
            if j < toks.len() && toks[j] == "hundred" {
                val *= 100;
                j += 1;
                if j < toks.len() && toks[j] == "and" {
                    j += 1;
                }
                if j < toks.len() {
                    if let Some(u) = word_val(&toks[j]) {
                        let mut extra = u;
                        let mut k = j + 1;
                        if TENS.iter().any(|(kk, _)| *kk == toks[j]) && k < toks.len() {
                            if let Some(u2) = word_val(&toks[k]) {
                                if u2 < 10 {
                                    extra += u2;
                                    k += 1;
                                }
                            }
                        }
                        val += extra;
                        j = k;
                    }
                }
            }
            out.push(val.to_string());
            i = j;
            continue;
        }
        out.push(w.to_string());
        i += 1;
    }
    out
}

// ------------------------------------------------------------- addresses
//
// Whisper hears an address as the words someone said, which is a faithful
// transcription and a useless one: "h-t-t-p-s colon slash slash kevin dash
// mooney dot com" is exactly right about the sounds and exactly wrong about
// the text.
//
// This is mechanical work and belongs in rules rather than in a model. The
// mapping is fixed -- "dash" is always "-" -- so a rule reconstructs the
// address every time, while a model would occasionally produce
// `kevinmooney.com`: plausible, wrong, and unlike the phonetic version you
// will not notice before pasting it. A wrong address is worse than an
// obviously broken one.

/// Words that join the parts of an address, and the character each becomes.
fn connector(tok: &str) -> Option<&'static str> {
    match tok {
        "dot" => Some("."),
        "dash" | "hyphen" => Some("-"),
        "underscore" => Some("_"),
        "slash" => Some("/"),
        "colon" => Some(":"),
        "at" => Some("@"),
        _ => None,
    }
}

/// Endings common enough in speech to be worth anchoring on. Deliberately
/// short: every entry is a chance to mangle ordinary prose, and the cost of
/// omitting one is that an address stays as the user said it.
const TLDS: &[&str] = &[
    "com", "org", "net", "io", "dev", "edu", "gov", "ai", "app", "uk", "co",
];

/// Words that end a sentence more often than they start an address. Without
/// this, "the dot com boom" becomes "the.com".
const NOT_ADDRESS_STARTS: &[&str] = &[
    "the", "a", "an", "this", "that", "these", "those", "my", "your", "our",
    "is", "was", "are", "were", "of", "in", "on", "at", "to", "and", "or",
    "but", "it", "its", "first", "second", "third", "one", "two", "three",
];

/// "h-t-t-p-s" -> "https". Whisper spells out letters it hears named
/// individually and joins them with hyphens, so the hyphens are an artefact of
/// the spelling rather than part of the word.
fn collapse_spelled(tok: &str) -> Option<String> {
    let parts: Vec<&str> = tok.split('-').collect();
    if parts.len() >= 3
        && parts
            .iter()
            .all(|p| p.chars().count() == 1 && p.chars().all(|c| c.is_ascii_alphanumeric()))
    {
        Some(parts.concat())
    } else {
        None
    }
}

/// A single spelled-out character. Whisper writes a named letter as its own
/// token -- "k e v i n", not "k-e-v-i-n" -- so a run of these is one word that
/// has been taken apart, and rejoining them is most of this pass's job.
///
/// It is also why the address must be rebuilt before anything else runs: the
/// stutter collapse reads "m o o n e y" as a repetition and returns "m o n e
/// y", and reads the "slash slash" of a scheme as one slash.
fn single_letter(tok: &str) -> bool {
    tok.chars().count() == 1 && tok.chars().all(|c| c.is_ascii_alphanumeric())
}

/// A token whisper already wrote as a domain: "mooney.com". It punctuates
/// some addresses itself and spells others out, and the two arrive in the same
/// sentence, so both have to be recognised.
fn domain_like(tok: &str) -> bool {
    match tok.rsplit_once('.') {
        Some((host, tld)) => {
            !host.is_empty()
                && host
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '.')
                && TLDS.contains(&tld)
        }
        None => false,
    }
}

/// Could this token be part of an address?
fn addressy(tok: &str) -> bool {
    !tok.is_empty()
        && connector(tok).is_none()
        && (tok.chars().all(|c| c.is_ascii_alphanumeric())
            || collapse_spelled(tok).is_some()
            || domain_like(tok))
}

/// Schemes worth anchoring on. A scheme followed by "colon" is the one signal
/// that survives every shape whisper produces -- it does not depend on how the
/// host was spelled, or on whether the ending arrived as a word or already
/// punctuated.
const SCHEMES: &[&str] = &["http", "https", "ftp"];

/// Join one span of address tokens, carrying across whatever punctuation ended
/// the sentence the span sat in.
fn build_address(span: &[String], last: &str) -> String {
    let mut built = String::new();
    for b in span {
        match connector(b) {
            Some(c) => built.push_str(c),
            None => built.push_str(&collapse_spelled(b).unwrap_or_else(|| b.clone())),
        }
    }
    // Exactly what `bare` trimmed off, and nothing else. Skipping characters
    // by kind instead cost the sentence its full stop, because the dot in
    // "mooney.com" looks identical to the one ending "…com."
    let trimmed = last.trim_end_matches(|c: char| matches!(c, ',' | '.' | '!' | '?' | ';' | ':'));
    built.push_str(&last[trimmed.len()..]);
    built
}

/// Rebuild spoken web and email addresses.
pub fn apply_addresses(s: &str) -> String {
    let toks: Vec<&str> = s.split_whitespace().collect();
    if toks.len() < 2 {
        return s.to_string();
    }
    // Lower-cased and stripped of sentence punctuation, for matching only; the
    // original tokens are what gets rebuilt around.
    let bare: Vec<String> = toks
        .iter()
        .map(|t| {
            t.trim_end_matches(|c: char| matches!(c, ',' | '.' | '!' | '?' | ';' | ':'))
                .to_ascii_lowercase()
        })
        .collect();

    let mut out: Vec<String> = Vec::with_capacity(toks.len());
    let mut i = 0;
    while i < toks.len() {
        // A scheme followed by "colon" begins an address whatever comes next,
        // so this walks forward from it rather than backward from the ending.
        if SCHEMES.contains(&bare[i].as_str()) && i + 1 < bare.len() && bare[i + 1] == "colon" {
            let mut end = i;
            let mut j = i + 1;
            while j < bare.len() {
                if connector(&bare[j]).is_some() {
                    end = j;
                    j += 1;
                    continue;
                }
                if !addressy(&bare[j]) {
                    break;
                }
                // A run of single letters is one word taken apart.
                let mut k = j;
                while k + 1 < bare.len() && single_letter(&bare[k]) && single_letter(&bare[k + 1])
                {
                    k += 1;
                }
                end = k;
                j = k + 1;
                // Two plain words in a row end the address: the second belongs
                // to the sentence.
                if j >= bare.len() || connector(&bare[j]).is_none() {
                    break;
                }
            }
            if end > i {
                out.push(build_address(&bare[i..=end], toks[end]));
                i = end + 1;
                continue;
            }
        }

        // Otherwise anchor on "dot" plus a known ending and walk backward.
        let anchored = i > 0 && bare[i - 1] == "dot" && TLDS.contains(&bare[i].as_str());
        if !anchored {
            out.push(toks[i].to_string());
            i += 1;
            continue;
        }

        // Walk left. An address alternates token, connector, token -- so a
        // plain word is only part of it when a connector sits to its left, and
        // "at" takes exactly one token with it because an address has one
        // local part.
        let mut start = i;
        while start > 0 {
            let p = start - 1;
            match connector(&bare[p]) {
                Some("@") => {
                    if p == 0 || !addressy(&bare[p - 1]) {
                        break;
                    }
                    start = p - 1;
                    break;
                }
                Some(_) => start = p,
                None => {
                    if !addressy(&bare[p]) {
                        break;
                    }
                    // The stop-word list guards against "the dot com boom", so
                    // it only applies to whole words. A single letter inside a
                    // spelled-out run is never the English word: "m a i l"
                    // must not stop at its "a".
                    if !single_letter(&bare[p])
                        && NOT_ADDRESS_STARTS.contains(&bare[p].as_str())
                    {
                        break;
                    }
                    // A run of single letters is one word taken apart. Take the
                    // whole run, or the walk stops at the first letter and
                    // rebuilds "y.com" out of "mooney dot com".
                    let mut q = p;
                    while q > 0 && single_letter(&bare[q]) && single_letter(&bare[q - 1]) {
                        q -= 1;
                    }
                    start = q;
                    if q == 0 || connector(&bare[q - 1]).is_none() {
                        break;
                    }
                }
            }
        }

        // Nothing but "dot com" on its own is not an address.
        if start >= i - 1 {
            out.push(toks[i].to_string());
            i += 1;
            continue;
        }

        out.truncate(out.len() - (i - start));
        out.push(build_address(&bare[start..=i], toks[i]));
        i += 1;
    }
    out.join(" ")
}

// ------------------------------------------------------------- guardrail

#[derive(Debug, PartialEq)]
pub enum Verdict {
    Pass,
    /// Words the stage dropped, and words it invented.
    Fail {
        dropped: Vec<String>,
        added: Vec<String>,
    },
}

/// The whole guardrail: exact equality of canonical forms. Runs per stage.
pub fn check(stage_input: &str, stage_output: &str, cfg: &Config) -> Verdict {
    let a = normalize(stage_input, cfg);
    let mut collapsed: Vec<String> = Vec::new();
    for w in a {
        if collapsed.last().map(|p| p == &w).unwrap_or(false) {
            continue;
        }
        collapsed.push(w);
    }
    let a = collapsed;

    let b = normalize(stage_output, cfg);
    if a == b {
        return Verdict::Pass;
    }
    let mut dropped: Vec<String> = Vec::new();
    let mut bb = b.clone();
    for w in &a {
        match bb.iter().position(|x| x == w) {
            Some(p) => {
                bb.remove(p);
            }
            None => dropped.push(w.clone()),
        }
    }
    let mut added: Vec<String> = Vec::new();
    let mut aa = a.clone();
    for w in &b {
        match aa.iter().position(|x| x == w) {
            Some(p) => {
                aa.remove(p);
            }
            None => added.push(w.clone()),
        }
    }
    Verdict::Fail { dropped, added }
}

/// A chain stage: run it, check it, and fall through to the input on failure.
pub fn run_stage<F>(input: &str, cfg: &Config, stage: F) -> (String, Verdict)
where
    F: Fn(&str) -> String,
{
    let out = stage(input);
    match check(input, &out, cfg) {
        Verdict::Pass => (out, Verdict::Pass),
        fail => (input.to_string(), fail),
    }
}

// ------------------------------------------------------------------ tone

/// Register for the finished text. Orthogonal to cleanup: cleanup decides
/// *which words* survive, tone decides how they're dressed. Because tone only
/// touches case, punctuation and line breaks — precisely what `normalize()`
/// erases — a tone transform is word-preserving by construction and cannot
/// trip the guardrail.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Tone {
    /// Sentence case, full stops, commas. Email and work chat.
    Formal,
    /// Capitals kept, sentence-ending periods become line breaks, no trailing
    /// full stop. `?` and `!` survive — they carry tone, not grammar.
    Casual,
    /// Casual, plus all-lowercase and no commas.
    VeryCasual,
}

impl Tone {
    pub fn parse(s: &str) -> Option<Tone> {
        match s.to_lowercase().replace(['-', '_'], "").as_str() {
            "formal" => Some(Tone::Formal),
            "casual" => Some(Tone::Casual),
            "verycasual" | "vcasual" => Some(Tone::VeryCasual),
            _ => None,
        }
    }
    pub fn name(&self) -> &'static str {
        match self {
            Tone::Formal => "formal",
            Tone::Casual => "casual",
            Tone::VeryCasual => "very casual",
        }
    }
}

pub fn apply_tone(s: &str, tone: Tone) -> String {
    if tone == Tone::Formal {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '.' && (i == chars.len() - 1 || chars[i + 1] == '\n') {
            i += 1;
            continue;
        }
        out.push(c);
        i += 1;
    }

    let mut t: String = out
        .split('\n')
        .map(|l| l.split_whitespace().collect::<Vec<_>>().join(" "))
        .collect::<Vec<_>>()
        .join("\n");
    while t.contains("\n\n\n") {
        t = t.replace("\n\n\n", "\n\n");
    }
    t = t.trim().to_string();

    if tone == Tone::VeryCasual {
        t = t.to_lowercase();
    }
    t
}

// ------------------------------------------------------------- signature

/// Sign-off phrases, longest first so "thank you" wins over "thanks".
const SIGNOFFS: &[&str] = &[
    "thanks so much",
    "thank you so much",
    "many thanks",
    "all the best",
    "best regards",
    "kind regards",
    "warm regards",
    "best wishes",
    "yours truly",
    "talk soon",
    "take care",
    "thank you",
    "thanks",
    "sincerely",
    "regards",
    "cheers",
    "warmly",
    "respectfully",
    "best",
    "love",
    "yours",
];

/// Split a trailing sign-off ("...done. Thanks, Kevin") off the end.
/// Returns `(body, Some((signoff, name)))`.
///
/// Requires a name: bare "ok thanks" at the end of a text message is not a
/// signature, and mangling it would be worse than missing one.
pub fn split_signature(s: &str) -> (String, Option<(String, String)>) {
    let toks: Vec<&str> = s.split_whitespace().collect();
    if toks.len() < 2 {
        return (s.to_string(), None);
    }
    let bare = |t: &str| -> String {
        t.chars()
            .filter(|c| c.is_alphanumeric() || *c == '\'')
            .collect()
    };
    let capitalized = |t: &str| -> bool {
        let b = bare(t);
        !b.is_empty() && b.chars().next().map(|c| c.is_uppercase()).unwrap_or(false)
    };

    // name is the last 1-2 tokens, each a capitalized word
    for name_len in [2usize, 1] {
        if toks.len() < name_len + 1 {
            continue;
        }
        let name_start = toks.len() - name_len;
        if !toks[name_start..]
            .iter()
            .all(|t| capitalized(t) && bare(t).chars().all(|c| c.is_alphabetic()))
        {
            continue;
        }
        for phrase in SIGNOFFS {
            let words: Vec<&str> = phrase.split(' ').collect();
            if name_start < words.len() {
                continue;
            }
            let start = name_start - words.len();
            let got: Vec<String> = toks[start..name_start]
                .iter()
                .map(|t| bare(t).to_lowercase())
                .collect();
            if got != words {
                continue;
            }
            // the sign-off must open its own clause: the token before it ends a
            // sentence, or it is the whole message.
            let boundary = start == 0
                || toks[start - 1].ends_with(['.', ',', '!', '?', '\n'])
                || toks[start - 1].contains('\n');
            if !boundary {
                continue;
            }
            let body = toks[..start].join(" ").trim().to_string();
            let name = toks[name_start..]
                .iter()
                .map(|t| bare(t))
                .collect::<Vec<_>>()
                .join(" ");
            let signoff = words
                .iter()
                .map(|w| {
                    let mut c = w.chars();
                    match c.next() {
                        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                        None => String::new(),
                    }
                })
                .collect::<Vec<_>>()
                .join(" ");
            return (body, Some((signoff, name)));
        }
    }
    (s.to_string(), None)
}

/// Tone, with the signature kept legible in every register.
///
/// A sign-off is the one place where "very casual" should not apply: lowercasing
/// someone's own name reads as sloppy rather than relaxed. So the signature is
/// split off, the body is toned, and the signature is rendered the same way in
/// all three registers -- its own block, capitalized name.
pub fn apply_tone_with_signature(s: &str, tone: Tone) -> String {
    let (body, sig) = split_signature(s);
    let toned = apply_tone(&body, tone);
    match sig {
        None => toned,
        Some((signoff, name)) => {
            if toned.is_empty() {
                format!("{},\n{}", signoff, name)
            } else {
                format!("{}\n\n{},\n{}", toned, signoff, name)
            }
        }
    }
}

// ---------------------------------------------------------------- quoting

/// Words that end a noun phrase. Used to guess the span of a spoken
/// "quote-unquote" when only the opening marker was said.
const NP_STOP: &[&str] = &[
    "is",
    "are",
    "was",
    "were",
    "be",
    "been",
    "being",
    "am",
    "said",
    "says",
    "say",
    "will",
    "would",
    "can",
    "could",
    "should",
    "has",
    "have",
    "had",
    "do",
    "does",
    "did",
    "get",
    "got",
    "make",
    "made",
    "and",
    "or",
    "but",
    "that",
    "which",
    "who",
    "whom",
    "when",
    "where",
    "to",
    "of",
    "in",
    "on",
    "at",
    "for",
    "with",
    "from",
    "by",
    "as",
    "if",
    "then",
    "so",
    "because",
    "than",
    "into",
    "about",
    "over",
    "according",
    "regarding",
    "including",
    "before",
    "after",
    "during",
    "since",
    "until",
    "while",
    "though",
    "although",
    "unless",
    "without",
    "within",
    "upon",
    "per",
    "versus",
    "near",
    "above",
    "below",
    "under",
    "between",
    "among",
    "through",
    "across",
    "against",
    "toward",
    "towards",
];

// NOTE: this list will never be complete -- span detection from a single
// opening marker is a semantic problem wearing a lexical disguise. Missing a
// stopword over-extends the quote ("best practice according" instead of "best
// practice"). It fails safe: the words are all still there and the guardrail
// still passes, the quotation marks just land in the wrong place. If an LLM
// stage ever earns its keep, this is the first thing it should take over.

const CLOSERS: &[&str] = &["unquote", "endquote", "closequote"];

/// Is there a spoken closing marker later in this sentence?
fn has_closer_ahead(toks: &[String], from: usize) -> bool {
    for j in from..toks.len() {
        let b = bare_lower(&toks[j]);
        if CLOSERS.contains(&b.as_str()) {
            return true;
        }
        if (b == "end" || b == "close") && j + 1 < toks.len() && bare_lower(&toks[j + 1]) == "quote"
        {
            return true;
        }
        if toks[j].ends_with(['.', '?', '!']) {
            return false;
        }
    }
    false
}

fn bare_lower(t: &str) -> String {
    t.chars()
        .filter(|c| c.is_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

/// Trailing punctuation on a token, e.g. "oats." -> ("oats", ".")
fn split_trailing_punct(t: &str) -> (&str, &str) {
    let end = t.trim_end_matches(['.', ',', '!', '?', ';', ':']);
    (end, &t[end.len()..])
}

/// Turn spoken quote markers into real quotation marks.
///
/// Two shapes, because people say both:
///   "quote ... unquote"   -> exact span, unambiguous
///   "quote-unquote X"     -> only the opening marker; the span has to be
///                            guessed, which is the genuinely hard part.
///
/// The guess: run to the end of the sentence when what remains is short,
/// otherwise stop at the first word that ends a noun phrase. Capped at 6 words.
/// Closing punctuation moves inside the quotes (US convention).
pub fn apply_quotes(s: &str) -> String {
    let toks: Vec<String> = s.split_whitespace().map(|t| t.to_string()).collect();
    let mut out: Vec<String> = Vec::new();
    let mut i = 0;

    while i < toks.len() {
        // is this an opening marker? returns tokens consumed and whether the
        // closer was spoken adjacently ("quote-unquote" / "quote unquote").
        let bare = bare_lower(&toks[i]);
        let hyphenated = bare == "quoteunquote";
        let two_word = bare == "quote"
            && i + 1 < toks.len()
            && CLOSERS.contains(&bare_lower(&toks[i + 1]).as_str());
        let open_quote =
            bare == "open" && i + 1 < toks.len() && bare_lower(&toks[i + 1]) == "quote";
        // A bare "quote" is only a marker if a closer actually follows in the
        // same sentence -- otherwise it is the ordinary noun, as in "she gave
        // me a quote for the work".
        let plain_quote = bare == "quote" && !two_word && has_closer_ahead(&toks, i + 1);

        if !(hyphenated || two_word || open_quote || plain_quote) {
            out.push(toks[i].clone());
            i += 1;
            continue;
        }

        let marker_len = if hyphenated {
            1
        } else if two_word || open_quote {
            2
        } else {
            1
        };
        let start = i + marker_len;
        if start >= toks.len() {
            out.push(toks[i].clone());
            i += 1;
            continue;
        }

        // Explicit closer later in the span? Then the span is exact.
        let mut explicit_end = None;
        for j in start..toks.len() {
            let b = bare_lower(&toks[j]);
            if CLOSERS.contains(&b.as_str())
                || (b == "end" && j + 1 < toks.len() && bare_lower(&toks[j + 1]) == "quote")
                || (b == "close" && j + 1 < toks.len() && bare_lower(&toks[j + 1]) == "quote")
            {
                explicit_end = Some(j);
                break;
            }
            if toks[j].ends_with(['.', '?', '!']) {
                break; // don't cross a sentence boundary looking for a closer
            }
        }

        let (span_end, closer_len) = match explicit_end {
            Some(j) => {
                let b = bare_lower(&toks[j]);
                (j, if b == "end" || b == "close" { 2 } else { 1 })
            }
            None => {
                // guess the span
                let mut j = start;
                let mut n = 0;
                while j < toks.len() && n < 6 {
                    let (word, punct) = split_trailing_punct(&toks[j]);
                    let b = bare_lower(word);
                    if n > 0 && NP_STOP.contains(&b.as_str()) {
                        break;
                    }
                    j += 1;
                    n += 1;
                    if punct.contains(['.', '?', '!']) {
                        break; // sentence ended; take it all
                    }
                }
                (j, 0)
            }
        };

        if span_end <= start {
            out.push(toks[i].clone());
            i += 1;
            continue;
        }

        // build the quoted span, pulling trailing punctuation inside
        let mut span: Vec<String> = toks[start..span_end].to_vec();
        let last = span.len() - 1;
        let (word, punct) = split_trailing_punct(&span[last]);
        let inner_punct = if punct.contains(['.', ',', '!', '?']) {
            punct.to_string()
        } else {
            String::new()
        };
        let outer_punct = if inner_punct.is_empty() {
            punct.to_string()
        } else {
            String::new()
        };
        span[last] = word.to_string();
        out.push(format!(
            "\"{}{}\"{}",
            span.join(" "),
            inner_punct,
            outer_punct
        ));

        i = span_end + closer_len;
    }

    out.join(" ")
}

// -------------------------------------------------------- declared edits

/// Why a stage changed a word. Each category is separately allowed or denied
/// by config, so "fix proper nouns" and "rewrite my grammar" are different
/// permissions rather than one blanket trust decision.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditReason {
    /// A term from the user's vocabulary: "Largemont" -> "Larchmont".
    Vocabulary,
    /// A spoken self-correction: "Bob, I mean Bill" -> "Bill".
    SelfCorrection,
    /// A word consumed by structural formatting -- the "and" in "bread, and
    /// butter" when it becomes a bulleted list.
    Structure,
    /// Anything else a stage wants to do. Denied by default.
    Other,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Edit {
    pub from: String,
    pub to: String,
    pub reason: EditReason,
}

/// How much word-changing a stage is permitted. The defaults encode "changing
/// a word here or there is fine, but the system should be strongly biased
/// against it": one narrow category allowed, a hard cap of a few edits, and a
/// ceiling on the share of the utterance that may change.
#[derive(Clone, Debug)]
pub struct Policy {
    pub allowed: Vec<EditReason>,
    pub max_edits: usize,
    pub max_changed_fraction: f32,
    /// Words that may always change regardless of the fraction. Without a
    /// floor, one proper-noun fix in a short sentence trips the percentage --
    /// and short sentences are most of dictation.
    pub always_allow_words: usize,
}

impl Default for Policy {
    fn default() -> Self {
        Policy {
            allowed: vec![
                EditReason::Vocabulary,
                EditReason::SelfCorrection,
                EditReason::Structure,
            ],
            max_edits: 3,
            max_changed_fraction: 0.25,
            always_allow_words: 2,
        }
    }
}

impl Policy {
    /// Nothing may change. The old exact-equality contract.
    pub fn strict() -> Self {
        Policy {
            allowed: vec![],
            max_edits: 0,
            max_changed_fraction: 0.0,
            always_allow_words: 0,
        }
    }
}

#[derive(Debug, PartialEq)]
pub enum EditVerdict {
    /// Output differs from input only by the edits the stage declared.
    Pass,
    /// A category the operator has not allowed.
    Forbidden(EditReason),
    /// Within policy per-edit, but too much of the utterance changed. The
    /// expression of "strongly biased against": a stage gets to fix a word
    /// here or there, not to reword you.
    OverBudget {
        edits: usize,
        changed: usize,
        of: usize,
    },
    /// Words changed that the stage did not declare -- the failure that
    /// matters. Declaring one edit is not a licence for others.
    Undeclared {
        dropped: Vec<String>,
        added: Vec<String>,
    },
}

/// The guardrail, generalized: **no _undeclared_ word changes.**
///
/// A stage may change words if it says which ones and why. The host verifies
/// that the declared edits fully account for the difference, so a silent
/// rewrite is still caught while a legitimate, auditable substitution is
/// allowed through and logged. Exact equality (`check`) is the special case
/// where the declared edit list is empty.
pub fn check_declared(
    stage_input: &str,
    stage_output: &str,
    declared: &[Edit],
    policy: &Policy,
    cfg: &Config,
) -> EditVerdict {
    for e in declared {
        if !policy.allowed.contains(&e.reason) {
            return EditVerdict::Forbidden(e.reason);
        }
    }

    // Apply the declared edits to the input's canonical form, then require
    // exact equality with the output's. Anything left over is undeclared.
    let mut a = normalize(stage_input, cfg);
    for e in declared {
        let from = normalize(&e.from, cfg);
        let to = normalize(&e.to, cfg);
        if from.is_empty() {
            continue;
        }
        let mut i = 0;
        while i + from.len() <= a.len() {
            if a[i..i + from.len()] == from[..] {
                a.splice(i..i + from.len(), to.iter().cloned());
                i += to.len();
            } else {
                i += 1;
            }
        }
    }
    let mut collapsed: Vec<String> = Vec::new();
    for w in a {
        if collapsed.last().map(|p| p == &w).unwrap_or(false) {
            continue;
        }
        collapsed.push(w);
    }
    let a = collapsed;

    let b = normalize(stage_output, cfg);
    if a == b {
        // Accounted for. Now: was it more than a word here or there?
        let input_words = normalize(stage_input, cfg).len();
        // Count words *introduced*. Deleting a false start is the whole point
        // of a self-correction; inventing text is the danger worth budgeting.
        let changed: usize = declared
            .iter()
            .map(|e| {
                let from = normalize(&e.from, cfg);
                let to = normalize(&e.to, cfg);
                to.iter().filter(|w| !from.contains(w)).count()
            })
            .sum();
        let ceiling = (input_words as f32 * policy.max_changed_fraction)
            .max(policy.always_allow_words as f32);
        if declared.len() > policy.max_edits || (changed as f32) > ceiling {
            return EditVerdict::OverBudget {
                edits: declared.len(),
                changed,
                of: input_words,
            };
        }
        return EditVerdict::Pass;
    }

    let mut dropped = Vec::new();
    let mut bb = b.clone();
    for w in &a {
        match bb.iter().position(|x| x == w) {
            Some(p) => {
                bb.remove(p);
            }
            None => dropped.push(w.clone()),
        }
    }
    let mut added = Vec::new();
    let mut aa = a.clone();
    for w in &b {
        match aa.iter().position(|x| x == w) {
            Some(p) => {
                aa.remove(p);
            }
            None => added.push(w.clone()),
        }
    }
    EditVerdict::Undeclared { dropped, added }
}

// ------------------------------------------------------------------ lists

/// Turn a spoken enumeration into a numbered list.
///
/// ```text
/// "Here's my grocery list. One, garlic cloves. Two, milk. Three, raisin bran."
///   ->  Here's my grocery list.
///
///       1. Garlic cloves
///       2. Milk
///       3. Raisin bran
/// ```
///
/// The signal is not "a number appeared" but **consecutive** enumerators, each
/// opening its own sentence, ascending by one. That is what separates a list
/// from a sentence that happens to contain numbers ("I'll take one. Two would
/// be better." -- there the numbers do not open their clauses in sequence).
pub fn apply_lists(s: &str, min_items: usize) -> String {
    if s.contains('\n') {
        return s
            .split('\n')
            .map(|l| apply_lists(l, min_items))
            .collect::<Vec<_>>()
            .join("\n");
    }
    let sentences = split_sentences(s);
    if sentences.len() < min_items {
        return s.to_string();
    }

    // enumerator value opening each sentence, if any
    let heads: Vec<Option<(u64, usize)>> =
        sentences.iter().map(|t| leading_enumerator(t)).collect();

    // find the longest ascending-by-one run
    let (mut best_start, mut best_len) = (0usize, 0usize);
    let mut i = 0;
    while i < heads.len() {
        if let Some((v, _)) = heads[i] {
            let mut j = i + 1;
            let mut expect = v + 1;
            while j < heads.len() && heads[j].map(|(w, _)| w == expect).unwrap_or(false) {
                expect += 1;
                j += 1;
            }
            if j - i > best_len {
                best_len = j - i;
                best_start = i;
            }
            i = j;
        } else {
            i += 1;
        }
    }

    if best_len < min_items {
        return s.to_string();
    }

    let mut out = String::new();
    let preamble: Vec<&str> = sentences[..best_start].iter().map(|t| t.as_str()).collect();
    if !preamble.is_empty() {
        out.push_str(&preamble.join(" "));
        out.push_str("\n\n");
    }
    for (n, idx) in (best_start..best_start + best_len).enumerate() {
        let (val, skip) = heads[idx].unwrap();
        let _ = val;
        let body = sentences[idx][skip..]
            .trim()
            .trim_start_matches([',', ':', '-'])
            .trim()
            .trim_end_matches('.')
            .to_string();
        out.push_str(&format!("{}. {}\n", n + 1, body));
    }
    let tail: Vec<&str> = sentences[best_start + best_len..]
        .iter()
        .map(|t| t.as_str())
        .collect();
    if !tail.is_empty() {
        out.push('\n');
        out.push_str(&tail.join(" "));
    }
    out.trim_end().to_string()
}

/// Split on sentence terminators, keeping the terminator with its sentence.
fn split_sentences(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let chars: Vec<char> = s.chars().collect();
    for (i, c) in chars.iter().enumerate() {
        cur.push(*c);
        if matches!(c, '.' | '?' | '!') {
            let next_is_space = chars.get(i + 1).map(|n| n.is_whitespace()).unwrap_or(true);
            let prev_alnum = chars
                .get(i.wrapping_sub(1))
                .map(|p| p.is_alphanumeric())
                .unwrap_or(false);
            // "1." opening a segment is a list marker, not a sentence end --
            // splitting there fragments the item away from its number.
            let marker = {
                let so_far = cur.trim_end_matches('.').trim();
                !so_far.is_empty() && so_far.chars().all(|c| c.is_ascii_digit())
            };
            if next_is_space && prev_alnum && !marker {
                out.push(cur.trim().to_string());
                cur.clear();
            }
        }
    }
    if !cur.trim().is_empty() {
        out.push(cur.trim().to_string());
    }
    out
}

/// If this sentence opens with an enumerator, return its value and the byte
/// length to skip. Accepts "One,", "1.", "first,".
fn leading_enumerator(sent: &str) -> Option<(u64, usize)> {
    let first = sent.split_whitespace().next()?;
    let bare: String = first.chars().filter(|c| c.is_alphanumeric()).collect();
    if bare.is_empty() {
        return None;
    }
    let lower = bare.to_lowercase();
    let val = if let Ok(n) = lower.parse::<u64>() {
        n
    } else if let Some(v) = ordinal_val(&lower) {
        v
    } else if let Some(v) = word_val(&lower) {
        if v == 0 {
            return None;
        }
        v
    } else {
        return None;
    };
    // require a separator or a following word, so a bare "One." is not an item
    let skip = first.len();
    if sent.len() <= skip {
        return None;
    }
    Some((val, skip))
}

// -------------------------------------------------- unordered enumerations

/// Phrases that announce a list. **The cue is required**, and that is the whole
/// safety story: a comma series is syntactically identical to ordinary prose
/// ("I like coffee, tea and juice"), so without an announcement there is no
/// signal worth acting on. Requiring the user to say "here's my list" makes the
/// behaviour predictable and gives them an explicit way to ask for it.
const LIST_CUES: &[&str] = &[
    "list",
    "lists",
    "shopping",
    "groceries",
    "grocery",
    "agenda",
    "items",
    "ingredients",
    "inventory",
    "checklist",
    "todo",
    "errands",
];

/// Cues that can open the series sentence itself: "I need milk, eggs, bread."
const INLINE_CUES: &[&str] = &[
    "i need",
    "we need",
    "i want",
    "don't forget",
    "dont forget",
    "remember to get",
    "pick up",
    "we should get",
    "i should get",
];

/// Finite verbs. An item containing one is a clause, not a noun phrase, which
/// is what separates a list from a narrative ("I went to the store, bought
/// milk, came home").
const FINITE_VERBS: &[&str] = &[
    "is", "are", "was", "were", "am", "be", "been", "being", "go", "goes", "went", "gone", "come",
    "comes", "came", "buy", "buys", "bought", "make", "makes", "made", "take", "takes", "took",
    "get", "gets", "got", "put", "puts", "run", "runs", "ran", "do", "does", "did", "have", "has",
    "had", "will", "would", "shall", "can", "could", "should", "may", "might", "must", "need",
    "needs", "want", "wants", "like", "likes", "think", "thinks", "said", "says", "say", "told",
    "tell", "tells", "call", "called",
];

fn has_cue(sent: &str) -> bool {
    let low = sent.to_lowercase();
    low.split(|c: char| !c.is_alphanumeric())
        .any(|w| LIST_CUES.contains(&w))
}

fn strip_inline_cue(sent: &str) -> Option<&str> {
    let low = sent.to_lowercase();
    for cue in INLINE_CUES {
        if low.starts_with(cue) {
            let rest = sent[cue.len()..].trim_start_matches([':', ' ', ',']);
            return Some(rest);
        }
    }
    None
}

/// Is this a bare series of noun phrases?
fn comma_series(sent: &str, min_items: usize) -> Option<Vec<String>> {
    let body = sent.trim().trim_end_matches(['.', '!', '?']);
    if body.contains(';') || body.contains(':') {
        return None;
    }
    let parts: Vec<String> = body
        .split(',')
        .map(|p| p.trim().trim_start_matches("and ").trim().to_string())
        .filter(|p| !p.is_empty())
        .collect();
    if parts.len() < min_items {
        return None;
    }
    for p in &parts {
        // a clause, not an item
        if p.split_whitespace().any(|w| {
            let b: String = w
                .chars()
                .filter(|c| c.is_alphanumeric() || *c == '\'')
                .collect();
            FINITE_VERBS.contains(&b.to_lowercase().as_str())
        }) {
            return None;
        }
        // runaway fragment: real spoken list items are short
        if p.split_whitespace().count() > 6 {
            return None;
        }
    }
    Some(parts)
}

/// Turn an announced comma series into a bulleted list.
pub fn apply_unordered_lists(s: &str, min_items: usize) -> String {
    if s.contains('\n') {
        return s
            .split('\n')
            .map(|l| apply_unordered_lists(l, min_items))
            .collect::<Vec<_>>()
            .join("\n");
    }
    let sentences = split_sentences(s);
    if sentences.is_empty() {
        return s.to_string();
    }
    let mut out: Vec<String> = Vec::new();
    let mut i = 0;
    while i < sentences.len() {
        let sent = &sentences[i];
        let announced_before = i > 0 && has_cue(&sentences[i - 1]);
        let inline = strip_inline_cue(sent);

        let candidate: Option<(Option<String>, Vec<String>)> = if let Some(rest) = inline {
            comma_series(rest, min_items).map(|items| {
                let cue_len = sent.len() - rest.len();
                (
                    Some(
                        sent[..cue_len]
                            .trim_end_matches([' ', ',', ':'])
                            .to_string(),
                    ),
                    items,
                )
            })
        } else if announced_before {
            comma_series(sent, min_items).map(|items| (None, items))
        } else {
            None
        };

        match candidate {
            Some((lead, items)) => {
                if let Some(l) = lead {
                    if !l.is_empty() {
                        out.push(format!("{}:", l));
                    }
                }
                let mut block = String::new();
                if !out.is_empty() {
                    block.push('\n');
                }
                for it in items {
                    block.push_str(&format!("- {}\n", it));
                }
                out.push(block.trim_end().to_string());
            }
            None => out.push(sent.clone()),
        }
        i += 1;
    }

    // rejoin: bulleted blocks get a blank line, prose stays inline
    let mut res = String::new();
    for (n, part) in out.iter().enumerate() {
        let is_block = part.starts_with('\n') || part.starts_with("- ");
        if n > 0 {
            res.push_str(if is_block || res.ends_with(']') {
                "\n\n"
            } else {
                " "
            });
        }
        res.push_str(part.trim_start_matches('\n'));
    }
    res.trim().to_string()
}

// ------------------------------------------------------- spoken corrections

/// Cues that throw away the whole preceding clause. "Let's meet at noon,
/// scratch that, let's meet at one" -> the entire first attempt goes.
const CLAUSE_CUES: &[&str] = &[
    "scratch that",
    "strike that",
    "delete that",
    "forget that",
    "start over",
    "let me start over",
    "let me try again",
];

/// Cues that replace just the phrase before them. "Send it to Bob, I mean
/// Bill" -> only "Bob" is replaced, not the whole sentence. These are a
/// different operation from the clause cues and need a different scope.
const PHRASE_CUES: &[&str] = &["no i mean", "i mean", "correction", "rather"];

fn is_no_run(toks: &[String], i: usize) -> Option<usize> {
    // "no, no, no" -- two or more in a row is a correction, one is an answer
    let mut j = i;
    while j < toks.len() && bare_lower(&toks[j]) == "no" {
        j += 1;
    }
    if j - i >= 2 {
        Some(j)
    } else {
        None
    }
}

/// Erase a false start and everything up to the control phrase.
///
/// Scope: back to the previous comma or sentence boundary. If the cue sits
/// immediately after a boundary ("send it to Bob, I mean Bill") that would
/// erase nothing, so it reaches back one boundary further -- which is what
/// makes both shapes work with a single rule.
///
/// Every erasure is returned as a declared `SelfCorrection` edit, so it lands
/// in the utterance's ledger rather than silently changing the text.
pub fn apply_corrections(s: &str) -> (String, Vec<Edit>) {
    let mut text = s.to_string();
    let mut edits = Vec::new();

    'outer: loop {
        let toks: Vec<String> = text.split_whitespace().map(|t| t.to_string()).collect();
        // byte offset of each token
        let mut offs = Vec::with_capacity(toks.len());
        let mut cur = 0usize;
        for t in &toks {
            let idx = text[cur..].find(t.as_str()).map(|p| cur + p).unwrap_or(cur);
            offs.push(idx);
            cur = idx + t.len();
        }

        for i in 0..toks.len() {
            // find a cue starting at token i
            let mut end_tok = None;
            let mut clause_scope = true;
            if let Some(j) = is_no_run(&toks, i) {
                end_tok = Some(j);
            } else {
                'cue: for (cues, is_clause) in [(CLAUSE_CUES, true), (PHRASE_CUES, false)] {
                    for cue in cues {
                        let words: Vec<&str> = cue.split(' ').collect();
                        if i + words.len() > toks.len() {
                            continue;
                        }
                        let got: Vec<String> = toks[i..i + words.len()]
                            .iter()
                            .map(|t| bare_lower(t))
                            .collect();
                        if got == words {
                            end_tok = Some(i + words.len());
                            clause_scope = is_clause;
                            break 'cue;
                        }
                    }
                }
            }
            let Some(end_tok) = end_tok else { continue };

            // reach back to a boundary; if that erases nothing, go back further
            let boundary_before = |k: usize| -> Option<usize> {
                (0..k)
                    .rev()
                    .find(|&m| toks[m].ends_with([',', '.', '!', '?', ';']))
            };
            let mut start_tok = boundary_before(i).map(|m| m + 1).unwrap_or(0);
            if start_tok >= i {
                // The cue sits right after a boundary, so reaching back to it
                // erases nothing. What to do then depends on the cue:
                start_tok = if clause_scope {
                    // discard the whole previous clause too
                    boundary_before(start_tok.saturating_sub(1))
                        .map(|m| m + 1)
                        .unwrap_or(0)
                } else {
                    // replace only the phrase: take the one word before the
                    // boundary. Erring toward deleting LESS -- an extra word
                    // left in is recoverable, a deleted one is not.
                    boundary_before(i).unwrap_or(0)
                };
            }
            if start_tok >= end_tok {
                continue;
            }

            let start_b = offs[start_tok];
            let end_b = if end_tok < toks.len() {
                offs[end_tok]
            } else {
                text.len()
            };
            let erased = text[start_b..end_b].trim().to_string();
            if erased.is_empty() {
                continue;
            }
            let mut next = String::with_capacity(text.len());
            next.push_str(text[..start_b].trim_end());
            let tail = text[end_b..].trim_start();
            if !next.is_empty() && !tail.is_empty() {
                next.push(' ');
            }
            next.push_str(tail);
            edits.push(Edit {
                from: erased,
                to: String::new(),
                reason: EditReason::SelfCorrection,
            });
            text = next;
            continue 'outer;
        }
        break;
    }
    (text.trim().to_string(), edits)
}

/// The rules formatter, reporting the word changes it made.
///
/// Word-preserving work (fillers, tone, quoting, enumeration) returns an empty
/// edit list and is verified by exact equality. Anything that genuinely removes
/// a word -- a spoken correction, or the connector in "bread, and butter" --
/// declares it here so the ledger can account for it.
pub fn format_with_edits(raw: &str, cfg: &Config) -> (String, Vec<Edit>) {
    let mut edits = Vec::new();
    let mut s = raw.to_string();
    if cfg.corrections {
        let (t, e) = apply_corrections(&s);
        s = t;
        edits.extend(e);
    }
    let before_lists = s.clone();
    let out = format(&s, cfg);
    // the unordered-list pass consumes a trailing "and" connector
    if cfg.lists {
        let a = normalize(&before_lists, cfg);
        let b = normalize(&out, cfg);
        if a != b {
            let mut bb = b.clone();
            for w in &a {
                if let Some(p) = bb.iter().position(|x| x == w) {
                    bb.remove(p);
                }
            }
            let mut dropped: Vec<String> = Vec::new();
            let mut bb2 = b.clone();
            for w in &a {
                match bb2.iter().position(|x| x == w) {
                    Some(p) => {
                        bb2.remove(p);
                    }
                    None => dropped.push(w.clone()),
                }
            }
            for w in dropped {
                if w == "and" {
                    edits.push(Edit {
                        from: "and".into(),
                        to: String::new(),
                        reason: EditReason::Structure,
                    });
                }
            }
        }
    }
    (out, edits)
}

// ------------------------------------------------------------ salutation

/// Openings that start a letter. The counterpart to SIGNOFFS.
const GREETINGS: &[&str] = &[
    "good morning",
    "good afternoon",
    "good evening",
    "dear",
    "hello",
    "hey there",
    "hey",
    "hi there",
    "hi",
    "hiya",
    "greetings",
    "yo",
];

/// Split a leading salutation ("Hi John," / "Dear Sarah,") off the front.
/// Returns `(Some(salutation), body)`.
///
/// Requires greeting + a capitalized name + a comma. "Hi," alone is not a
/// salutation worth reformatting, and "hey we should ship it" has no name.
pub fn split_salutation(s: &str) -> (Option<String>, String) {
    let toks: Vec<&str> = s.split_whitespace().collect();
    if toks.len() < 2 {
        return (None, s.to_string());
    }
    let bare = |t: &str| -> String {
        t.chars()
            .filter(|c| c.is_alphanumeric() || *c == '\'')
            .collect()
    };

    for greet in GREETINGS {
        let words: Vec<&str> = greet.split(' ').collect();
        if toks.len() <= words.len() {
            continue;
        }
        let got: Vec<String> = toks[..words.len()]
            .iter()
            .map(|t| bare(t).to_lowercase())
            .collect();
        if got != words {
            continue;
        }
        // 1-2 capitalized name tokens, the last carrying the comma
        for name_len in [2usize, 1] {
            let end = words.len() + name_len;
            if end > toks.len() {
                continue;
            }
            let name = &toks[words.len()..end];
            let all_names = name.iter().all(|t| {
                let b = bare(t);
                !b.is_empty()
                    && b.chars().all(|c| c.is_alphabetic())
                    && b.chars().next().map(|c| c.is_uppercase()).unwrap_or(false)
            });
            if !all_names || !toks[end - 1].ends_with(',') {
                continue;
            }
            let sal = toks[..end].join(" ");
            let consumed: usize = s.find(&sal).map(|p| p + sal.len()).unwrap_or(0);
            let body = s[consumed..].trim_start().to_string();
            if body.is_empty() {
                continue;
            }
            return (Some(sal), body);
        }
    }
    (None, s.to_string())
}

/// Letter layout: salutation, body in the chosen register, signature.
///
/// The salutation break is suppressed in `VeryCasual`, which is the texting
/// register -- "Hey John," followed by a blank line is email shape, and a text
/// message should not acquire one. Formal and casual get it.
pub fn apply_letter_layout(s: &str, tone: Tone) -> String {
    let (sal, rest) = if tone == Tone::VeryCasual {
        (None, s.to_string())
    } else {
        split_salutation(s)
    };
    let body = apply_tone_with_signature(&rest, tone);
    match sal {
        None => body,
        Some(sal) => format!("{}\n\n{}", sal, body),
    }
}

#[cfg(test)]
mod address_tests {
    use super::*;

    fn f(s: &str) -> String {
        apply_addresses(s)
    }

    /// The case that started this: faithful to the sounds, useless as text.
    #[test]
    fn rebuilds_a_spoken_url() {
        assert_eq!(
            f("my site is h-t-t-p-s colon slash slash kevin dash mooney dot com"),
            "my site is https://kevin-mooney.com"
        );
    }

    #[test]
    fn rebuilds_a_bare_domain() {
        assert_eq!(f("go to kevin dash mooney dot com"), "go to kevin-mooney.com");
    }

    #[test]
    fn rebuilds_an_email() {
        assert_eq!(
            f("reach me at kevin at gmail dot com"),
            "reach me at kevin@gmail.com"
        );
    }

    /// An address has one local part. The "at" that means "at" must survive.
    #[test]
    fn does_not_swallow_the_preposition() {
        assert!(f("email me at kevin at gmail dot com").starts_with("email me at "));
    }

    /// The guard that earns its place: a real English phrase that looks exactly
    /// like an address to a naive rule.
    #[test]
    fn leaves_the_dot_com_boom_alone() {
        assert_eq!(f("the dot com boom was wild"), "the dot com boom was wild");
    }

    #[test]
    fn leaves_ordinary_prose_alone() {
        let s = "put a dot at the end and dash off a note";
        assert_eq!(f(s), s);
    }

    /// Sentence punctuation belongs to the sentence, not the address.
    #[test]
    fn keeps_trailing_punctuation() {
        assert_eq!(f("see kevin dash mooney dot com."), "see kevin-mooney.com.");
    }

    #[test]
    fn collapses_spelled_letters() {
        assert_eq!(collapse_spelled("h-t-t-p-s").as_deref(), Some("https"));
        assert_eq!(collapse_spelled("e-mail"), None, "two parts is a hyphenated word");
        assert_eq!(collapse_spelled("kevin"), None);
    }

    /// Already-correct text must pass through: whisper sometimes gets it right,
    /// and a second pass must not make it worse.
    #[test]
    fn leaves_a_real_url_alone() {
        let s = "see https://kevin-mooney.com for details";
        assert_eq!(f(s), s);
    }

    #[test]
    fn dot_com_alone_is_not_an_address() {
        assert_eq!(f("dot com"), "dot com");
    }
}

#[cfg(test)]
mod address_shape_tests {
    use super::*;

    /// Whisper does not produce one shape, it produces several — these three
    /// are all real output from the same spoken sentence on the same phone.
    #[test]
    fn handles_letters_spelled_out_as_separate_tokens() {
        assert_eq!(
            apply_addresses("http colon slash slash k e v i n dash m o o n e y dot com"),
            "http://kevin-mooney.com"
        );
    }

    #[test]
    fn handles_a_host_whisper_already_punctuated() {
        assert_eq!(
            apply_addresses("https colon slash slash kevin dash mooney.com"),
            "https://kevin-mooney.com"
        );
    }

    #[test]
    fn handles_the_fully_spoken_form() {
        assert_eq!(
            apply_addresses("h-t-t-p-s colon slash slash kevin dash mooney dot com"),
            "https://kevin-mooney.com"
        );
    }

    /// The address must end where the sentence resumes.
    #[test]
    fn stops_at_the_end_of_the_address() {
        assert_eq!(
            apply_addresses("go to https colon slash slash kevin dash mooney.com and tell me"),
            "go to https://kevin-mooney.com and tell me"
        );
    }

    /// A scheme said on its own is not an address and must not eat the sentence.
    #[test]
    fn a_bare_scheme_is_left_alone() {
        assert_eq!(apply_addresses("https is a protocol"), "https is a protocol");
    }
}
