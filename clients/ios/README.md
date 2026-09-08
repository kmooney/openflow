# OpenFlow for iOS

Three targets, and the split is forced by the platform rather than chosen:

| target | what it does |
|---|---|
| **OpenFlow** (app) | microphone, whisper, formatting, history — everything |
| **OpenFlowKeyboard** | starts and finishes recordings, and inserts the text |
| **OpenFlowActivity** | the Dynamic Island / lock-screen readout |

**A keyboard extension cannot use the microphone.** That is an Apple rule, not
a difficulty, and extensions additionally run under a memory ceiling far below
what a Whisper model needs. So the keyboard never records: the app does, and
the finished text is handed back through a shared App Group container.

## The session

The one idea everything else follows from.

**The app opens the microphone once and holds it open.** Not per recording —
once, in the foreground, when the user taps *Start*. From then on the audio
graph runs continuously: buffers arrive, and a flag decides whether they are
kept or thrown away.

```
tap Start (in the app, foreground)
        │  microphone opens, indicator lights, Live Activity appears
        ▼
   ┌─ session ──────────────────────────────────────────────┐
   │                                                        │
   │   recording ⇄ open        recording ⇄ open        …    │  ← from the keyboard,
   │       │                       │                        │    in any other app
   │   transcribe + insert     transcribe + insert          │
   └────────────────────────────────────────────────────────┘
        │  tap Close mic (on the keyboard)
        ▼
   microphone closed, indicator out
```

That is what makes the keyboard's microphone key work. iOS forbids a
backgrounded app from **beginning** capture; it has never forbidden one from
**continuing**. Starting a recording inside a live session touches no CoreAudio
object at all — it flips a boolean the audio tap reads — so nothing the system
would refuse ever happens.

### The price, stated plainly

The system recording indicator is lit for the whole session, and the app really
is holding the microphone for all of it. Audio outside a recording is discarded
on arrival and never reaches disk, memory, or a model — but the microphone is
genuinely open, and pretending otherwise would be a lie the indicator would
immediately expose.

This is the trade. It is why *Close mic* sits on the keyboard — the surface you
are actually looking at once the session is running — why the Live Activity says
which state the session is in rather than merely that something is happening,
and why the session is never opened without an explicit tap.

An earlier revision of this file called that trade "not worth making" and had
dictation begin in the app every time. It is the trade Wispr Flow makes, it is
the only arrangement in which a keyboard can start a recording, and the cost is
visible rather than hidden — so it is the one this now makes.

## What the platform actually forbids

Worth writing down, because every part of it looks solvable until it is tested,
and because the shape of the session above is a direct consequence.

**The keyboard cannot open its containing app.** `extensionContext.open`
returns false, and the undocumented responder-chain `openURL:` walk that
several shipping keyboards rely on finds a responder, calls it, and does
nothing. Both were measured on iOS 26.

**A backgrounded app cannot start capturing.** It can be kept alive under the
`audio` background mode and it does receive Darwin notifications, but:

| what was tried | result |
|---|---|
| `setActive(true)` from the background | OSStatus 560557684 `'!int'`, *cannot interrupt others* |
| the same with `.mixWithOthers` | same |
| session established in the foreground and merely *held*, recorder touching nothing | `AVAudioEngine.start()` fails, 2003329396 `'what'` |
| the same with an exclusive (non-mixable) session | same |

Note the third row: holding an *inactive* graph is not enough. The engine has
to already be **running**, which is why the tap is installed and started at
`Start` and stays that way, discarding buffers between recordings, rather than
being started on demand.

**Deactivating is fine from the background.** Only starting is refused, which is
why *Close mic* works from the keyboard and *Start* does not.

## The handoff

```
keyboard: tap mic  ──── Darwin: dev.openflow.start ───▶  app: keep the buffers
keyboard: tap ✓    ──── Darwin: dev.openflow.stop  ───▶  app: transcribe, format
                                                              │
                                                        writes pending.json
                                                              │
                        ◀─── Darwin: dev.openflow.transcript ─┘
keyboard: take() and insertText()
```

`session.json` in the App Group carries the two facts the keyboard needs, and
they are deliberately two rather than one:

- **live** — the graph is running. The keyboard may start a recording.
- **recording** — buffers are being kept. The keyboard may finish one.

Plus a **heartbeat**, rewritten every five seconds while the session is open. A
killed app leaves that file behind saying "microphone open" forever; a
timestamp older than 20 seconds reads as closed, so the keyboard offers to open
the app instead of offering a key that can never work.

Elapsed time crosses as a **start date**, never as a number of seconds. The app
is in the background whenever the count matters and cannot be relied on to
tick — the keyboard and the Live Activity each run their own timer from the
origin.

`take()` is one-shot — reading deletes — because inserting the same sentence
twice into someone's message is a worse failure than missing it once. Offers
older than three minutes are discarded rather than pasted into whatever the
user happens to be typing later.

