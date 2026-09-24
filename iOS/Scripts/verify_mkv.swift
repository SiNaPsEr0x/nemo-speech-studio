import AVFoundation
import Foundation

// This fixture links the exact muxer source shipped in the iPhone app.
struct StudioLine {
    let start: Double
    let end: Double
    let text: String
}

enum MediaComposerError: Error {
    case unsupported
}

@main
struct MKVSmoke {
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let target = URL(fileURLWithPath: CommandLine.arguments[2])
        let asset = AVURLAsset(url: source)
        let reader = try AVAssetReader(asset: asset)
        for mediaType in [AVMediaType.video, .audio] {
            guard let track = try await asset.loadTracks(withMediaType: mediaType).first else { continue }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
        }
        guard reader.startReading() else { throw reader.error ?? MediaComposerError.unsupported }
        for output in reader.outputs {
            for index in 0..<3 {
                guard let sample = output.copyNextSampleBuffer() else { break }
                let count = CMSampleBufferGetNumSamples(sample)
                let size = count > 0 ? CMSampleBufferGetSampleSize(sample, at: 0) : 0
                let codec = CMSampleBufferGetFormatDescription(sample).map(CMFormatDescriptionGetMediaSubType)
                FileHandle.standardError.write(Data("Sample output=\(output.mediaType.rawValue) index=\(index) count=\(count) size=\(size) data=\(CMSampleBufferGetDataBuffer(sample) != nil) image=\(CMSampleBufferGetImageBuffer(sample) != nil) codec=\(String(describing: codec))\\n".utf8))
            }
        }
        reader.cancelReading()
        try await MatroskaMuxer.write(
            source: source,
            captions: [.init(start: 0.1, end: 0.7, text: "Testo originale")],
            translated: [.init(start: 0.1, end: 0.7, text: "Translated text")],
            output: target)
    }
}
