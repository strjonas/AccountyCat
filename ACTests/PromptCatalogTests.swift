//
//  PromptCatalogTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Testing
@testable import AC

struct PromptCatalogTests {

    @Test
    func resolvesDefaultMonitoringPromptProfile() {
        let profile = PromptCatalog.monitoringProfile(id: MonitoringConfiguration.defaultPromptProfileID)
        let fallback = PromptCatalog.monitoringProfile(id: "missing-profile")
        let prompt = PromptCatalog.loadMonitoringPrompt(
            profileID: MonitoringConfiguration.defaultPromptProfileID,
            variant: .visionPrimary
        )

        #expect(profile.descriptor.id == MonitoringConfiguration.defaultPromptProfileID)
        #expect(profile.descriptor.version == "focus_default_v2")
        #expect(fallback.descriptor.id == profile.descriptor.id)
        #expect(prompt.asset.id == "monitoring.focus_default_v2.vision_system")
        #expect(prompt.asset.version == "focus_default_v2")
        #expect(prompt.contents.isEmpty == false)
    }
}
