// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeBridge",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "TypeBridge", targets: ["TypeBridge"]),
               .executable(name: "TypeBridgeCredentials", targets: ["TypeBridgeCredentials"])],
    targets: [
        .target(name: "TypeBridgeCredentialSupport"),
        .executableTarget(name: "TypeBridgeCredentials", dependencies: ["TypeBridgeCredentialSupport"]),
        .target(name: "TypeBridgeCore", dependencies: ["TypeBridgeCredentialSupport"], resources: [.process("Resources")]),
        .executableTarget(name: "TypeBridge", dependencies: ["TypeBridgeCore"]),
        .testTarget(name: "TypeBridgeCoreTests", dependencies: ["TypeBridgeCore"])
    ],
    swiftLanguageModes: [.v5]
)
