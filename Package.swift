// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HomeVideo",
    // iOS is for HomeVideoCore only, which the phone app (ios/HomeVideoMobile.xcodeproj) links.
    // The Mac app, the renderer and the tests stay macOS.
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .executable(name: "HomeVideo", targets: ["HomeVideo"]),
        .executable(name: "homevideo-render", targets: ["homevideo-render"]),
        .library(name: "HomeVideoCore", targets: ["HomeVideoCore"]),
    ],
    // Sparkle is the one dependency, for app updates. It links into the app only, never the core
    // or the renderer.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // The engine: frame source, signal chain, layers, preview renderer.
        // Shaders/*.metal are compiled by SwiftPM into the target's resource bundle.
        .target(
            name: "HomeVideoCore",
            resources: [.process("Shaders")]
        ),
        .executableTarget(
            name: "HomeVideo",
            dependencies: [
                "HomeVideoCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        // Headless renderer: the same Exporter, driven from the command line (works over ssh).
        .executableTarget(
            name: "homevideo-render",
            dependencies: ["HomeVideoCore"]
        ),
        .testTarget(
            name: "HomeVideoCoreTests",
            dependencies: ["HomeVideoCore"]
        ),
    ]
)
