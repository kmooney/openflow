# OpenFlow clients

```
macos/     the Mac app, and the script that builds it
ios/       the iPhone app, its keyboard, and the Xcode project setup
windows/   the Windows app, its own cargo workspace
shared/    the Swift both Apple apps use, and its tests
```

`Package.swift` sits here rather than inside `macos/` because SwiftPM will not
take a target path outside the package root, and the package covers `macos/`
and `shared/` both. Run `swift build` and `swift test` from this directory.

**Everything that is not platform-shaped lives in `shared/OpenFlowKit`** —
audio, whisper, formatting, history — so the iOS app reuses it whole. The
platform folders hold only what needs the platform: hotkeys, pasting, windows.
If something needs `AppKit`, it belongs in `macos/`; if it doesn't, it belongs
in the Kit.

Windows is Rust rather than Swift and does not share the Kit. It follows the
same split internally: `src/kit/` is the shared-shaped half, `src/win/` is the
platform half.

The logic that has to be *right* — formatting, cleanup, the record of what
changed — is further down still, in Rust (`crates/openflow-core`), written once
and shared by every client.

Per-platform detail: [macos/README.md](macos/README.md) ·
[ios/README.md](ios/README.md)
