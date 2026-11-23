// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppleIntelligenceRecoveryAgent",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "recovery-agent", targets: ["RecoveryAgent"])],
    targets: [.executableTarget(name: "RecoveryAgent")]
)
