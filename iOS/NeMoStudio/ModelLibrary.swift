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

enum RivaQuality: String, CaseIterable, Identifiable {
    case q4 = "Q4_K_M", q5 = "Q5_K_M", q6 = "Q6_K", q8 = "Q8_0"
    var id: String { rawValue }
    var file: String { "Riva-Translate-4B-Instruct-v2-\(rawValue).gguf" }
    var path: URL { AppStoragePaths.models.appendingPathComponent(file) }
    var url: URL {
        URL(string: "https://huggingface.co/liodon-ai/Riva-Translate-4B-Instruct-v2-imatrix-GGUF/resolve/main/\(file)?download=true")!
    }
    var hash: String {
        switch self {
        case .q4: "90c2f48ff5549b770d9aaecb7eea603548bcca035a970a800d9c17781991804d"
        case .q5: "14f6926b8044b4b3e049266df4158815259c62b5342d10fad63b84a518c13dde"
        case .q6: "35a3b9d87b1b53aefab92b871f0b78dacd10716caa392e2bef682646aec122e3"
        case .q8: "924b01c1b17ea592b46cf555c56c00b623f67bf6b0b99bd1653428c2ea595ad0"
        }
    }
    var sizeGB: String {
        switch self {
        case .q4: "2,76"
        case .q5: "3,14"
        case .q6: "3,66"
        case .q8: "4,45"
        }
    }
    var description: String {
        switch self {
        case .q4: "Equilibrato e già provato su iPhone 17 Pro"
        case .q5: "Più precisione, maggiore uso della memoria"
        case .q6: "Qualità vicina al modello pieno"
        case .q8: "Qualità massima; da provare su questo iPhone"
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
    @Published private(set) var selectedRiva: RivaQuality =
        RivaQuality(rawValue: UserDefaults.standard.string(forKey: "selectedRivaQuality") ?? "") ?? .q4

    var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
    var recommendedRiva: RivaQuality {
        if memoryGB >= 10 { return .q6 }
        if memoryGB >= 8 { return .q5 }
        return .q4
    }
    var availableStorage: String {
        let bytes = (try? AppStoragePaths.models.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        guard let bytes else { return "Spazio non disponibile" }
        let format = ByteCountFormatter()
        format.countStyle = .file
        return "Spazio libero: \(format.string(fromByteCount: bytes))"
    }
    func select(_ quality: RivaQuality) {
        guard !downloading else { return }
        selectedRiva = quality
        UserDefaults.standard.set(quality.rawValue, forKey: "selectedRivaQuality")
        refreshPresence()
        SessionLog.shared.write("Riva selected quality=\(quality.rawValue) RAM=\(memoryGB)GiB", always: true)
    }

    init() {
        refreshPresence()
    }

    nonisolated static var rivaPath: URL {
        let quality = RivaQuality(rawValue: UserDefaults.standard.string(forKey: "selectedRivaQuality") ?? "") ?? .q4
        return quality.path
    }
    static let verifiedMarker = AppStoragePaths.models.appendingPathComponent("models-verified-v1.txt")

    private func refreshPresence() {
        let asr = try? Self.modelDirectory(NemotronStreamingASRModel.defaultModelId)
        let sort = try? Self.modelDirectory(SortformerDiarizer.defaultModelId)
        let magpie = try? Self.modelDirectory(MagpieTTSVariant.int8.huggingFaceRepoId)
        let files: [(String, String, URL?)] = [
            ("nemotron", "Nemotron 3.5", asr?.appendingPathComponent("encoder.mlmodelc")),
            ("sortformer", "Sortformer", sort?.appendingPathComponent("Sortformer.mlmodelc")),
            ("magpie", "Magpie", magpie?.appendingPathComponent("nanocodec_decoder/model.safetensors")),
        ] + RivaQuality.allCases.map { quality in
            ("riva:\(quality.rawValue)", "Riva 4B \(quality.rawValue)", Optional(quality.path))
        }
        models = files.map { id, name, file in
            ModelPresence(id: id, name: name,
                          installed: file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        }
        let marker = try? String(contentsOf: Self.verifiedMarker, encoding: .utf8)
        ready = marker == "Riva SHA-256: \(selectedRiva.hash)"
            && models.filter { !$0.id.hasPrefix("riva:") || $0.id == "riva:\(selectedRiva.rawValue)" }
                .allSatisfy(\.installed)
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

    func downloadAll() { download(ids: ["nemotron", "sortformer", "magpie", "riva"]) }

    func downloadModel(_ id: String) {
        guard !id.hasPrefix("riva:") || id == "riva:\(selectedRiva.rawValue)" else { return }
        download(ids: [id.hasPrefix("riva:") ? "riva" : id])
    }

    private func download(ids: Set<String>) {
        guard !downloading else { return }
        downloading = true
        let quality = selectedRiva
        SessionLog.shared.write("Model download started ids=\(ids.sorted()) riva=\(quality.rawValue)", always: true)
        work = Task {
            do {
                try Self.ensureSpace(512 * 1024 * 1024)
                if ids.contains("nemotron") {
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
                }
                try Task.checkCancellation()
                if ids.contains("sortformer") {
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
                }
                try Task.checkCancellation()
                if ids.contains("magpie") {
                status = "Magpie + NanoCodec: download/resume + verifica SHA"
                lastProgressBucket = -1
                _ = try await MagpieTTSDownloader.ensureDownloaded(
                    variant: .int8, progressHandler: reportProgress(base: 0.50, weight: 0.25, model: "Magpie"))
                refreshPresence()
                SessionLog.shared.write("Magpie/NanoCodec download verified")
                }
                try Task.checkCancellation()
                if ids.contains("riva") {
                status = "Riva Translate \(quality.rawValue): download/resume + SHA-256"
                lastProgressBucket = -1
                try await Self.downloadRiva(quality, progress: reportProgress(base: 0.75, weight: 0.25, model: "Riva"))
                }
                refreshPresence()
                if models.filter({ !$0.id.hasPrefix("riva:") || $0.id == "riva:\(quality.rawValue)" })
                    .allSatisfy(\.installed) {
                    // Check the selected file even when it was installed in an older session.
                    guard try Self.sha256(quality.path) == quality.hash else {
                        throw DownloadError.checksumMismatch(file: quality.file, expected: quality.hash,
                                                              actual: try Self.sha256(quality.path))
                    }
                    try ("Riva SHA-256: " + quality.hash).write(
                        to: Self.verifiedMarker, atomically: true, encoding: .utf8)
                }
                fraction = 1
                refreshPresence()
                status = ready ? "Modelli pronti sul dispositivo" : "Scarica i modelli mancanti per iniziare"
                SessionLog.shared.write("Download modelli completato ready=\(ready)", always: true)
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

    func deleteModel(_ id: String) throws {
        guard !downloading else { return }
        let destination: URL
        switch id {
        case "nemotron": destination = try Self.modelDirectory(NemotronStreamingASRModel.defaultModelId)
        case "sortformer": destination = try Self.modelDirectory(SortformerDiarizer.defaultModelId)
        case "magpie": destination = try Self.modelDirectory(MagpieTTSVariant.int8.huggingFaceRepoId)
        case let rivaID where rivaID.hasPrefix("riva:"):
            guard let quality = RivaQuality(rawValue: String(rivaID.dropFirst("riva:".count))) else { return }
            destination = quality.path
        default: return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        if id.hasPrefix("riva:") {
            let partial = destination.appendingPathExtension("part")
            if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
        }
        if !id.hasPrefix("riva:") || id == "riva:\(selectedRiva.rawValue)" {
            try? FileManager.default.removeItem(at: Self.verifiedMarker)
        }
        refreshPresence()
        SessionLog.shared.write("Model removed id=\(id) name=\(destination.lastPathComponent)", always: true)
    }

    private static func downloadRiva(_ quality: RivaQuality, progress: @escaping @Sendable (Double) -> Void) async throws {
        let final = quality.path
        if FileManager.default.fileExists(atPath: final.path),
           try sha256(final) == quality.hash {
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
            var request = URLRequest(url: quality.url)
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
        SessionLog.shared.write("Riva SHA-256 expected=\(quality.hash) actual=\(actual)")
        guard actual == quality.hash else {
            try FileManager.default.removeItem(at: part)
            throw DownloadError.checksumMismatch(file: quality.file, expected: quality.hash, actual: actual)
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
