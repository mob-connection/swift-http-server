// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-http-server",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(
            name: "HTTPServer",
            targets: ["HTTPServer"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.58.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.19.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.20.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.19.0"),
    ],
    targets: [
        .target(
            name: "HTTPServer",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
        .testTarget(
            name: "HTTPServerTests",
            dependencies: [
                .byName(name: "HTTPServer"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOHTTPTypesHTTP1", package: "swift-nio-extras")
            ]
        ),
    ]
)
