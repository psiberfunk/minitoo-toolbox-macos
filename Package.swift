// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DivoomMiniToo",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "DivoomMiniToo", targets: ["DivoomMiniToo"]),
        .executable(name: "DivoomDaemon", targets: ["DivoomDaemon"]),
    ],
    dependencies: [
        // Pin the updater framework used by the release/update path.  The
        // app bundle is still assembled by tools/build-divoom-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "DivoomMiniToo",
            dependencies: [
                "CZstd",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "tools",
            exclude: [
                "__pycache__", "vendor", "DivoomDaemon.swift", "DivoomRFCOMM.swift", "DivoomRFCOMMSend.swift",
                "build-divoom-app.sh", "build-ffmpeg.sh", "build-zstd.sh", "dmgbuild-settings.py",
                "divoom-daemon", "divoom-menubar", "divoom_album.py", "divoom_atmosphere.py", "divoom_clock.py",
                "divoom_device_settings.py", "divoom_display.py", "divoom_send.py", "divoom_whitenoise.py",
                "parse_divoom_spp.py", "send_divoom_image.py",
            ],
            sources: [
                "DivoomMenuBar.swift",
                "DivoomControlCenter.swift",
                "DivoomPreferences.swift",
                "DivoomAtmosphereIcons.swift",
                "DivoomDeviceSetup.swift",
                "DivoomBluetooth.swift",
                "DivoomBuildInfo.swift",
                "DivoomUpdateController.swift",
                "DivoomZstd.swift",
                "DivoomClockFrame.swift",
                "DivoomChunkedUpload.swift",
                "DivoomImageResize.swift",
                "DivoomAlbumEncode.swift",
                "DivoomMediaEncode.swift",
                "DivoomProcess.swift",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Network"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .target(
            name: "CZstd",
            path: "tools/vendor/zstd-1.5.7",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("lib"),
                .headerSearchPath("lib/common"),
                .headerSearchPath("lib/compress"),
            ]
        ),
        .executableTarget(
            name: "DivoomDaemon",
            path: "tools",
            exclude: [
                "__pycache__", "vendor", "DivoomAlbumEncode.swift", "DivoomAtmosphereIcons.swift",
                "DivoomBluetooth.swift", "DivoomBuildInfo.swift", "DivoomChunkedUpload.swift", "DivoomClockFrame.swift",
                "DivoomControlCenter.swift", "DivoomDeviceSetup.swift", "DivoomImageResize.swift", "DivoomMediaEncode.swift",
                "DivoomMenuBar.swift", "DivoomPreferences.swift", "DivoomProcess.swift", "DivoomRFCOMM.swift",
                "DivoomRFCOMMSend.swift", "DivoomUpdateController.swift", "DivoomZstd.swift", "build-divoom-app.sh",
                "build-ffmpeg.sh", "build-zstd.sh", "dmgbuild-settings.py", "divoom-daemon", "divoom-menubar",
                "divoom_album.py", "divoom_atmosphere.py", "divoom_clock.py", "divoom_device_settings.py",
                "divoom_display.py", "divoom_send.py", "divoom_whitenoise.py", "parse_divoom_spp.py",
                "send_divoom_image.py",
            ],
            sources: ["DivoomDaemon.swift"],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Network"),
            ]
        ),
    ],
    // Keep this existing AppKit codebase on the same language-mode behavior
    // as its direct swiftc build while dependencies are moved to SwiftPM.
    swiftLanguageModes: [.v5]
)
