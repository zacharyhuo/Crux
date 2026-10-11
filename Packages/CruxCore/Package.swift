// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CruxCore",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "CruxCore", targets: ["CruxCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.7"),
    ],
    targets: [
        // Built from pinned upstream sources by
        // scripts/build-libarchive-xcframework.sh. The artifact is not checked
        // in, so the script must run once before building this package.
        .binaryTarget(
            name: "CLibArchive",
            path: "../../Artifacts/CLibArchive.xcframework"
        ),
        // The only target allowed to touch libarchive handles and raw pointers.
        .target(
            name: "ArchiveBridge",
            dependencies: ["CLibArchive"]
        ),
        .target(
            name: "CruxCore",
            dependencies: [
                "ArchiveBridge",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .testTarget(
            name: "CruxCoreTests",
            dependencies: [
                "CruxCore",
                "ArchiveBridge",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
