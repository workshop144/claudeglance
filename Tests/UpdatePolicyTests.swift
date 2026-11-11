import XCTest
@testable import ClaudeGlance

final class UpdatePolicyTests: XCTestCase {
    func testReleaseBuildInApplicationsUpdates() {
        XCTAssertEqual(UpdatePolicy.decide(bundlePath: "/Applications/ClaudeGlance.app",
                                           teamID: "Q4PR8D5TG8"), .enabled)
    }

    func testNixStoreNeverUpdatesEvenWhenSigned() {
        let p = "/nix/store/abc123-claudeglance-1.9.0/Applications/ClaudeGlance.app"
        XCTAssertEqual(UpdatePolicy.decide(bundlePath: p, teamID: "Q4PR8D5TG8"), .nixStore)
    }

    func testAdHocAndOtherTeamsDoNotUpdate() {
        XCTAssertEqual(UpdatePolicy.decide(bundlePath: "/Applications/ClaudeGlance.app", teamID: nil),
                       .unsignedBuild)
        XCTAssertEqual(UpdatePolicy.decide(bundlePath: "/Applications/ClaudeGlance.app", teamID: "ABCDE12345"),
                       .unsignedBuild)
    }

    func testOnlyDisabledStatesExplainThemselves() {
        XCTAssertNil(UpdatePolicy.enabled.explanation)
        XCTAssertNotNil(UpdatePolicy.nixStore.explanation)
        XCTAssertNotNil(UpdatePolicy.unsignedBuild.explanation)
    }

    func testInfoPlistCarriesASignedFeedSetup() throws {
        // The test host is the app, so Bundle.main is ClaudeGlance's Info.plist.
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["SUFeedURL"] as? String,
                       "https://github.com/workshop144/claudeglance/releases/latest/download/appcast.xml")
        XCTAssertEqual((info["SUPublicEDKey"] as? String)?.count, 44)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["CFBundleVersion"] as? String, info["CFBundleShortVersionString"] as? String)
    }
}
