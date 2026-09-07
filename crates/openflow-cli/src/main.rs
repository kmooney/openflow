use openflow_core::*;
use std::io::Read;

fn esc(s: &str) -> String {
    s.chars().map(|c| match c {
        '"' => "\\\"".into(),
        '\\' => "\\\\".into(),
        '\n' => "\\n".into(),
        '\t' => "\\t".into(),
        c if (c as u32) < 0x20 => format!("\\u{:04x}", c as u32),
        c => c.to_string(),
    }).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cfg = if args.iter().any(|a| a == "--aggressive") {
        Config::aggressive()
    } else {
        Config::default()
    };

    let tone = args.iter().position(|a| a == "--tone")
        .and_then(|i| args.get(i + 1))
        .and_then(|t| Tone::parse(t))
        .unwrap_or(Tone::Formal);

    // Skip flag values as well as flags, or `--tone formal` reads "formal"
    // as an input filename.
    let mut path: Option<&String> = None;
    let mut i = 1;
    while i < args.len() {
        let a = &args[i];
        if a == "--tone" {
            i += 2;
            continue;
        }
        if a.starts_with("--") {
            i += 1;
            continue;
        }
        path = Some(a);
        break;
    }

    let mut raw = String::new();
    match path {
        Some(p) => raw = std::fs::read_to_string(p).expect("read input"),
        None => { std::io::stdin().read_to_string(&mut raw).expect("read stdin"); }
    }
    let raw = raw.trim();

    let policy = Policy::default();
    let (formatted, edits) = format_with_edits(raw, &cfg);
    let candidate = apply_letter_layout(&formatted, tone);

    let verdict = check_declared(raw, &candidate, &edits, &policy, &cfg);
    // A stage that fails its check is skipped; its input passes through.
    let (out, pass, dropped, added, note) = match &verdict {
        EditVerdict::Pass => (candidate, true, vec![], vec![], String::new()),
        EditVerdict::Undeclared { dropped, added } =>
            (raw.to_string(), false, dropped.clone(), added.clone(), "undeclared".into()),
        EditVerdict::Forbidden(r) =>
            (raw.to_string(), false, vec![], vec![], format!("forbidden:{:?}", r)),
        EditVerdict::OverBudget { edits, changed, of } =>
            (raw.to_string(), false, vec![], vec![],
             format!("over budget: {} edits, {} of {} words", edits, changed, of)),
    };
    let changed = out != raw;
    let ledger: Vec<String> = edits.iter().map(|e| format!(
        "{{\"from\":\"{}\",\"to\":\"{}\",\"why\":\"{:?}\"}}",
        esc(&e.from), esc(&e.to), e.reason)).collect();
    println!(
        "{{\"raw\":\"{}\",\"formatted\":\"{}\",\"tone\":\"{}\",\"guardrail_passed\":{},\"note\":\"{}\",\"ledger\":[{}],\"changed\":{},\"dropped\":[{}],\"added\":[{}]}}",
        esc(raw), esc(&out), tone.name(), pass, esc(&note), ledger.join(","), changed,
        dropped.iter().map(|w| format!("\"{}\"", esc(w))).collect::<Vec<_>>().join(","),
        added.iter().map(|w| format!("\"{}\"", esc(w))).collect::<Vec<_>>().join(","),
    );
}
