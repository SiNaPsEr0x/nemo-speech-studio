import AVFoundation
import Combine
import Foundation
import CoreTransferable
import PhotosUI
import Photos
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

// Files → On My iPhone → NeMo Studio → session.log. A new debug session
// preserves recent sessions; no diagnostics are written with Debug disabled.
final class SessionLog: @unchecked Sendable {
    static let shared = SessionLog()
    let url: URL
    private let queue = DispatchQueue(label: "NeMoStudio.sessionLog")
    private let formatter = ISO8601DateFormatter()
    private var enabled = false
    private let sessionID = UUID().uuidString.prefix(8)

    private init() {
        url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("session.log")
        refresh()
        UserDefaults.standard.set(true, forKey: "lastSessionUnfinished")
    }

    func refresh() {
        let shouldEnable = UserDefaults.standard.bool(forKey: "debugEnabled")
        queue.sync {
            guard shouldEnable != enabled else { return }
            if shouldEnable {
                let legacy = AppStoragePaths.base.appendingPathComponent("session.log")
                try? FileManager.default.removeItem(at: legacy)
                do {
                    let logSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if logSize > 8_000_000 {
                        let previous = url.deletingLastPathComponent().appendingPathComponent("session-previous.log")
                        try? FileManager.default.removeItem(at: previous)
                        try? FileManager.default.moveItem(at: url, to: previous)
                    }
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try Data().write(to: url, options: .atomic)
                    }
                    enabled = true
                    append("──────────────── NEW SESSION ────────────────")
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                    append("SESSION \(sessionID) | NeMo Studio \(version) (\(build)) | \(ProcessInfo.processInfo.operatingSystemVersionString) | RAM \(ProcessInfo.processInfo.physicalMemory / 1_048_576) MiB")
                    if UserDefaults.standard.bool(forKey: "lastSessionUnfinished") {
                        append("PREVIOUS SESSION ended unexpectedly while active (possible crash or system termination)")
                    }
                    if UserDefaults.standard.bool(forKey: "jobInProgress") {
                        append("PREVIOUS JOB interrupted at phase=\(UserDefaults.standard.string(forKey: "lastJobPhase") ?? "unknown"); inspect iOS crash/Analytics logs for the termination reason")
                    }
                    append("DEBUG enabled; models kept in Application Support, log exported in Documents")
                } catch { enabled = false }
            } else {
                append("DEBUG disabled")
                enabled = false
            }
        }
    }

    func write(_ message: String, always: Bool = false) {
        let event = "\(always ? "EVENT" : "DEBUG") \(message)"
        if always {
            queue.sync { if enabled { append(event, durable: true) } }
        } else {
            queue.async { [self] in if enabled { append(event) } }
        }
    }

    private func append(_ message: String, durable: Bool = false) {
        let safe = message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(formatter.string(from: Date())) \(safe)\n"
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            if durable { try handle.synchronize() }
        } catch { /* Diagnostics must never interrupt inference. */ }
    }

    func phase(_ message: String) {
        UserDefaults.standard.set(message, forKey: "lastJobPhase")
        write("Pipeline phase: \(message) | thermal=\(ProcessInfo.processInfo.thermalState.rawValue) | uptime=\(Int(ProcessInfo.processInfo.systemUptime))s", always: true)
    }

    func finish() {
        write("App in background", always: true)
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
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        SessionLog.shared.refresh()
                        UserDefaults.standard.set(true, forKey: "lastSessionUnfinished")
                        SessionLog.shared.write("App active", always: true)
                    } else if phase == .background {
                        SessionLog.shared.finish()
                    }
                }
        }
    }
}

private enum StudioStyle {
    static let background = Color(red: 0.035, green: 0.072, blue: 0.10)
    static let surface = Color(red: 0.085, green: 0.145, blue: 0.175)
    static let accent = Color(red: 0.50, green: 0.96, blue: 0.73)
    static let muted = Color(red: 0.68, green: 0.77, blue: 0.79)
}

private enum StudioTab: Hashable { case home, studio, results, voice }

private enum PhotoExportError: LocalizedError {
    case accessDenied
    case invalidVideo

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Consenti a NeMo Studio di aggiungere video in Impostazioni → Foto."
        case .invalidVideo: "Il video non è leggibile da iOS e non può essere salvato in Foto."
        }
    }
}

private enum PhotoLibraryWriter {
    static func saveVideo(_ file: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.lastPathComponent
            options.shouldMoveFile = false
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: options)
        }
    }
}

// Photos gives the app a temporary file; preserve it inside the transfer
// callback so long videos never have to pass through an in-memory Data value.
private struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let name = "photo-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)"
            let destination = AppStoragePaths.temporary.appendingPathComponent(name)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}

private enum StudioMode: String, CaseIterable, Identifiable {
    case transcription = "Solo trascrizione"
    case subtitles = "File sottotitoli"
    case softSubtitles = "Video con tracce selezionabili"
    case burnIn = "Video con sottotitoli originali"
    case burnTranslated = "Video con sottotitoli tradotti"
    case translatedVideo = "Video tradotto senza sottotitoli"
    case dubbing = "Doppiaggio con audio selezionabile"
    case complete = "Tutti i formati"

