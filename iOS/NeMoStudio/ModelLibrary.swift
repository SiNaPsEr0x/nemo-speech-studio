import AudioCommon
import CryptoKit
import Foundation
import MagpieTTS
import NemotronStreamingASR
import SpeechVAD

// The explicit user action that fills persistent storage. Inference uses local bundles only.
@MainActor
final class ModelLibrary: ObservableObject {
    @Published private(set) var downloading = false
    @Published private(set) var ready = false
    @Published private(set) var status = "Modelli non ancora verificati"
    @Published private(set) var fraction = 0.0
    private var work: Task<Void, Never>?

    init() {
        Task {
            let asr = try? Self.modelDirectory(NemotronStreamingASRModel.defaultModelId)
            let sort = try? Self.modelDirectory(SortformerDiarizer.defaultModelId)
            let magpie = try? Self.modelDirectory(MagpieTTSVariant.int8.huggingFaceRepoId)
            ready = [asr?.appendingPathComponent("encoder.mlmodelc"),
                     sort?.appendingPathComponent("Sortformer.mlmodelc"),
                     magpie?.appendingPathComponent("nanocodec_decoder/model.safetensors"),
                     Self.rivaPath].allSatisfy { $0.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
            status = ready ? "Modelli in cache · verifica integrità al download" : "Scarica i modelli per iniziare"
        }
    }

    static let rivaFile = "Riva-Translate-4B-Instruct-v2-Q4_K_M.gguf"
    static let rivaHash = "90c2f48ff5549b770d9aaecb7eea603548bcca035a970a800d9c17781991804d"
    static let rivaURL = URL(string: "https://huggingface.co/liodon-ai/Riva-Translate-4B-Instruct-v2-imatrix-GGUF/resolve/main/Riva-Translate-4B-Instruct-v2-Q4_K_M.gguf?download=true")!
    static let rivaPath = AppStoragePaths.models.appendingPathComponent(rivaFile)

    static func modelDirectory(_ modelId: String) throws -> URL {
        try HuggingFaceDownloader.getCacheDirectory(for: modelId)
    }

    func downloadAll() {
        guard !downloading else { return }
        downloading = true
        ready = false
        work = Task {
            do {
                let asrID = NemotronStreamingASRModel.defaultModelId
                status = "Nemotron 3.5: download/resume + verifica SHA"
                let asrPath = try Self.modelDirectory(asrID)
                try await HuggingFaceDownloader.downloadWeights(
                    modelId: asrID, to: asrPath,
                    additionalFiles: ["encoder.mlmodelc/**", "decoder.mlmodelc/**", "joint.mlmodelc/**",
                                      "vocab.json", "tokenizer.model", "*_tokenizer.model",
                                      "vocab.txt", "languages.json", "config.json"],
                    progressHandler: { value in Task { @MainActor in self.fraction = 0.25 * value } })
                try Task.checkCancellation()
                status = "Sortformer: download/resume + verifica SHA"
                let sortID = SortformerDiarizer.defaultModelId
                let sortPath = try Self.modelDirectory(sortID)
                try await HuggingFaceDownloader.downloadWeights(
                    modelId: sortID, to: sortPath,
                    additionalFiles: ["Sortformer.mlmodelc/**", "config.json"],
                    progressHandler: { value in Task { @MainActor in self.fraction = 0.25 + 0.25 * value } })
                try Task.checkCancellation()
                status = "Magpie + NanoCodec: download/resume + verifica SHA"
                _ = try await MagpieTTSDownloader.ensureDownloaded(variant: .int8) { value in
                    Task { @MainActor in self.fraction = 0.50 + 0.25 * value }
                }
                try Task.checkCancellation()
                status = "Riva Translate Q4_K_M: download/resume + SHA-256"
                try await Self.downloadRiva { value in
                    Task { @MainActor in self.fraction = 0.75 + 0.25 * value }
                }
                fraction = 1
                ready = true
                status = "Modelli pronti sul dispositivo"
                SessionLog.shared.write("Download modelli completato", always: true)
            } catch is CancellationError {
                status = "Download sospeso: riprende dal pulsante"
                SessionLog.shared.write("Download sospeso", always: true)
            } catch {
                status = "Modelli incompleti: \(error.localizedDescription)"
                SessionLog.shared.write("Download modello fallito: \(error.localizedDescription)", always: true)
            }
            downloading = false
            work = nil
        }
    }

    func stop() { work?.cancel() }

    private static func downloadRiva(progress: @escaping (Double) -> Void) async throws {
        let final = rivaPath
        if FileManager.default.fileExists(atPath: final.path),
           try sha256(final) == rivaHash { return }
        let part = final.appendingPathExtension("part")
        var offset = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var total: Int64?
        repeat {
            try Task.checkCancellation()
            let end = offset + 8 * 1024 * 1024 - 1
            var request = URLRequest(url: rivaURL)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
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
            if let total, total > 0 { progress(min(1, Double(offset) / Double(total))) }
        } while total.map { offset < $0 } ?? true
        let actual = try sha256(part)
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
