import Foundation

// Exercise the same muxer source used by the iPhone application.
struct StudioLine {
    let start: Double
    let end: Double
    let text: String
}

enum MediaComposerError: Error {
    case unsupported
}

@main
struct MKVSmoke {
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let target = URL(fileURLWithPath: CommandLine.arguments[2])
        try await MatroskaMuxer.write(
            source: source,
            captions: [.init(start: 0.1, end: 0.7, text: "Testo originale")],
            translated: [.init(start: 0.1, end: 0.7, text: "Translated text")],
            output: target)
    }
}
