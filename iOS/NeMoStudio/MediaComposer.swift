import AVFoundation
import Foundation
import QuartzCore
import UIKit

enum MediaComposerError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        "Contenitore o codec video non esportabile con le API iOS su questo dispositivo."
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
        SessionLog.shared.write("MOV mux source=\(video.pathExtension.lowercased()) duration=\(CMTimeGetSeconds(duration))s voice=\(CMTimeGetSeconds(voiceDuration))s")
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
        let originalTracks = try await asset.loadTracks(withMediaType: .audio)
        SessionLog.shared.write("MOV mux original audio tracks=\(originalTracks.count)")
        for original in originalTracks {
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

    static func burnSubtitles(video: URL, lines: [StudioLine], output: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty,
              let exporter = AVAssetExportSession(asset: asset,
                                                   presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaComposerError.unsupported
        }
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds > 0, seconds.isFinite else { throw MediaComposerError.unsupported }
        SessionLog.shared.write("Burn-in MP4 duration=\(seconds)s captions=\(lines.count)")
        let sourceComposition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        guard let composition = sourceComposition.mutableCopy() as? AVMutableVideoComposition else {
            throw MediaComposerError.unsupported
        }
        let size = composition.renderSize
        let parent = CALayer()
        let picture = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        picture.frame = parent.bounds
        parent.addSublayer(picture)
        let colors: [UIColor] = [
            UIColor(red: 0.345, green: 0.651, blue: 1, alpha: 1),
            UIColor(red: 1, green: 0.482, blue: 0.447, alpha: 1),
            UIColor(red: 0.824, green: 0.659, blue: 1, alpha: 1),
            UIColor(red: 0.247, green: 0.725, blue: 0.314, alpha: 1)
        ]
        for line in lines where line.start < seconds {
            let caption = CATextLayer()
            caption.string = line.text
            caption.fontSize = max(22, size.height * 0.045)
            caption.contentsScale = 2
            caption.isWrapped = true
            caption.alignmentMode = .center
            caption.foregroundColor = colors[max(0, min(3, line.speaker - 1))].cgColor
            caption.backgroundColor = UIColor.black.withAlphaComponent(0.68).cgColor
            caption.cornerRadius = 12
            caption.shadowColor = UIColor.black.cgColor
            caption.shadowOpacity = 1
            caption.shadowRadius = 4
            caption.frame = CGRect(x: size.width * 0.08, y: size.height * 0.075,
                                   width: size.width * 0.84, height: size.height * 0.18)
            caption.opacity = 0
            let start = max(0, min(1, line.start / seconds))
            let end = max(start, min(1, line.end / seconds))
            let visible = CAKeyframeAnimation(keyPath: "opacity")
            visible.keyTimes = [0, NSNumber(value: start), NSNumber(value: start),
                                NSNumber(value: end), NSNumber(value: end), 1]
            visible.values = [0, 0, 1, 1, 0, 0]
            visible.calculationMode = .discrete
            visible.duration = seconds
            visible.beginTime = AVCoreAnimationBeginTimeAtZero
            visible.isRemovedOnCompletion = false
            visible.fillMode = .both
            caption.add(visible, forKey: "captionVisible")
            parent.addSublayer(caption)
        }
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: picture, in: parent)
        exporter.videoComposition = composition
        guard exporter.supportedFileTypes.contains(.mp4) else {
            throw MediaComposerError.unsupported
        }
        try await exporter.export(to: output, as: .mp4)
    }
}
