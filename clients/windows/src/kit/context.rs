//! What has focus right now: which app, and which kind of field inside it.
//! This is the key tone is remembered against, and the key the vocabulary is
//! indexed by.

/// Deliberately coarse: UI Automation exposes dozens of control types, and a
/// taxonomy we cannot populate correctly is worse than four buckets we can.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash)]
pub enum FieldKind {
    UrlBar,
    Search,
    SingleLine,
    MultiLine,
    Unknown,
}

impl FieldKind {
    pub fn as_str(self) -> &'static str {
        match self {
            FieldKind::UrlBar => "url",
            FieldKind::Search => "search",
            FieldKind::SingleLine => "line",
            FieldKind::MultiLine => "body",
            FieldKind::Unknown => "any",
        }
    }

    /// Kinds that earn a memory slot of their own, separate from the app's.
    ///
    /// An address bar is a genuinely different register from the page below it
    /// -- you type search terms into one and prose into the other. A subject
    /// line is not: it wants the same register as the mail body, so
    /// `SingleLine` and `MultiLine` share the app's slot rather than splitting
    /// it and making the user teach the same thing twice.
    pub fn is_distinct(self) -> bool {
        matches!(self, FieldKind::UrlBar | FieldKind::Search)
    }

    pub fn label(self) -> &'static str {
        match self {
            FieldKind::UrlBar => "address bar",
            FieldKind::Search => "search field",
            FieldKind::SingleLine => "text field",
            FieldKind::MultiLine => "text area",
            FieldKind::Unknown => "",
        }
    }

    /// Classify from whatever UI Automation gave us. Pure, so the interesting
    /// half of focus detection is testable without a running app.
    ///
    /// `role` is the UIA control type ("edit", "document", "combobox"), and
    /// `hints` is every scrap of naming we could read -- automation id, name,
    /// help text, the parent's name -- matched case-insensitively.
    pub fn classify(role: Option<&str>, hints: &[Option<&str>]) -> FieldKind {
        let hint = hints
            .iter()
            .flatten()
            .copied()
            .collect::<Vec<_>>()
            .join(" ")
            .to_lowercase();
        let role = role.unwrap_or("").to_lowercase();

        // Address before search, and it is not a tie-break for tidiness:
        // Chrome and Edge both call the omnibox "Address and search bar", so it
        // matches "search" too. The URL reading is the right one for both.
        if is_address_hint(&hint) {
            return FieldKind::UrlBar;
        }
        if hint.contains("search") || role.contains("search") {
            return FieldKind::Search;
        }

        match role.as_str() {
            "document" | "text" => FieldKind::MultiLine,
            "edit" | "combobox" => FieldKind::SingleLine,
            _ => FieldKind::Unknown,
        }
    }
}

fn is_address_hint(hint: &str) -> bool {
    ["address", "url", "omnibox", "location bar"]
        .iter()
        .any(|needle| hint.contains(needle))
}

/// Where an utterance is headed: the app, and the field inside it.
///
/// On Windows the app's identity is its executable name -- "chrome.exe",
/// "outlook.exe". macOS has reverse-DNS bundle ids and Windows has nothing as
/// tidy: `AppUserModelID` exists but only packaged apps set one honestly, and
/// window class names are not stable. The executable is what a user can
/// recognise and type into a `[section]` header, which is the requirement.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct DictationContext {
    /// Lower-cased executable name. None means we could not tell -- dictating
    /// to the clipboard, or nothing in the foreground.
    pub app_id: Option<String>,
    /// For display only. The executable is the identity; this is the name a
    /// human recognises in a list.
    pub app_name: Option<String>,
    pub field: FieldKind,
}

impl Default for FieldKind {
    fn default() -> Self {
        FieldKind::Unknown
    }
}

impl DictationContext {
    pub fn unknown() -> Self {
        DictationContext {
            app_id: None,
            app_name: None,
            field: FieldKind::Unknown,
        }
    }

