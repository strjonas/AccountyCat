import Foundation
import Testing
@testable import AC

/// Guards the app-version comparison that decides whether to surface an
/// "update available" prompt. Must be numeric (not lexicographic) and tolerate
/// `v` prefixes / malformed components.
struct AppUpdateServiceTests {

    @Test
    func detectsNewerVersions() {
        #expect(AppUpdateService.isVersion("1.05", newerThan: "1.0"))
        #expect(AppUpdateService.isVersion("1.10", newerThan: "1.9"))      // numeric, not lexical
        #expect(AppUpdateService.isVersion("2.0", newerThan: "1.99"))
        #expect(AppUpdateService.isVersion("1.0.5", newerThan: "1.0"))
    }

    @Test
    func equalOrOlderIsNotNewer() {
        #expect(!AppUpdateService.isVersion("1.0", newerThan: "1.0"))
        #expect(!AppUpdateService.isVersion("1.0", newerThan: "1.05"))
        #expect(!AppUpdateService.isVersion("1.9", newerThan: "1.10"))
    }

    @Test
    func normalizesVPrefixAndWhitespace() {
        #expect(AppUpdateService.normalizedVersion("v1.05") == "1.05")
        #expect(AppUpdateService.normalizedVersion("  V2.1 ") == "2.1")
        #expect(AppUpdateService.normalizedVersion("1.0") == "1.0")
    }

    @Test
    func toleratesMalformedComponents() {
        // A non-numeric suffix degrades to 0 rather than crashing or winning.
        #expect(!AppUpdateService.isVersion("1.0-beta", newerThan: "1.0"))
        #expect(AppUpdateService.isVersion("1.2", newerThan: "1.0-rc1"))
    }
}
