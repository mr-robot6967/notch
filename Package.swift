// swift-tools-version: 5.10
import PackageDescription
import Foundation

// Command Line Tools ship swift-testing macros outside the default search path.
let testingPluginCandidates = [
    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib",
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
]
let testSwiftSettings: [SwiftSetting] = {
    for path in testingPluginCandidates where FileManager.default.fileExists(atPath: path) {
        return [.unsafeFlags(["-load-plugin-library", path])]
    }
    return []
}()

let package = Package(
    name: "LockWidgets",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LockWidgets", targets: ["LockWidgets"])
    ],
    targets: [
        .target(name: "LockWidgetsCore", path: "Sources/LockWidgetsCore"),
        .executableTarget(
            name: "LockWidgets",
            dependencies: ["LockWidgetsCore"],
            path: "Sources/LockWidgets",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOBluetooth")
            ]
        ),
        .testTarget(
            name: "LockWidgetsCoreTests",
            dependencies: ["LockWidgetsCore"],
            path: "Tests/LockWidgetsCoreTests",
            swiftSettings: testSwiftSettings
        )
    ]
)
