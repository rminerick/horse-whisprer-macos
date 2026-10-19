import Foundation

enum AppDistributionFlavor: String, Sendable {
    case community
    case official
}

struct AppDistribution: Sendable {
    let flavor: AppDistributionFlavor

    var isOfficial: Bool {
        flavor == .official
    }

    var displayName: String {
        switch flavor {
        case .community:
            return "Community build"
        case .official:
            return "Official build"
        }
    }

    var updatesSummary: String {
        switch flavor {
        case .community:
            return "Community builds update manually from source or downloaded releases."
        case .official:
            return "Official builds can use Sparkle updates when signed and configured."
        }
    }

    static func current(bundle: Bundle = .main) -> AppDistribution {
        Self.from(infoDictionary: bundle.infoDictionary)
    }

    static func from(infoDictionary: [String: Any]?) -> AppDistribution {
        let rawValue = (infoDictionary?["HorseWhisprerDistributionFlavor"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let flavor = rawValue.flatMap(AppDistributionFlavor.init(rawValue:)) ?? .community
        return AppDistribution(flavor: flavor)
    }
}
