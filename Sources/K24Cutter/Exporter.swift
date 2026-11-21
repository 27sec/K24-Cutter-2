import Foundation

/// Lossless export with ffmpeg stream copy (-c copy). No re-encoding.
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

    /// progress: (0...1, message) on main thread. completion on main thread.
    func run(info: MediaInfo, segments: [Segment], output: URL, mode: Mode,
             progress: @escaping (Double, String) -> Void,
             completion: @escaping (Result<[URL], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[URL], Error>
            do {
                result = .success(try self.work(info: info, segments: segments, output: output, mode: mode, progress: progress))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func work(info: MediaInfo, segments: [Segment], output: URL, mode: Mode,
                      progress: @escaping (Double, String) -> Void) throws -> [URL] {
        guard let ffmpeg = FFTools.ffmpeg else { throw CutterError.toolMissing("ffmpeg") }
        let fm = FileManager.default
        let total = segments.reduce(0) { $0 + $1.duration }
        let ext = output.pathExtension.lowercased()
        let report: (Double, String) -> Void = { p, m in DispatchQueue.main.async { progress(min(1, p), m) } }

        switch mode {
        case .separate:
            var outs: [URL] = []
            var done = 0.0
            let base = output.deletingPathExtension()
            for (i, seg) in segments.enumerated() {
                let url = segments.count == 1 ? output
                    : URL(fileURLWithPath: base.path + String(format: "_%02d.", i + 1) + output.pathExtension)
                let msg = "Segment \(i + 1)/\(segments.count)"
                try runFF(ffmpeg, cutArgs(info, seg, url, ext: ext), duration: seg.duration) { t in
                    report((done + t) / total, msg)
                }
                done += seg.duration
                outs.append(url)
            }
            return outs

        case .join:
            if segments.count == 1 {
                try runFF(ffmpeg, cutArgs(info, segments[0], output, ext: ext), duration: total) { t in
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
                try runFF(ffmpeg, cutArgs(info, seg, part, ext: "ts"), duration: seg.duration) { t in
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

    private func cutArgs(_ info: MediaInfo, _ seg: Segment, _ out: URL, ext: String) -> [String] {
        var a = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats",
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
