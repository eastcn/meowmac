// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MeowMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MeowMac", targets: ["MeowMac"])],
    dependencies: [.package(path: "../tuncanary")],
    targets: [
        .target(name: "MeowMacCore"),
        .target(name: "MeowMacSystem", dependencies: ["MeowMacCore"], linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "MeowMacQuota", dependencies: ["MeowMacCore"]),
        .target(name: "MeowMacUI", dependencies: ["MeowMacCore", "MeowMacSystem", "MeowMacQuota", .product(name: "TunCanaryCore", package: "tuncanary"), .product(name: "TunCanarySystem", package: "tuncanary"), .product(name: "TunCanaryProbe", package: "tuncanary"), .product(name: "TunCanaryUI", package: "tuncanary"), .product(name: "TunCanaryRuntime", package: "tuncanary")]),
        .executableTarget(name: "MeowMac", dependencies: ["MeowMacUI"]),
        .executableTarget(name: "MeowMacSelfTest", dependencies: ["MeowMacCore", "MeowMacSystem", "MeowMacQuota", "MeowMacUI"]),
    ]
)
