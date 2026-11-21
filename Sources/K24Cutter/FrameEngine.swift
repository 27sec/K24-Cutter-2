import Foundation
import AVFoundation
import CoreGraphics
import QuartzCore

// MARK: - Frame decoding (single frames / thumbnail strip) via ffmpeg

enum FrameDecoder {
    static func videoFilter(_ info: MediaInfo, _ w: Int, _ h: Int) -> String {
        (info.interlaced ? "yadif=0:-1:0," : "") + "scale=\(w):\(h):flags=bilinear"
    }

    static func makeImage(_ data: Data, _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Decode `count` frames starting at time `t` (frame accurate).
    static func decode(_ info: MediaInfo, at t: Double, count: Int, w: Int, h: Int) -> [CGImage] {
        guard let ffmpeg = FFTools.ffmpeg else { return [] }
        // seek a quarter frame early so float error never skips the wanted frame
        let seek = max(0, t - info.frameDuration * 0.25)
        let args = ["-hide_banner", "-loglevel", "error", "-nostdin",
                    "-ss", TimeFmt.arg(seek), "-i", info.url.path,
                    "-map", "0:v:0", "-an", "-sn", "-dn",
                    "-frames:v", "\(count)",
                    "-vf", videoFilter(info, w, h),
                    "-f", "rawvideo", "-pix_fmt", "bgra", "pipe:1"]
        guard let r = try? FFTools.run(ffmpeg, args) else { return [] }
        let size = w * h * 4
        var images: [CGImage] = []
        var off = 0
        while off + size <= r.out.count {
            if let img = makeImage(r.out.subdata(in: off..<(off + size)), w, h) { images.append(img) }
            off += size
        }
        return images
    }
}

/// Serialises frame requests: while one decode runs, only the newest pending request is kept
/// (so scrubbing stays responsive without spawning hundreds of ffmpeg processes).
final class FrameRequester {
    struct Request { var t: Double; var count: Int; var w: Int; var h: Int }

    private let queue = DispatchQueue(label: "k24.frames", qos: .userInitiated)
    private var busy = false
    private var pending: Request?
    private var generation = 0
    var info: MediaInfo
    var handler: ((Request, [CGImage]) -> Void)?

    init(info: MediaInfo) { self.info = info }

    /// Call on main thread.
    func request(_ r: Request) {
        if busy { pending = r; return }
        run(r)
    }

    /// Drop results of everything requested so far.
    func invalidate() {
        generation += 1
        pending = nil
    }

    private func run(_ r: Request) {
        busy = true
        let gen = generation
        let info = self.info
        queue.async {
            let imgs = FrameDecoder.decode(info, at: r.t, count: r.count, w: r.w, h: r.h)
            DispatchQueue.main.async {
                self.busy = false
                if gen == self.generation { self.handler?(r, imgs) }
                if let p = self.pending {
                    self.pending = nil
                    self.run(p)
                }
            }
        }
    }
}

// MARK: - Real-time playback (video + audio decoded by ffmpeg)

final class PlaybackEngine {
    let info: MediaInfo
    let width: Int
    let height: Int
    var onFrame: ((CGImage, Double) -> Void)?
    var onEnded: (() -> Void)?
    var volume: Float = 0.8 { didSet { engine.mainMixerNode.outputVolume = volume } }

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var session: Session?
    private var audioOK = false

    private final class Session {
        private let lock = NSLock()
        private var _cancelled = false
        private var procs: [Process] = []
        let audioReady = DispatchSemaphore(value: 0)
        var player: AVAudioPlayerNode?

        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func add(_ p: Process) { lock.lock(); procs.append(p); lock.unlock() }
        func cancel() {
            lock.lock(); _cancelled = true; let ps = procs; lock.unlock()
            for p in ps where p.isRunning { p.terminate() }
        }
    }

    init(info: MediaInfo, width: Int, height: Int) {
        self.info = info
        self.width = width
        self.height = height
        _ = engine.mainMixerNode
        engine.mainMixerNode.outputVolume = volume
        do { try engine.start(); audioOK = true } catch { audioOK = false }
    }

    deinit { stop(); engine.stop() }

