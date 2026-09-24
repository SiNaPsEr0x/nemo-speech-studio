import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AudioCommon
import UIKit

final class StudioAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping @Sendable () -> Void) {
        HuggingFaceDownloader.handleBackgroundSessionEvents(
            identifier: identifier, completionHandler: completionHandler)
    }
}

// A single, per-process session log: truncate before anything else writes to it.
final class SessionLog: @unchecked Sendable {
    static let shared = SessionLog()
    let url: URL
    private let queue = DispatchQueue(label: "NeMoStudio.sessionLog")
    private let formatter = ISO8601DateFormatter()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        write("Avvio applicazione", always: true)
        if UserDefaults.standard.bool(forKey: "lastSessionUnfinished") {
            write("Sessione precedente interrotta senza chiusura regolare (possibile arresto improvviso).", always: true)
        }
        UserDefaults.standard.set(true, forKey: "lastSessionUnfinished")
    }

    func write(_ message: String, always: Bool = false) {
        guard always || UserDefaults.standard.bool(forKey: "debugEnabled") else { return }
        queue.async { [self] in
            let safe = message.replacingOccurrences(of: "\n", with: " ")
            let line = "\(formatter.string(from: Date())) \(safe)\n"
            guard let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch { /* Logging cannot crash the app. */ }
        }
    }

    func finish() {
        write("Sessione in pausa / background", always: true)
        UserDefaults.standard.set(false, forKey: "lastSessionUnfinished")
    }
}

enum AppStoragePaths {
    static let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let models = base.appendingPathComponent("Models", isDirectory: true)
    static let output = base.appendingPathComponent("Output", isDirectory: true)
    static let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("NeMoStudio", isDirectory: true)

    static func prepare() {
        for folder in [models, output, temporary] {
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            catch { SessionLog.shared.write("Creazione cartella \(folder.lastPathComponent): \(error.localizedDescription)", always: true) }
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var modelDirectory = models
        var temporaryDirectory = temporary
        try? modelDirectory.setResourceValues(values)
        try? temporaryDirectory.setResourceValues(values)
    }
}

@main
struct NeMoStudioApp: App {
    @UIApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UserDefaults.standard.register(defaults: ["debugEnabled": false])
        _ = SessionLog.shared
        AppStoragePaths.prepare()
        // Models are never placed in the purgeable iOS Library/Caches directory.
        setenv("QWEN3_CACHE_DIR", AppStoragePaths.models.path, 1)
        HuggingFaceDownloader.backgroundTransfer = BackgroundTransferConfiguration(
            sessionIdentifier: "io.github.sinapser0x.nemostudio.models")
    }

    var body: some Scene {
        WindowGroup {
            StudioView()
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        UserDefaults.standard.set(true, forKey: "lastSessionUnfinished")
                        SessionLog.shared.write("App attiva")
                    } else if phase == .background {
                        SessionLog.shared.finish()
                    }
                }
        }
    }
}

private enum StudioStyle {
    static let background = Color(red: 0.035, green: 0.075, blue: 0.10)
    static let surface = Color(red: 0.075, green: 0.14, blue: 0.17)
    static let accent = Color(red: 0.54, green: 0.96, blue: 0.61)
    static let muted = Color(red: 0.62, green: 0.72, blue: 0.72)
}

private enum StudioMode: String, CaseIterable, Identifiable {
    case transcription = "Trascrizione"
    case subtitles = "Sottotitoli"
    case softSubtitles = "Video + traccia"
    case burnIn = "Video impresso"
    case dubbing = "Doppiaggio"
    case complete = "Tutto"
    var id: String { rawValue }
    var available: Bool { self == .transcription || self == .subtitles }
}

