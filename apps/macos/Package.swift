// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XuQiao",
    platforms: [.macOS(.v15)],
    products: [.library(name: "XuQiaoCore", targets: ["XuQiaoCore"]), .executable(name: "XuQiaoMac", targets: ["XuQiaoMac"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "XuQiaoCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "XuQiaoMac", dependencies: ["XuQiaoCore"]),
        .testTarget(name: "XuQiaoCoreTests", dependencies: ["XuQiaoCore"])
    ],
    swiftLanguageModes: [.v5]
)
