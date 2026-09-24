import AudioCommon
import CryptoKit
import Foundation
import MagpieTTS
import NemotronStreamingASR
import SpeechVAD

enum ModelStorageError: LocalizedError {
    case insufficient(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .insufficient(let required, let available):
            let format = ByteCountFormatter()
            format.countStyle = .file
            return "Spazio insufficiente: servono \(format.string(fromByteCount: required)), disponibili \(format.string(fromByteCount: available)). Libera spazio e premi Riprendi."
        }
    }
}

struct ModelPresence: Identifiable {
    let id: String
    let name: String
    let installed: Bool
}

// The explicit user action that fills persistent storage. Inference uses local bundles only.
@MainActor
final class ModelLibrary: ObservableObject {
    @Published private(set) var downloading = false
    @Published private(set) var ready = false
    @Published private(set) var status = "Modelli non ancora verificati"
    @Published private(set) var fraction = 0.0
    @Published private(set) var models: [ModelPresence] = []
    private var work: Task<Void, Never>?
    private var lastProgressBucket = -1

    init() {
        refreshPresence()
    }

    nonisolated static let rivaFile = "Riva-Translate-4B-Instruct-v2-Q4_K_M.gguf"
    static let rivaHash = "90c2f48ff5549b770d9aaecb7eea603548bcca035a970a800d9c17781991804d"
    static let rivaURL = URL(string: "https://huggingface.co/liodon-ai/Riva-Translate-4B-Instruct-v2-imatrix-GGUF/resolve/main/Riva-Translate-4B-Instruct-v2-Q4_K_M.gguf?download=true")!
    nonisolated static let rivaPath = AppStoragePaths.models.appendingPathComponent(rivaFile)
    static let verifiedMarker = AppStoragePaths.models.appendingPathComponent("models-verified-v1.txt")

    private func refreshPresence() {
        let asr = try? Self.modelDirectory(NemotronStreamingASRModel.defaultModelId)
        let sort = try? Self.modelDirectory(SortformerDiarizer.defaultModelId)
        let magpie = try? Self.modelDirectory(MagpieTTSVariant.int8.huggingFaceRepoId)
        let files: [(String, String, URL?)] = [
            ("nemotron", "Nemotron 3.5", asr?.appendingPathComponent("encoder.mlmodelc")),
            ("sortformer", "Sortformer", sort?.appendingPathComponent("Sortformer.mlmodelc")),
            ("magpie", "Magpie", magpie?.appendingPathComponent("nanocodec_decoder/model.safetensors")),
            ("riva", "Riva 4B", Self.rivaPath)
        ]
        models = files.map { id, name, file in
            ModelPresence(id: id, name: name,
                          installed: file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        }
        ready = FileManager.default.fileExists(atPath: Self.verifiedMarker.path)
            && models.allSatisfy(\.installed)
        if !downloading {
            status = ready ? "Tutti i modelli sono già sul tuo iPhone" : "Scarica i modelli mancanti per iniziare"
        }
        SessionLog.shared.write("Cache models: \(models.map { "\($0.name)=\($0.installed)" }.joined(separator: ", ")); verified=\(ready)")
    }

    private static func ensureSpace(_ minimum: Int64) throws {
        let values = try AppStoragePaths.models.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < minimum {
            throw ModelStorageError.insufficient(required: minimum, available: available)
        }
    }

    static func modelDirectory(_ modelId: String) throws -> URL {
        try HuggingFaceDownloader.getCacheDirectory(for: modelId)
    }

    private func reportProgress(base: Double, weight: Double, model: String) -> @Sendable (Double) -> Void {
        { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fraction = base + weight * value
                let bucket = Int(value * 20)
                if bucket > self.lastProgressBucket {
                    self.lastProgressBucket = bucket
                    SessionLog.shared.write("Download \(model): \(Int(value * 100))% overall=\(Int(self.fraction * 100))%")
                }
            }
        }
    }

