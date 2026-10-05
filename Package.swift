// swift-tools-version: 6.0
//
// Orbit is built with SwiftPM. Use the wrappers in Scripts/ instead of calling
// `swift` directly: they apply workarounds needed on machines that only have the
// Command Line Tools (see docs/development.md).
//
//   Scripts/swiftpm.sh build            # compile everything
//   Scripts/swiftpm.sh test             # run the unit tests (Swift Testing)
//   Scripts/build-app.sh [debug|release] # assemble and sign build/<config>/Orbit.app

import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Orbit", targets: ["Orbit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
    ],
    targets: [
        // The app itself. Resources (AppleScripts, String Catalogs, icon) are not
        // SwiftPM resources: Scripts/build-app.sh copies them into Orbit.app so the
        // code can use Bundle.main exactly like an Xcode-built app would.
        .executableTarget(
            name: "Orbit",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Orbit",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "OrbitTests",
            dependencies: ["Orbit"],
            path: "OrbitTests",
            exclude: ["Fixtures"]
        ),

        // Developer tools, never shipped inside Orbit.app.
        .executableTarget(name: "FakeLLMServer", path: "DevTools/FakeLLMServer"),
        .executableTarget(name: "orbitctl", path: "DevTools/orbitctl"),
        .executableTarget(name: "OrbitStrings", path: "DevTools/OrbitStrings"),
    ],
    swiftLanguageModes: [.v6]
)