    var id: String { rawValue }
    static let videoChoices: [StudioMode] = [.burnIn, .burnTranslated, .translatedVideo]
    static let otherChoices: [StudioMode] = [.transcription, .subtitles, .softSubtitles, .dubbing, .complete]
    var needsVideo: Bool {
        switch self {
        case .softSubtitles, .burnIn, .burnTranslated, .translatedVideo, .complete: true
        default: false
        }
    }
    var requiresTranslation: Bool { self == .burnTranslated || self == .translatedVideo }
    var symbol: String {
        switch self {
        case .burnIn: "captions.bubble.fill"
        case .burnTranslated: "character.bubble.fill"
        case .translatedVideo: "waveform"
        default: "doc.on.doc"
        }
    }
    var detail: String {
        switch self {
        case .burnIn: "Audio originale e sottotitoli impressi in lingua originale."
        case .burnTranslated: "Audio originale e sottotitoli tradotti impressi nel video."
        case .translatedVideo: "Solo audio tradotto, senza voce originale né sottotitoli."
        case .softSubtitles: "MKV H.264/HEVC con tracce sottotitoli attivabili."
        case .dubbing: "MOV con audio originale e doppiato selezionabili."
        case .complete: "Trascrizioni, sottotitoli, MKV, MP4 e doppiaggio."
        case .subtitles: "File SRT, VTT e ASS separati dal video."
        case .transcription: "File TXT e JSON con il testo riconosciuto."
        }
    }
}

