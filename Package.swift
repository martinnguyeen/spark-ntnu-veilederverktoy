// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Ordlyd",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Ordlyd", targets: ["Ordlyd"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(name: "Ordlyd", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "OrdlydTests", dependencies: ["Ordlyd"])
    ]
)