    func start(at t: Double) {
        stop()
        let s = Session()
        session = s
        let useAudio = info.hasAudio && audioOK
        if useAudio {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            s.player = node
            if !engine.isRunning { try? engine.start() }
            Thread { [weak self] in self?.audioLoop(s, from: t) }.start()
        }
        Thread { [weak self] in self?.videoLoop(s, from: t, waitAudio: useAudio) }.start()
    }

    func stop() {
        guard let s = session else { return }
        session = nil
        s.cancel()
        if let node = s.player {
            node.stop()
            engine.detach(node)
        }
    }

    private func spawn(_ args: [String], _ s: Session) -> (Process, Int32)? {
        guard let ffmpeg = FFTools.ffmpeg else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        s.add(p)
        if s.cancelled { p.terminate() }
        return (p, pipe.fileHandleForReading.fileDescriptor)
    }

    private func videoLoop(_ s: Session, from t: Double, waitAudio: Bool) {
        let args = ["-hide_banner", "-loglevel", "error", "-nostdin",
                    "-ss", TimeFmt.arg(max(0, t - info.frameDuration * 0.25)), "-i", info.url.path,
                    "-map", "0:v:0", "-an", "-sn", "-dn",
                    "-vf", FrameDecoder.videoFilter(info, width, height),
                    "-f", "rawvideo", "-pix_fmt", "bgra", "pipe:1"]
        guard let (proc, fd) = spawn(args, s) else { return }
        defer { if proc.isRunning { proc.terminate() } }

        let frameSize = width * height * 4
        let fps = info.fps
        var n = 0
        var t0 = 0.0
        var droppedLast = false
        let end = info.duration

        while !s.cancelled {
            guard let buf = malloc(frameSize) else { break }
            if readFully(fd, buf, frameSize) < frameSize { free(buf); break }
            let data = Data(bytesNoCopy: buf, count: frameSize, deallocator: .free)

            if n == 0 {
                if waitAudio { _ = s.audioReady.wait(timeout: .now() + 3) }
                if s.cancelled { break }
                s.player?.play()
                t0 = CACurrentMediaTime()
            }
            let target = t0 + Double(n) / fps
            let now = CACurrentMediaTime()
            if now < target {
                usleep(useconds_t((target - now) * 1_000_000))
            } else if now - target > 0.1 && !droppedLast {
                droppedLast = true
                n += 1
                continue
            }
            droppedLast = false
            let frameTime = t + Double(n) / fps
            n += 1
            if frameTime > end { break }
            guard let img = FrameDecoder.makeImage(data, width, height) else { continue }
            DispatchQueue.main.async { [weak self] in
                guard !s.cancelled else { return }
                self?.onFrame?(img, frameTime)
            }
        }
        if !s.cancelled {
            DispatchQueue.main.async { [weak self] in
                guard !s.cancelled else { return }
                self?.onEnded?()
            }
        }
    }

    private func audioLoop(_ s: Session, from t: Double) {
        var scheduled = 0
        defer { if scheduled < 4 { s.audioReady.signal() } }
        let args = ["-hide_banner", "-loglevel", "error", "-nostdin",
                    "-ss", TimeFmt.arg(t), "-i", info.url.path,
                    "-map", "0:a:0", "-vn", "-sn", "-dn",
                    "-ac", "2", "-ar", "48000", "-f", "f32le", "pipe:1"]
        guard let player = s.player, let (proc, fd) = spawn(args, s) else { return }
        defer { if proc.isRunning { proc.terminate() } }

        let chunk = 4096
        let bytes = chunk * 8
        let inflight = DispatchSemaphore(value: 12)   // ~1 s queued
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        defer { raw.deallocate() }

        outer: while !s.cancelled {
            let got = readFully(fd, raw, bytes)
            let frames = got / 8
            if frames == 0 { break }
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let ch = buf.floatChannelData else { break }
            buf.frameLength = AVAudioFrameCount(frames)
            let src = raw.assumingMemoryBound(to: Float.self)
            let l = ch[0], r = ch[1]
            for i in 0..<frames {
                l[i] = src[2 * i]
                r[i] = src[2 * i + 1]
            }
            while inflight.wait(timeout: .now() + 0.2) == .timedOut {
                if s.cancelled { break outer }
            }
            if s.cancelled { break }
            player.scheduleBuffer(buf) { inflight.signal() }
            scheduled += 1
            if scheduled == 4 { s.audioReady.signal() }
            if got < bytes { break }
        }
    }
}
