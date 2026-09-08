# OpenFlow for iOS

Two targets, and the split is forced by the platform rather than chosen:

| target | what it does |
|---|---|
| **OpenFlow** (app) | microphone, whisper, formatting, history — everything |
| **OpenFlowKeyboard** | a microphone *button* and a text sink |

**A keyboard extension cannot use the microphone.** That is an Apple rule, not
a difficulty, and extensions additionally run under a memory ceiling far below
what a Whisper model needs. So the keyboard never records: it opens the app, the
app transcribes, and the finished text is handed back through a shared App Group
container.

## The handoff

```
keyboard: mic key ──URL scheme──► app: record → transcribe → format
                                        │
                                  writes pending.json to the App Group
                                        │
                                  posts a Darwin notification
                                        ▼
keyboard: on next appearance, take() the text and insertText()
```

`take()` is one-shot — reading deletes — because inserting the same sentence
twice into someone's message is a worse failure than missing it once. Offers
older than three minutes are discarded rather than pasted into whatever the
user happens to be typing later.

Insertion happens **every time the keyboard appears**, not only on the
notification. The normal path is the user switching back by hand, and no
notification is delivered then.

## The model ships in the app

`build-ios.sh` copies `ggml-base.en.bin` into the bundle, so the app dictates on
first launch with no network. Downloading on first run would mean a dictation
app that cannot dictate until it has fetched 141 MB — broken on a plane, which
is exactly where this gets used.

**base.en, not small.en**, and this is a genuine trade rather than a default.
M0 measured base.en substituting words rather than admitting uncertainty (it
turned "uh" into "that"), which is why small.en is the macOS default. On a phone
the calculus differs: 141 MB against 466 MB is the difference between a download
people accept and one they abandon, and vocabulary biasing (spec §5.2) recovers
most of what base.en gives up on the proper nouns that matter.

Expect noticeably worse transcription than the Mac — **and you can fix that in
the app.** Tap the waveform button: every model in the catalogue can be
downloaded, selected, and deleted, with its real size and an honest note about
the trade. Small (English) is the one to fetch if names matter.

The bundled model can never be deleted, so the app always has something to fall
back on; deleting the active model moves the selection rather than stranding it
on a missing file.

## Build

```sh
./build-ios.sh          # frameworks, project, build
open OpenFlowIOS.xcodeproj
```

`project.yml` is the source of truth; the `.xcodeproj` is generated and should
not be edited or committed.

## Testing in the simulator

```sh
./build-ios.sh --run          # builds, boots, installs, launches
```

Two things behave differently there:

- **The microphone is your Mac's.** macOS asks *Simulator* for permission the
  first time you record, not the app.
- **Whisper runs on the CPU.** The simulator's Metal support is not what ggml
  expects, so the GPU is disabled there deliberately — transcription is much
  slower than on a phone. Use it to check behaviour, never to judge speed.

### Trying the keyboard

1. In the simulator: **Settings → General → Keyboard → Keyboards → Add New
   Keyboard → OpenFlow**.
2. Tap **OpenFlow** in that list and turn on **Allow Full Access**. Without it
   the App Group container is unreachable and nothing will ever be inserted.
3. Open Notes, tap a text field, and press 🌐 until the OpenFlow keyboard shows.
4. Tap the microphone. The app opens and starts recording.
5. **Switch straight back to Notes.** Recording keeps going — the app declares
   the `audio` background mode for exactly this.
6. Tap the keyboard's key again (it now reads **Finish**). The app transcribes
   in the background and the text is inserted where your cursor is.

Step 6 is the whole point: you never have to go back to OpenFlow to end a
recording. If you do return to the app, its own button works the same way, and
the keyboard picks the text up whenever it next appears.

## Before it runs on a device

1. Set your development team on **both** targets in Signing & Capabilities.
2. Keep the App Group `group.dev.openflow` on **both**. A mismatch silently
   breaks the handoff — the container just resolves to nil.
3. Settings → General → Keyboard → Keyboards → add OpenFlow, then enable
   **Allow Full Access**. Without it the keyboard cannot read the App Group
   container, which is the whole mechanism.

## Known constraint

Opening the app from the keyboard walks the responder chain looking for
`openURL:`, because an extension has no `UIApplication`. Several shipping
dictation keyboards do this, but it is not documented API and could stop
working. The failure is visible rather than silent, and the user can always
open the app by hand — the pending text is picked up either way.

## TestFlight

Needs a paid Apple Developer Program membership ($99/yr) — free accounts cannot
distribute.

**Once, in the Apple Developer portal** (or let Xcode create them with
`-allowProvisioningUpdates`, which `release-ios.sh` passes):

- App IDs `dev.openflow.ios` and `dev.openflow.ios.keyboard`
- An App Group `group.dev.openflow`, enabled on **both** App IDs
- App Services on the app ID: nothing beyond the App Group

**Once, in App Store Connect:** create the app record with bundle id
`dev.openflow.ios`.

**Then, each build:**

```sh
TEAM_ID=ABCDE12345 ./release-ios.sh                      # archive + .ipa
TEAM_ID=... ASC_KEY_ID=... ASC_ISSUER_ID=... \
  ./release-ios.sh --upload                              # and upload
```

The API key comes from App Store Connect → Users and Access → Integrations, and
the `.p8` belongs in `~/.appstoreconnect/private_keys/`. Without `--upload` you
get an `.ipa` and can drag it into Transporter, or open the archive in Xcode's
Organizer.

Build numbers are stamped from the timestamp, because TestFlight rejects a build
number it has already seen.

### What review will ask about

A keyboard requesting **Full Access** draws scrutiny, so put this in the App
Review notes: OpenFlow uses Full Access solely to read a transcript the
containing app wrote to a shared App Group container. Nothing is transmitted;
transcription happens on device. That is true, and it is the whole reason the
permission is needed.

Export compliance is pre-answered in the plist
(`ITSAppUsesNonExemptEncryption: false`) — the only network traffic is HTTPS
model downloads, which is exempt.

### Size

The `.ipa` is ~150 MB because the model ships inside it. That is under every
App Store limit, but it is a large download on cellular; the in-app model
picker is what lets people add the bigger models on their own terms.
