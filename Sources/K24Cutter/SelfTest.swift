import Foundation

/// `K24Cutter --selftest <file>` : headless check of probe, frame decode and lossless export.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        runCutTestIfRequested(args)
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        do {
            let info = try MediaInfo.probe(url)
            print("probe:", info.videoCodec, info.width, info.height, "->", info.displayWidth, info.displayHeight,
                  "fps", info.fps, "dur", info.duration, "interlaced", info.interlaced, "audio", info.audioDescriptions)
            let (w, h) = info.previewSize(maxWidth: 1280)
            var t0 = Date()
            let one = FrameDecoder.decode(info, at: 30, count: 1, w: w, h: h)
            print("decode 1 frame:", one.count, String(format: "%.2fs", Date().timeIntervalSince(t0)))
            t0 = Date()
            let strip = FrameDecoder.decode(info, at: 30, count: 15, w: 192, h: 108)
            print("decode strip:", strip.count, String(format: "%.2fs", Date().timeIntervalSince(t0)))
            print("timefmt:", TimeFmt.string(3882.666, fps: info.fps), TimeFmt.parse("1:04:42.20", fps: info.fps) ?? -1)

            let segs = [Segment(start: 10, end: 20), Segment(start: 40, end: 55.5), Segment(start: 90, end: 100)]
            let dir = URL(fileURLWithPath: args.count > i + 2 ? args[i + 2] : NSTemporaryDirectory())
            let base = url.deletingPathExtension().lastPathComponent
            print("last index before:", Exporter.lastIndex(in: dir, base: base))
            for (mode, ext) in [(Exporter.Mode.join, "ts"), (.join, "mp4"), (.join, "mkv"), (.separate, "ts")] {
                let outs = Exporter.numberedOutputs(dir: dir, base: base, ext: ext,
                                                    count: mode == .separate ? segs.count : 1)
                let sem = DispatchSemaphore(value: 0)
                t0 = Date()
                Exporter().run(info: info, segments: segs, outputs: outs, mode: mode, progress: { _, _ in }) { r in
                    switch r {
                    case .success(let urls): print("export \(mode.rawValue) .\(ext):", urls.map(\.lastPathComponent), String(format: "%.2fs", Date().timeIntervalSince(t0)))
                    case .failure(let e): print("export FAILED:", e.localizedDescription)
                    }
                    sem.signal()
                }
                while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            }
            print("last index after:", Exporter.lastIndex(in: dir, base: base))
        } catch {
            print("selftest error:", error.localizedDescription)
        }
        exit(0)
    }

    /// `K24Cutter --cuttest <file> <out.ext> <start> <end> [<start> <end> …]` : export the given
    /// segments (seconds, snapped to frames) joined into one file, headless.
    static func runCutTestIfRequested(_ args: [String]) {
        guard let i = args.firstIndex(of: "--cuttest"), i + 4 < args.count else { return }
        do {
            let info = try MediaInfo.probe(URL(fileURLWithPath: args[i + 1]))
            let out = URL(fileURLWithPath: args[i + 2])
            let nums = args[(i + 3)...].compactMap(Double.init)
            let segs = stride(from: 0, to: nums.count - 1, by: 2).map {
                Segment(start: info.snap(nums[$0]), end: info.snap(nums[$0 + 1]))
            }
            print("frame-exact:", Exporter.isFrameExact(info), "segments:", segs.map { ($0.start, $0.end) })
            let sem = DispatchSemaphore(value: 0)
            let t0 = Date()
            Exporter().run(info: info, segments: segs, outputs: [out], mode: .join, progress: { _, _ in }) { r in
                switch r {
                case .success(let urls): print("ok", urls.map(\.path), String(format: "%.2fs", Date().timeIntervalSince(t0)))
                case .failure(let e): print("FAILED:", e.localizedDescription)
                }
                sem.signal()
            }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        } catch {
            print("cuttest error:", error.localizedDescription)
        }
        exit(0)
    }
}
