import AVFoundation
import Foundation

enum MediaComposerError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        "Il video non può essere esportato in MOV con i codec disponibili su questo iPhone. La traccia WAV rimane nella cartella Output."
    }
}

enum MediaComposer {
    static func hasVideo(_ url: URL) async throws -> Bool {
        !(try await AVURLAsset(url: url).loadTracks(withMediaType: .video)).isEmpty
    }

    // MOV preserves a selectable original audio track and a separate dubbed
    // track; the caller also keeps a standalone WAV for other video editors.
    static func muxOriginalAndDubbing(video: URL, dubbing: URL, output: URL) async throws {
        let asset = AVURLAsset(url: video)
        let voice = AVURLAsset(url: dubbing)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let voiceTrack = try await voice.loadTracks(withMediaType: .audio).first else {
            throw MediaComposerError.unsupported
        }
        let duration = try await asset.load(.duration)
        let voiceDuration = try await voice.load(.duration)
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid),
              let dubTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaComposerError.unsupported
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                       of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let voiceRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, voiceDuration))
        try dubTrack.insertTimeRange(voiceRange, of: voiceTrack, at: .zero)
        for original in try await asset.loadTracks(withMediaType: .audio) {
            guard let originalTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MediaComposerError.unsupported
            }
            let originalRange = try await original.load(.timeRange)
            let clip = CMTimeRange(start: originalRange.start,
                                   duration: CMTimeMinimum(originalRange.duration, duration))
            try originalTrack.insertTimeRange(clip, of: original, at: originalRange.start)
        }
        guard let exporter = AVAssetExportSession(asset: composition,
                                                   presetName: AVAssetExportPresetPassthrough),
              exporter.supportedFileTypes.contains(.mov) else {
            throw MediaComposerError.unsupported
        }
        try await exporter.export(to: output, as: .mov)
    }
}
