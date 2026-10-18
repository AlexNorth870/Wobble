// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WobbleReplay",
    targets: [
        // Pure, framework-free algorithm module. Shared by the CLI, the tests,
        // and (later) the iOS app's process() path so replay == live behaviour.
        .target(name: "StrokeAnalysis"),

        // Command-line tool: reprocess a recorded CSV on the Mac.
        //   swift run wobble-replay <input.csv> [--out <output.csv>]
        .executableTarget(
            name: "wobble-replay",
            dependencies: ["StrokeAnalysis"]
        ),

        // Golden test: replaying the recorded surge must reproduce the stroke
        // rate the app logged live.
        .testTarget(
            name: "StrokeAnalysisTests",
            dependencies: ["StrokeAnalysis"],
            resources: [
                .copy("Fixtures/sample.csv"),
                .copy("Fixtures/sample2.csv"),
                .copy("Fixtures/track42.csv"),
                .copy("Fixtures/track46.csv"),
            ]
        ),
    ]
)
