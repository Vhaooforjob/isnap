// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iSnap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iSnap", targets: ["iSnap"])
    ],
    targets: [
        .executableTarget(
            name: "iSnap",
            path: "Sources/iSnap",
            exclude: ["Resources/Info.plist", "Resources/iSnap.entitlements"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Network"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision"),
                .linkedFramework("WidgetKit")
            ]
        ),
        .testTarget(
            name: "iSnapTests",
            dependencies: ["iSnap"],
            path: "Tests/iSnapTests"
        )
    ]
)
