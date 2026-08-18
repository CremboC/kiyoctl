// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "kiyoctl",
    // kIOMainPortDefault landed in macOS 12; nothing here needs anything newer.
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "kiyoctl", targets: ["kiyoctl"]),
        // Exposed so a menu-bar app can link the same protocol and transport
        // layer without going through the CLI.
        .library(name: "KiyoKit", targets: ["KiyoKit"]),
    ],
    targets: [
        // The entire platform-specific surface: IOKit device discovery,
        // descriptor parsing and control transfers.
        .target(
            name: "CKiyoUSB",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]),
        .target(name: "KiyoKit", dependencies: ["CKiyoUSB"]),
        .executableTarget(name: "kiyoctl", dependencies: ["KiyoKit"]),
        .testTarget(name: "KiyoKitTests", dependencies: ["KiyoKit"]),
    ],
    swiftLanguageModes: [.v5])