struct StudioView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = ModelLibrary()
    @State private var selectedTab: StudioTab = .home
    @State private var importerOpen = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedFile: URL?
    @State private var selectedHasVideo = false
    @State private var importing = false
    @State private var mode: StudioMode = .transcription
    @State private var info: String?
    @State private var language = "it-IT"
    @State private var translate = false
    @State private var targetLanguage = "en"
    @State private var diarization = true
    @State private var working = false
    @State private var status = ""
    @State private var activeStages: [String] = []
    @State private var jobStartedAt = Date()
    @State private var estimatedFinish: Date?
    @State private var progressExpanded = false
    @State private var savingVideo: URL?
    @State private var lines: [StudioLine] = []
    @State private var translated: [StudioLine] = []
    @State private var files: [URL] = []
    @State private var job: Task<Void, Never>?
    @State private var voiceText = ""
    @State private var voice = "John"
    @State private var voiceFile: URL?
    @State private var voicePlayer: AVPlayer?
    @State private var voicePlaying = false
    @FocusState private var voiceTextFocused: Bool

    private var keepsScreenAwake: Bool {
        library.downloading || working || importing || savingVideo != nil
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && keepsScreenAwake
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Inizio", systemImage: "house.fill", value: .home) { homeScreen }
            Tab("Studio", systemImage: "waveform", value: .studio) { studioScreen }
            Tab("Risultati", systemImage: "square.stack.fill", value: .results) { resultsScreen }
            Tab("Voce", systemImage: "mic.fill", value: .voice) { voiceScreen }
        }
        .tint(StudioStyle.accent)
        .overlay(alignment: .topTrailing) {
            if working && !activeStages.isEmpty {
                processingBubble
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                    .zIndex(10)
                    .transition(.scale(scale: 0.65, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: progressExpanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: working)
        .onChange(of: working) { _, isWorking in
            if !isWorking { progressExpanded = false }
        }
        .onAppear { updateIdleTimer() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: keepsScreenAwake) { _, _ in updateIdleTimer() }
        .onChange(of: scenePhase) { _, _ in updateIdleTimer() }
        .fileImporter(isPresented: $importerOpen, allowedContentTypes: [.item]) { result in
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
            SessionLog.shared.refresh()
        }
        .onChange(of: selectedTab) { _, tab in
            voiceTextFocused = false
            SessionLog.shared.write("Tab \(String(describing: tab))")
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: RunLoop.main)) { notification in
            if let item = notification.object as? AVPlayerItem, item === voicePlayer?.currentItem {
                voicePlaying = false
                voicePlayer = nil
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            importPhoto(item)
        }
    }

    private func screen<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            ScrollView {
                content()
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                StudioStyle.background.ignoresSafeArea()
                    .onTapGesture { voiceTextFocused = false }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var homeScreen: some View {
        screen(title: "NeMo Studio") {
            VStack(alignment: .leading, spacing: 18) {
                hero
                modelCard
                Button {
                    selectedTab = .studio
                } label: {
                    Label("Nuova elaborazione", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.accent)
                .controlSize(.large)
                HStack(spacing: 12) {
                    Image(systemName: "iphone.gen3")
                        .font(.title2).foregroundStyle(StudioStyle.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Elabora sul tuo iPhone").font(.subheadline.bold())
                        Text("I file importati restano sul dispositivo.")
                            .font(.caption).foregroundStyle(StudioStyle.muted)
                    }
                }.card()
                Text("NeMo Studio · progetto indipendente · SiNaPsEr0x")
                    .font(.caption2).foregroundStyle(StudioStyle.muted)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var studioScreen: some View {
        screen(title: "Studio") {
            VStack(alignment: .leading, spacing: 18) {
                importCard
                workflowCard
            }
        }
    }

    private var processingBubble: some View {
        Group {
            if progressExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        progressExpanded = false
                    } label: {
                        HStack {
                            Label("Elaborazione in corso", systemImage: "waveform")
                                .font(.subheadline.bold())
                            Spacer()
                            Image(systemName: "chevron.up")
                        }
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chiudi dettagli elaborazione")
                    .padding(.bottom, 10)
                    processingDetails
                }
                .padding(16)
                .frame(width: 310, alignment: .leading)
                .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(StudioStyle.accent.opacity(0.55)))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                .transition(.scale(scale: 0.55, anchor: .topTrailing).combined(with: .opacity))
            } else {
                Button {
                    progressExpanded = true
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "waveform")
                            .font(.title3.bold())
                            .symbolEffect(.pulse, options: .repeating)
                        Text("IN CORSO").font(.system(size: 8, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(StudioStyle.background)
                    .frame(width: 74, height: 74)
                    .background(StudioStyle.accent, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 2))
                    .shadow(color: StudioStyle.accent.opacity(0.45), radius: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Apri dettagli elaborazione: \(status)")
                .transition(.scale(scale: 0.55, anchor: .topTrailing).combined(with: .opacity))
            }
        }
    }

    private var processingDetails: some View {
        let current = stageIndex(for: status)
        return VStack(alignment: .leading, spacing: 9) {
            Text("Fase \(current + 1) di \(activeStages.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(StudioStyle.muted)
            Text(status)
                .font(.subheadline)
                .foregroundStyle(StudioStyle.accent)
                .lineLimit(2)
            ProgressView(value: progressFraction(for: status))
                .tint(StudioStyle.accent)
                .accessibilityLabel("Avanzamento stimato dell'elaborazione")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let estimatedFinish, estimatedFinish > context.date {
                    let seconds = Int(ceil(estimatedFinish.timeIntervalSince(context.date)))
                    Text("Tempo rimanente stimato: \(seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StudioStyle.muted)
                } else {
                    Text("Calcolo il tempo rimanente dai progressi reali…")
                        .font(.caption)
                        .foregroundStyle(StudioStyle.muted)
                }
            }
            Button("Ferma elaborazione", role: .cancel) { job?.cancel() }
                .font(.subheadline)
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.surface)
        .overlay(alignment: .top) { StudioStyle.accent.opacity(0.25).frame(height: 1) }
    }

    private func stageIndex(for phase: String) -> Int {
        let stage: String
        if phase.hasPrefix("Carico Nemotron") || phase.hasPrefix("Trascrivo") { stage = "Trascrizione" }
        else if phase.hasPrefix("Carico Sortformer") || phase.hasPrefix("Riconosco i parlanti") { stage = "Parlanti" }
        else if phase.hasPrefix("Carico Riva") || phase.hasPrefix("Traduco") { stage = "Traduzione" }
        else if phase.hasPrefix("Preparo il doppiaggio") || phase.hasPrefix("Sintetizzo")
                    || phase.hasPrefix("Voce sintetizzata")
                    || phase.hasPrefix("Creo ") || phase.hasPrefix("Imprimo") { stage = "Esportazione" }
        else { stage = "Preparazione" }
        return activeStages.firstIndex(of: stage) ?? 0
    }

    private func progressFraction(for phase: String) -> Double {
        let outputWeight: Double = (mode == .dubbing || mode == .complete || mode == .translatedVideo) ? 12 : 4
        let weights = activeStages.map { stage -> Double in
            switch stage {
            case "Preparazione": return 1
            case "Trascrizione": return 6
            case "Parlanti": return 5
            case "Traduzione": return 4
            default: return outputWeight
            }
        }
        let index = stageIndex(for: phase)
        let completed = weights.prefix(index).reduce(0, +)
        let currentFraction: Double
        if phase.hasPrefix("Traduco con Riva: "), let ratio = countRatio(in: phase, after: "Traduco con Riva: ") {
            currentFraction = max(0, ratio - 1 / Double(max(1, countTotal(in: phase, after: "Traduco con Riva: "))))
        } else if phase.hasPrefix("Sintetizzo la voce: "), let ratio = countRatio(in: phase, after: "Sintetizzo la voce: ") {
            let total = Double(max(1, countTotal(in: phase, after: "Sintetizzo la voce: ")))
            let parts = countRatio(in: phase, after: " · parte ") ?? 0
            let partTotal = Double(max(1, countTotal(in: phase, after: " · parte ")))
            currentFraction = max(0, ratio - 1 / total) + parts / (total * partTotal)
        } else if phase.hasPrefix("Voce sintetizzata: "), let ratio = countRatio(in: phase, after: "Voce sintetizzata: ") {
            currentFraction = ratio
        } else if phase.hasPrefix("Trascrivo sul dispositivo: "), let ratio = countRatio(in: phase, after: "Trascrivo sul dispositivo: ") {
            currentFraction = ratio
        } else if phase.hasPrefix("Riconosco i parlanti: "), let ratio = countRatio(in: phase, after: "Riconosco i parlanti: ") {
            currentFraction = ratio
        } else if phase.hasPrefix("Creo ") || phase.hasPrefix("Imprimo") {
            currentFraction = 0.85
        } else {
            currentFraction = 0
        }
        let total = max(1, weights.reduce(0, +))
        return min(0.99, (completed + weights[index] * min(1, currentFraction)) / total)
    }

    private func countTotal(in phase: String, after marker: String) -> Int {
        guard let range = phase.range(of: marker) else { return 0 }
        let token = phase[range.upperBound...].split(separator: " ").first ?? ""
        return Int(token.split(separator: "/").last ?? "") ?? 0
    }

    private func countRatio(in phase: String, after marker: String) -> Double? {
        guard let range = phase.range(of: marker) else { return nil }
        let token = phase[range.upperBound...].split(separator: " ").first ?? ""
        let numbers = token.split(separator: "/")
        guard numbers.count == 2, let count = Double(numbers[0]),
              let total = Double(numbers[1]), total > 0 else { return nil }
        return min(1, count / total)
    }

    private func refreshEstimate(for phase: String) {
        let fraction = progressFraction(for: phase)
        let elapsed = Date().timeIntervalSince(jobStartedAt)
        guard elapsed >= 2, fraction >= 0.12, fraction < 0.98 else { return }
        let seconds = min(21_600, elapsed * (1 - fraction) / fraction)
        estimatedFinish = Date().addingTimeInterval(seconds)
    }

    private var resultsScreen: some View {
        screen(title: "Risultati") {
            VStack(alignment: .leading, spacing: 18) { resultsCard }
        }
    }

    private var voiceScreen: some View {
        screen(title: "Voce") {
            VStack(alignment: .leading, spacing: 18) { voiceCard }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AUDIO · VOCI · VIDEO")
                .font(.caption.bold()).tracking(1.8).foregroundStyle(StudioStyle.accent)
            Text("Ogni voce ha una storia.")
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text("Trascrivi, traduci e dai voce ai tuoi file.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.8))
            Waveform().frame(height: 40).padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(
            LinearGradient(colors: [Color(red: 0.11, green: 0.31, blue: 0.24), StudioStyle.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(StudioStyle.accent.opacity(0.25)))
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("File da elaborare", systemImage: "square.and.arrow.down.fill")
                .font(.headline).foregroundStyle(.white)
            if let selectedFile {
                Label(selectedFile.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(StudioStyle.accent)
                    .lineLimit(2)
            }
            if importing { ProgressView("Importazione video…").tint(StudioStyle.accent) }
            HStack(spacing: 10) {
                Button { importerOpen = true } label: {
                    Label("File", systemImage: "folder.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.accent)
                .frame(maxWidth: .infinity)
                PhotosPicker(selection: $selectedPhoto, matching: .videos) {
                    Label("Foto", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.accent)
                .frame(maxWidth: .infinity)
            }
            .disabled(importing || working)
            Text("Audio o video da File · video dalla galleria Foto")
                .font(.caption).foregroundStyle(StudioStyle.muted)
        }.card()
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Modelli sul tuo iPhone", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                Spacer()
                Text(library.ready ? "PRONTI" : "DA COMPLETARE")
                    .font(.caption2.bold())
                    .foregroundStyle(library.ready ? StudioStyle.accent : StudioStyle.muted)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Memoria: \(library.memoryGB) GB · \(library.availableStorage)")
                    .font(.subheadline.bold())
                Text("La scelta usa la RAM del dispositivo; velocità e stabilità dipendono anche dal video e dagli altri processi aperti.")
                    .font(.caption).foregroundStyle(StudioStyle.muted)
            }
            Text("Traduzione Riva 4B · classifica per qualità")
                .font(.subheadline.bold())
            Text("È lo stesso modello in quattro precisioni. Più precisione richiede più spazio e memoria.")
                .font(.caption).foregroundStyle(StudioStyle.muted)
            Button {
                library.select(library.recommendedRiva)
            } label: {
                Label("Scegli il massimo consigliato: \(library.recommendedRiva.rawValue)",
                      systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(StudioStyle.accent)
            .disabled(library.downloading || working)
            ForEach(Array(RivaQuality.allCases.reversed())) { quality in
                let selected = library.selectedRiva == quality
                let installed = library.models.first { $0.id == "riva:\(quality.rawValue)" }?.installed ?? false
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        library.select(quality)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? StudioStyle.accent : StudioStyle.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(quality.rawValue) · \(quality.sizeGB) GB")
                                    .font(.subheadline.weight(.semibold))
                                Text(quality.description)
                                    .font(.caption).foregroundStyle(StudioStyle.muted)
                                if quality == library.recommendedRiva {
                                    Text("Consigliato per questo dispositivo")
                                        .font(.caption2.bold()).foregroundStyle(StudioStyle.accent)
                                }
                            }
                            Spacer()
                            if installed {
                                Image(systemName: "internaldrive.fill")
                                    .foregroundStyle(StudioStyle.accent)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(selected ? StudioStyle.accent.opacity(0.13) : StudioStyle.background,
                                    in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(selected ? StudioStyle.accent : StudioStyle.muted.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .disabled(library.downloading || working)
                    if installed {
                        Button("Elimina \(quality.rawValue)", role: .destructive) {
                            do { try library.deleteModel("riva:\(quality.rawValue)") }
                            catch {
                                let message = "Impossibile eliminare Riva \(quality.rawValue): \(error.localizedDescription)"
                                info = message
                                SessionLog.shared.write(message, always: true)
                            }
                        }
                        .font(.caption)
                        .disabled(library.downloading || working)
                        if selected && !library.ready {
                            Button("Verifica \(quality.rawValue)") { library.downloadModel("riva:\(quality.rawValue)") }
                                .font(.caption)
                                .disabled(library.downloading || working)
                        }
                    } else if selected {
                        Button("Scarica \(quality.rawValue)") { library.downloadModel("riva:\(quality.rawValue)") }
                            .font(.caption)
                            .disabled(library.downloading || working)
                    }
                }
            }
            Text("Q8 è la qualità più alta disponibile, ma non è ancora verificata su tutti i dispositivi. Puoi selezionarla manualmente.")
                .font(.caption).foregroundStyle(StudioStyle.muted)
            Text("Modelli per voce e sottotitoli")
                .font(.subheadline.bold())
            ForEach(library.models.filter { !$0.id.hasPrefix("riva:") }) { model in
                HStack(spacing: 8) {
                    Image(systemName: model.installed ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(model.installed ? StudioStyle.accent : StudioStyle.muted)
                    Text(model.name).font(.caption.bold())
                    Spacer(minLength: 4)
                    if model.installed {
                        Button("Elimina") {
                            do { try library.deleteModel(model.id) }
                            catch {
                                let message = "Impossibile eliminare \(model.name): \(error.localizedDescription)"
                                info = message
                                SessionLog.shared.write(message, always: true)
                            }
                        }
                        .tint(.orange)
                    } else {
                        Button("Scarica") { library.downloadModel(model.id) }
                            .tint(StudioStyle.accent)
                    }
                }
                .controlSize(.small)
                .disabled(library.downloading || working)
            }
            Text("Nemotron riconosce le parole · Sortformer distingue fino a 4 parlanti · Magpie crea la voce · Riva traduce.")
                .font(.caption).foregroundStyle(StudioStyle.muted)
            Text(library.status).font(.caption).foregroundStyle(StudioStyle.muted)
            if library.downloading {
                ProgressView(value: library.fraction).tint(StudioStyle.accent)
                Button("Ferma download") { library.stop() }
                    .tint(.orange)
            } else if !library.ready {
                Button("Scarica i modelli mancanti") { library.downloadAll() }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent).tint(StudioStyle.accent)
                    .disabled(working)
            } else {
                Label("Configurazione pronta", systemImage: "checkmark.seal.fill")
                    .font(.caption.bold()).foregroundStyle(StudioStyle.accent)
            }
        }
        .card()
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("Cosa vuoi creare?", systemImage: "slider.horizontal.3")
                .font(.headline)
            Text("VIDEO FINALE")
                .font(.caption.bold()).tracking(1.2).foregroundStyle(StudioStyle.muted)
            ForEach(StudioMode.videoChoices) { option in
                Button {
                    mode = option
                    SessionLog.shared.write("Preset selezionato: \(option.rawValue)")
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: option.symbol)
                            .font(.title3)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.rawValue).font(.subheadline.weight(.semibold))
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(StudioStyle.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: mode == option ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(mode == option ? StudioStyle.accent : StudioStyle.muted)
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(mode == option ? StudioStyle.accent.opacity(0.16) : StudioStyle.background,
                                in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(mode == option ? StudioStyle.accent : StudioStyle.muted.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .disabled(working)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
            Menu {
                ForEach(StudioMode.otherChoices) { option in
                    Button(option.rawValue) {
                        mode = option
                        SessionLog.shared.write("Preset selezionato: \(option.rawValue)")
                    }
                }
            } label: {
                Label(StudioMode.videoChoices.contains(mode) ? "Altri risultati" : mode.rawValue,
                      systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(StudioStyle.accent)
            .controlSize(.large)
            .disabled(working)
            if !StudioMode.videoChoices.contains(mode) {
                Text(mode.detail).font(.caption).foregroundStyle(StudioStyle.muted)
            }
            VStack(alignment: .leading, spacing: 7) {
                Label("Lingua originale del file", systemImage: "waveform")
                    .font(.subheadline.bold())
                Text("La lingua parlata nell'audio importato. Serve a riconoscere le parole e a tradurle correttamente.")
                    .font(.caption).foregroundStyle(StudioStyle.muted)
                Picker("Lingua originale del file", selection: $language) {
                Text("Italiano").tag("it-IT")
                Text("Automatico").tag("auto")
                Text("Inglese").tag("en")
                Text("Francese").tag("fr")
                Text("Tedesco").tag("de")
                Text("Spagnolo").tag("es")
            }
                .tint(StudioStyle.accent)
                .pickerStyle(.menu)
            }
            Toggle("Riconosci i parlanti con Sortformer", isOn: $diarization)
                .tint(StudioStyle.accent).font(.subheadline)
            if !mode.requiresTranslation {
                Toggle("Traduci in locale con Riva 4B", isOn: $translate)
                    .tint(StudioStyle.accent).font(.subheadline)
            }
            if translate || mode.requiresTranslation {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Lingua del risultato tradotto", systemImage: "character.bubble")
                        .font(.subheadline.bold())
                    Text(mode == .translatedVideo
                         ? "La lingua della nuova voce nel video. L'audio originale non sarà presente."
                         : "La lingua dei sottotitoli tradotti o della nuova voce, secondo il risultato scelto.")
                        .font(.caption).foregroundStyle(StudioStyle.muted)
                    Picker("Lingua del risultato tradotto", selection: $targetLanguage) {
                    Text("Inglese").tag("en")
                    Text("Italiano").tag("it")
                    Text("Francese").tag("fr")
                    Text("Tedesco").tag("de")
                    Text("Spagnolo").tag("es")
                }
                    .tint(StudioStyle.accent)
                    .pickerStyle(.menu)
                }
                Text("Riva traduce sul dispositivo dalla lingua originale alla lingua del risultato; scegline due diverse.")
                    .font(.caption).foregroundStyle(StudioStyle.muted)
            }
            if (translate || mode.requiresTranslation) && targetLanguage == String(language.prefix(2)) {
                Text("Scegli una lingua di destinazione diversa dall'originale.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button { start() } label: {
                Label(working ? "Elaborazione in corso" : "Crea risultato", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(StudioStyle.accent).controlSize(.large)
            .disabled(working || importing || !library.ready || selectedFile == nil
                || (mode.needsVideo && !selectedHasVideo)
                || ((translate || mode.requiresTranslation || mode == .dubbing || mode == .complete) && language == "auto")
                || ((translate || mode.requiresTranslation) && targetLanguage == String(language.prefix(2))))
            if mode.needsVideo && selectedFile != nil && !selectedHasVideo {
                Text("Questo risultato richiede un video con audio.")
                    .font(.caption).foregroundStyle(StudioStyle.muted)
            }
            if !working && !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(StudioStyle.accent)
            }
            if !library.ready {
                Text("Prima scarica i modelli nella tab Inizio.")
                    .font(.caption).foregroundStyle(StudioStyle.muted)
            }
        }.card()
    }

    private func isVideo(_ url: URL) -> Bool {
        ["mp4", "mov", "mkv"].contains(url.pathExtension.lowercased())
    }

    private var displayFiles: [URL] {
        files.filter(isVideo) + files.filter { !isVideo($0) }
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            if lines.isEmpty && files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 38)).foregroundStyle(StudioStyle.accent)
                    Text("I risultati appariranno qui").font(.headline)
                    Text("Importa un file e avvia un'elaborazione nella tab Studio.")
                        .font(.subheadline).multilineTextAlignment(.center)
                        .foregroundStyle(StudioStyle.muted)
                    Button("Apri Studio") { selectedTab = .studio }
                        .buttonStyle(.borderedProminent).tint(StudioStyle.accent)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            }
            let videos = displayFiles.filter(isVideo)
            if !videos.isEmpty {
                Label("Video pronti", systemImage: "film.stack.fill").font(.headline)
                ForEach(videos, id: \.self) { file in fileRow(file) }
            }
            let otherFiles = displayFiles.filter { !isVideo($0) }
            if !otherFiles.isEmpty {
                Divider().overlay(StudioStyle.muted.opacity(0.4))
                Text("Altri file").font(.headline)
                ForEach(otherFiles, id: \.self) { file in fileRow(file) }
            }
            if !lines.isEmpty {
                DisclosureGroup("Leggi trascrizione") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(lines) { line in
                            Text("\(line.speaker > 0 ? "Speaker \(line.speaker) · " : "")\(line.text)")
                                .font(.caption).foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
                .tint(StudioStyle.accent)
            }
            if !translated.isEmpty {
                DisclosureGroup("Leggi traduzione") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(translated) { line in
                            Text("\(line.speaker > 0 ? "Speaker \(line.speaker) · " : "")\(line.text)")
                                .font(.caption).foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
                .tint(StudioStyle.accent)
            }
        }.card()
    }

    private func fileRow(_ file: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(file.lastPathComponent, systemImage: isVideo(file) ? "film.fill" : "doc.fill")
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(2)
            HStack(spacing: 12) {
                ShareLink(item: file) {
                    Label("Condividi", systemImage: "square.and.arrow.up")
                }
                if ["mp4", "mov"].contains(file.pathExtension.lowercased()) {
                    Button {
                        saveToPhotos(file)
                    } label: {
                        Label(savingVideo == file ? "Salvo…" : "Salva in Foto",
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled(savingVideo != nil)
                }
            }
            .font(.subheadline)
            .foregroundStyle(StudioStyle.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(StudioStyle.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func saveToPhotos(_ file: URL) {
        savingVideo = file
        SessionLog.shared.write("Photos save started type=\(file.pathExtension.lowercased())", always: true)
        Task {
            do {
                let asset = AVURLAsset(url: file)
                guard FileManager.default.fileExists(atPath: file.path),
                      try await asset.load(.isPlayable),
                      !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                    throw PhotoExportError.invalidVideo
                }
                SessionLog.shared.write("Photos save video validated", always: true)
                let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                SessionLog.shared.write("Photos save authorization=\(authorization.rawValue)", always: true)
                guard authorization == .authorized || authorization == .limited else {
                    throw PhotoExportError.accessDenied
                }
                try await PhotoLibraryWriter.saveVideo(file)
                info = "Video salvato nel rullino Foto."
                SessionLog.shared.write("Photos save succeeded type=\(file.pathExtension.lowercased())", always: true)
            } catch {
                info = "Salvataggio in Foto non riuscito: \(error.localizedDescription)"
                SessionLog.shared.write("Photos save failed: \(String(reflecting: error))", always: true)
            }
            savingVideo = nil
        }
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Voce Magpie", systemImage: "waveform.badge.mic").font(.headline)
            VStack(alignment: .trailing, spacing: 6) {
                TextField("Testo da pronunciare", text: $voiceText, axis: .vertical)
                    .focused($voiceTextFocused)
                    .lineLimit(2...5)
                if voiceTextFocused {
                    Button("Fine") { voiceTextFocused = false }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioStyle.accent)
                }
            }
            .padding(10)
            .background(StudioStyle.background, in: RoundedRectangle(cornerRadius: 11))
            Picker("Voce", selection: $voice) {
                ForEach(["John", "Sofia", "Jason", "Aria", "Leo"], id: \.self) { Text($0).tag($0) }
            }
            Button { synthesize() } label: {
                Label("Genera WAV in italiano", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
                .disabled(!library.ready || voiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                .buttonStyle(.borderedProminent).tint(StudioStyle.accent).controlSize(.large)
            if let voiceFile {
                Button {
                    if voicePlaying {
                        voicePlayer?.pause()
                        voicePlaying = false
                    } else {
                        do { try playVoice(voiceFile) }
                        catch { info = "Riproduzione non riuscita: \(error.localizedDescription)" }
                    }
                } label: {
                    Label(voicePlaying ? "Pausa" : "Riproduci", systemImage: voicePlaying ? "pause.fill" : "play.fill")
                }
                .foregroundStyle(StudioStyle.accent)
                ShareLink(item: voiceFile) { Label("Condividi WAV", systemImage: "square.and.arrow.up") }
                    .foregroundStyle(StudioStyle.accent)
            }
            if !library.ready {
                Text("I modelli Magpie si scaricano dalla tab Inizio.")
                    .font(.caption).foregroundStyle(StudioStyle.muted)
            }
        }.card()
    }

    private func start() {
        guard let selectedFile else { return }
        working = true
        files = []
        lines = []
        translated = []
        status = "Preparo la traccia audio"
        jobStartedAt = Date()
        estimatedFinish = nil
        activeStages = ["Preparazione", "Trascrizione"]
        if diarization { activeStages.append("Parlanti") }
        if translate || mode.requiresTranslation { activeStages.append("Traduzione") }
        activeStages.append("Esportazione")
        UserDefaults.standard.set(true, forKey: "jobInProgress")
        UserDefaults.standard.set(status, forKey: "lastJobPhase")
        let selectedLanguage = language
        let selectedTarget = (translate || mode.requiresTranslation) ? targetLanguage : nil
        let useDiarization = diarization
        let makeSubtitles = mode != .transcription && mode != .dubbing && mode != .translatedVideo
        let makeSoft = mode == .softSubtitles || mode == .complete
        let makeDubbing = mode == .dubbing || mode == .complete || mode == .translatedVideo
        let makeBurnIn = mode == .burnIn || mode == .burnTranslated || mode == .complete
        let burnTranslated = mode == .burnTranslated || (mode == .complete && translate)
        let dubbedOnly = mode == .translatedVideo
        let strictExports = mode == .complete || mode == .burnIn || mode == .burnTranslated || dubbedOnly
        let startedAt = Date()
        SessionLog.shared.write("Job start mode=\(mode.rawValue) language=\(selectedLanguage) target=\(selectedTarget ?? "none") diarization=\(useDiarization) subtitles=\(makeSubtitles) soft=\(makeSoft) dubbing=\(makeDubbing) burnIn=\(makeBurnIn) media=\(selectedFile.lastPathComponent)", always: true)
        job = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await StudioPipeline.process(source: selectedFile, language: selectedLanguage,
                                                     targetLanguage: selectedTarget,
                                                     diarization: useDiarization, subtitles: makeSubtitles,
                                                     softSubtitles: makeSoft, dubbing: makeDubbing,
                                                     burnIn: makeBurnIn, burnTranslated: burnTranslated,
                                                     dubbedOnly: dubbedOnly, strictExports: strictExports) { phase in
                        SessionLog.shared.phase(phase)
                        Task { @MainActor in
                             self.status = phase
                             self.refreshEstimate(for: phase)
                         }
                    }
                }
                let result = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: { worker.cancel() })
                lines = result.lines
                translated = result.translated
                files = result.files
                status = result.warnings.isEmpty
                    ? "Completato: \(result.files.count) file pronti"
                    : "Completato con avviso: \(result.warnings.joined(separator: " "))"
                selectedTab = .results
                SessionLog.shared.write("Job complete in \(Int(Date().timeIntervalSince(startedAt)))s: \(result.lines.count) lines, \(result.translated.count) translated, \(result.files.count) files, \(result.warnings.count) warnings", always: true)
            } catch is CancellationError {
                status = "Interrotto"
                SessionLog.shared.write("Job cancelled after \(Int(Date().timeIntervalSince(startedAt)))s", always: true)
            } catch {
                status = "Errore: \(error.localizedDescription)"
                SessionLog.shared.write("Job failed after \(Int(Date().timeIntervalSince(startedAt)))s: \(String(reflecting: error))", always: true)
            }
            UserDefaults.standard.set(false, forKey: "jobInProgress")
            working = false
            job = nil
        }
    }

    private func synthesize() {
        voiceTextFocused = false
        voicePlayer?.pause()
        voicePlayer = nil
        voicePlaying = false
        voiceFile = nil
        activeStages = []
        working = true
        status = "MagpieTTS genera la voce..."
        let text = voiceText
        let selectedVoice = voice
        SessionLog.shared.write("Magpie start speaker=\(selectedVoice) characters=\(text.count)", always: true)
        job = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await StudioPipeline.synthesize(text, voice: selectedVoice, language: "it")
                }
                let generatedFile = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: { worker.cancel() })
                voiceFile = generatedFile
                status = "WAV pronto"
                SessionLog.shared.write("Magpie WAV ready: \(voiceFile?.lastPathComponent ?? "unknown")", always: true)
                do { try playVoice(generatedFile) }
                catch { info = "WAV creato, ma riproduzione non riuscita: \(error.localizedDescription)" }
            } catch {
                status = "Errore voce: \(error.localizedDescription)"
                SessionLog.shared.write("Magpie failed: \(String(reflecting: error))", always: true)
            }
            working = false
            job = nil
        }
    }

    private func playVoice(_ url: URL) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        if voicePlayer == nil { voicePlayer = AVPlayer(url: url) }
        voicePlayer?.play()
        voicePlaying = true
    }

    private func importMedia(_ url: URL) {
        importing = true
        SessionLog.shared.write("Import start file=\(url.lastPathComponent)")
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
                let hasVideo: Bool
                do {
                    hasVideo = try await validateMedia(destination)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                if let previous = selectedFile { try? FileManager.default.removeItem(at: previous) }
                selectedFile = destination
                selectedHasVideo = hasVideo
                if hasVideo && mode == .transcription { mode = .burnIn }
                let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                SessionLog.shared.write("Import complete file=\(destination.lastPathComponent) bytes=\(bytes)", always: true)
            } catch {
                info = "Copia non riuscita: \(error.localizedDescription)"
                SessionLog.shared.write("Import failed: \(String(reflecting: error))", always: true)
            }
            importing = false
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        importing = true
        selectedPhoto = nil
        SessionLog.shared.write("Photos import started")
        Task {
            do {
                guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                    throw StudioPipelineError.unsupportedFormat
                }
                let hasVideo: Bool
                do {
                    hasVideo = try await validateMedia(movie.url)
                } catch {
                    try? FileManager.default.removeItem(at: movie.url)
                    throw error
                }
                if let previous = selectedFile { try? FileManager.default.removeItem(at: previous) }
                selectedFile = movie.url
                selectedHasVideo = hasVideo
                if hasVideo && mode == .transcription { mode = .burnIn }
                SessionLog.shared.write("Photos import complete file=\(movie.url.lastPathComponent)", always: true)
            } catch {
                info = "Video dalla galleria non importato: \(error.localizedDescription)"
                SessionLog.shared.write("Photos import failed: \(String(reflecting: error))", always: true)
            }
            importing = false
        }
    }

    private func validateMedia(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        guard !audio.isEmpty else { throw StudioPipelineError.noAudio }
        SessionLog.shared.write("Media validated audioTracks=\(audio.count) videoTracks=\(video.count)")
        return !video.isEmpty
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
