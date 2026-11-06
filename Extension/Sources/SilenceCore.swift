import AVFoundation

struct SilenceSettings {
    var thresholdDB = -35.0
    var minDuration = 0.5
    var padding = 0.1
}

/// Everything read from the media once; cut plans are recomputed from it instantly.
struct AudioProfile {
    var url: URL
    var name: String
    var duration: Double
    var frameValue: Int64      // reduced frame duration = frameValue / frameScale
    var frameScale: Int64
    var width: Int
    var height: Int
    var audioRate: Int
    var audioChannels: Int
    var windows: [Float]       // RMS level in dB per 50 ms window

    var fps: Double { Double(frameScale) / Double(frameValue) }
    var totalFrames: Int64 { Int64(duration * fps) }
}

struct CutPlan {
    struct Segment { var silent: Bool; var start: Int64; var end: Int64 } // frames
    var segments: [Segment]
    var cuts: [(start: Double, end: Double)]   // removed ranges, seconds
    var removedSeconds: Double
    var keptSeconds: Double
}

enum SilenceError: LocalizedError {
    case noVideo, noAudio
    var errorDescription: String? {
        switch self {
        case .noVideo: return "Le fichier n'a pas de piste vidéo."
        case .noAudio: return "Le fichier n'a pas de piste audio."
        }
    }
}

/// Trace file inside the extension's sandbox container (…/Data/tmp/silencecut.log).
func trace(_ message: String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("silencecut.log")
    let line = "\(Date()) \(message)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

private func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? abs(a) : gcd(b, a % b) }

/// Reads the audio once and stores a dB level per 50 ms window.
func analyze(url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> AudioProfile {
    trace("analyze \(url.path) readable=\(FileManager.default.isReadableFile(atPath: url.path))")
    let asset = AVURLAsset(url: url)
    guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw SilenceError.noVideo }
    guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw SilenceError.noAudio }

    let duration = try await asset.load(.duration).seconds
    let size = try await video.load(.naturalSize)
    var fd = try await video.load(.minFrameDuration)
    if !fd.isValid || fd.value == 0 { fd = CMTime(value: 1001, timescale: 30000) }
    let g = max(gcd(Int64(fd.value), Int64(fd.timescale)), 1)

    var rate = 48000.0, channels: UInt32 = 2
    if let desc = try await audio.load(.formatDescriptions).first,
       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
        rate = asbd.mSampleRate
        channels = asbd.mChannelsPerFrame
    }

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    trace("startReading=\(reader.startReading()) status=\(reader.status.rawValue)")

    let windowSize = 800 // 50 ms at 16 kHz
    var windows: [Float] = []
    var acc = 0.0, n = 0
    while let sb = output.copyNextSampleBuffer() {
        if duration > 0 { progress?(min(CMSampleBufferGetPresentationTimeStamp(sb).seconds / duration, 1)) }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
        let len = CMBlockBufferGetDataLength(bb)
        var samples = [Float](repeating: 0, count: len / 4)
        CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &samples)
        for s in samples {
            acc += Double(s * s)
            n += 1
            if n == windowSize {
                windows.append(Float(10 * log10(max(acc / Double(windowSize), 1e-12))))
                acc = 0; n = 0
            }
        }
    }
    trace("read done: \(windows.count) windows, status=\(reader.status.rawValue) error=\(String(describing: reader.error))")
    if let error = reader.error { throw error }

    return AudioProfile(
        url: url, name: url.deletingPathExtension().lastPathComponent, duration: duration,
        frameValue: Int64(fd.value) / g, frameScale: Int64(fd.timescale) / g,
        width: Int(size.width), height: Int(size.height),
        audioRate: Int(rate), audioChannels: Int(channels), windows: windows)
}

/// Pure and fast: called on every slider change.
func makePlan(_ p: AudioProfile, _ s: SilenceSettings) -> CutPlan {
    let w = p.windows
    var runs: [(Double, Double)] = []
    var i = 0
    while i < w.count {
        guard Double(w[i]) < s.thresholdDB else { i += 1; continue }
        var j = i
        while j + 1 < w.count && Double(w[j + 1]) < s.thresholdDB { j += 1 }
        let start = Double(i) * 0.05
        let end = j == w.count - 1 ? p.duration : Double(j + 1) * 0.05
        if end - start >= s.minDuration { runs.append((start, end)) }
        i = j + 1
    }

    // Frame-aligned; padding shrinks each silence so speech keeps a margin.
    let fps = p.fps, total = p.totalFrames
    var segs: [CutPlan.Segment] = []
    var pos: Int64 = 0
    for (rs, re) in runs {
        let a = Int64(((rs + s.padding) * fps).rounded())
        let b = min(Int64(((re - s.padding) * fps).rounded()), total)
        guard b > a else { continue }
        if a > pos { segs.append(.init(silent: false, start: pos, end: a)) }
        segs.append(.init(silent: true, start: a, end: b))
        pos = b
    }
    if pos < total { segs.append(.init(silent: false, start: pos, end: total)) }

    let silent = segs.filter(\.silent)
    let removed = silent.reduce(0) { $0 + ($1.end - $1.start) }
    return CutPlan(segments: segs,
                   cuts: silent.map { (start: Double($0.start) / fps, end: Double($0.end) / fps) },
                   removedSeconds: Double(removed) / fps,
                   keptSeconds: Double(total - removed) / fps)
}

