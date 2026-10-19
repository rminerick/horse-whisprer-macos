import Foundation
import Security
import Sparkle

@MainActor
final class SparkleUpdateService {
    private var updaterController: SPUStandardUpdaterController?

    var isEnabled: Bool {
        updaterController != nil
    }

    init() {
        guard Self.shouldEnableSparkle() else { return }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    static func isAvailable(bundle: Bundle = .main) -> Bool {
        shouldEnableSparkle(bundle: bundle)
    }

    private static func shouldEnableSparkle(bundle: Bundle = .main) -> Bool {
        guard AppDistribution.current(bundle: bundle).isOfficial else {
            return false
        }

        let bundleURL = bundle.bundleURL
        guard bundleURL.pathExtension == "app" else { return false }
        guard isDeveloperIDSigned(bundleURL: bundleURL) else { return false }
        guard let info = bundle.infoDictionary else { return false }

        let feedURL = info["SUFeedURL"] as? String
        let publicKey = info["SUPublicEDKey"] as? String

        return (feedURL?.isEmpty == false) && (publicKey?.isEmpty == false)
    }

    private static func isDeveloperIDSigned(bundleURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else {
            return false
        }

        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else {
            return false
        }

        guard let summary = SecCertificateCopySubjectSummary(leaf) as String? else {
            return false
        }

        return summary.hasPrefix("Developer ID Application:")
    }
}
