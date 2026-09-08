# OpenFlow

An open source, self-hostable dictation app in the spirit of Wispr Flow. Hold a
hotkey, speak, release; cleaned-up text appears at the cursor in whatever app
has focus. MIT licensed.

**Inference runs on your machine.** Speech recognition is whisper.cpp, compiled
into the client; formatting is deterministic Rust. Nothing is sent anywhere, and
the only network traffic is downloading a model the first time. There is no
account, no container, and no server to stand up.

## Status

The Rust core and three clients are built. The server, and with it the
"spin up an instance" story, is not — it is designed in `notes/spec.md` as a
*fallback and sync point*, not something you need to dictate.

| | what it is | state |
|---|---|---|
| `crates/openflow-core` | formatting rules, normalization, the edit ledger | built |
| `crates/openflow-ffi` | C ABI over the core, for the Swift clients | built |
| `crates/openflow-cli` | `of-fmt` — the formatter over stdin, for testing | built |
| `clients/` macOS | menu bar app, push-to-talk, paste, history | built |
| `clients/ios` | app + keyboard extension, on-device whisper | built |
| `clients/windows` | tray app, push-to-talk, paste, history | built |
| server, container, web console | paired mode, cross-device history, BYO drivers | spec only |

## How a dictation goes

```
hold ⌃⌥ ──► capture ──► whisper.cpp ──► format chain ──► guardrail ──► paste
                        (on device)     (deterministic)   (per stage)
```

The formatter removes "uh" and "um", collapses stutters, turns spoken
enumerations into numbered and bulleted lists, handles spoken quotes and
corrections ("scratch that"), and applies punctuation and a register — formal,
casual, or very casual — to what you said.

**It cannot invent words.** Every change a stage makes is declared in an edit
ledger, and the host — not the driver — checks the output against the input
before anything reaches your cursor. A stage that changed a word it did not
declare is skipped, and its input passes through untouched. The history window
shows the ledger for every utterance, and *Show Original* shows exactly what you
said before formatting.

## Repository layout

```
crates/
  openflow-core/   formatting, normalization, ledger, guardrail — all the
                   logic that has to be correct, written once
  openflow-ffi/    C ABI consumed by macOS and iOS
  openflow-cli/    of-fmt
clients/
  Sources/         Swift: OpenFlowKit (shared), OpenFlowMac, OpenFlowIOS,
                   OpenFlowKeyboard
  ios/             Xcode project generation, build and release scripts
  windows/         its own cargo workspace — egui, WASAPI, Win32
notes/spec.md      the design, and why each decision went the way it did
```

## Build

**macOS** — see `clients/README.md`.

```sh
cd clients && ./build-macos.sh && open build/OpenFlow.app
```

Builds the Rust core, fetches and statically builds whisper.cpp, downloads
`small.en`, and assembles the `.app`. Needs Accessibility and Microphone
permissions to be useful.

**iOS** — see `clients/ios/README.md`.

```sh
cd clients/ios && ./build-ios.sh --run     # builds, boots the simulator, runs
```

Ships `base.en` inside the bundle so it dictates on first launch with no
network. Bigger models are downloadable in the app.

**Windows** — needs Visual Studio with the C++ workload; the script finds the
toolchain itself.

```powershell
cd clients\windows
.\build-windows.ps1                 # Release
.\build-windows.ps1 -Gpu cuda       # optional, needs the CUDA SDK
```

**The formatter alone**, no audio, no client:

```sh
$ echo "Um, one, buy milk. Two, call mom. Three, book the flight." | cargo run -q -p openflow-cli
{"raw":"...","formatted":"1. Buy milk\n2. Call mom\n3. Book the flight", ...}

$ cargo run -q -p openflow-cli -- --tone casual notes.txt
```

JSON out: the formatted text, the tone, the ledger of what changed and why, and
whether the guardrail passed.

## Tests

```sh
cargo test                          # 60 formatting tests in the core
swift test                          # macOS/iOS Kit: seams, not logic
cd clients/windows && .\build-windows.ps1 -Test
```

The Swift and Windows suites cover the platform seams — that the FFI round
trips, that tone and the ledger survive the boundary, that vocabulary biasing
reaches whisper, that capture and the chord behave. The formatting rules
themselves are tested in Rust, where they live.

## Privacy

History is SQLite on the device. Audio is discarded after transcription unless
you turn *Keep audio* on. Delete means delete — the row goes, the audio blob is
unlinked, and there is no tombstone holding the text.
