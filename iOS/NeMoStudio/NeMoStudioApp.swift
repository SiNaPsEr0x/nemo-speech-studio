import Foundation
import SwiftUI
import UniformTypeIdentifiers

// A single, per-process session log: truncate before anything else writes to it.
final class SessionLog {
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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UserDefaults.standard.register(defaults: ["debugEnabled": false])
        _ = SessionLog.shared
        AppStoragePaths.prepare()
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
}

struct StudioView: View {
    @State private var importerOpen = false
    @State private var selectedFile: URL?
    @State private var mode: StudioMode = .transcription
    @State private var info: String?
    @State private var debugEnabled = UserDefaults.standard.bool(forKey: "debugEnabled")

    var body: some View {
        ZStack {
            StudioStyle.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    hero
                    importCard
                    workflowCard
                    engineCard
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
                    Text(selectedFile?.lastPathComponent ?? "Scegli audio o video")
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text("Il file viene copiato nello spazio privato dell’app")
                        .font(.caption).foregroundStyle(StudioStyle.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 25)
                .background(StudioStyle.background, in: RoundedRectangle(cornerRadius: 17))
            }
            .buttonStyle(.plain)
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
            HStack(spacing: 9) {
                feature("Trascrivi", "text.quote")
                feature("Parlanti", "person.2.wave.2")
                feature("Traduci", "character.book.closed")
            }
            Text("Le elaborazioni saranno disponibili quando il runtime NeMo sarà portato e validato su iOS.")
                .font(.caption).foregroundStyle(StudioStyle.muted)
            Button("Avvia elaborazione") {}
                .buttonStyle(.borderedProminent).tint(StudioStyle.accent)
                .disabled(true)
                .frame(maxWidth: .infinity)
        }.card()
    }

    private var engineCard: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "cpu").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Motore NeMo non disponibile su iOS").font(.subheadline.bold())
                Text("Questa versione contiene l’interfaccia e la diagnostica, non i modelli o il motore di inferenza. Nessun risultato viene simulato.")
                    .font(.caption).foregroundStyle(StudioStyle.muted)
            }
        }.card()
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
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let destination = AppStoragePaths.temporary.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            if let previous = selectedFile { try? FileManager.default.removeItem(at: previous) }
            selectedFile = destination
            SessionLog.shared.write("Media importato: \(destination.lastPathComponent)")
        } catch {
            info = "Copia non riuscita: \(error.localizedDescription)"
            SessionLog.shared.write("Copia media fallita: \(error.localizedDescription)", always: true)
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
