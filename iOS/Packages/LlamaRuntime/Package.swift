// swift-tools-version: 6.0
import PackageDescription

// Pinned upstream release. Updating requires verifying the published SHA-256
// and compiling the unsigned iPhone build before changing this reference.
let package = Package(
    name: "LlamaRuntime",
    platforms: [.iOS(.v18)],
    products: [.library(name: "LlamaRuntime", targets: ["LlamaFramework"])],
    targets: [
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11155/llama-b11155-xcframework.zip",
            checksum: "1f157b625fe298aba099572a90aade102a1de31769ddfeff0e08330fb1296979"
        )
    ]
)
