import Foundation
import Testing
@testable import VoiceInkPlusPlus

@Suite("Commercial-free VoiceInk++ distribution")
struct CommercialFreeDistributionTests {
    @Test
    func appExposesNoCommercialGateOrPurchaseSurface() throws {
        #expect(!OnboardingStage.allCases.contains { $0.rawValue == "license" })
        #expect(!ViewType.allCases.contains { $0.rawValue == "VoiceInk Pro" })

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let removedRuntimeFiles = [
            "VoiceInk/Models/LicenseViewModel.swift",
            "VoiceInk/Services/LicenseManager.swift",
            "VoiceInk/Services/PolarService.swift",
            "VoiceInk/Services/AnnouncementsService.swift",
            "VoiceInk/Views/LicenseManagementView.swift",
            "VoiceInk/Views/Components/ProBadge.swift",
            "VoiceInk/Views/Dashboard/DashboardPromotionsSection.swift",
            "VoiceInk/Views/Onboarding/OnboardingLicenseScreen.swift",
        ]

        for relativePath in removedRuntimeFiles {
            let fileURL = repositoryRoot.appendingPathComponent(relativePath)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }

        let deliverySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        #expect(!deliverySource.contains("LicenseViewModel"))
        #expect(!deliverySource.contains("usageRestrictionMessage"))

        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("VoiceInk/VoiceInk.swift"),
            encoding: .utf8
        )
        #expect(!appSource.contains("AnnouncementsService"))
        #expect(!appSource.contains("confettiCelebrationPresenter"))
    }

    @MainActor
    @Test
    func legacyLicenseOnboardingStateResumesAtTheFinalNonCommercialStep() {
        let suiteName = "CommercialFreeDistributionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("license", forKey: OnboardingStorageKeys.stage)

        let coordinator = OnboardingCoordinator(defaults: defaults)

        #expect(coordinator.stage == .trust)
        #expect(coordinator.currentStepNumber == coordinator.totalStepCount)
    }
}
