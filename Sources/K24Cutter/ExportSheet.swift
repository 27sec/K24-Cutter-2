import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ExportSheet: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    enum Container: String, CaseIterable, Identifiable {
        case source = "Same as source"
        case ts = "MPEG-TS (.ts)"
        case mp4 = "MP4 (.mp4)"
        case mkv = "Matroska (.mkv)"
        var id: String { rawValue }
    }

    @StateObject private var st = ExportState()

    private var segments: [Segment] { model.exportSegments }

    private var ext: String {
        switch st.container {
        case .source:
            let e = model.info?.url.pathExtension.lowercased() ?? "ts"
            return e.isEmpty ? "ts" : e
        case .ts: return "ts"
        case .mp4: return "mp4"
        case .mkv: return "mkv"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export (lossless, no re-encode)").font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(segments.count) segment(s) — total \(model.fmt(segments.reduce(0) { $0 + $1.duration }))  ·  ≈ \(TimeFmt.mb(model.estimatedBytes(segments.reduce(0) { $0 + $1.duration }))) MB")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(segments.enumerated()), id: \.element.id) { i, s in
                                Text("\(i + 1).  \(model.fmt(s.start))  →  \(model.fmt(s.end))   (\(model.fmt(s.duration)))")
                                    .font(.system(.callout, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .padding(4)
            }

            Form {
                Picker("Container:", selection: $st.container) {
                    ForEach(Container.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Output:", selection: $st.mode) {
                    ForEach(Exporter.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .disabled(segments.count < 2)
                HStack {
                    Text(st.output?.path ?? "—")
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(st.output == nil ? .secondary : .primary)
                    Button("Choose…") { choose() }
                }
            }
            .disabled(st.running)

            Text("Stream copy keeps the original quality. Cuts snap to the nearest keyframe (GOP), so each segment may start up to ~0.5 s earlier than the mark.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if st.running || !st.results.isEmpty || st.error != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: st.progress)
                    Text(st.error ?? (st.results.isEmpty ? st.message : "Done — \(st.results.count) file(s) written"))
                        .font(.callout)
                        .foregroundStyle(st.error == nil ? Color.primary : Color.red)
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
            }

            HStack {
                if !st.results.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(st.results) }
                }
                Spacer()
                if st.running {
                    Button("Cancel Export") { st.exporter?.cancel() }
                } else {
                    if st.results.isEmpty {
                        Button("Cancel") { close() }
                            .keyboardShortcut(.cancelAction)
                        Button("Export") { start() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(segments.isEmpty)
                    } else {
                        Button("Export Again") { start() }
                        Button("Close") { close() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear { st.output = defaultOutput() }
        .onDisappear {
            DispatchQueue.main.async {
                NSApp.mainWindow?.makeFirstResponder(nil)
                model.seek(to: model.cursor)    // refresh preview + strip
            }
        }
        .onChange(of: st.container) { _ in
            if let o = st.output { st.output = o.deletingPathExtension().appendingPathExtension(ext) }
        }
    }

    private func close() {
        model.showExport = false
        dismiss()
    }

    private func defaultOutput() -> URL? {
        guard let src = model.info?.url else { return nil }
        let base = src.deletingPathExtension().lastPathComponent + "_cut"
        var url = src.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = src.deletingLastPathComponent().appendingPathComponent("\(base)\(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    private func choose() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = st.output?.lastPathComponent ?? "output.\(ext)"
        if let dir = st.output?.deletingLastPathComponent() { panel.directoryURL = dir }
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension.lowercased() != ext { url = url.deletingPathExtension().appendingPathExtension(ext) }
            st.output = url
        }
    }

    private func start() {
        guard let info = model.info else { return }
        if st.output == nil { choose() }
        guard let out = st.output else { return }
        if out.standardizedFileURL == info.url.standardizedFileURL {
            st.error = "Output must be different from the source file."
            return
        }
        let ex = Exporter()
        st.exporter = ex
        st.running = true
        st.error = nil
        st.results = []
        st.progress = 0
        st.message = "Starting…"
        ex.run(info: info, segments: segments, output: out, mode: segments.count < 2 ? .join : st.mode,
               progress: { p, m in st.progress = p; st.message = m },
               completion: { r in
                   st.running = false
                   switch r {
                   case .success(let urls): st.results = urls; st.progress = 1
                   case .failure(let e): st.error = e.localizedDescription
                   }
               })
    }
}

final class ExportState: ObservableObject {
    @Published var container: ExportSheet.Container = .source
    @Published var mode: Exporter.Mode = .join
    @Published var output: URL?
    @Published var running = false
    @Published var progress = 0.0
    @Published var message = ""
    @Published var results: [URL] = []
    @Published var error: String?
    @Published var exporter: Exporter?

}
