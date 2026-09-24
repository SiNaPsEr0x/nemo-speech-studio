import AVFoundation
import AudioCommon
import Foundation
import MagpieTTS
import NemotronStreamingASR
import SpeechVAD

struct StudioLine: Codable, Identifiable {
    var id: Int
    var start: Double
    var end: Double
    var speaker: Int
    var text: String
}

struct StudioResult {
    var lines: [StudioLine]
    var files: [URL]
}

enum StudioPipelineError: LocalizedError {
    case noAudio
    case noWords
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noAudio: return "Il file non contiene una traccia audio utilizzabile."
        case .noWords: return "Nemotron non ha riconosciuto parole nel file."
        case .unsupportedFormat: return "Questo formato video non è decodificabile da iOS."
        }
    }
}

enum StudioPipeline {
    static func process(
        source: URL,
        language: String,
        diarization: Bool,
        subtitles: Bool,
        progress: @escaping (String) -> Void
    ) async throws -> StudioResult {
        progress("Preparo la traccia audio")
        let audio = try await prepareAudio(source)
        try Task.checkCancellation()

        progress("Carico Nemotron 3.5 INT8")
        let asrPath = try HuggingFaceDownloader.getCacheDirectory(for: NemotronStreamingASRModel.defaultModelId)
        let model = try await NemotronStreamingASRModel.fromLocal(bundleDir: asrPath)
        try Task.checkCancellation()
        let session = try model.createSession(language: language == "auto" ? nil : language)

        progress("Trascrivo sul dispositivo")
        let stream = AudioFileLoader.stream(
            url: audio,
            options: AudioFileStreamOptions(targetSampleRate: 16_000, chunkDuration: 2))
        var timedWords: [TimedWord] = []
        for try await chunk in stream {
            try Task.checkCancellation()
            for update in try session.pushAudio(chunk.samples) where !update.words.isEmpty {
                timedWords = update.words
            }
        }
        for update in try session.finalize() where !update.words.isEmpty {
            timedWords = update.words
        }
        guard !timedWords.isEmpty else { throw StudioPipelineError.noWords }
        // Release the ASR graph before loading the second model on the phone.
        model.unload()

        var speakers: [DiarizedSegment] = []
        if diarization {
            try Task.checkCancellation()
            progress("Carico Sortformer (4 speaker)")
            let sortPath = try HuggingFaceDownloader.getCacheDirectory(for: SortformerDiarizer.defaultModelId)
            let diarizer = try await SortformerDiarizer.fromPretrained(
                cacheDir: sortPath, offlineMode: true)
            try Task.checkCancellation()
            progress("Riconosco i parlanti")
            let samples = try AudioFileLoader.load(url: audio, targetSampleRate: 16_000)
            speakers = diarizer.diarize(audio: samples, sampleRate: 16_000).segments
        }

        let lines = makeLines(words: timedWords, speakers: speakers)
        let directory = AppStoragePaths.output.appendingPathComponent(
            "\(source.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files = try writeTranscripts(lines, to: directory)
        if subtitles {
            files += try writeSubtitles(lines, to: directory)
        }
        progress("Pronto")
        return StudioResult(lines: lines, files: files)
    }

    static func synthesize(_ text: String, voice: String, language: String) async throws -> URL {
        let model = try await MagpieTTS.fromPretrained(variant: .int8)
        try Task.checkCancellation()
        guard let selectedVoice = MagpieSpeaker(named: voice),
              let selectedLanguage = MagpieLanguage(code: language) else {
            throw StudioPipelineError.unsupportedFormat
        }
        let samples = try model.synthesize(
            text: text, speaker: selectedVoice, language: selectedLanguage,
            params: MagpieTTSParams(temperature: 0, topK: 1, maxSteps: 500))
        let url = AppStoragePaths.output.appendingPathComponent("magpie-\(UUID().uuidString.prefix(8)).wav")
        try writeWAV(samples, at: url, sampleRate: Double(MagpieTTS.sampleRate))
        return url
    }

    private static func prepareAudio(_ url: URL) async throws -> URL {
        if ["wav", "m4a", "mp3", "aac", "flac", "aif", "aiff"].contains(url.pathExtension.lowercased()) {
            return url
        }
        let asset = AVURLAsset(url: url)
        guard !asset.tracks(withMediaType: .audio).isEmpty else { throw StudioPipelineError.noAudio }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw StudioPipelineError.unsupportedFormat
        }
        let target = AppStoragePaths.temporary.appendingPathComponent("audio-\(UUID().uuidString).m4a")
        exporter.outputURL = target
        exporter.outputFileType = .m4a
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                if exporter.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: exporter.error ?? StudioPipelineError.unsupportedFormat)
                }
            }
        }
        return target
    }

    private static func makeLines(words: [TimedWord], speakers: [DiarizedSegment]) -> [StudioLine] {
        var lines: [StudioLine] = []
        var group: [TimedWord] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let match = speakers.max { a, b in
                overlap(a, first.startTime, last.endTime) < overlap(b, first.startTime, last.endTime)
            }
            let speaker = match.flatMap { overlap($0, first.startTime, last.endTime) > 0 ? $0.speakerId + 1 : nil } ?? 0
            lines.append(StudioLine(id: lines.count + 1, start: max(0, first.startTime),
                                    end: max(first.startTime + 0.4, last.endTime), speaker: speaker,
                                    text: group.map(\.text).joined(separator: " ")))
            group.removeAll()
        }
        for word in words {
            if let first = group.first,
               word.endTime - first.startTime > 5 || group.count >= 14 { flush() }
            group.append(word)
            if word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!") { flush() }
        }
        flush()
        return lines
    }

    private static func overlap(_ segment: DiarizedSegment, _ start: Double, _ end: Double) -> Double {
        max(0, min(Double(segment.endTime), end) - max(Double(segment.startTime), start))
    }

    private static func writeTranscripts(_ lines: [StudioLine], to directory: URL) throws -> [URL] {
        let txt = directory.appendingPathComponent("trascrizione.txt")
        let json = directory.appendingPathComponent("trascrizione.json")
        try lines.map { "[\(stamp($0.start, separator: ":"))] \($0.speaker > 0 ? "Speaker \($0.speaker): " : "")\($0.text)" }
            .joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(lines).write(to: json, options: .atomic)
        return [txt, json]
    }

    private static func writeSubtitles(_ lines: [StudioLine], to directory: URL) throws -> [URL] {
        let srt = directory.appendingPathComponent("sottotitoli.srt")
        let vtt = directory.appendingPathComponent("sottotitoli.vtt")
        let ass = directory.appendingPathComponent("sottotitoli.ass")
        let captions = lines.map { line in
            "\(line.id)\n\(stamp(line.start, separator: ",")) --> \(stamp(line.end, separator: ","))\n\(line.text)"
        }.joined(separator: "\n\n")
        try captions.write(to: srt, atomically: true, encoding: .utf8)
        let vttText = lines.map { line in
            "\(line.id)\n\(stamp(line.start, separator: ".")) --> \(stamp(line.end, separator: "."))\n\(line.text)"
        }.joined(separator: "\n\n")
        try ("WEBVTT\n\n" + vttText)
            .write(to: vtt, atomically: true, encoding: .utf8)
        let header = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Speaker1,Arial,56,&H00FFA658,&H00FFA658,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,40,40,50,1
        Style: Speaker2,Arial,56,&H00727BFF,&H00727BFF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,40,40,50,1
        Style: Speaker3,Arial,56,&H00FFA8D2,&H00FFA8D2,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,40,40,50,1
        Style: Speaker4,Arial,56,&H0050B93F,&H0050B93F,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,40,40,50,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        let events = lines.map { line in
            "Dialogue: 0,\(assStamp(line.start)),\(assStamp(line.end)),Speaker\(max(1, min(4, line.speaker))),,0,0,0,,\(line.text.replacingOccurrences(of: "\n", with: "\\N").replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")"))"
        }.joined(separator: "\n")
        try (header + events + "\n").write(to: ass, atomically: true, encoding: .utf8)
        return [srt, vtt, ass]
    }

    private static func stamp(_ time: Double, separator: String) -> String {
        let millis = max(0, Int((time * 1000).rounded()))
        return String(format: "%02d:%02d:%02d%@%03d", millis / 3_600_000,
                      (millis / 60_000) % 60, (millis / 1_000) % 60, separator, millis % 1_000)
    }

    private static func assStamp(_ time: Double) -> String {
        let centis = max(0, Int((time * 100).rounded()))
        return String(format: "%d:%02d:%02d.%02d", centis / 360_000,
                      (centis / 6_000) % 60, (centis / 100) % 60, centis % 100)
    }

    private static func writeWAV(_ samples: [Float], at url: URL, sampleRate: Double) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                        channels: 1, interleaved: false) else { throw StudioPipelineError.noAudio }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        var offset = 0
        while offset < samples.count {
            let count = min(16_384, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let target = buffer.floatChannelData?[0] else { throw StudioPipelineError.noAudio }
            samples.withUnsafeBufferPointer { pointer in
                target.update(from: pointer.baseAddress!.advanced(by: offset), count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
    }
}
