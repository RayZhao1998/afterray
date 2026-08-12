// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AfterRayCaptureShim",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AfterRayCaptureShim", targets: ["AfterRayCaptureShim"]),
    ],
    targets: [
        .executableTarget(
            name: "AfterRayCaptureShim",
            path: "Sources/AfterRayCaptureShim"
        ),
    ]
)
