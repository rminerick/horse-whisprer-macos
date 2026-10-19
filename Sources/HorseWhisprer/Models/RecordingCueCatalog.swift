import Foundation

struct RecordingCueSoundOption: Identifiable, Hashable {
    let name: String
    let title: String

    var id: String { name }
}

struct RecordingCueDescriptor {
    struct Segment {
        let frequency: Double?
        let duration: TimeInterval
        let amplitude: Float

        static func tone(_ frequency: Double, duration: TimeInterval, amplitude: Float) -> Segment {
            Segment(frequency: frequency, duration: duration, amplitude: amplitude)
        }

        static func silence(_ duration: TimeInterval) -> Segment {
            Segment(frequency: nil, duration: duration, amplitude: 0)
        }
    }

    let name: String
    let title: String
    let segments: [Segment]

    var duration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }
}

enum RecordingCueSoundCatalog {
    static let defaultStartName = "soft"
    static let defaultStopName = "standard"

    static var availableSounds: [RecordingCueSoundOption] {
        let systemSounds = availableSystemSoundNames.map {
            RecordingCueSoundOption(name: $0, title: $0)
        }

        return bundledSounds + systemSounds
    }

    static func normalizedSoundName(_ candidate: String?, fallback fallbackName: String) -> String {
        guard let candidate, !candidate.isEmpty else {
            return fallbackName
        }

        let availableNames = Set(availableSounds.map(\.name))
        return availableNames.contains(candidate) ? candidate : fallbackName
    }

    static func descriptor(for name: String) -> RecordingCueDescriptor? {
        descriptorsByName[name]
    }

    static func audioAssetURL(for name: String) -> URL? {
        guard availableSystemSoundNames.contains(name) else {
            return nil
        }

        return supportedExtensions
            .map { systemSoundsDirectory.appendingPathComponent(name).appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let bundledSounds = [standard, soft, bright].map {
        RecordingCueSoundOption(name: $0.name, title: "Horse \($0.title)")
    }

    private static let standard = RecordingCueDescriptor(
        name: "standard",
        title: "Standard",
        segments: [
            .tone(622.0, duration: 0.10, amplitude: 0.18),
            .silence(0.025),
            .tone(880.0, duration: 0.20, amplitude: 0.24),
            .silence(0.03),
            .tone(988.0, duration: 0.08, amplitude: 0.16)
        ]
    )

    private static let soft = RecordingCueDescriptor(
        name: "soft",
        title: "Soft",
        segments: [
            .tone(493.88, duration: 0.14, amplitude: 0.14),
            .silence(0.03),
            .tone(659.25, duration: 0.22, amplitude: 0.18)
        ]
    )

    private static let bright = RecordingCueDescriptor(
        name: "bright",
        title: "Bright",
        segments: [
            .tone(740.0, duration: 0.08, amplitude: 0.18),
            .silence(0.02),
            .tone(1047.0, duration: 0.18, amplitude: 0.24),
            .silence(0.025),
            .tone(1318.5, duration: 0.08, amplitude: 0.16)
        ]
    )

    private static let descriptorsByName = Dictionary(
        uniqueKeysWithValues: [standard, soft, bright].map { ($0.name, $0) }
    )

    private static let systemSoundsDirectory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    private static let supportedExtensions = ["aiff", "wav", "caf", "aif", "aifc"]
    private static let fallbackSystemSoundNames = [
        "Basso",
        "Blow",
        "Bottle",
        "Frog",
        "Funk",
        "Glass",
        "Hero",
        "Morse",
        "Ping",
        "Pop",
        "Purr",
        "Sosumi",
        "Submarine",
        "Tink"
    ]

    private static var availableSystemSoundNames: [String] {
        let directoryContents = try? FileManager.default.contentsOfDirectory(
            at: systemSoundsDirectory,
            includingPropertiesForKeys: nil
        )
        let discoveredNames = directoryContents?.compactMap { url -> String? in
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                return nil
            }

            return url.deletingPathExtension().lastPathComponent
        }
        .sorted()

        return discoveredNames?.isEmpty == false ? discoveredNames! : fallbackSystemSoundNames
    }
}
