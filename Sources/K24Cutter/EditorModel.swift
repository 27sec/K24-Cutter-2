import Foundation
import AppKit
import QuartzCore

struct Thumbnail: Identifiable {
    let id: Int          // frame index
    let time: Double
    let image: CGImage
}

/// Shows frames directly on a CALayer (no SwiftUI re-render per frame).
final class FrameSink {
    weak var layer: CALayer? { didSet { apply() } }
    private(set) var image: CGImage?

    func show(_ img: CGImage?) {
        image = img
        apply()
    }
    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}

final class EditorModel: ObservableObject {
    static let shared = EditorModel()

    @Published var info: MediaInfo?
    @Published var cursor: Double = 0
    @Published var markIn: Double?
    @Published var markOut: Double?
    @Published var segments: [Segment] = []
    @Published var selection = Set<Segment.ID>()
    @Published var isPlaying = false
    @Published var thumbnails: [Thumbnail] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showExport = false
    @Published var volume: Float = 0.8 { didSet { player?.volume = volume } }

    let thumbCount = 15
    let frameSink = FrameSink()
    private var mainFrames: FrameRequester?
    private var stripFrames: FrameRequester?
    private var player: PlaybackEngine?
    private var stripWork: DispatchWorkItem?

    var fps: Double { info?.fps ?? 29.97 }
    func fmt(_ t: Double?) -> String { t.map { TimeFmt.string($0, fps: fps) } ?? "--:--:--.--" }