    pub fn new(app_id: Option<String>, app_name: Option<String>, field: FieldKind) -> Self {
        // Normalise once, here, so every key derived from this agrees. File
        // names on Windows are case-insensitive and inconsistent in the wild
        // (Code.exe, chrome.exe, WINWORD.EXE).
        let id = app_id
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty());
        DictationContext {
            app_id: id,
            app_name,
            field,
        }
    }

    /// The slot a tone chosen here is written to.
    pub fn key(&self) -> Option<String> {
        let id = self.app_id.as_ref()?;
        Some(if self.field.is_distinct() {
            format!("{id}#{}", self.field.as_str())
        } else {
            id.clone()
        })
    }

    /// Slots to consult, most specific first. A tone remembered for the app
    /// answers for its address bar too, until the address bar is taught
    /// something of its own.
    pub fn lookup_keys(&self) -> Vec<String> {
        let (Some(id), Some(key)) = (self.app_id.clone(), self.key()) else {
            return Vec::new();
        };
        if key == id {
            vec![id]
        } else {
            vec![key, id]
        }
    }

    /// "Chrome address bar", "Outlook", "anywhere else".
    pub fn label(&self) -> String {
        let Some(id) = &self.app_id else {
            return "anywhere else".into();
        };
        let app = self.app_name.clone().unwrap_or_else(|| id.clone());
        if self.field.is_distinct() {
            format!("{app} {}", self.field.label())
        } else {
            app
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_omnibox_reads_as_an_address_bar_not_a_search_field() {
        // Chrome and Edge both name it "Address and search bar".
        assert_eq!(
            FieldKind::classify(Some("edit"), &[Some("Address and search bar")]),
            FieldKind::UrlBar
        );
    }

    #[test]
    fn a_search_box_is_a_search_field() {
        assert_eq!(
            FieldKind::classify(Some("edit"), &[Some("Search"), None]),
            FieldKind::Search
        );
    }

    #[test]
    fn control_types_fall_back_to_shape() {
        assert_eq!(FieldKind::classify(Some("document"), &[]), FieldKind::MultiLine);
        assert_eq!(FieldKind::classify(Some("edit"), &[]), FieldKind::SingleLine);
        assert_eq!(FieldKind::classify(Some("combobox"), &[]), FieldKind::SingleLine);
        assert_eq!(FieldKind::classify(Some("button"), &[]), FieldKind::Unknown);
        assert_eq!(FieldKind::classify(None, &[]), FieldKind::Unknown);
    }

    #[test]
    fn a_parent_hint_rescues_an_anonymous_field() {
        // Electron apps routinely leave the field itself unnamed.
        assert_eq!(
            FieldKind::classify(Some("edit"), &[None, None, Some("Omnibox")]),
            FieldKind::UrlBar
        );
    }

    #[test]
    fn the_executable_is_lower_cased_on_the_way_in() {
        let c = DictationContext::new(Some("WINWORD.EXE".into()), None, FieldKind::MultiLine);
        assert_eq!(c.app_id.as_deref(), Some("winword.exe"));
        assert_eq!(c.key().as_deref(), Some("winword.exe"));
    }

    #[test]
    fn only_distinct_fields_get_their_own_slot() {
        let body = DictationContext::new(Some("outlook.exe".into()), None, FieldKind::MultiLine);
        assert_eq!(body.key().as_deref(), Some("outlook.exe"));
        assert_eq!(body.lookup_keys(), vec!["outlook.exe"]);

        let bar = DictationContext::new(Some("chrome.exe".into()), None, FieldKind::UrlBar);
        assert_eq!(bar.key().as_deref(), Some("chrome.exe#url"));
        // The app-wide lesson still answers for the address bar.
        assert_eq!(bar.lookup_keys(), vec!["chrome.exe#url", "chrome.exe"]);
    }

    #[test]
    fn no_app_means_no_slot() {
        let c = DictationContext::unknown();
        assert!(c.key().is_none());
        assert!(c.lookup_keys().is_empty());
        assert_eq!(c.label(), "anywhere else");
    }

    #[test]
    fn the_label_reads_like_english() {
        let c = DictationContext::new(
            Some("chrome.exe".into()),
            Some("Google Chrome".into()),
            FieldKind::UrlBar,
        );
        assert_eq!(c.label(), "Google Chrome address bar");
    }
}
