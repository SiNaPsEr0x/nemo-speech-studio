import AVFoundation
import AudioCommon
import Foundation
import MagpieTTS
import NemotronStreamingASR
import SpeechVAD

struct StudioLine: Codable, Identifiable, Sendable {
    var id: Int
    var start: Double
    var end: Double
    var speaker: Int
    var text: String
}

struct StudioResult: Sendable {
    var lines: [StudioLine]
    var translated: [StudioLine]
    var files: [URL]
    var warnings: [String]
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
        targetLanguage: String?,
        diarization: Bool,
        subtitles: Bool,
        dubbing: Bool,
        burnIn: Bool,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> StudioResult {
        SessionLog.shared.write("Pipeline input type=\(source.pathExtension.lowercased()) diarization=\(diarization) subtitles=\(subtitles) dubbing=\(dubbing) burnIn=\(burnIn)")
        progress("Preparo la traccia audio")
        let audio = try await prepareAudio(source)
        SessionLog.shared.write("Audio prepared type=\(audio.pathExtension.lowercased())")
        try Task.checkCancellation()

        progress("Carico Nemotron 3.5 INT8")
        let asrStarted = Date()
        let asrPath = try HuggingFaceDownloader.getCacheDirectory(for: NemotronStreamingASRModel.defaultModelId)
        let model = try await NemotronStreamingASRModel.fromLocal(bundleDir: asrPath)
        SessionLog.shared.write("Nemotron loaded in \(Int(Date().timeIntervalSince(asrStarted)))s")
        try Task.checkCancellation()
        let session = try model.createSession(language: language == "auto" ? nil : language)

        progress("Trascrivo sul dispositivo")
        let stream = AudioFileLoader.stream(
            url: audio,
            options: AudioFileStreamOptions(targetSampleRate: 16_000, chunkDuration: 2))
        var timedWords: [TimedWord] = []
        var audioChunks = 0
        for try await chunk in stream {
            try Task.checkCancellation()
            audioChunks += 1
            for update in try session.pushAudio(chunk.samples) where !update.words.isEmpty {
                timedWords = update.words
            }
            if audioChunks % 15 == 0 {
                SessionLog.shared.write("ASR streaming chunks=\(audioChunks) latestWords=\(timedWords.count)")
            }
        }
        for update in try session.finalize() where !update.words.isEmpty {
            timedWords = update.words
        }
        guard !timedWords.isEmpty else { throw StudioPipelineError.noWords }
        SessionLog.shared.write("ASR final chunks=\(audioChunks) words=\(timedWords.count)", always: true)
        // Release the ASR graph before loading the second model on the phone.
        model.unload()

        var speakers: [DiarizedSegment] = []
        if diarization {
            try Task.checkCancellation()
            progress("Carico Sortformer (4 speaker)")
            let sortPath = try HuggingFaceDownloader.getCacheDirectory(for: SortformerDiarizer.defaultModelId)
            let diarizer = try await SortformerDiarizer.fromPretrained(
                cacheDir: sortPath, offlineMode: true)
            SessionLog.shared.write("Sortformer loaded from local cache")
            try Task.checkCancellation()
            progress("Riconosco i parlanti")
            let speakerSession = diarizer.makeStreamingSession()
            // Avoid holding the complete audio of a long video in RAM.
            let audioStream = AudioFileLoader.stream(
                url: audio,
                options: AudioFileStreamOptions(targetSampleRate: 16_000, chunkDuration: 30))
            var diarChunks = 0
            for try await chunk in audioStream {
                try Task.checkCancellation()
                _ = try speakerSession.push(audio: chunk.samples)
                diarChunks += 1
                if diarChunks % 10 == 0 { SessionLog.shared.write("Sortformer chunks=\(diarChunks)") }
            }
            speakers = try speakerSession.finish().segments
            SessionLog.shared.write("Sortformer final chunks=\(diarChunks) segments=\(speakers.count)", always: true)
        }

        let lines = makeLines(words: timedWords, speakers: speakers)
        SessionLog.shared.write("Aligned transcript lines=\(lines.count)")
        var translated: [StudioLine] = []
        if let targetLanguage, !lines.isEmpty {
            progress("Carico Riva Translate 4B (Metal)")
            let translator = try RivaTranslator(url: ModelLibrary.rivaPath)
            SessionLog.shared.write("Riva GGUF loaded; translating \(lines.count) lines")
            for (index, line) in lines.enumerated() {
                try Task.checkCancellation()
                progress("Traduco con Riva: \(index + 1)/\(lines.count)")
                var output = line
                output.text = try translator.translate(line.text, from: language, to: targetLanguage)
                translated.append(output)
                if (index + 1) % 10 == 0 || index + 1 == lines.count {
                    SessionLog.shared.write("Riva translated=\(index + 1)/\(lines.count)")
                }
            }
        }
        let directory = AppStoragePaths.output.appendingPathComponent(
            "\(source.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files = try writeTranscripts(lines, to: directory)
        SessionLog.shared.write("Transcript exported files=\(files.count)")
        var warnings: [String] = []
        if subtitles {
            files += try writeSubtitles(lines, to: directory)
            SessionLog.shared.write("Subtitles exported SRT/VTT/ASS")
        }
        if !translated.isEmpty {
            files += try writeTranscripts(translated, to: directory, suffix: "-tradotta")
            if subtitles { files += try writeSubtitles(translated, to: directory, suffix: "-tradotti") }
        }
        if dubbing {
            try Task.checkCancellation()
            progress("Preparo il doppiaggio Magpie + NanoCodec")
            let voiceLines = translated.isEmpty ? lines : translated
            let voiceLanguage = targetLanguage ?? language
            let dubbedWAV = try await dub(voiceLines, language: voiceLanguage,
                                          to: directory, progress: progress)
            files.append(dubbedWAV)
            SessionLog.shared.write("Dubbing WAV exported bytes=\((try? dubbedWAV.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)", always: true)
            if try await MediaComposer.hasVideo(source) {
                try Task.checkCancellation()
                progress("Creo MOV con audio originale + doppiaggio separato")
                let video = directory.appendingPathComponent("video-doppiato.mov")
                do {
                    try await MediaComposer.muxOriginalAndDubbing(
                        video: source, dubbing: dubbedWAV, output: video)
                    files.append(video)
                    SessionLog.shared.write("MOV with separate original/dub audio exported", always: true)
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: video)
                    throw CancellationError()
                } catch {
                    try? FileManager.default.removeItem(at: video)
                    let warning = "MOV non disponibile: \(error.localizedDescription). WAV pronto."
                    SessionLog.shared.write(warning, always: true)
                    warnings.append(warning)
                }
            }
        }
        if burnIn {
            try Task.checkCancellation()
            progress("Imprimo i sottotitoli nel video MP4")
            let video = directory.appendingPathComponent("video-sottotitolato.mp4")
            do {
                try await MediaComposer.burnSubtitles(
                    video: source, lines: translated.isEmpty ? lines : translated,
                    output: video)
                files.append(video)
                SessionLog.shared.write("Burn-in MP4 exported", always: true)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: video)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: video)
                let warning = "MP4 non disponibile: \(error.localizedDescription). SRT e ASS pronti."
                SessionLog.shared.write(warning, always: true)
                warnings.append(warning)
            }
        }
        progress("Pronto")
        SessionLog.shared.write("Pipeline done lines=\(lines.count) files=\(files.count) warnings=\(warnings.count)", always: true)
        return StudioResult(lines: lines, translated: translated, files: files,
                            warnings: warnings)
    }

    static func synthesize(_ text: String, voice: String, language: String) async throws -> URL {
        let model = try await MagpieTTS.fromPretrained(variant: .int8)
        SessionLog.shared.write("Magpie voice model loaded")
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
        SessionLog.shared.write("Magpie synthesized samples=\(samples.count)")
        return url
    }

    // Mix overlapping speakers on a bounded sliding buffer; only completed
    // samples are written to disk, even for hour-long source videos.
    private static func dub(_ lines: [StudioLine], language: String, to directory: URL,
                            progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard let speechLanguage = MagpieLanguage(code: String(language.prefix(2))) else {
            throw StudioPipelineError.unsupportedFormat
        }
        let model = try await MagpieTTS.fromPretrained(variant: .int8)
        SessionLog.shared.write("Magpie dubbing model loaded lines=\(lines.count)")
        let sampleRate = MagpieTTS.sampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate), channels: 1,
                                         interleaved: false) else { throw StudioPipelineError.noAudio }
        let url = directory.appendingPathComponent("doppiaggio.wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        var pending: [Float] = []
        var cursor = 0
        func emit(_ count: Int) throws {
            var written = 0
            while written < count {
                let length = min(16_384, count - written)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(length)),
                      let destination = buffer.floatChannelData?[0] else {
                    throw StudioPipelineError.noAudio
                }
                for j in 0..<length { destination[j] = max(-1, min(1, pending[written + j])) }
                buffer.frameLength = AVAudioFrameCount(length)
                try file.write(from: buffer)
                written += length
            }
            pending.removeFirst(count)
            cursor += count
        }
        func silence(until frame: Int) throws {
            while cursor < frame {
                let length = min(16_384, frame - cursor)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(length)),
                      let destination = buffer.floatChannelData?[0] else {
                    throw StudioPipelineError.noAudio
                }
                buffer.frameLength = AVAudioFrameCount(length)
                for j in 0..<length { destination[j] = 0 }
                try file.write(from: buffer)
                cursor += length
            }
        }
        let voices: [MagpieSpeaker] = [.johnVanStan, .sofia, .jason, .aria]
        for (index, line) in lines.enumerated() {
            try Task.checkCancellation()
            let start = max(0, Int((line.start * Double(sampleRate)).rounded()))
            if start > cursor + pending.count {
                try emit(pending.count)
                try silence(until: start)
            }
            progress("Sintetizzo la voce: \(index + 1)/\(lines.count)")
            let voice = voices[max(0, min(3, line.speaker - 1))]
            let samples = try model.synthesize(
                text: line.text, speaker: voice, language: speechLanguage,
                params: MagpieTTSParams(temperature: 0, topK: 1, maxSteps: 500))
            if (index + 1) % 10 == 0 || index + 1 == lines.count {
                SessionLog.shared.write("Magpie dubbed=\(index + 1)/\(lines.count) samples=\(samples.count)")
            }
            let offset = max(0, start - cursor)
            if offset + samples.count > pending.count {
                pending.append(contentsOf: repeatElement(Float(0), count: offset + samples.count - pending.count))
            }
            for j in samples.indices { pending[offset + j] += samples[j] }
            let nextStart = index + 1 < lines.count
                ? max(0, Int((lines[index + 1].start * Double(sampleRate)).rounded()))
                : cursor + pending.count
            try emit(min(pending.count, max(0, nextStart - cursor)))
        }
        try emit(pending.count)
        if let last = lines.last {
            try silence(until: max(cursor, Int((last.end * Double(sampleRate)).rounded())))
        }
        return url
    }

    private static func prepareAudio(_ url: URL) async throws -> URL {
        if ["wav", "m4a", "mp3", "aac", "flac", "aif", "aiff"].contains(url.pathExtension.lowercased()) {
            return url
        }
        let asset = AVURLAsset(url: url)
        guard !((try await asset.loadTracks(withMediaType: .audio)).isEmpty) else { throw StudioPipelineError.noAudio }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw StudioPipelineError.unsupportedFormat
        }
        let target = AppStoragePaths.temporary.appendingPathComponent("audio-\(UUID().uuidString).m4a")
        try await exporter.export(to: target, as: .m4a)
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

    private static func writeTranscripts(_ lines: [StudioLine], to directory: URL,
                                         suffix: String = "") throws -> [URL] {
        let txt = directory.appendingPathComponent("trascrizione\(suffix).txt")
        let json = directory.appendingPathComponent("trascrizione\(suffix).json")
        try lines.map { "[\(stamp($0.start, separator: ":"))] \($0.speaker > 0 ? "Speaker \($0.speaker): " : "")\($0.text)" }
            .joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(lines).write(to: json, options: .atomic)
        return [txt, json]
    }

    private static func writeSubtitles(_ lines: [StudioLine], to directory: URL,
                                       suffix: String = "") throws -> [URL] {
        let srt = directory.appendingPathComponent("sottotitoli\(suffix).srt")
        let vtt = directory.appendingPathComponent("sottotitoli\(suffix).vtt")
        let ass = directory.appendingPathComponent("sottotitoli\(suffix).ass")
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
