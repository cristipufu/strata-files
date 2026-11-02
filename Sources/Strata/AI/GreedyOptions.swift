import FoundationModels

extension GenerationOptions {
    /// Always the likeliest answer. SDK 27 renamed the option (the old name is deprecated there), and CI builds with
    /// Xcode 26, which knows only the old one.
    package nonisolated static func greedy(maximumResponseTokens: Int) -> GenerationOptions {
        #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
        #else
        GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumResponseTokens)
        #endif
    }
}
