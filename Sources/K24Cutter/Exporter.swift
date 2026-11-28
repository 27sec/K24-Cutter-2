import Foundation

/// Frame-exact export ("smart cut", like VideoReDo): only the few frames between a mark and the
/// nearest keyframe are re-encoded; everything else is stream-copied (-c copy) untouched.
final class Exporter {
    enum Mode: String, CaseIterable, Identifiable {
        case join = "Join into one file"
        case separate = "Separate file per segment"
        var id: String { rawValue }
    }

    private let lock = NSLock()
    private var current: Process?
    private var _cancelled = false
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    func cancel() {
        lock.lock()
        _cancelled = true
        let p = current
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    // MARK: Output naming  —  "<source name>-001.ext", "-002", … continuing from the folder

    /// Highest NNN already used in `dir` for files named "<base>-NNN.<any ext>" (0 if none).
    static func lastIndex(in dir: URL, base: String) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let prefix = base + "-"
        var best = 0
        for name in names {
            let stem = (name as NSString).deletingPathExtension
            guard stem.hasPrefix(prefix) else { continue }
            let num = stem.dropFirst(prefix.count)
            if num.count >= 3, num.allSatisfy(\.isASCII), num.allSatisfy(\.isNumber), let n = Int(num) {
                best = max(best, n)
            }
        }
        return best
    }

    /// Next `count` output URLs in `dir`, e.g. base-005.ts, base-006.ts …
    static func numberedOutputs(dir: URL, base: String, ext: String, count: Int) -> [URL] {
        let start = lastIndex(in: dir, base: base) + 1
        return (0..<max(1, count)).map {
            dir.appendingPathComponent(String(format: "%@-%03d", base, start + $0)).appendingPathExtension(ext)
        }
    }

