# OpenFlow for iOS

Two targets, and the split is forced by the platform rather than chosen:

| target | what it does |
|---|---|
| **OpenFlow** (app) | microphone, whisper, formatting, history — everything |
| **OpenFlowKeyboard** | a *Finish* key and a text sink |

**A keyboard extension cannot use the microphone.** That is an Apple rule, not
a difficulty, and extensions additionally run under a memory ceiling far below
what a Whisper model needs. So the keyboard never records: the app does, and
the finished text is handed back through a shared App Group container.

It cannot start the app's recording either — that was measured, not assumed,
and the evidence is below. Dictation begins in the app; the keyboard ends it
and inserts the result.

## The handoff

```
app: you tap the mic → record → transcribe → format
                                        │
                                  writes pending.json to the App Group
                                        │
                                  posts a Darwin notification
                                        ▼
keyboard: on next appearance, take() the text and insertText()
```

**Dictation starts in the app, not from the keyboard.** That is forced by the
platform and was measured rather than assumed — see *Why the keyboard cannot
start dictation* below. The keyboard ends a recording that is already running
and inserts the result; it never begins one.

`take()` is one-shot — reading deletes — because inserting the same sentence
twice into someone's message is a worse failure than missing it once. Offers
older than three minutes are discarded rather than pasted into whatever the
user happens to be typing later.

Insertion happens **every time the keyboard appears**, not only on the
notification. The normal path is the user switching back by hand, and no
notification is delivered then.

## Why the keyboard cannot start dictation

A keyboard extension cannot use the microphone, which is why the app does the
recording. The obvious repair — have the keyboard ask the app to start — does
not work either, and the reason is worth writing down because every part of it
looks solvable until it is tested.

**The keyboard cannot open its containing app.** `extensionContext.open`
returns false, and the undocumented responder-chain `openURL:` walk that
several shipping keyboards rely on finds a responder, calls it, and does
nothing. Both were measured on iOS 26.

**The app cannot be driven from the background either.** It can be kept alive
(a silent looping `AVAudioPlayer` under the `audio` background mode) and it
does receive the Darwin notification — but it cannot then start capturing:

| what was tried | result |
|---|---|
| `setActive(true)` from the background | OSStatus 560557684 `'!int'`, *cannot interrupt others* |
| the same with `.mixWithOthers` | same |
| session established in the foreground and merely *held*, recorder touching nothing | `AVAudioEngine.start()` fails, 2003329396 `'what'` |
| the same with an exclusive (non-mixable) session | same |

At the point of that last failure the session was `.playAndRecord` /
`.measurement`, active, with `inputAvailable=1`, one routed input and a valid
48 kHz mono format. The microphone is *there*; iOS simply will not let a
backgrounded app begin capturing with it. An app may continue a recording it
already had, which is not the same thing.

The only design that would evade this keeps the audio graph running
permanently so nothing ever starts in the background — at the cost of the
microphone indicator being lit whenever the app is resident, and the app
genuinely capturing all the time. That is not a trade worth making for a
dictation app, so the keyboard tells the truth instead.

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
3. Open OpenFlow and tap its microphone to start recording.
4. **Switch to whatever you are typing into.** Recording keeps going — the app
   declares the `audio` background mode for exactly this.
5. Bring up the OpenFlow keyboard. Its key now reads **Finish**.
6. Tap it. The app transcribes in the background and the text is inserted where
   your cursor is.

Step 6 is the point: you never have to go *back* to OpenFlow to end a recording
or to collect the result. Starting one is the only thing that has to happen
there.

## Before it runs on a device

1. Set your development team on **both** targets in Signing & Capabilities.
2. Keep the App Group `group.dev.openflow` on **both**. A mismatch silently
   breaks the handoff — the container just resolves to nil.
3. Settings → General → Keyboard → Keyboards → add OpenFlow, then enable
   **Allow Full Access**. Without it the keyboard cannot read the App Group
   container, which is the whole mechanism.

## Known constraint

The keyboard's key still *attempts* both routes to open the app, because they
cost nothing and the rule has moved between releases before. Neither is
allowed to report success: an earlier version said "Opening OpenFlow…" the
instant the responder chain accepted the selector, which was indistinguishable
from success while the screen sat unchanged.

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
