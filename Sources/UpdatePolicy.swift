import Foundation
import Security

// MARK: - When the app may update itself (D-011)

/// Whether this copy of the app may run Sparkle. Kept free of Sparkle so it is testable.
enum UpdatePolicy: Equatable {
    case enabled
    /// Installed from the Nix flake: the bundle is in the read-only Nix store, and Nix,
    /// not Sparkle, owns the version.
    case nixStore
    /// Not signed by the release team (dev-install, Xcode run, ad-hoc fallback build):
    /// replacing it with a release would discard the build being tested.
    case unsignedBuild

    /// The team that signs releases (Workshop 144 LLC).
    static let releaseTeamID = "Q4PR8D5TG8"

    static func decide(bundlePath: String, teamID: String?) -> UpdatePolicy {
        let path = (bundlePath as NSString).resolvingSymlinksInPath
        if path.hasPrefix("/nix/store/") || bundlePath.hasPrefix("/nix/store/") { return .nixStore }
        guard teamID == releaseTeamID else { return .unsignedBuild }
        return .enabled
    }

    static var current: UpdatePolicy {
        decide(bundlePath: Bundle.main.bundlePath, teamID: runningTeamID())
    }

    /// One line for Settings when updates are off; nil when they are on.
    var explanation: String? {
        switch self {
        case .enabled: return nil
        case .nixStore: return "Installed with Nix: update it with your Nix configuration."
        case .unsignedBuild: return "This is a development build, so it does not update itself."
        }
    }
}

/// The Team ID in the running app's code signature, or nil for ad-hoc / unsigned code.
func runningTeamID() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
}