struct StudioView: View {
    @StateObject private var library = ModelLibrary()
    @State private var importerOpen = false
    @State private var selectedFile: URL?
    @State private var importing = false
    @State private var mode: StudioMode = .transcription
    @State private var info: String?
    @State private var debugEnabled = UserDefaults.standard.bool(forKey: "debugEnabled")
    @State private var language = "it-IT"
    @State private var translate = false
    @State private var targetLanguage = "en"
    @State private var diarization = true
    @State private var working = false
    @State private var status = ""
    @State private var lines: [StudioLine] = []
    @State private var translated: [StudioLine] = []
    @State private var files: [URL] = []
    @State private var job: Task<Void, Never>?
    @State private var voiceText = ""
    @State private var voice = "John"
    @State private var voiceFile: URL?

    var body: some View {
        ZStack {
            StudioStyle.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    hero
                    modelCard
                    importCard
                    workflowCard
                    engineCard
                    voiceCard
                    diagnostics
                    Text("NeMo Studio · progetto indipendente · SiNaPsEr0x")
                        .font(.caption2).foregroundStyle(StudioStyle.muted)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .fileImporter(isPresented: $importerOpen, allowedContentTypes: [.audio, .movie, .video, .mpeg4Movie, .data]) { result in
            switch result {
            case .success(let url): importMedia(url)
            case .failure(let error):
                info = "Impossibile aprire il file: \(error.localizedDescription)"
                SessionLog.shared.write("Importazione fallita: \(error.localizedDescription)", always: true)
            }
        }
        .alert("NeMo Studio", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
            Button("OK", role: .cancel) { info = nil }
        } message: { Text(info ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            debugEnabled = UserDefaults.standard.bool(forKey: "debugEnabled")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.title2.weight(.bold)).foregroundStyle(StudioStyle.accent)
                .frame(width: 48, height: 48).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text("NeMo Studio").font(.title2.bold())
                Text("Il tuo studio audio, sul dispositivo").font(.caption).foregroundStyle(StudioStyle.muted)
            }
            Spacer()
            Circle().fill(.orange).frame(width: 9, height: 9)
        }
        .accessibilityElement(children: .combine)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("AUDIO · VOCI · VIDEO").font(.caption.bold()).tracking(2).foregroundStyle(StudioStyle.accent)
            Text("Ogni voce ha\nuna storia.")
                .font(.system(size: 40, weight: .heavy, design: .rounded)).tracking(-1.6)
                .fixedSize(horizontal: false, vertical: true)
            Text("Importa una registrazione e prepara il tuo flusso di lavoro, senza caricare file su un server.")
                .foregroundStyle(.white.opacity(0.78))
            Waveform().frame(height: 65).padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            LinearGradient(colors: [Color(red: 0.11, green: 0.31, blue: 0.24), StudioStyle.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 25)
        )
        .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(StudioStyle.accent.opacity(0.25)))
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Il tuo file", systemImage: "square.and.arrow.down.fill").font(.headline)
            Button { importerOpen = true } label: {
                VStack(spacing: 8) {
                    Image(systemName: selectedFile == nil ? "plus.circle.fill" : "waveform")
                        .font(.system(size: 33)).foregroundStyle(StudioStyle.accent)
                    Text(importing ? "Copio il file in locale…" : (selectedFile?.lastPathComponent ?? "Scegli audio o video"))
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text("Il file viene copiato nello spazio privato dell’app")
                        .font(.caption).foregroundStyle(StudioStyle.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 25)
                .background(StudioStyle.background, in: RoundedRectangle(cornerRadius: 17))
            }
            .buttonStyle(.plain)
            .disabled(importing)
        }.card()
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Modelli sul telefono", systemImage: "arrow.down.circle.fill").font(.headline)
            Text(library.status).font(.caption).foregroundStyle(StudioStyle.muted)
            if library.downloading { ProgressView(value: library.fraction).tint(StudioStyle.accent) }
            HStack {
                Button(library.downloading ? "Download in corso" : "Scarica / riprendi modelli") {
                    library.downloadAll()
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.accent)
                .disabled(library.downloading)
                if library.downloading {
                    Button("Stop") { library.stop() }.buttonStyle(.bordered)
                }
            }
            Text("Nemotron 3.5 · Sortformer · Magpie/NanoCodec · Riva 4B. I file restano nella cartella privata Models; un download interrotto riparte da quelli già verificati.")
                .font(.caption2).foregroundStyle(StudioStyle.muted)
        }.card()
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("Flusso di lavoro", systemImage: "slider.horizontal.3").font(.headline)
            Picker("Preset", selection: $mode) {
                ForEach(StudioMode.allCases) { option in Text(option.rawValue).tag(option) }
            }
            .tint(StudioStyle.accent)
            .onChange(of: mode) { value in SessionLog.shared.write("Preset selezionato: \(value.rawValue)") }
            Picker("Lingua originale", selection: $language) {
                Text("Italiano").tag("it-IT")
                Text("Automatico").tag("auto")
                Text("Inglese").tag("en")
                Text("Francese").tag("fr")
                Text("Tedesco").tag("de")
                Text("Spagnolo").tag("es")
            }
            .tint(StudioStyle.accent)
            Toggle("Riconosci i parlanti con Sortformer", isOn: $diarization)
                .tint(StudioStyle.accent).font(.subheadline)
            Toggle("Traduci in locale con Riva 4B", isOn: $translate)
                .tint(StudioStyle.accent).font(.subheadline)
            if translate {
                Picker("Lingua di destinazione", selection: $targetLanguage) {
                    Text("Inglese").tag("en")
                    Text("Italiano").tag("it")
                    Text("Francese").tag("fr")
                    Text("Tedesco").tag("de")
                    Text("Spagnolo").tag("es")
                }
                Text("Riva supporta queste lingue tramite l’inglese; scegli una lingua originale esplicita per la traduzione.")
                    .font(.caption2).foregroundStyle(StudioStyle.muted)
            }
            HStack(spacing: 9) {
                feature("Trascrivi", "text.quote")
                feature("Parlanti", "person.2.wave.2")
                feature("Traduci", "character.book.closed")
            }
            Text(mode.available ? "Nemotron 3.5, Sortformer e Riva elaborano sul dispositivo. I modelli vanno scaricati una sola volta." : "Questo preset richiede ancora produzione video iOS: non produce risultati simulati.")
                .font(.caption).foregroundStyle(StudioStyle.muted)
            Button(working ? "Elaborazione in corso" : "Avvia elaborazione") { start() }
                .buttonStyle(.borderedProminent).tint(StudioStyle.accent)
                .disabled(working || importing || !library.ready || selectedFile == nil || !mode.available || (translate && language == "auto"))
                .frame(maxWidth: .infinity)
            if working { Button("Stop elaborazione") { job?.cancel() }.foregroundStyle(.orange) }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(StudioStyle.accent) }
        }.card()
    }

    private var engineCard: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "cpu").foregroundStyle(StudioStyle.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Nemotron 3.5 + Sortformer + Riva + Magpie").font(.subheadline.bold())
                Text("Modelli NVIDIA sul dispositivo: ASR Core ML, Riva GGUF/Metal e TTS MLX. Il mux video non è ancora disponibile.")
                    .font(.caption).foregroundStyle(StudioStyle.muted)
            }
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trascrizione").font(.headline)
                    ForEach(lines) { line in
                        Text("\(line.speaker > 0 ? "Speaker \(line.speaker) · " : "")\(line.text)")
                            .font(.caption).foregroundStyle(.white.opacity(0.9))
                    }
                    ForEach(files, id: \.self) { file in
                        ShareLink(item: file) { Label(file.lastPathComponent, systemImage: "square.and.arrow.up") }
                            .font(.caption).foregroundStyle(StudioStyle.accent)
                    }
                }
            }
            if !translated.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Traduzione Riva").font(.headline)
                    ForEach(translated) { line in
                        Text("\(line.speaker > 0 ? "Speaker \(line.speaker) · " : "")\(line.text)")
                            .font(.caption).foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
        }.card()
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Voce Magpie", systemImage: "waveform.badge.mic").font(.headline)
            TextField("Testo da pronunciare", text: $voiceText, axis: .vertical)
                .lineLimit(2...5).padding(10).background(StudioStyle.background, in: RoundedRectangle(cornerRadius: 11))
            Picker("Voce", selection: $voice) {
                ForEach(["John", "Sofia", "Jason", "Aria", "Leo"], id: \.self) { Text($0).tag($0) }
            }
            Button("Genera WAV in italiano") { synthesize() }
                .disabled(!library.ready || voiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                .buttonStyle(.borderedProminent).tint(StudioStyle.accent)
            if let voiceFile {
                ShareLink(item: voiceFile) { Label("Condividi WAV", systemImage: "square.and.arrow.up") }
                    .foregroundStyle(StudioStyle.accent)
            }
        }.card()
    }

    private func start() {
        guard let selectedFile else { return }
        working = true
        files = []
        lines = []
        translated = []
        status = "Avvio modello locale..."
        let selectedLanguage = language
        let selectedTarget = translate && targetLanguage != String(language.prefix(2)) ? targetLanguage : nil
        let useDiarization = diarization
        let makeSubtitles = mode == .subtitles
        job = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await StudioPipeline.process(source: selectedFile, language: selectedLanguage,
                                                     targetLanguage: selectedTarget,
                                                     diarization: useDiarization, subtitles: makeSubtitles) { phase in
                        Task { @MainActor in self.status = phase }
                    }
                }
                let result = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: { worker.cancel() })
                lines = result.lines
                translated = result.translated
                files = result.files
                status = "Completato: \(result.files.count) file pronti"
            } catch is CancellationError {
                status = "Interrotto"
            } catch {
                status = "Errore: \(error.localizedDescription)"
                SessionLog.shared.write("Elaborazione fallita: \(error.localizedDescription)", always: true)
            }
            working = false
            job = nil
        }
    }

    private func synthesize() {
        working = true
        status = "MagpieTTS genera la voce..."
        let text = voiceText
        let selectedVoice = voice
        job = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await StudioPipeline.synthesize(text, voice: selectedVoice, language: "it")
                }
                voiceFile = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: { worker.cancel() })
                status = "WAV pronto"
            } catch {
                status = "Errore voce: \(error.localizedDescription)"
                SessionLog.shared.write("Magpie fallito: \(error.localizedDescription)", always: true)
            }
            working = false
            job = nil
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Diagnostica", systemImage: "stethoscope").font(.headline)
            Text("Debug \(debugEnabled ? "attivo" : "spento") · Impostazioni iOS → NeMo Studio → Debug")
                .font(.caption).foregroundStyle(StudioStyle.muted)
            ShareLink(item: SessionLog.shared.url) {
                Label("Condividi il log di questa sessione", systemImage: "square.and.arrow.up")
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(StudioStyle.accent)
        }.card()
    }

    private func feature(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(StudioStyle.accent)
            Text(title).font(.caption2).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 13)
        .background(StudioStyle.background, in: RoundedRectangle(cornerRadius: 13))
    }

    private func importMedia(_ url: URL) {
        importing = true
        Task {
            do {
                let destination = try await Task.detached(priority: .utility) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let destination = AppStoragePaths.temporary.appendingPathComponent(
                        UUID().uuidString + "-" + url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: destination)
                    return destination
                }.value
                if let previous = selectedFile { try? FileManager.default.removeItem(at: previous) }
                selectedFile = destination
                SessionLog.shared.write("Media importato: \(destination.lastPathComponent)")
            } catch {
                info = "Copia non riuscita: \(error.localizedDescription)"
                SessionLog.shared.write("Copia media fallita: \(error.localizedDescription)", always: true)
            }
            importing = false
        }
    }
}

private struct Waveform: View {
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<44, id: \.self) { index in
                    Capsule()
                        .fill(StudioStyle.accent.opacity(0.32 + Double(index % 5) * 0.13))
                        .frame(maxWidth: .infinity)
                        .frame(height: 8 + CGFloat((index * 17 + index * index * 3) % 54))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }
}

private extension View {
    func card() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08)))
    }
}
