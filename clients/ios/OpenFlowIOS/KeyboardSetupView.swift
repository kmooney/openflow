import SwiftUI
import UIKit

/// Explains the one permission OpenFlow's keyboard needs.
///
/// "Allow Full Access" is Apple's wording and it means nothing to anyone who
/// has not read the developer documentation — it sounds like handing a keyboard
/// the run of your phone. Worth a whole screen, because a greyed-out key with a
/// jargon label is exactly where people give up.
struct KeyboardSetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, "Open Settings", "General → Keyboard → Keyboards")
                    step(2, "Add OpenFlow", "Tap “Add New Keyboard…” and choose OpenFlow")
                    step(3, "Tap OpenFlow in that list", "Then turn on Allow Full Access")
                }

                Section("What Allow Full Access actually does") {
                    row("arrow.left.arrow.right", .blue,
                        "Lets the keyboard read the text your dictation produced. That text passes between the OpenFlow app and its keyboard, and nowhere else.")
                    row("lock.shield", .green,
                        "Your speech is transcribed on this device. Nothing is uploaded — with or without this permission.")
                    row("exclamationmark.triangle", .orange,
                        "Without it, iOS blocks the keyboard from reaching the app at all, so the microphone key cannot work.")
                }

                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                    }
                } footer: {
                    Text("Settings opens on OpenFlow. Tap Keyboards from there.")
                }
            }
            .navigationTitle("Set up the keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func row(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}
