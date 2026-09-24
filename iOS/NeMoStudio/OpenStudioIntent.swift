import AppIntents

// Makes a real app action available to Shortcuts and gives Xcode metadata to extract.
struct OpenStudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Apri NeMo Studio"
    static let description = IntentDescription("Apri NeMo Studio sul tuo iPhone.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    func perform() async throws -> some IntentResult {
        .result()
    }
}
