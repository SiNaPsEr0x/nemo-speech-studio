import AVFoundation
import Foundation

// Remux H.264/HEVC + AAC from iPhone-compatible MP4/MOV without recompression.
// Matroska text cues carry a duration, so players can enable/disable them.
enum MatroskaMuxer {
    private static let segmentID: [UInt8] = [0x18, 0x53, 0x80, 0x67]

    static func write(source: URL, captions: [StudioLine], translated: [StudioLine], output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let audio = try await asset.loadTracks(withMediaType: .audio).first,
              let videoFormat = try await video.load(.formatDescriptions).first,
              let audioFormat = try await audio.load(.formatDescriptions).first,
              let sound = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat) else {
            throw unsupported("traccia video/audio o descrizione AAC mancante")
        }
        let codec = CMFormatDescriptionGetMediaSubType(videoFormat)
        let atomName: String
        let codecID: String
        switch codec {
        case kCMVideoCodecType_H264: (atomName, codecID) = ("avcC", "V_MPEG4/ISO/AVC")
        case kCMVideoCodecType_HEVC: (atomName, codecID) = ("hvcC", "V_MPEGH/ISO/HEVC")
        default: throw unsupported("codec video diverso da H.264/HEVC")
        }
        guard CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC,
              let atoms = CMFormatDescriptionGetExtension(videoFormat,
                  extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let codecPrivate = atoms[atomName] as? Data,
              !codecPrivate.isEmpty else { throw unsupported("configurazione \(atomName) o codec AAC mancante") }
        let rate = Int(sound.pointee.mSampleRate.rounded())
        let channels = Int(sound.pointee.mChannelsPerFrame)
        let samplingRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
                             24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        guard let frequency = samplingRates.firstIndex(of: rate), (1...7).contains(channels) else {
            throw unsupported("frequenza o canali AAC non supportati")
        }
        let aacPrivate = Data([UInt8((2 << 3) | (frequency >> 1)),
                               UInt8(((frequency & 1) << 7) | (channels << 3))])
        let size = try await video.load(.naturalSize)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard size.width > 0, size.height > 0, duration.isFinite, duration > 0 else {
            throw unsupported("dimensioni o durata del video non valide")
        }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
        guard reader.canAdd(videoOutput), reader.canAdd(audioOutput) else {
            throw unsupported("AVAssetReader non accetta le tracce compresse")
        }
        reader.add(videoOutput)
        reader.add(audioOutput)
        guard reader.startReading() else { throw reader.error ?? unsupported("avvio lettura fallito") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var entries = Data()
        entries.append(track(number: 1, kind: 1, codec: codecID, privateData: codecPrivate,
                             video: (Int(size.width.rounded()), Int(size.height.rounded()))))
        entries.append(track(number: 2, kind: 2, codec: "A_AAC", privateData: aacPrivate,
                             audio: (rate, channels)))
        entries.append(track(number: 3, kind: 17, codec: "S_TEXT/UTF8", name: "Sottotitoli originali"))
        if !translated.isEmpty {
            entries.append(track(number: 4, kind: 17, codec: "S_TEXT/UTF8", name: "Sottotitoli tradotti"))
        }
        let info = element([0x15, 0x49, 0xA9, 0x66],
            element([0x2A, 0xD7, 0xB1], unsigned(1_000_000)) +
            element([0x44, 0x89], floating(duration * 1000)) +
            element([0x4D, 0x80], Data("NeMo Studio".utf8)) +
            element([0x57, 0x41], Data("NeMo Studio iOS".utf8)))
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        try file.write(contentsOf: ebmlHeader())
        try file.write(contentsOf: Data(segmentID) + unknownSize)
        let segmentStart = try file.offset()
        try file.write(contentsOf: info)
        try file.write(contentsOf: element([0x16, 0x54, 0xAE, 0x6B], entries))

        var videoSample = nextPayloadSample(videoOutput)
        var audioSample = nextPayloadSample(audioOutput)
        var originalIndex = 0
        var translatedIndex = 0
        var clusterTime = -1
        var clusterOffset: UInt64 = 0
        var cues: [(Int, UInt64)] = []
        while videoSample != nil || audioSample != nil || originalIndex < captions.count || translatedIndex < translated.count {
            try Task.checkCancellation()
            let nextVideo = videoSample.map(timestamp) ?? Int.max
            let nextAudio = audioSample.map(timestamp) ?? Int.max
            let nextOriginal = originalIndex < captions.count ? millis(captions[originalIndex].start) : Int.max
            let nextTranslated = translatedIndex < translated.count ? millis(translated[translatedIndex].start) : Int.max
            let current = min(nextVideo, nextAudio, nextOriginal, nextTranslated)
            guard current != Int.max else { break }
            if clusterTime < 0 || current - clusterTime >= 20_000 || current - clusterTime < -32_000 {
                clusterTime = max(0, current)
                clusterOffset = try file.offset() - segmentStart
                try file.write(contentsOf: Data([0x1F, 0x43, 0xB6, 0x75]) + unknownSize)
                try file.write(contentsOf: element([0xE7], unsigned(UInt64(clusterTime))))
            }
            if nextVideo <= nextAudio && nextVideo <= nextOriginal && nextVideo <= nextTranslated,
               let sample = videoSample {
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
                if keyframe { cues.append((current, clusterOffset)) }
                try file.write(contentsOf: element([0xA3], try block(sample: sample, track: 1,
                                                                      relative: current - clusterTime,
                                                                      keyframe: keyframe)))
                videoSample = nextPayloadSample(videoOutput)
            } else if nextAudio <= nextOriginal && nextAudio <= nextTranslated,
                      let sample = audioSample {
                try file.write(contentsOf: element([0xA3], try block(sample: sample, track: 2,
                                                                      relative: current - clusterTime,
                                                                      keyframe: true)))
                audioSample = nextPayloadSample(audioOutput)
            } else {
                let translatedCue = nextTranslated < nextOriginal
                let line = translatedCue ? translated[translatedIndex] : captions[originalIndex]
                let number = translatedCue ? 4 : 3
                let block = block(track: number, relative: current - clusterTime,
                                  keyframe: true, payload: Data(line.text.utf8))
                let group = element([0xA1], block) +
                    element([0x9B], unsigned(UInt64(max(1, millis(line.end) - current))))
                try file.write(contentsOf: element([0xA0], group))
                if translatedCue { translatedIndex += 1 } else { originalIndex += 1 }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? unsupported("lettura delle tracce non completata: \(reader.status.rawValue)") }
        var points = Data()
        for cue in cues {
            let position = element([0xF7], unsigned(1)) + element([0xF1], unsigned(cue.1))
            points.append(element([0xBB], element([0xB3], unsigned(UInt64(max(0, cue.0)))) +
                                  element([0xB7], position)))
        }
        try file.write(contentsOf: element([0x1C, 0x53, 0xBB, 0x6B], points))
    }

    private static func unsupported(_ reason: String) -> NSError {
        NSError(domain: "NeMoStudio.MatroskaMuxer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Esportazione MKV: \(reason)."])
    }

    private static let unknownSize = Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

    private static func ebmlHeader() -> Data {
        element([0x1A, 0x45, 0xDF, 0xA3],
            element([0x42, 0x86], unsigned(1)) + element([0x42, 0xF7], unsigned(1)) +
            element([0x42, 0xF2], unsigned(4)) + element([0x42, 0xF3], unsigned(8)) +
            element([0x42, 0x82], Data("matroska".utf8)) +
            element([0x42, 0x87], unsigned(4)) + element([0x42, 0x85], unsigned(2)))
    }

    private static func track(number: Int, kind: UInt64, codec: String,
                              privateData: Data? = nil, name: String? = nil,
                              video: (Int, Int)? = nil, audio: (Int, Int)? = nil) -> Data {
        var value = element([0xD7], unsigned(UInt64(number))) +
            element([0x73, 0xC5], unsigned(UInt64(number))) +
            element([0x83], unsigned(kind)) +
            element([0x86], Data(codec.utf8))
        if let privateData { value.append(element([0x63, 0xA2], privateData)) }
        if let name { value.append(element([0x53, 0x6E], Data(name.utf8))) }
        if let video {
            value.append(element([0xE0], element([0xB0], unsigned(UInt64(video.0))) +
                                              element([0xBA], unsigned(UInt64(video.1)))))
        }
        if let audio {
            value.append(element([0xE1], element([0xB5], floating(Double(audio.0))) +
                                              element([0x9F], unsigned(UInt64(audio.1)))))
        }
        return element([0xAE], value)
    }

    // AVAssetReader may emit zero-sample format/discontinuity markers before encoded frames.
    private static func nextPayloadSample(_ output: AVAssetReaderTrackOutput) -> CMSampleBuffer? {
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { return sample }
        }
        return nil
    }

