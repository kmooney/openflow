// swift-tools-version:5.9
import PackageDescription

// Static libraries produced by `cargo build --release` and the whisper.cpp
// static build. Absolute paths keep this buildable without an Xcode project;
// build-macos.sh regenerates them if the checkout moves.
let whisperLib = "/Users/kevin/Projects/openflow/m0/whisper.cpp/build-static"
let rustLib = "/Users/kevin/Projects/openflow/target/release"

let package = Package(
    name: "OpenFlow",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OpenFlowKit", targets: ["OpenFlowKit"]),
        .executable(name: "OpenFlowMac", targets: ["OpenFlowMac"]),
    ],
    targets: [
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .systemLibrary(name: "COpenFlow", path: "Sources/COpenFlow"),

        // Everything both platforms share: capture, inference, formatting,
        // history. No macOS-only API may appear here.
        .target(
            name: "OpenFlowKit",
            dependencies: ["CWhisper", "COpenFlow"],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(whisperLib)/src", "-L\(whisperLib)/ggml/src",
                    "-L\(whisperLib)/ggml/src/ggml-metal",
                    "-L\(whisperLib)/ggml/src/ggml-blas",
                    "-L\(rustLib)",
                ]),
                .linkedLibrary("whisper"), .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"), .linkedLibrary("ggml-cpu"),
                .linkedLibrary("ggml-metal"), .linkedLibrary("ggml-blas"),
                .linkedLibrary("openflow_ffi"), .linkedLibrary("sqlite3"),
                .linkedLibrary("c++"),   // whisper.cpp is C++
                .linkedFramework("Accelerate"), .linkedFramework("Metal"),
                .linkedFramework("MetalKit"), .linkedFramework("Foundation"),
                .linkedFramework("AVFoundation"), .linkedFramework("CoreML"),
            ]
        ),

        .testTarget(name: "OpenFlowKitTests", dependencies: ["OpenFlowKit"]),

        // The macOS shell: hotkey, paste, menu bar. Thin by design.
        .executableTarget(
            name: "OpenFlowMac",
            dependencies: ["OpenFlowKit"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon")]
        ),
    ]
)
