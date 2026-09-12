import SwiftUI
import OpenFlowKit

/// The two word lists, which are opposite ends of the same pipeline.
///
/// Vocabulary is given to whisper *before* it listens, so it changes what gets
/// heard — "Siobhan" instead of "Shivonne". The dictionary runs at the very end,
/// after the polish model, and rewrites what was written — "my email" into the
/// address, exactly as typed. Keeping them on one screen makes the difference
/// visible; keeping them in separate files keeps each one editable by hand.
struct WordsView: View {
    @ObservedObject var vocabulary: WordListStore
    @ObservedObject var dictionary: WordListStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        Editor(store: vocabulary, title: "Vocabulary",
                               footer: "One term per line. These are handed to the speech model before it listens, so they bias what it hears.")
                    } label: {
                        LabeledContent("Vocabulary", value: count(vocabulary.terms.count, "term"))
                    }
                } footer: {
                    Text("Names, places and jargon whisper would otherwise guess at.")
                }

                Section {
                    NavigationLink {
                        Editor(store: dictionary, title: "Dictionary",
                               footer: "One entry per line: phrase = replacement. The replacement is inserted exactly as written; \\n makes a line break.")
                    } label: {
                        LabeledContent("Dictionary",
                                       value: count(dictionary.shortcuts.count, "shortcut"))
                    }
                    ForEach(dictionary.shortcuts.prefix(6), id: \.phrase) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.phrase).font(.callout)
                            Text(entry.replacement.replacingOccurrences(of: "\n", with: " ⏎ "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } footer: {
                    Text("Say the phrase, get the text. Applied last, after the polish model — so what you typed is what gets pasted.")
                }
            }
            .navigationTitle("Words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    /// The file itself. A text view rather than a row-per-entry form: the file
    /// is the interface on every other platform, and a person who keeps their
    /// vocabulary in a dotfile should be able to paste it in whole.
    private struct Editor: View {
        @ObservedObject var store: WordListStore
        let title: String
        let footer: String

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $store.text)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
                Divider()
                Text(footer)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(12)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // The debounce has not necessarily fired when the view goes away.
            .onDisappear { store.save() }
        }
    }
}