    /// progress: (0...1, message) on main thread. completion on main thread.
    /// `outputs`: one URL for .join, one per segment for .separate.
    func run(info: MediaInfo, segments: [Segment], outputs: [URL], mode: Mode,
             progress: @escaping (Double, String) -> Void,
             completion: @escaping (Result<[URL], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[URL], Error>
            do {
                result = .success(try self.work(info: info, segments: segments, outputs: outputs, mode: mode, progress: progress))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func work(info: MediaInfo, segments: [Segment], outputs: [URL], mode: Mode,
                      progress: @escaping (Double, String) -> Void) throws -> [URL] {
        guard let ffmpeg = FFTools.ffmpeg else { throw CutterError.toolMissing("ffmpeg") }
        let segments = segments.map { info.frameAligned($0) }.filter { $0.duration >= info.frameDuration / 2 }
        guard !segments.isEmpty else { throw CutterError.ffmpeg("nothing to export") }
        guard let output = outputs.first else { throw CutterError.ffmpeg("no output file") }
        if mode == .separate && outputs.count < segments.count { throw CutterError.ffmpeg("not enough output names") }
        let fm = FileManager.default
        let total = segments.reduce(0) { $0 + $1.duration }
        let ext = output.pathExtension.lowercased()
        let report: (Double, String) -> Void = { p, m in DispatchQueue.main.async { progress(min(1, p), m) } }

        switch mode {
        case .separate:
            var outs: [URL] = []
            var done = 0.0
            for (i, seg) in segments.enumerated() {
                let url = outputs[i]
                let msg = "Segment \(i + 1)/\(segments.count)"
                try cutSegment(ffmpeg, info, seg, url, ext: ext) { t in
                    report((done + t) / total, msg)
                }
                done += seg.duration
                outs.append(url)
            }
            return outs

        case .join:
            if segments.count == 1 {
                try cutSegment(ffmpeg, info, segments[0], output, ext: ext) { t in
                    report(t / total, "Writing")
                }
                return [output]
            }
            // 1) cut each segment to a temp .ts on the same volume  2) concat (stream copy)
            let tmp = output.deletingLastPathComponent()
                .appendingPathComponent(".k24cut-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            var parts: [URL] = []
            var done = 0.0
            for (i, seg) in segments.enumerated() {
                let part = tmp.appendingPathComponent(String(format: "part_%03d.ts", i + 1))
                try cutSegment(ffmpeg, info, seg, part, ext: "ts") { t in
                    report((done + t) / (total * 2), "Cutting segment \(i + 1)/\(segments.count)")
                }
                done += seg.duration
                parts.append(part)
            }
            let list = tmp.appendingPathComponent("list.txt")
            let body = parts.map { "file '" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                .joined(separator: "\n")
            try body.write(to: list, atomically: true, encoding: .utf8)

            var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats",
                        "-f", "concat", "-safe", "0", "-i", list.path,
                        "-map", "0", "-c", "copy"]
            args += containerArgs(info, ext: ext)
            args.append(output.path)
            try runFF(ffmpeg, args, duration: total) { t in
                report(0.5 + t / (total * 2), "Joining \(segments.count) segments")
            }
            return [output]
        }
    }

    private static let common = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                                 "-progress", "pipe:1", "-nostats"]

    /// Keyframe-snapped stream copy (fallback for codecs we cannot re-encode).
    private func cutArgs(_ info: MediaInfo, _ seg: Segment, _ out: URL, ext: String) -> [String] {
        var a = Self.common + [
                 "-ss", TimeFmt.arg(seg.start),
                 "-i", info.url.path,
                 "-t", TimeFmt.arg(seg.duration),
                 "-map", "0:v:0", "-map", "0:a?",
                 "-c", "copy", "-sn", "-dn", "-ignore_unknown",
                 "-avoid_negative_ts", "make_zero"]
        a += containerArgs(info, ext: ext)
        a.append(out.path)
        return a
    }

    // MARK: Smart cut

    /// Video packet in decode order; pts relative to the file start (same clock as the marks).
    private struct Packet { let pts: Double; let dts: Double; let key: Bool }

    private struct SmartPlan {
        /// re-encoded start part: first frame time + frame count
        var head: (start: Double, frames: Int)?
        /// stream-copied middle: keep packets with pts in [from, to)
        var copy: (from: Double, to: Double)?
        /// re-encoded end part
        var tail: (start: Double, frames: Int)?
        /// source reorder delay (max pts - dts); the head part's dts are moved back by this much
        /// so that they stay before the dts of the copied frames that follow
        var delay: Double = 0
    }

    /// Writes one segment cut exactly on the marked frames. `onTime` gets 0...seg.duration.
    private func cutSegment(_ ffmpeg: String, _ info: MediaInfo, _ seg: Segment, _ out: URL, ext: String,
                            onTime: @escaping (Double) -> Void) throws {
        guard let enc = Self.encoderArgs(info, ffmpeg: ffmpeg) else {
            // unknown codec: old behaviour (cut snaps to the keyframe before the mark)
            try runFF(ffmpeg, cutArgs(info, seg, out, ext: ext), duration: seg.duration, onTime: onTime)
            return
        }
        let plan = try makePlan(info, seg)
        DebugLog.log("smartcut \(seg.start)-\(seg.end) head=\(String(describing: plan.head)) copy=\(String(describing: plan.copy)) tail=\(String(describing: plan.tail))")

        let fm = FileManager.default
        let tmp = out.deletingLastPathComponent()
            .appendingPathComponent(".k24smart-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let fd = info.frameDuration
        let dur = seg.duration
        var parts: [(URL, Double)] = []      // file, exact duration
        var videoDone = 0.0                  // seconds of video written (progress: video = 70 %)
        func videoProgress(_ t: Double) { onTime(0.7 * min(dur, videoDone + max(0, t))) }

        // ffmpeg's input seek on MPEG-TS can land on a keyframe *after* the target, so every step
        // seeks well before it and then selects frames/packets by their exact source timestamps.
        let margin = 10.0
        func abs(_ t: Double) -> String { TimeFmt.arg(t + info.formatStart) }

        func encode(_ name: String, _ start: Double, _ frames: Int, dtsShift: Double = 0) throws {
            let url = tmp.appendingPathComponent(name)
            var args = Self.common + [
                "-copyts", "-ss", TimeFmt.arg(start - margin), "-i", info.url.path,
                "-map", "0:v:0", "-vf", "trim=start=\(abs(start - fd / 2)),setpts=PTS-STARTPTS",
                "-frames:v", "\(frames)"] + enc
            if info.videoCodec == "mpeg2video" {
                // the encoder keeps one frame of delay even without B-frames, and leaves dts unset
                // when it writes a single frame; set it explicitly (pts - 1 frame)
                args += ["-bsf:v", "setts=pts=PTS:dts=PTS-\(TimeFmt.arg(fd + dtsShift))/TB"]
            } else if dtsShift > 0 {
                args += ["-bsf:v", "setts=pts=PTS:dts=DTS-\(TimeFmt.arg(dtsShift))/TB"]
            }
            args += ["-an", "-sn", "-dn", "-f", "mpegts", url.path]
            try runFF(ffmpeg, args, duration: Double(frames) * fd) { t in videoProgress(t) }
            parts.append((url, Double(frames) * fd))
            videoDone += Double(frames) * fd
        }

        if let h = plan.head { try encode("head.ts", h.start, h.frames, dtsShift: plan.delay) }
        if let c = plan.copy {
            let url = tmp.appendingPathComponent("copy.ts")
            let drop = "noise=drop=lt(pts*tb\\,\(abs(c.from - fd / 2)))+gte(pts*tb\\,\(abs(c.to - fd / 2)))"
            let args = Self.common + [
                "-copyts", "-ss", TimeFmt.arg(c.from - margin), "-t", TimeFmt.arg(c.to - c.from + margin + 3),
                "-i", info.url.path,
                "-map", "0:v:0", "-c", "copy", "-bsf:v", drop,
                "-an", "-sn", "-dn", "-f", "mpegts", url.path]
            let span = c.to - c.from
            var base: Double?
            try runFF(ffmpeg, args, duration: .greatestFiniteMagnitude) { t in
                if base == nil { base = t }
                videoProgress(min(span, t - base!))
            }
            parts.append((url, span))
            videoDone += span
        }
        if let t = plan.tail { try encode("tail.ts", t.start, t.frames) }
        onTime(0.7 * dur)

        // audio: stream copy, keep the packets whose middle lies inside [start, end)
        var audio: URL?
        if info.hasAudio {
            let url = tmp.appendingPathComponent("audio.mka")
            let drop = "noise=drop=lt((pts+duration/2)*tb\\,\(abs(seg.start)))+gte((pts+duration/2)*tb\\,\(abs(seg.end)))"
            let args = Self.common + [
                "-copyts", "-ss", TimeFmt.arg(seg.start - margin), "-t", TimeFmt.arg(dur + margin + 3),
                "-i", info.url.path,
                "-map", "0:a", "-c", "copy", "-bsf:a", drop,
                "-vn", "-sn", "-dn", "-f", "matroska", url.path]
            var base: Double?
            try runFF(ffmpeg, args, duration: .greatestFiniteMagnitude) { t in
                if base == nil { base = t }
                onTime(0.7 * dur + 0.15 * min(dur, max(0, t - base!)))
            }
            audio = url
        }
        onTime(0.85 * dur)

        // join the video parts and add the audio
        let list = tmp.appendingPathComponent("video.txt")
        let body = parts.map { "file '\($0.0.lastPathComponent)'\nduration \(TimeFmt.arg($0.1))" }
            .joined(separator: "\n")
        try body.write(to: list, atomically: true, encoding: .utf8)
        var args = Self.common + ["-f", "concat", "-safe", "0", "-i", list.path]
        if let audio { args += ["-i", audio.path] }
        args += ["-map", "0:v:0"]
        if audio != nil { args += ["-map", "1:a"] }
        args += ["-c", "copy", "-sn", "-dn", "-ignore_unknown", "-avoid_negative_ts", "make_zero"]
        args += containerArgs(info, ext: ext)
        args.append(out.path)
        try runFF(ffmpeg, args, duration: dur) { t in onTime(0.85 * dur + 0.15 * t) }
    }

    /// Decide which frames are re-encoded and which are copied.
    private func makePlan(_ info: MediaInfo, _ seg: Segment) throws -> SmartPlan {
        let fd = info.frameDuration
        let s = seg.start, e = seg.end
        let total = max(1, Int(((e - s) / fd).rounded()))
        let whole = SmartPlan(head: (s, total), copy: nil, tail: nil)

        let win = 15.0
        let headPk: [Packet], tailPk: [Packet]
        if e - s <= 2 * win {
            headPk = try probePackets(info, from: s - 1, to: e + 3)
            tailPk = headPk
        } else {
            headPk = try probePackets(info, from: s - 1, to: s + win)
            tailPk = try probePackets(info, from: e - win, to: e + 3)
        }
        // first keyframe at/after the in-mark that starts a new coded sequence (IDR). Re-encoded
        // frames may only be spliced in front of such a frame: before an open-GOP I-frame the
        // decoder would continue the picture order count and show copied frames too early.
        let safe = try spliceSafeKeyframes(info, from: s - 1, to: min(e, s + win))
        guard let k1 = headPk.first(where: { p in
            p.key && p.pts >= s - fd / 2 && safe.contains { Swift.abs($0 - p.pts) < fd / 2 }
        })?.pts else { return whole }

        // last keyframe whose GOP's earliest frame (open-GOP leading B-frames come right after it
        // in decode order but are shown before it) is not after the out-mark
        var copyEnd: Double?
        for (j, p) in tailPk.enumerated() where p.key && p.pts > k1 + fd / 2 {
            var m = p.pts
            var q = j + 1
            while q < tailPk.count, !tailPk[q].key { m = min(m, tailPk[q].pts); q += 1 }
            if m <= e + fd / 2, m > k1 + fd / 2 { copyEnd = m }
        }
        guard let m = copyEnd else { return whole }

        let headFrames = Int(((k1 - s) / fd).rounded())
        let tailFrames = Int(((e - m) / fd).rounded())
        let delay = (headPk + tailPk).reduce(0) { max($0, $1.pts - $1.dts) }
        return SmartPlan(head: headFrames > 0 ? (s, headFrames) : nil,
                         copy: (k1, m),
                         tail: tailFrames > 0 ? (m, tailFrames) : nil,
                         delay: delay + fd)
    }

    /// Times of keyframes in [from, to] where a new coded video sequence starts:
    /// H.264 IDR, HEVC IDR/BLA. MPEG-2 I-frames always qualify.
    private func spliceSafeKeyframes(_ info: MediaInfo, from: Double, to: Double) throws -> [Double] {
        guard info.videoCodec == "h264" || info.videoCodec == "hevc" else {
            return try probePackets(info, from: from, to: to).filter(\.key).map(\.pts)
        }
        guard let ffmpeg = FFTools.ffmpeg else { throw CutterError.toolMissing("ffmpeg") }
        let r = try FFTools.run(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "trace", "-copyts",
                                         "-ss", TimeFmt.arg(from - 10), "-t", TimeFmt.arg(to - from + 10),
                                         "-i", info.url.path, "-map", "0:v:0", "-c", "copy",
                                         "-bsf:v", "noise=drop=not(key),trace_headers", "-f", "null", "-"])
        let safeTypes: Set<Int> = info.videoCodec == "h264" ? [5] : [16, 17, 18, 19, 20]
        let isVCL: (Int) -> Bool = { info.videoCodec == "h264" ? (1...5).contains($0) : $0 < 32 }
        var result: [Double] = []
        var pts: Double?          // current packet, until its first VCL NAL is seen
        for line in String(decoding: r.err, as: UTF8.self).split(separator: "\n") where line.contains("[trace_headers") {
            if let range = line.range(of: "Packet: ") {
                pts = nil
                let rest = line[range.upperBound...]
                if let p = rest.range(of: "pts ") {
                    let num = rest[p.upperBound...].prefix { $0.isNumber || $0 == "-" }
                    if let v = Double(num) { pts = v * info.timeBase - info.formatStart }
                }
            } else if let p = pts, line.contains(" nal_unit_type "), let eq = line.range(of: "= ", options: .backwards),
                      let type = Int(line[eq.upperBound...].trimmingCharacters(in: .whitespaces)) {
                if isVCL(type) {
                    if safeTypes.contains(type) { result.append(p) }
                    pts = nil
                }
            }
        }
        return result
    }

    private func probePackets(_ info: MediaInfo, from: Double, to: Double) throws -> [Packet] {
        guard let ffprobe = FFTools.ffprobe else { throw CutterError.toolMissing("ffprobe") }
        let a = max(0, from) + info.formatStart, b = to + info.formatStart
        let r = try FFTools.run(ffprobe, ["-v", "error", "-select_streams", "v:0",
                                          "-read_intervals", "\(TimeFmt.arg(a))%\(TimeFmt.arg(b))",
                                          "-show_entries", "packet=pts_time,dts_time,flags", "-of", "csv=p=0",
                                          info.url.path])
        guard r.status == 0 else {
            throw CutterError.probe(String(decoding: r.err, as: UTF8.self))
        }
        return String(decoding: r.out, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: ",")
            guard f.count >= 3, let pts = Double(f[0]) else { return nil }
            let dts = Double(f[1]) ?? pts
            return Packet(pts: pts - info.formatStart, dts: dts - info.formatStart, key: f[2].hasPrefix("K"))
        }
    }

    /// Encoder settings that match the source closely, or nil when the codec is not supported.
    /// H.264/HEVC keep B-frames so the stream header (taken from the first, re-encoded part in
    /// MP4/MKV) announces a reorder depth; MPEG-2 uses none, as its decoder mis-handles the switch.
    private static func encoderArgs(_ info: MediaInfo, ffmpeg: String) -> [String]? {
        let tff = info.fieldOrder == "tt" || info.fieldOrder == "tb"
        switch info.videoCodec {
        case "h264" where hasEncoder("libx264", ffmpeg):
            var a = ["-c:v", "libx264", "-preset", "medium", "-crf", "15", "-pix_fmt", info.pixFmt]
            if info.interlaced { a += ["-flags", "+ildct+ilme", "-x264-params", tff ? "tff=1" : "bff=1"] }
            return a
        case "hevc" where hasEncoder("libx265", ffmpeg):
            return ["-c:v", "libx265", "-preset", "fast", "-crf", "16", "-pix_fmt", info.pixFmt,
                    "-x265-params", "log-level=error:repeat-headers=1"]
        case "mpeg2video" where hasEncoder("mpeg2video", ffmpeg):
            var a = ["-c:v", "mpeg2video", "-q:v", "2", "-qmin", "1", "-g", "15", "-bf", "0", "-pix_fmt", info.pixFmt]
            if info.interlaced { a += ["-flags", "+ildct+ilme"] }   // field order comes from the frames
            return a
        default:
            return nil
        }
    }

    private static var encoderCache: [String: Bool] = [:]
    private static let encoderLock = NSLock()
    private static func hasEncoder(_ name: String, _ ffmpeg: String) -> Bool {
        encoderLock.lock(); defer { encoderLock.unlock() }
        if let v = encoderCache[name] { return v }
        let out = (try? FFTools.run(ffmpeg, ["-hide_banner", "-encoders"]).out) ?? Data()
        let ok = String(decoding: out, as: UTF8.self).split(separator: "\n")
            .contains { $0.split(separator: " ").dropFirst().first == Substring(name) }
        encoderCache[name] = ok
        return ok
    }

    /// True when exports of this source are frame-exact (codec can be re-encoded).
    static func isFrameExact(_ info: MediaInfo) -> Bool {
        guard let ffmpeg = FFTools.ffmpeg else { return false }
        return encoderArgs(info, ffmpeg: ffmpeg) != nil
    }

    private func containerArgs(_ info: MediaInfo, ext: String) -> [String] {
        switch ext {
        case "mp4", "m4v", "mov":
            return info.videoCodec == "hevc" ? ["-tag:v", "hvc1"] : []
        case "ts", "m2ts", "mts", "m2t":
            return ["-f", "mpegts"]
        default:
            return []
        }
    }

    private func runFF(_ exe: String, _ args: [String], duration: Double, onTime: @escaping (Double) -> Void) throws {
        if cancelled { throw CutterError.cancelled }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        var errData = Data()
        let errLock = NSLock()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            errLock.lock(); errData.append(d); errLock.unlock()
        }
        lock.lock(); current = p; lock.unlock()
        try p.run()

        var buffer = ""
        let fh = out.fileHandleForReading
        while true {
            let d = fh.availableData
            if d.isEmpty { break }
            buffer += String(decoding: d, as: UTF8.self)
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<nl])
                buffer.removeSubrange(...nl)
                if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                    if let us = Double(line.split(separator: "=").last ?? "") {
                        onTime(min(duration, max(0, us / 1_000_000)))
                    }
                }
            }
        }
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        lock.lock(); current = nil; lock.unlock()

        if cancelled { throw CutterError.cancelled }
        if p.terminationStatus != 0 {
            errLock.lock(); let msg = String(decoding: errData, as: UTF8.self); errLock.unlock()
            throw CutterError.ffmpeg(msg.isEmpty ? "exit code \(p.terminationStatus)" : msg)
        }
        onTime(duration)
    }
}
