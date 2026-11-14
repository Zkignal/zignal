import Foundation
import Testing
@testable import Zignal

/// Checks on what the app ships, so an upload isn't refused for something a test can catch.
@Suite("Release readiness")
struct ReleaseReadinessTests {
    @Test("the app carries its privacy manifest: no tracking, no data collected, three declared uses")
    func privacyManifest() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let plist = try #require(object as? [String: Any])
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        let uses = plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        var reasons: [String: [String]] = [:]
        for use in uses {
            let type = try #require(use["NSPrivacyAccessedAPIType"] as? String)
            reasons[type] = use["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        #expect(reasons == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
        ])
    }
}
