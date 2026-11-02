import AppKit
import FoundationModels

/// The on-device Apple Intelligence model: whether it can be used right now, and how to explain it when it can't.
/// Every AI feature checks this first and falls back to deterministic behaviour (rules, key sentences) or hides itself.
package nonisolated enum AIModel {
    package enum Status: Sendable, Equatable {
        case available
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unsupportedLanguage
        /// Switched off for testing (`STRATA_AI_DISABLED=1`).
        case disabled
    }

    /// Apple Intelligence runs only natively on Apple silicon. An Intel build (or one running under Rosetta) never
    /// asks for the model: every AI feature takes its built-in path and says nothing about Apple Intelligence.
    package static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    package static var status: Status {
        if ProcessInfo.processInfo.environment["STRATA_AI_DISABLED"] == "1" { return .disabled }
        guard isAppleSilicon else { return .deviceNotEligible }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return model.supportsLocale() ? .available : .unsupportedLanguage
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .modelNotReady
        }
    }

    package static var isAvailable: Bool { status == .available }

    /// This Mac can run Apple Intelligence at all (it may still be off or downloading). When it can't, the app never
    /// mentions it: no "turn it on" hints, no status captions, just the built-in behaviour.
    package static var isSupported: Bool { status != .deviceNotEligible }

    /// Tokens the model can see at once (instructions, prompt and response together).
    package static var contextSize: Int { isAvailable ? SystemLanguageModel.default.contextSize : 0 }

    /// One sentence for UI, or nil when the model is available.
    package static var explanation: String? {
        switch status {
        case .available: nil
        case .deviceNotEligible: String(localized: "This Mac doesn’t support Apple Intelligence.")
        case .appleIntelligenceNotEnabled: String(localized: "Turn on Apple Intelligence in System Settings to use this.")
        case .modelNotReady: String(localized: "Apple Intelligence is still getting ready. Try again in a little while.")
        case .unsupportedLanguage: String(localized: "Apple Intelligence doesn’t support your Mac’s language yet.")
        case .disabled: String(localized: "Apple Intelligence features are turned off.")
        }
    }

    /// A short phrase for captions: what to do (or why not) when the model isn't available.
    package static var shortStatus: String {
        switch status {
        case .available: String(localized: "Apple Intelligence · On this Mac", comment: "Caption: summaries and plans are made by Apple Intelligence on this Mac")
        case .appleIntelligenceNotEnabled: String(localized: "Apple Intelligence is off")
        case .deviceNotEligible: String(localized: "Apple Intelligence isn’t available on this Mac")
        case .modelNotReady: String(localized: "Apple Intelligence is getting ready")
        case .unsupportedLanguage: String(localized: "Apple Intelligence doesn’t support this language yet")
        case .disabled: String(localized: "Apple Intelligence is turned off")
        }
    }

    /// Whether opening System Settings can fix it.
    package static var canOpenSettings: Bool { status == .appleIntelligenceNotEnabled }

    package static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!

    @MainActor package static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// A short label for where a result came from.
    package static let onDeviceLabel = "Apple Intelligence"
}

/// Turns FoundationModels errors into a sentence for the UI.
package nonisolated enum AIErrorText {
    package static func describe(_ error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return String(localized: "The document is too long for the on-device model.")
            case .assetsUnavailable: return String(localized: "Apple Intelligence isn’t ready yet. Try again in a little while.")
            case .guardrailViolation, .refusal: return String(localized: "The on-device model declined this request.")
            case .unsupportedLanguageOrLocale: return String(localized: "This language isn’t supported by the on-device model.")
            case .rateLimited, .concurrentRequests: return String(localized: "The on-device model is busy. Try again in a moment.")
            case .decodingFailure, .unsupportedGuide: return String(localized: "The on-device model returned something unexpected.")
            @unknown default: return error.localizedDescription
            }
        }
        if error is CancellationError { return String(localized: "Cancelled.") }
        return error.localizedDescription
    }
}

/// Wording helpers usable off the main actor (`Format` is main-actor isolated).
package nonisolated enum AIText {
    package static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural)"
    }
}