Insertion happens **every time the keyboard appears**, not only on the
notification, because the user may switch back by hand.

## Surviving a long session

A session held open for eight seconds meets nothing. One held open for twenty
minutes meets phone calls, Bluetooth headsets arriving, and `audiod`
restarting — each of which kills the graph silently, and a dead graph is
indistinguishable from a quiet room by the time anyone notices.

So `AudioRecorder` observes the three that matter — `interruptionNotification`,
`AVAudioEngineConfigurationChange`, and `mediaServicesWereResetNotification` —
and rebuilds in place against the still-active session. When it cannot (a
resume attempted from the background is refused like any other start), the
session is marked closed, the Live Activity ends, and the keyboard goes back to
saying *Open OpenFlow*. What it must never do is keep claiming a microphone it
no longer has.

An interruption mid-recording keeps whatever was captured before it. That audio
is still worth transcribing.

## The notch

`OpenFlowActivity` is a WidgetKit extension holding one Live Activity. iOS's own
recording indicator is a coloured dot: it cannot say which app, whether a
recording is running or merely possible, or how long you have been talking. All
three matter when the session outlives the app's time on screen.

The compact trailing view is the seconds counter. It is a
`Text(timerInterval:)` — given a start date it counts on its own, with no
update from the backgrounded app.

If the user has Live Activities switched off, everything still works; the
session simply stops narrating itself.

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

Use an iPhone 14 Pro or later simulator if you want to see the Dynamic Island;
on other models the Live Activity appears on the lock screen only.

### Trying the keyboard

1. In the simulator: **Settings → General → Keyboard → Keyboards → Add New
   Keyboard → OpenFlow**.
2. Tap **OpenFlow** in that list and turn on **Allow Full Access**. Without it
   the App Group container is unreachable and nothing will ever be inserted.
3. Open OpenFlow and tap **Start**. The microphone opens and recording begins;
   the indicator lights and the Live Activity appears.
4. **Switch to whatever you are typing into.** The app tells you to swipe right
   along the bottom edge, because that is a system gesture and no button can
   stand in for it.
5. Bring up the OpenFlow keyboard. Its key reads **Insert** with a running
   seconds count.
6. Tap it. The text is inserted where your cursor is — and the key immediately
   reads **Speak** again, because the microphone never closed.
7. Repeat 6 as long as you like. The keyboard carries the other two actions:
   **✕** discards a recording, **mic-slash** closes the session.

Steps 6 and 7 are the point: after the first tap of *Start*, you never go back
to the app. That is also why discard and close live on the keyboard and not in
the app — by the time you want either, you are somewhere else, and a button on
a screen you are not looking at is not a button.

## Before it runs on a device

1. Set your development team on **all three** targets in Signing &
   Capabilities.
2. Keep the App Group `group.dev.openflow` on the **app and the keyboard**. A
   mismatch silently breaks the handoff — the container just resolves to nil.
   The activity extension does not need it.
3. Settings → General → Keyboard → Keyboards → add OpenFlow, then enable
   **Allow Full Access**. Without it the keyboard cannot read the App Group
   container, which is the whole mechanism.

## Getting back to the app

A keyboard cannot launch its containing app: `extensionContext.open` returns
false and the responder-chain `openURL:` walk does nothing, both measured on
iOS 26. Both are still attempted, because they cost nothing and the rule has
moved before, and neither is allowed to report success.

The route that works is a **local notification**. The keyboard posts one, the
banner belongs to the app, and tapping it launches the app — which opens the
microphone on arrival without being asked. Two taps rather than one, against a
key that previously did nothing at all.

Only needed when the app is not running. Once a session is open the keyboard
never needs it again.

## TestFlight

Needs a paid Apple Developer Program membership ($99/yr) — free accounts cannot
distribute.

**Once, in the Apple Developer portal** (or let Xcode create them with
`-allowProvisioningUpdates`, which `release-ios.sh` passes):

- App IDs `dev.openflow.ios`, `dev.openflow.ios.keyboard` and
  `dev.openflow.ios.activity`
- An App Group `group.dev.openflow`, enabled on the first **two**
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

**A microphone held open in the background will draw more.** The honest
statement, which is also the accurate one: the session is opened only by an
explicit tap in the foreground; the recording indicator is lit for its entire
duration; a Live Activity states continuously whether audio is being kept; the
session can be ended from the keyboard without returning to the app; and audio
captured outside a recording is discarded on arrival and never written, sent,
or transcribed.

Export compliance is pre-answered in the plist
(`ITSAppUsesNonExemptEncryption: false`) — the only network traffic is HTTPS
model downloads, which is exempt.

### Size

The `.ipa` is ~150 MB because the model ships inside it. That is under every
App Store limit, but it is a large download on cellular; the in-app model
picker is what lets people add the bigger models on their own terms.
