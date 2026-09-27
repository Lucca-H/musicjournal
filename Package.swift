// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicJournal",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MusicJournal",
            path: "Sources/MusicJournal"
        ),
        .testTarget(
            name: "MusicJournalTests",
            dependencies: ["MusicJournal"],
            path: "Tests/MusicJournalTests"
        ),
    ]
)
