// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Limevert",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Limevert",
            path: "Sources/Limevert",
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"), .linkedFramework("PDFKit"),
                .linkedFramework("Quartz"), .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"), .linkedFramework("UniformTypeIdentifiers"),
            ]
        )
    ]
)
