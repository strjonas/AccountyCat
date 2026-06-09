import Foundation
import Testing
@testable import AC

/// Guards the runtime-version drift check that decides whether an installed
/// llama.cpp build is behind the pinned target. Conservative by design: an
/// undeterminable installed commit must never trigger an update prompt.
struct RuntimeUpdateDetectionTests {

    private let pinned = "e3471b3e7306fe120dc8f38a2263c1293fc2add7"

    @Test
    func sameCommitDoesNotNeedUpdate() {
        #expect(!RuntimeSetupService.runtimeNeedsUpdate(installedCommit: pinned, pinnedCommit: pinned))
    }

    @Test
    func differentCommitNeedsUpdate() {
        let old = "a279d0f0f4e746d1ef3429d8e9d02d2990b2daa7"
        #expect(RuntimeSetupService.runtimeNeedsUpdate(installedCommit: old, pinnedCommit: pinned))
    }

    @Test
    func unknownInstalledCommitNeverNags() {
        #expect(!RuntimeSetupService.runtimeNeedsUpdate(installedCommit: nil, pinnedCommit: pinned))
        #expect(!RuntimeSetupService.runtimeNeedsUpdate(installedCommit: "", pinnedCommit: pinned))
        #expect(!RuntimeSetupService.runtimeNeedsUpdate(installedCommit: "   \n", pinnedCommit: pinned))
    }

    @Test
    func abbreviationOfPinnedIsConsideredCurrent() {
        // git short hash of the pinned commit.
        #expect(!RuntimeSetupService.runtimeNeedsUpdate(installedCommit: "e3471b3e", pinnedCommit: pinned))
    }

    @Test
    func toleratesSurroundingWhitespaceFromGitOutput() {
        #expect(!RuntimeSetupService.runtimeNeedsUpdate(installedCommit: "  \(pinned)\n", pinnedCommit: pinned))
    }
}
