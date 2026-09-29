// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "S400WakeProbeCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "ProbeCore", targets: ["ProbeCore"])],
    targets: [
        .target(name: "CryptoSwift", path: "Vendor/CryptoSwift/Sources/CryptoSwift"),
        .target(name: "ProbeCore", dependencies: ["CryptoSwift"]),
        .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore", "CryptoSwift"], resources: [.copy("Fixtures")])
    ]
)
