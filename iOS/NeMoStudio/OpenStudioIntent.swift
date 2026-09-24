import AppIntents

// Makes a real app action available to Shortcuts and gives Xcode metadata to extract.
struct OpenStudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Apri NeMo Studio"
    static let description = IntentDescription("Apri NeMo Studio sul tuo iPhone.")
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    func perform() async throws -> some IntentResult {
        .result()
    }
}

// Apple requires this legacy witness for foreground actions on iOS 18–25.
@available(*, deprecated)
extension OpenStudioIntent {
    static var openAppWhenRun: Bool { true }
}