// MARK: - FCPXML

private struct XMLWriter {
    let p: AudioProfile

    func t(_ frames: Int64) -> String {
        let num = frames * p.frameValue, den = p.frameScale
        let g = max(gcd(num, den), 1)
        return den / g == 1 ? "\(num / g)s" : "\(num / g)/\(den / g)s"
    }

    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    var resources: String {
        """
          <resources>
            <format id="r1" frameDuration="\(p.frameValue)/\(p.frameScale)s" width="\(p.width)" height="\(p.height)" colorSpace="1-1-1 (Rec. 709)"/>
            <asset id="r2" name="\(esc(p.name))" start="0s" duration="\(t(p.totalFrames))" hasVideo="1" format="r1" hasAudio="1" videoSources="1" audioSources="1" audioChannels="\(p.audioChannels)" audioRate="\(p.audioRate)">
              <media-rep kind="original-media" src="\(esc(p.url.absoluteString))"/>
            </asset>
          </resources>
        """
    }
}

/// A project (new timeline in the SilenceCut event), for the "import" button.
func projectXML(_ p: AudioProfile, _ plan: CutPlan) -> String {
    let x = XMLWriter(p: p)
    var offset: Int64 = 0
    var clips: [String] = []
    for seg in plan.segments where !seg.silent {
        let n = seg.end - seg.start
        clips.append(#"<asset-clip ref="r2" name="\#(x.esc(p.name))" offset="\#(x.t(offset))" start="\#(x.t(seg.start))" duration="\#(x.t(n))" format="r1" tcFormat="NDF" audioRole="dialogue"/>"#)
        offset += n
    }
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE fcpxml>
    <fcpxml version="1.10">
    \(x.resources)
      <library>
        <event name="SilenceCut">
          <project name="\(x.esc(p.name)) - SilenceCut">
            <sequence format="r1" duration="\(x.t(offset))" tcStart="0s" tcFormat="NDF">
              <spine>
                \(clips.joined(separator: "\n            "))
              </spine>
            </sequence>
          </project>
        </event>
      </library>
    </fcpxml>
    """
}

/// Top-level clips, the shape Final Cut itself puts on the pasteboard: dropped on a timeline they land back to back.
func clipsXML(_ p: AudioProfile, _ plan: CutPlan) -> String {
    let x = XMLWriter(p: p)
    let clips = plan.segments.filter { !$0.silent }.map {
        #"<asset-clip ref="r2" name="\#(x.esc(p.name))" start="\#(x.t($0.start))" duration="\#(x.t($0.end - $0.start))" format="r1" tcFormat="NDF" audioRole="dialogue"/>"#
    }
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE fcpxml>

    <fcpxml version="1.14">
    \(x.resources)
        \(clips.joined(separator: "\n    "))
    </fcpxml>
    """
}

/// One compound clip holding every cut clip in order: a single pasteboard item, so Final Cut cannot drop any of them.
func compoundXML(_ p: AudioProfile, _ plan: CutPlan) -> String {
    let x = XMLWriter(p: p)
    var offset: Int64 = 0
    var clips: [String] = []
    for seg in plan.segments where !seg.silent {
        let n = seg.end - seg.start
        clips.append(#"<asset-clip ref="r2" name="\#(x.esc(p.name))" offset="\#(x.t(offset))" start="\#(x.t(seg.start))" duration="\#(x.t(n))" format="r1" tcFormat="NDF" audioRole="dialogue"/>"#)
        offset += n
    }
    let name = x.esc(p.name + " - SilenceCut")
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE fcpxml>

    <fcpxml version="1.14">
    \(x.resources.replacingOccurrences(of: "  </resources>", with: """
        <media id="r3" name="\(name)">
          <sequence format="r1" duration="\(x.t(offset))" tcStart="0s" tcFormat="NDF">
            <spine>
              \(clips.joined(separator: "\n          "))
            </spine>
          </sequence>
        </media>
      </resources>
    """))
        <ref-clip ref="r3" name="\(name)" duration="\(x.t(offset))"/>
    </fcpxml>
    """
}
