// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Command Line Tools provide Swift Testing but not XCTest. This optional
// focused route exercises Lab plus the reused diagnosis/resistance suites.
let labChecksOnly = ProcessInfo.processInfo.environment["WHATCABLE_LAB_CHECKS"] == "1"

let package = Package(
    name: "WhatCable",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WhatCable", targets: ["WhatCable"]),
        .executable(name: "whatcable-cli", targets: ["WhatCableCLI"]),
        .library(name: "WhatCableCore", targets: ["WhatCableCore"]),
        .library(name: "WhatCableAppKit", targets: ["WhatCableAppKit"]),
        .library(name: "WhatCableDarwinBackend", targets: ["WhatCableDarwinBackend"])
    ],
    targets: [
        .target(name: "WhatCableLabWidgetShared", path: "Sources/WhatCableLabWidgetShared"),
        .testTarget(
            name: "WhatCableLabTests",
            dependencies: ["WhatCableCore", "WhatCablePlugins", "WhatCableLabWidgetShared"],
            path: "Tests/WhatCableLabTests"
        ),
        .target(
            name: "WhatCableCore",
            path: "Sources/WhatCableCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "WhatCableNotifications",
            dependencies: ["WhatCableCore"],
            path: "Sources/WhatCableNotifications",
            resources: [.process("Resources")]
        ),
        .target(
            name: "WhatCableDarwinBackend",
            dependencies: ["WhatCableCore"],
            path: "Sources/WhatCableDarwinBackend"
        ),
        .target(
            name: "WhatCableAppKit",
            dependencies: ["WhatCableCore", "WhatCableNotifications"],
            path: "Sources/WhatCableAppKit"
        ),
        .target(
            name: "WhatCablePlugins",
            dependencies: ["WhatCableCore", "WhatCableDarwinBackend", "WhatCableAppKit", "WhatCableLabWidgetShared"],
            path: "Sources/WhatCablePlugins"
        ),
        .executableTarget(
            name: "WhatCable",
            dependencies: ["WhatCableCore", "WhatCableNotifications", "WhatCableDarwinBackend", "WhatCableAppKit", "WhatCablePlugins"],
            path: "Sources/WhatCable",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "WhatCableCLI",
            dependencies: ["WhatCableCore", "WhatCableDarwinBackend", "WhatCableAppKit", "WhatCablePlugins"],
            path: "Sources/WhatCableCLI"
        ),
        .testTarget(
            name: "WhatCableCoreTests",
            dependencies: ["WhatCableCore"],
            path: "Tests/WhatCableCoreTests",
            sources: labChecksOnly ? ["ChargingDiagnosticTests.swift", "DataLinkDiagnosticTests.swift",
                "DisplayDiagnosticTests.swift", "EDIDInfoTests.swift", "EDIDInfo+Fixture.swift",
                "EDIDTestBuilder.swift", "CableResistanceTierTests.swift"] : nil
        ),
        .testTarget(
            name: "WhatCableNotificationsTests",
            dependencies: ["WhatCableNotifications", "WhatCableCore"],
            path: "Tests/WhatCableNotificationsTests"
        ),
        .testTarget(
            name: "WhatCableDarwinTests",
            dependencies: ["WhatCableCore", "WhatCable", "WhatCableDarwinBackend"],
            path: "Tests/WhatCableDarwinTests",
            sources: labChecksOnly ? ["RegressionAccumulatorTests.swift"] : nil
        )
    ].filter { !labChecksOnly || $0.name != "WhatCableNotificationsTests" }
)
