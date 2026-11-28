import Foundation

struct MediaInfo {
    var url: URL
    var duration: Double
    var formatStart: Double
    /// Offset of first video frame relative to file start (seconds)
    var videoOffset: Double
    var fps: Double
    var width: Int
    var height: Int
    var displayWidth: Int
    var displayHeight: Int
    var interlaced: Bool
    /// ffprobe field_order: "tt"/"tb" = top field first, "bb"/"bt" = bottom field first
    var fieldOrder: String = "progressive"
    var pixFmt: String = "yuv420p"
    /// video stream time base (seconds per tick)
    var timeBase: Double = 1.0 / 90000
    var videoCodec: String
    var audioDescriptions: [String]
    var formatName: String
    var sizeBytes: Double

    var hasAudio: Bool { !audioDescriptions.isEmpty }
    var frameDuration: Double { 1.0 / fps }
    var lastFrameTime: Double { snap(max(0, duration - frameDuration)) }

    /// Snap a time onto the video frame grid.
    func snap(_ t: Double) -> Double {
        let n = max(0, ((t - videoOffset) * fps).rounded())
        return videoOffset + n / fps
    }

    /// Segment snapped onto the frame grid and limited to the video's frames
    /// (the end is exclusive: the frame at `end` is not part of the segment).
    func frameAligned(_ s: Segment) -> Segment {
        let start = snap(s.start)
        let end = min(snap(s.end), lastFrameTime + frameDuration)
        return Segment(id: s.id, start: start, end: max(start, end))
    }

    /// Preview size (display aspect, capped).
    func previewSize(maxWidth: Int) -> (Int, Int) {
        let w = min(maxWidth, displayWidth)
        let h = Int((Double(w) * Double(displayHeight) / Double(displayWidth)).rounded())
        return (w & ~1, max(2, h & ~1))
    }

    static func probe(_ url: URL) throws -> MediaInfo {
        guard let ffprobe = FFTools.ffprobe else { throw CutterError.toolMissing("ffprobe") }
        let r = try FFTools.run(ffprobe, ["-v", "error", "-print_format", "json",
                                          "-show_format", "-show_streams", url.path])
        guard r.status == 0,
              let json = try JSONSerialization.jsonObject(with: r.out) as? [String: Any] else {
            throw CutterError.probe(String(data: r.err, encoding: .utf8) ?? "ffprobe failed")
        }
        let format = json["format"] as? [String: Any] ?? [:]
        let streams = json["streams"] as? [[String: Any]] ?? []

        func dbl(_ v: Any?) -> Double? {
            if let s = v as? String { return Double(s) }
            return v as? Double
        }
        func ratio(_ v: Any?) -> Double? {
            guard let s = v as? String else { return nil }
            let p = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).compactMap { Double($0) }
            guard p.count == 2, p[0] > 0, p[1] > 0 else { return nil }
            return p[0] / p[1]
        }

        guard let v = streams.first(where: { ($0["codec_type"] as? String) == "video"
                                              && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0 }) else {
            throw CutterError.probe("No video stream found")
        }
        let width = v["width"] as? Int ?? 1920
        let height = v["height"] as? Int ?? 1080
        var fps = ratio(v["avg_frame_rate"]) ?? ratio(v["r_frame_rate"]) ?? 29.97
        if fps < 1 || fps > 120 { fps = ratio(v["r_frame_rate"]) ?? 29.97 }
        let sar = ratio(v["sample_aspect_ratio"]) ?? 1
        let dw = Int((Double(width) * sar).rounded())
        let fieldOrder = v["field_order"] as? String ?? "progressive"
        let interlaced = ["tt", "bb", "tb", "bt"].contains(fieldOrder)

        let fStart = dbl(format["start_time"]) ?? 0
        let vStart = dbl(v["start_time"]) ?? fStart
        var duration = dbl(format["duration"]) ?? dbl(v["duration"]) ?? 0
        if duration <= 0 { duration = 1 }

        let audios = streams.filter { ($0["codec_type"] as? String) == "audio" }.map { a -> String in
            let codec = a["codec_name"] as? String ?? "?"
            let ch = a["channels"] as? Int ?? 0
            let lang = (a["tags"] as? [String: Any])?["language"] as? String
            return [codec, ch > 0 ? "\(ch)ch" : nil, lang].compactMap { $0 }.joined(separator: " ")
        }

        let size = dbl(format["size"]) ?? Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)

        return MediaInfo(url: url,
                         duration: duration,
                         formatStart: fStart,
                         videoOffset: max(0, vStart - fStart),
                         fps: fps,
                         width: width, height: height,
                         displayWidth: max(2, dw), displayHeight: height,
                         interlaced: interlaced,
                         fieldOrder: fieldOrder,
                         pixFmt: v["pix_fmt"] as? String ?? "yuv420p",
                         timeBase: ratio(v["time_base"]) ?? 1.0 / 90000,
                         videoCodec: v["codec_name"] as? String ?? "?",
                         audioDescriptions: audios,
                         formatName: format["format_name"] as? String ?? "?",
                         sizeBytes: size)
    }
}

enum CutterError: LocalizedError {
    case toolMissing(String)
    case probe(String)
    case ffmpeg(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .toolMissing(let t): return "\(t) not found. Install with: brew install ffmpeg"
        case .probe(let m): return "Cannot read video: \(m)"
        case .ffmpeg(let m): return "ffmpeg error: \(m)"
        case .cancelled: return "Cancelled"
        }
    }
}

struct Segment: Identifiable, Equatable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
}
