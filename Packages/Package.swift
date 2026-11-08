// swift-tools-version: 6.2
import Foundation
import PackageDescription

let package = Package(
    name: "OhiaPackages",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OhiaCore", targets: ["OhiaCore"]),
        .library(name: "OhiaIngest", targets: ["OhiaIngest"]),
        .library(name: "OhiaML", targets: ["OhiaML"]),
        .library(name: "OhiaScheduler", targets: ["OhiaScheduler"]),
        .library(name: "OhiaMail", targets: ["OhiaMail"]),
        .library(name: "OhiaMessagesReaderProtocol", targets: ["OhiaMessagesReaderProtocol"]),
        .executable(name: "OhiaMessagesReader", targets: ["OhiaMessagesReader"]),
        .executable(name: "OhiaPDFParser", targets: ["OhiaPDFParser"]),
        .executable(name: "OhiaRetrievalWorker", targets: ["OhiaRetrievalWorker"]),
        .executable(name: "OhiaGenerativeWorker", targets: ["OhiaGenerativeWorker"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/JGKarlin/mlx-swift-lm.git",
            revision: "b2087169bad4cb0a4b96c0bff899935559480494"
        ),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.12"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.7.1"),
        .package(url: "https://github.com/apple/swift-nio-imap.git", from: "0.2.0"),
        .package(url: "https://github.com/unum-cloud/usearch", .upToNextMajor(from: "2.0.0")),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        .target(name: "OhiaMessagesReaderProtocol"),
        .target(
            name: "OhiaMessagesReaderSupport",
            dependencies: ["OhiaMessagesReaderProtocol"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "OhiaMessagesReader",
            dependencies: [
                "OhiaMessagesReaderProtocol",
                "OhiaMessagesReaderSupport",
            ]
        ),
        .target(name: "OhiaPDFParsing"),
        // PDFKit and LiteParse code that opens untrusted PDFs. Only the
        // sandboxed OhiaPDFParser service links it.
        .target(
            name: "OhiaPDFParserEngine",
            dependencies: ["OhiaPDFParsing"]
        ),
        .executableTarget(
            name: "OhiaPDFParser",
            dependencies: ["OhiaPDFParserEngine", "OhiaPDFParsing"]
        ),
        .target(
            name: "OhiaCore",
            dependencies: [
                "OhiaPDFParsing",
                .product(name: "USearch", package: "usearch"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "OhiaIngest",
            dependencies: [
                "OhiaCore",
                "OhiaPDFParsing",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(
            name: "OhiaML",
            dependencies: [
                "OhiaCore",
                "OhiaIngest",
                "OhiaPDFParsing",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            resources: [
                .process("Layout/Shaders/ForceDirected.metal")
            ],
            swiftSettings: [
                .define("ACCELERATE_NEW_LAPACK"),
                .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"]),
            ]
        ),
        .target(
            name: "OhiaMail",
            dependencies: [
                "OhiaCore",
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
            ]
        ),
        .target(
            name: "OhiaScheduler",
            dependencies: ["OhiaCore", "OhiaIngest", "OhiaML", "OhiaMail"]
        ),
        .target(
            name: "OhiaWorkerSupport",
            dependencies: ["OhiaCore", "OhiaIngest", "OhiaPDFParsing", "OhiaML", "OhiaScheduler", "OhiaMail"]
        ),
        .executableTarget(
            name: "OhiaRetrievalWorker",
            dependencies: ["OhiaWorkerSupport"]
        ),
        .executableTarget(
            name: "OhiaGenerativeWorker",
            dependencies: ["OhiaWorkerSupport"]
        ),
    ]
)

// Test targets exist only in the development repository. Public source
// releases ship without `Tests/`, so the manifest declares them when present.
if FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests") {
    package.targets += [
        .testTarget(
            name: "OhiaCoreTests",
            dependencies: ["OhiaCore", "OhiaMail", "OhiaPDFParsing"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OhiaIngestTests",
            dependencies: [
                "OhiaIngest",
                "OhiaPDFParsing",
                "OhiaPDFParserEngine",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OhiaMLTests",
            dependencies: [
                "OhiaML",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "OhiaMessagesReaderSupportTests",
            dependencies: [
                "OhiaMessagesReaderProtocol",
                "OhiaMessagesReaderSupport",
            ]
        ),
        .testTarget(
            name: "OhiaSchedulerTests",
            dependencies: ["OhiaScheduler", "OhiaWorkerSupport", "OhiaML", "OhiaPDFParsing"]
        ),
        .testTarget(
            name: "OhiaMailTests",
            dependencies: ["OhiaMail", "OhiaCore"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "OhiaMailIntegrationTests",
            dependencies: ["OhiaMail", "OhiaCore"],
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "OhiaMLIntegrationTests",
            dependencies: [
                "OhiaML",
                "OhiaCore",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            exclude: ["README.md"]
        ),
    ]
}
