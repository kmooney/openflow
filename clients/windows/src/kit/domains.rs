//! Turning browsing history into vocabulary terms.
//!
//! Pure, and separate from anything that reads a browser's database, because
//! this is the half worth testing and the other half is file paths.

use std::collections::HashMap;

/// The term for one URL, or None if it is not worth spending prompt budget on.
/// "https://www.doordash.com/store/1" -> "doordash.com".
///
/// `www.` is stripped because whisper transcribes the spoken "www" part
/// perfectly well on its own -- the word it cannot guess is the name.
/// Subdomains are kept: "news.ycombinator.com" is what you would say.
pub fn term(url: &str) -> Option<String> {
    let (scheme, rest) = url.split_once("://")?;
    let scheme = scheme.to_lowercase();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    // Authority runs to the first /, ? or #.
    let authority = rest
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("")
        .to_lowercase();
    // Drop any userinfo.
    let host = authority.rsplit('@').next().unwrap_or("");
    let mut host = host.to_string();

    if let Some(stripped) = host.strip_prefix("www.") {
        host = stripped.to_string();
    }
    if host.ends_with('.') {
        host.pop(); // trailing dot is legal in DNS and noise here
    }

    // A bare label is not a domain, and an address is not pronounceable.
    if host.is_empty()
        || !host.contains('.')
        || host.contains(':')
        || host == "localhost"
        || is_ipv4(&host)
    {
        return None;
    }
    Some(host)
}

fn is_ipv4(host: &str) -> bool {
    let parts: Vec<&str> = host.split('.').collect();
    parts.len() == 4 && parts.iter().all(|p| p.parse::<u8>().is_ok())
}

/// Collapse visits to one weighted entry per domain, most-visited first.
///
/// Ties break alphabetically rather than by hash order, so seeding twice from
/// an unchanged history produces an unchanged file.
pub fn rank(visits: &[(String, i64)]) -> Vec<(String, i64)> {
    let mut totals: HashMap<String, i64> = HashMap::new();
    for (url, count) in visits {
        if let Some(t) = term(url) {
            *totals.entry(t).or_insert(0) += (*count).max(1);
        }
    }
    let mut out: Vec<(String, i64)> = totals.into_iter().collect();
    out.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_url_becomes_the_name_you_would_say() {
        assert_eq!(term("https://www.doordash.com/store/1").as_deref(), Some("doordash.com"));
        assert_eq!(
            term("https://news.ycombinator.com/item?id=1").as_deref(),
            Some("news.ycombinator.com"),
            "subdomains are part of what you say"
        );
    }

    #[test]
    fn unpronounceable_or_useless_hosts_are_dropped() {
        assert_eq!(term("http://localhost:3000/x"), None);
        assert_eq!(term("http://192.168.1.1/"), None);
        assert_eq!(term("file:///c:/tmp/x.html"), None);
        assert_eq!(term("about:blank"), None);
        assert_eq!(term("chrome://settings"), None);
        assert_eq!(term("http://intranet/"), None, "a bare label is not a domain");
    }

    #[test]
    fn userinfo_and_ports_do_not_leak_into_the_term() {
        assert_eq!(term("https://user@example.com/x").as_deref(), Some("example.com"));
        assert_eq!(term("https://example.com:8443/x"), None, "a port is not spoken");
    }

    #[test]
    fn ranking_is_by_visits_then_alphabetical() {
        let visits = vec![
            ("https://b.example/".to_string(), 5),
            ("https://a.example/".to_string(), 5),
            ("https://www.c.example/one".to_string(), 9),
            ("https://c.example/two".to_string(), 1),
        ];
        let ranked = rank(&visits);
        assert_eq!(
            ranked,
            vec![
                ("c.example".to_string(), 10),
                ("a.example".to_string(), 5),
                ("b.example".to_string(), 5),
            ],
            "ties must break alphabetically or seeding is not reproducible"
        );
    }

    #[test]
    fn ranking_twice_gives_the_same_answer() {
        let visits: Vec<(String, i64)> = (0..30)
            .map(|i| (format!("https://site{i}.example/"), 1))
            .collect();
        assert_eq!(rank(&visits), rank(&visits));
    }
}
