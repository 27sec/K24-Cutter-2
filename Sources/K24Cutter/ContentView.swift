import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        FrameView(sink: model.frameSink)
                        if model.info == nil { placeholder }
                        if model.isLoading { ProgressView("Reading video…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
                    }
                    ThumbnailStrip()
                        .frame(height: 96)
                }
                .background(Color.black)

                SegmentPanel()
                    .frame(width: 330)
            }
            Divider()
            ControlPanel()
        }
        .navigationTitle(model.info?.url.lastPathComponent ?? "K24 Cutter")
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.open(url) } }
            }
            return true
        }
        .sheet(isPresented: $model.showExport) { ExportSheet() }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil },
                                             set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("Drop a recorded TV file here").font(.title2).foregroundStyle(.white)
            Text("MPEG-TS / M2TS / MP4 / MKV — cut losslessly with ffmpeg (no re-encode)")
                .foregroundStyle(.secondary)
            Button("Open Video…") { model.openPanel() }.controlSize(.large)
        }
    }
}

// MARK: - Video surface

struct FrameView: NSViewRepresentable {
    let sink: FrameSink
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        v.layer = layer
        sink.layer = layer
        DebugLog.log("FrameView makeNSView")
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Thumbnail strip (frames around the cursor)

struct ThumbnailStrip: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let count = model.thumbCount
            let w = geo.size.width / CGFloat(count)
            HStack(spacing: 0) {
                ForEach(model.thumbnails) { th in
                    let isCursor = abs(th.time - model.cursor) < model.fps.reciprocal * 0.5
                    let kept = model.segmentContains(th.time)
                    VStack(spacing: 2) {
                        Image(decorative: th.image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay(Rectangle().stroke(isCursor ? Color.yellow : (kept ? Color.green : Color.clear),
                                                        lineWidth: isCursor ? 3 : 2))
                        Text(model.fmt(th.time))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(isCursor ? Color.yellow : Color.green)
                    }
                    .frame(width: w)
                    .contentShape(Rectangle())
                    .onTapGesture { model.seek(to: th.time) }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(white: 0.08))
    }
}

private extension Double { var reciprocal: Double { 1 / self } }
