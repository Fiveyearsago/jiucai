// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BeautyRegistration",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "BeautyRegistration", targets: ["BeautyRegistration"])],
    targets: [
        .target(name: "RegistrationCore"),
        .executableTarget(name: "BeautyRegistration", dependencies: ["RegistrationCore"], resources: [.copy("Resources/bridge.js"), .copy("Resources/mailbox-cleanup.js")]),
        .testTarget(name: "RegistrationCoreTests", dependencies: ["RegistrationCore"]),
        .testTarget(name: "BrowserIntegrationTests", dependencies: ["BeautyRegistration"])
    ]
)
