// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Ordlyd",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Ordlyd", targets: ["Ordlyd"])],
    targets: [
        .executableTarget(name: "Ordlyd"),
        .testTarget(name: "OrdlydTests", dependencies: ["Ordlyd"])
    ]
)