    // MARK: Open

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a recorded video (.ts, .m2ts, .mp4, .mkv …)"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        stopPlayback()
        guard FFTools.ffmpeg != nil, FFTools.ffprobe != nil else {
            errorMessage = CutterError.toolMissing("ffmpeg / ffprobe").localizedDescription
            return
        }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MediaInfo.probe(url) }
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .failure(let e): self.errorMessage = e.localizedDescription
                case .success(let info): self.load(info)
                }
            }
        }
    }

    private func load(_ info: MediaInfo) {
        player?.stop()
        self.info = info
        segments = []
        selection = []
        markIn = nil
        markOut = nil
        thumbnails = []
        frameSink.show(nil)
        NSDocumentController.shared.noteNewRecentDocumentURL(info.url)

        let (w, h) = info.previewSize(maxWidth: 1280)
        let main = FrameRequester(info: info)
        main.handler = { [weak self] _, imgs in
            guard let self, !self.isPlaying, let img = imgs.first else { return }
            self.frameSink.show(img)
        }
        mainFrames = main

        let strip = FrameRequester(info: info)
        strip.handler = { [weak self] req, imgs in
            guard let self, !self.isPlaying else { return }
            let first = Int(((req.t - info.videoOffset) * info.fps).rounded())
            self.thumbnails = imgs.enumerated().map { i, img in
                Thumbnail(id: first + i, time: info.snap(req.t + Double(i) / info.fps), image: img)
            }
        }
        stripFrames = strip

        let p = PlaybackEngine(info: info, width: w, height: h)
        p.volume = volume
        p.onFrame = { [weak self] img, t in
            guard let self, self.isPlaying else { return }
            self.frameSink.show(img)
            self.cursor = info.snap(t)
        }
        p.onEnded = { [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.scheduleStrip()
        }
        player = p
        seek(to: 0)
    }

    // MARK: Navigation

    func seek(to t: Double) {
        guard let info else { return }
        let target = info.snap(min(max(0, t), info.lastFrameTime))
        cursor = target
        if isPlaying {
            player?.start(at: target)
            return
        }
        let (w, h) = info.previewSize(maxWidth: 1280)
        mainFrames?.request(.init(t: target, count: 1, w: w, h: h))
        scheduleStrip()
    }

    func step(frames: Int) {
        if isPlaying { togglePlay() }
        seek(to: cursor + Double(frames) / fps)
    }

    func jump(seconds: Double) { seek(to: cursor + seconds) }

    func goToStart() { seek(to: 0) }
    func goToEnd() { if let info { seek(to: info.lastFrameTime) } }

    func togglePlay() {
        guard let info, let player else { return }
        if isPlaying {
            stopPlayback()
            scheduleStrip()
        } else {
            mainFrames?.invalidate()
            stripFrames?.invalidate()
            if cursor >= info.lastFrameTime - 0.5 { cursor = 0 }
            isPlaying = true
            player.start(at: cursor)
        }
    }

    func stopPlayback() {
        player?.stop()
        isPlaying = false
    }

    private func scheduleStrip() {
        stripWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let info = self.info, !self.isPlaying else { return }
            let half = self.thumbCount / 2
            let start = max(0, self.cursor - Double(half) / info.fps)
            let (w, h) = info.previewSize(maxWidth: 192)
            self.stripFrames?.request(.init(t: info.snap(start), count: self.thumbCount, w: w, h: h))
        }
        stripWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    // MARK: Marks & segments

    func setMarkIn() {
        guard info != nil else { return }
        markIn = cursor
        if let o = markOut, o <= cursor { markOut = nil }
    }

    func setMarkOut() {
        guard info != nil else { return }
        markOut = cursor
        if let i = markIn, i >= cursor { markIn = nil }
    }

    func clearMarks() { markIn = nil; markOut = nil }

    /// The range currently marked (out defaults to cursor when only In is set).
    var markedRange: Segment? {
        guard let i = markIn else { return nil }
        let o = markOut ?? (cursor > i ? cursor : nil)
        guard let o, o > i else { return nil }
        return Segment(start: i, end: o)
    }

    func addSegment() {
        guard let r = markedRange else { NSSound.beep(); return }
        segments.append(r)
        segments.sort { $0.start < $1.start }
        selection = [r.id]
        clearMarks()
    }

    func updateSelectedSegment() {
        guard selection.count == 1, let id = selection.first,
              let idx = segments.firstIndex(where: { $0.id == id }), let r = markedRange else { NSSound.beep(); return }
        segments[idx].start = r.start
        segments[idx].end = r.end
        segments.sort { $0.start < $1.start }
        clearMarks()
    }

    func loadSegmentToMarks(_ id: Segment.ID) {
        guard let seg = segments.first(where: { $0.id == id }) else { return }
        markIn = seg.start
        markOut = seg.end
        seek(to: seg.start)
    }

    func removeSelected() {
        segments.removeAll { selection.contains($0.id) }
        selection = []
    }

    func clearSegments() { segments = []; selection = [] }

    /// Replace kept segments with the parts between them (like VideoReDo "Invert All Cuts").
    func invertSegments() {
        guard let info else { return }
        let sorted = segments.sorted { $0.start < $1.start }
        var result: [Segment] = []
        var pos = 0.0
        for s in sorted {
            if s.start - pos > info.frameDuration { result.append(Segment(start: pos, end: s.start)) }
            pos = max(pos, s.end)
        }
        if info.duration - pos > info.frameDuration { result.append(Segment(start: pos, end: info.duration)) }
        segments = result
        selection = []
    }

    // MARK: Stats

    var outputDuration: Double { segments.reduce(0) { $0 + $1.duration } }
    func estimatedBytes(_ dur: Double) -> Double {
        guard let info, info.duration > 0 else { return 0 }
        return info.sizeBytes * dur / info.duration
    }

    /// Segments that will be exported (falls back to the current marks).
    var exportSegments: [Segment] {
        if !segments.isEmpty { return segments }
        if let r = markedRange { return [r] }
        return []
    }

    func segmentContains(_ t: Double) -> Bool {
        segments.contains { t >= $0.start && t < $0.end }
    }

    // MARK: Keyboard

    func handleKey(_ e: NSEvent) -> Bool {
        guard info != nil else { return false }
        if let r = NSApp.keyWindow?.firstResponder, r is NSText { return false }
        if e.modifierFlags.contains(.command) { return false }
        let shift = e.modifierFlags.contains(.shift)
        let opt = e.modifierFlags.contains(.option)
        switch e.keyCode {
        case 49: togglePlay(); return true                                  // space
        case 123: shift ? jump(seconds: -1) : opt ? jump(seconds: -10) : step(frames: -1); return true
        case 124: shift ? jump(seconds: 1) : opt ? jump(seconds: 10) : step(frames: 1); return true
        case 116: jump(seconds: -60); return true                           // page up
        case 121: jump(seconds: 60); return true                            // page down
        case 115: goToStart(); return true                                  // home
        case 119: goToEnd(); return true                                    // end
        case 51, 117:                                                       // delete
            if !selection.isEmpty { removeSelected(); return true }
            return false
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "i", "[": setMarkIn(); return true
        case "o", "]": setMarkOut(); return true
        case "a": addSegment(); return true
        case "j": jump(seconds: -10); return true
        case "l": jump(seconds: 10); return true
        case "k": if isPlaying { togglePlay() }; return true
        default: return false
        }
    }
}