    func downloadAll() {
        guard !downloading else { return }
        downloading = true
        ready = false
        SessionLog.shared.write("Model download started; available space checked before each large transfer", always: true)
        work = Task {
            do {
                try Self.ensureSpace(512 * 1024 * 1024)
                let asrID = NemotronStreamingASRModel.defaultModelId
                status = "Nemotron 3.5: download/resume + verifica SHA"
                lastProgressBucket = -1
                let asrPath = try Self.modelDirectory(asrID)
                SessionLog.shared.write("ASR model id=\(asrID) cache=\(asrPath.lastPathComponent)")
                try await HuggingFaceDownloader.downloadWeights(
                    modelId: asrID, to: asrPath,
                    additionalFiles: ["encoder.mlmodelc/**", "decoder.mlmodelc/**", "joint.mlmodelc/**",
                                      "vocab.json", "tokenizer.model", "*_tokenizer.model",
                                      "vocab.txt", "languages.json", "config.json"],
                    progressHandler: reportProgress(base: 0, weight: 0.25, model: "Nemotron"))
                refreshPresence()
                SessionLog.shared.write("ASR download verified")
                try Task.checkCancellation()
                status = "Sortformer: download/resume + verifica SHA"
                lastProgressBucket = -1
                let sortID = SortformerDiarizer.defaultModelId
                let sortPath = try Self.modelDirectory(sortID)
                try await HuggingFaceDownloader.downloadWeights(
                    modelId: sortID, to: sortPath,
                    additionalFiles: ["Sortformer.mlmodelc/**", "config.json"],
                    progressHandler: reportProgress(base: 0.25, weight: 0.25, model: "Sortformer"))
                refreshPresence()
                SessionLog.shared.write("Sortformer download verified")
                try Task.checkCancellation()
                status = "Magpie + NanoCodec: download/resume + verifica SHA"
                lastProgressBucket = -1
                _ = try await MagpieTTSDownloader.ensureDownloaded(
                    variant: .int8, progressHandler: reportProgress(base: 0.50, weight: 0.25, model: "Magpie"))
                refreshPresence()
                SessionLog.shared.write("Magpie/NanoCodec download verified")
                try Task.checkCancellation()
                status = "Riva Translate Q4_K_M: download/resume + SHA-256"
                lastProgressBucket = -1
                try await Self.downloadRiva(progress: reportProgress(base: 0.75, weight: 0.25, model: "Riva"))
                refreshPresence()
                try ("Riva SHA-256: " + Self.rivaHash).write(
                    to: Self.verifiedMarker, atomically: true, encoding: .utf8)
                fraction = 1
                refreshPresence()
                status = "Modelli pronti sul dispositivo"
                SessionLog.shared.write("Download modelli completato", always: true)
            } catch is CancellationError {
                status = "Download sospeso: riprende dal pulsante"
                SessionLog.shared.write("Model download cancelled at \(Int(fraction * 100))%", always: true)
            } catch {
                status = "Modelli incompleti: \(error.localizedDescription)"
                SessionLog.shared.write("Model download failed at \(Int(fraction * 100))%: \(String(reflecting: error))", always: true)
            }
            downloading = false
            work = nil
        }
    }

    func stop() {
        SessionLog.shared.write("Model download stop requested")
        work?.cancel()
    }

    private static func downloadRiva(progress: @escaping @Sendable (Double) -> Void) async throws {
        let final = rivaPath
        if FileManager.default.fileExists(atPath: final.path),
           try sha256(final) == rivaHash {
            SessionLog.shared.write("Riva cache SHA-256 verified; skipping download")
            return
        }
        let part = final.appendingPathExtension("part")
        var offset = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        SessionLog.shared.write("Riva resume offset=\(offset) bytes")
        var total: Int64?
        repeat {
            try Task.checkCancellation()
            try ensureSpace(256 * 1024 * 1024)
            let end = offset + 8 * 1024 * 1024 - 1
            var request = URLRequest(url: rivaURL)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            SessionLog.shared.write("Riva HTTP \(http.statusCode) requested=\(offset)-\(end) received=\(response.expectedContentLength)")
            if http.statusCode == 416,
               let range = http.value(forHTTPHeaderField: "Content-Range"),
               range.hasPrefix("bytes */"),
               Int64(range.dropFirst("bytes */".count)) == offset {
                // The previous launch wrote the final block, but was stopped before
                // it could hash and promote the .part file.
                total = offset
                try? FileManager.default.removeItem(at: tempURL)
            } else if http.statusCode == 200 {
                if FileManager.default.fileExists(atPath: part.path) { try FileManager.default.removeItem(at: part) }
                try FileManager.default.moveItem(at: tempURL, to: part)
                total = (try part.resourceValues(forKeys: [.fileSizeKey])).fileSize.map(Int64.init)
                offset = total ?? 0
            } else if http.statusCode == 206 {
                guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                      let match = range.range(of: #"^bytes ([0-9]+)-([0-9]+)/([0-9]+)$"#, options: .regularExpression) else {
                    throw URLError(.cannotParseResponse)
                }
                let fields = String(range[match]).split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
                guard fields.count == 4, let startByte = Int64(fields[1]), startByte == offset,
                      let endByte = Int64(fields[2]), let size = Int64(fields[3]), endByte < size else {
                    throw URLError(.cannotParseResponse)
                }
                if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: Data()) }
                let input = try FileHandle(forReadingFrom: tempURL)
                let output = try FileHandle(forWritingTo: part)
                do {
                    try output.seekToEnd()
                    while true {
                        let data = try input.read(upToCount: 1_048_576) ?? Data()
                        if data.isEmpty { break }
                        try output.write(contentsOf: data)
                    }
                    try input.close(); try output.close()
                    try FileManager.default.removeItem(at: tempURL)
                } catch {
                    try? input.close(); try? output.close()
                    throw error
                }
                offset = (try part.resourceValues(forKeys: [.fileSizeKey])).fileSize.map(Int64.init) ?? 0
                guard offset == endByte + 1 else { throw URLError(.cannotParseResponse) }
                guard offset > startByte else { throw URLError(.cannotParseResponse) }
                total = size
            } else {
                throw URLError(.badServerResponse)
            }
            if let total, total > 0 {
                // The next download chunk has its own temporary file; keep headroom.
                if offset < total { try ensureSpace(total - offset + 256 * 1024 * 1024) }
                progress(min(1, Double(offset) / Double(total)))
            }
        } while total.map { offset < $0 } ?? true
        let actual = try sha256(part)
        SessionLog.shared.write("Riva SHA-256 expected=\(rivaHash) actual=\(actual)")
        guard actual == rivaHash else {
            try FileManager.default.removeItem(at: part)
            throw DownloadError.checksumMismatch(file: rivaFile, expected: rivaHash, actual: actual)
        }
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: part, to: final)
    }

    static func sha256(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var digest = SHA256()
        while true {
            let chunk = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
