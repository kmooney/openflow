# OpenFlow

An open source dictation app you can run yourself, along the lines of Wispr
Flow. Hold a hotkey, speak, let go, and tidied-up text appears at the cursor in
whatever app you are using. MIT licensed.

**Everything runs on your own machine.** Speech recognition is whisper.cpp,
built into the app. The formatting is plain Rust code following fixed rules.
Nothing you say is sent anywhere. The only time OpenFlow uses the network is to
download a speech model the first time. There is no account and no server to set
up.

## Status

The Rust core and all three apps work. The server does not exist yet. It is
written up in `notes/spec.md` as an optional extra for syncing between devices,
and you do not need it to dictate.

| | what it is | state |
|---|---|---|
| `crates/openflow-core` | the formatting rules and the record of what they changed | built |
| `crates/openflow-ffi` | lets the Swift apps call into the core | built |
| `crates/openflow-cli` | `of-fmt`, runs the formatter on text you pipe in | built |
| `clients/macos` | menu bar app, push-to-talk, paste, history | built |
| `clients/ios` | app and keyboard, whisper on the phone | built |
| `clients/windows` | tray app, push-to-talk, paste, history | built |
| server, container, web console | syncing between devices, running your own speech or formatting services | written up only |

## What happens when you dictate

```
hold ⌃⌥ ──► record ──► whisper.cpp ──► formatting ──► check ──► paste
                       (on your        (fixed         (every
                        machine)        rules)         step)
```

The formatter drops "uh" and "um", cleans up repeated words, turns spoken lists
into numbered or bulleted lists, handles spoken quotes and spoken fixes
("scratch that"), and adds punctuation. You pick a tone: formal, casual, or very
casual.

**It cannot make up words.** Every formatting step has to declare each change it
makes, and the app then compares the result against what you actually said. If a
step changed a word it did not declare, that step is thrown out and its input is
used unchanged. The history window lists the changes for everything you dictate,
and *Show Original* shows exactly what you said before formatting.

## Repository layout

```
crates/
  openflow-core/   formatting, cleanup, the record of changes, and the
                   check — all the logic that has to be right, written once
  openflow-ffi/    the bridge the macOS and iOS apps use
  openflow-cli/    of-fmt
clients/
  macos/           the Mac app and its build script
  ios/             the iPhone app, its keyboard, and the Xcode setup
  windows/         its own cargo workspace: egui, WASAPI, Win32
  shared/          the Swift both Apple apps use, and its tests
notes/spec.md      the design, and why each decision went the way it did
```

## Build

**macOS** — see `clients/macos/README.md`.

```sh
cd clients/macos && ./build-macos.sh && open build/OpenFlow.app
```

This builds the Rust core, fetches and builds whisper.cpp, downloads the
`small.en` model, and puts the `.app` together. You will need to give it
Accessibility and Microphone permission before it can do anything.

**iOS** — see `clients/ios/README.md`.

```sh
cd clients/ios && ./build-ios.sh --run     # builds, starts the simulator, runs
```

The `base.en` model is included in the app, so it dictates the first time you
open it with no network. You can download bigger models from inside the app.

**Windows** — needs Visual Studio with the C++ workload. The script finds the
tools itself.

```powershell
cd clients\windows
.\build-windows.ps1                 # Release
.\build-windows.ps1 -Gpu cuda       # optional, needs the CUDA SDK
```

**Just the formatter**, with no audio and no app:

```sh
$ echo "Um, one, buy milk. Two, call mom. Three, book the flight." | cargo run -q -p openflow-cli
{"raw":"...","formatted":"1. Buy milk\n2. Call mom\n3. Book the flight", ...}

$ cargo run -q -p openflow-cli -- --tone casual notes.txt
```

It prints JSON: the formatted text, the tone, a list of what changed and why,
and whether the check passed.

## Tests

```sh
cargo test                          # 60 formatting tests in the core
cd clients && swift test            # macOS and iOS: the joins, not the logic
cd clients/windows && .\build-windows.ps1 -Test
```

The Swift and Windows tests cover the places where the platform code meets the
Rust core: that text makes the trip across the boundary and back, that the tone
and the list of changes survive it, that your custom words reach whisper, and
that recording and the hotkey behave. The formatting rules themselves are tested
in Rust, where they live.

## Privacy

History is a SQLite file on the device. Audio is thrown away after it has been
transcribed, unless you turn *Keep audio* on. Deleting really deletes: the row
goes, the audio file is removed, and nothing is left holding on to the text.
