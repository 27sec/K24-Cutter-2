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

    /// Snapshot taken when the sheet opens (the list may be cleared after export).
    private var segments: [Segment] { st.segments }

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

    private var effectiveMode: Exporter.Mode { segments.count < 2 ? .join : st.mode }

    private var baseName: String { model.info?.url.deletingPathExtension().lastPathComponent ?? "output" }

    /// File names the next export will create: "<source>-NNN.ext", continuing from the folder.
    private var plannedOutputs: [URL] {
        guard let dir = st.outputDir else { return [] }
        let count = effectiveMode == .separate ? segments.count : 1
        return Exporter.numberedOutputs(dir: dir, base: baseName, ext: ext, count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export (lossless, no re-encode)").font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    let total = segments.reduce(0) { $0 + $1.duration }
                    Text("\(segments.count) segment(s) — total \(model.fmt(total))  ·  ≈ \(TimeFmt.mb(model.estimatedBytes(total))) MB")
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
                    Text(st.outputDir?.path ?? "—")
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(st.outputDir == nil ? .secondary : .primary)
                    Button("Choose Folder…") { chooseFolder() }
                }
                LabeledContent("File name:") {
                    Text(fileNameSummary)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Toggle("Clear segments after export", isOn: $st.clearAfterExport)
            }
            .disabled(st.running)

            Text("Stream copy keeps the original quality. Cuts snap to the nearest keyframe (GOP), so each segment may start up to ~0.5 s earlier than the mark.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if st.running || !st.results.isEmpty || st.error != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: st.progress)
                    Text(st.error ?? (st.results.isEmpty ? st.message : doneMessage))
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
        .frame(width: 600)
        .onAppear {
            st.segments = model.exportSegments
            st.outputDir = model.info?.url.deletingLastPathComponent()
        }
        .onDisappear {
            DispatchQueue.main.async {
                NSApp.mainWindow?.makeFirstResponder(nil)
                model.seek(to: model.cursor)    // refresh preview + strip
            }
        }
    }

    private var fileNameSummary: String {
        let names = plannedOutputs.map(\.lastPathComponent)
        guard let first = names.first else { return "—" }
        if names.count == 1 { return first }
        return "\(first)  …  \(names.last!)  (\(names.count) files)"
    }

    private var doneMessage: String {
        let names = st.results.map(\.lastPathComponent)
        let list = names.count <= 3 ? names.joined(separator: ", ")
            : "\(names.first!) … \(names.last!)"
        return "Done — \(names.count) file(s) written: \(list)" + (st.clearedSegments ? "  ·  segment list cleared" : "")
    }

    private func close() {
        model.showExport = false
        dismiss()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Folder for the exported files"
        if let dir = st.outputDir { panel.directoryURL = dir }
        if panel.runModal() == .OK, let url = panel.url { st.outputDir = url }
    }

    private func start() {
        guard let info = model.info else { return }
        if st.outputDir == nil { chooseFolder() }
        // names are computed right now, so files written since the sheet opened are respected
        let outs = plannedOutputs
        guard !outs.isEmpty else { return }
        if outs.contains(where: { $0.standardizedFileURL == info.url.standardizedFileURL }) {
            st.error = "Output must be different from the source file."
            return
        }
        let ex = Exporter()
        let segs = segments
        let clear = st.clearAfterExport
        st.exporter = ex
        st.running = true
        st.error = nil
        st.results = []
        st.clearedSegments = false
        st.progress = 0
        st.message = "Starting…"
        ex.run(info: info, segments: segs, outputs: outs, mode: effectiveMode,
               progress: { p, m in st.progress = p; st.message = m },
               completion: { r in
                   st.running = false
                   switch r {
                   case .success(let urls):
                       st.results = urls
                       st.progress = 1
                       if clear {
                           model.clearSegments()
                           model.clearMarks()
                           st.clearedSegments = true
                       }
                   case .failure(let e):
                       st.error = e.localizedDescription
                   }
               })
    }
}

final class ExportState: ObservableObject {
    @Published var container: ExportSheet.Container = .source
    @Published var mode: Exporter.Mode = .separate
    @Published var outputDir: URL?
    @Published var clearAfterExport = true
    @Published var segments: [Segment] = []
    @Published var running = false
    @Published var progress = 0.0
    @Published var message = ""
    @Published var results: [URL] = []
    @Published var clearedSegments = false
    @Published var error: String?
    @Published var exporter: Exporter?
}
