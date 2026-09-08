# OpenFlow clients

```
Sources/
  OpenFlowKit/    shared — audio, whisper, formatting, history.  macOS + iOS
  OpenFlowMac/    macOS only — hotkey, paste, menu bar
  CWhisper/       whisper.cpp C API
  COpenFlow/      C ABI over the Rust core
```

**Everything that isn't platform-shaped lives in OpenFlowKit**, so the iOS app
(M4) reuses it whole. The macOS target is deliberately thin — four files, none
of which contain dictation logic. If something needs `AppKit`, it belongs in
`OpenFlowMac`; if it doesn't, it belongs in the Kit.

The logic that has to be *correct* — formatting, normalization, the edit
ledger — is further down still, in Rust (`crates/openflow-core`), written once
and shared by every client and eventually the server.

## Build and run

```sh
./build-macos.sh
open build/OpenFlow.app
```

The script builds the Rust core, builds whisper.cpp statically if needed,
compiles the Swift, assembles the `.app`, and links a model from `m0/` into
`~/Library/Application Support/OpenFlow/models/` so the first run is instant.


## Using it

**Hold ⌃⌥, speak, release.** The text is transcribed, formatted, and pasted
into whatever has focus.

**The window** (menu bar → Open OpenFlow, or ⌘O) shows words spoken, a Listen
button, and the full history: search it, copy any entry, delete entries one at a
time or all at once. Closing the window leaves the app running in the menu bar;
reopen from the same menu item.

**Tone follows where you are dictating.** An address bar gets *very casual*,
Mail gets *formal*, Slack gets *casual*. Picking a register is what teaches it:
whatever you choose is remembered for the app — and for the address or search
field specifically, which is the one field whose register differs from the app
around it. The list button beside the picker shows everything remembered, and
lets you change or delete any of it. Nothing is learned while you dictate with
the Listen button, which has no destination to attribute a choice to.

Two details that matter:

- **Listen copies rather than pastes.** When you press it the window has focus,
  so pasting would put the text into OpenFlow itself. The hotkey pastes; the
  button copies.
- **History rows show the ledger** — every word the formatter changed and why —
  and right-click offers *Show Original* to see exactly what you said before any
  formatting.
- **Every recording gets a row**, including ones that produced nothing. Those
  are the ones worth listening back to; turn on *Keep audio* and they get a play
  button.

## Noisy places

Three layers, and the third is the one that matters: Apple's voice-processing
unit (AEC + noise suppression + AGC), a 4th-order high-pass at 85 Hz for rumble,
and a check that refuses to transcribe obvious non-speech — whisper will
otherwise invent fluent sentences out of engine noise.

The gate is deliberately **permissive**: anything clearly audible is transcribed
regardless of dynamics, because AGC flattens exactly the dynamic range a strict
test keys on, and losing something you actually said is worse than a
hallucination you can see and delete. Measured on real recordings: clean speech
shows a 90th/10th percentile energy ratio of 3–11; the gate only rejects below
0.006 RMS, or between 0.006 and 0.030 with a ratio under 1.5.

## Permissions

Three, and the app is useless without the first two:

| permission | why |
|---|---|
| Accessibility | see the hotkey chord, and synthesize ⌘V to paste |
| Microphone | hear you |
| Input Monitoring | may be requested alongside Accessibility |

The app asks for Accessibility only when it genuinely lacks it: it tries to
install the event tap first and treats *that* as the answer, rather than trusting
`AXIsProcessTrusted()`. Once you grant it, the hotkey starts working within a
second — no relaunch.

**If it re-asks after every rebuild**, that is the ad-hoc signature: macOS keys
the grant to the code signature, and ad-hoc signatures change with the binary.
To stop it, create a stable self-signed certificate once —

> Keychain Access → Certificate Assistant → **Create a Certificate…**
> Name: `OpenFlow Dev` · Identity Type: Self Signed Root · Certificate Type:
> **Code Signing**

`build-macos.sh` picks it up automatically from then on, and the grant persists
across rebuilds.

## Tests

```sh
swift test                          # 9 interop tests
cargo test -p openflow-core         # 60 formatting tests
```

The Swift tests deliberately cover **seams, not logic**: that the FFI round
trips, that tone and the ledger survive the boundary, that whisper transcribes
through the wrapper, that vocabulary biasing actually reaches whisper, and that
the store counts spoken words. The formatting rules themselves are tested in
Rust, where they live.
