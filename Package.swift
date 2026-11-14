// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickChat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "QuickChat"),
        .testTarget(name: "QuickChatTests", dependencies: ["QuickChat"]),
    ]
)