    private static func timestamp(_ sample: CMSampleBuffer) -> Int {
        millis(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
    }

    private static func millis(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return max(0, Int((seconds * 1000).rounded()))
    }

    private static func block(sample: CMSampleBuffer, track: Int, relative: Int,
                              keyframe: Bool) throws -> Data {
        guard let buffer = CMSampleBufferGetDataBuffer(sample) else { throw unsupported("campione senza dati compressi") }
        var contents = Data(count: CMBlockBufferGetDataLength(buffer))
        let status = contents.withUnsafeMutableBytes { raw -> OSStatus in
            guard let address = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: raw.count,
                                              destination: address)
        }
        guard status == noErr else { throw unsupported("copia dei dati compressi non riuscita: \(status)") }
        return block(track: track, relative: relative, keyframe: keyframe, payload: contents)
    }

    private static func block(track: Int, relative: Int, keyframe: Bool, payload: Data) -> Data {
        let time = Int16(clamping: relative)
        return Data([0x80 | UInt8(track), UInt8(truncatingIfNeeded: time >> 8),
                     UInt8(truncatingIfNeeded: time), keyframe ? 0x80 : 0x00]) + payload
    }

    private static func element(_ id: [UInt8], _ value: Data) -> Data {
        Data(id) + variableSize(value.count) + value
    }

    private static func variableSize(_ count: Int) -> Data {
        for width in 1...8 where UInt64(count) < (UInt64(1) << (7 * width)) - 1 {
            let marked = UInt64(count) | (UInt64(1) << (7 * width))
            return fixed(marked, bytes: width)
        }
        preconditionFailure("EBML element exceeds supported size")
    }

    private static func unsigned(_ number: UInt64) -> Data {
        let bytes = max(1, (64 - number.leadingZeroBitCount + 7) / 8)
        return fixed(number, bytes: bytes)
    }

    private static func fixed(_ number: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) })
    }

    private static func floating(_ value: Double) -> Data {
        fixed(value.bitPattern, bytes: 8)
    }
}
