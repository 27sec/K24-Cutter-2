import SwiftUI
import AppKit

struct SegmentPanel: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Segments to keep").font(.headline)
                Spacer()
                Text("\(model.segments.count)").foregroundStyle(.secondary)
            }
            Table(model.segments, selection: $model.selection) {
                TableColumn("#") { s in
                    Text("\((model.segments.firstIndex(of: s) ?? 0) + 1)").foregroundStyle(.secondary)
                }
                .width(24)
                TableColumn("Start") { s in Text(model.fmt(s.start)).font(.system(.callout, design: .monospaced)) }
                TableColumn("End") { s in Text(model.fmt(s.end)).font(.system(.callout, design: .monospaced)) }
                TableColumn("Duration") { s in Text(model.fmt(s.duration)).font(.system(.callout, design: .monospaced)) }
            }
            .contextMenu(forSelectionType: Segment.ID.self) { ids in
                if ids.count == 1, let id = ids.first {
                    Button("Go to Start") { if let s = model.segments.first(where: { $0.id == id }) { model.seek(to: s.start) } }
                    Button("Go to End") { if let s = model.segments.first(where: { $0.id == id }) { model.seek(to: s.end) } }
                    Button("Edit (load into marks)") { model.loadSegmentToMarks(id) }
                }
                Button("Remove") { model.selection = ids; model.removeSelected() }
            } primaryAction: { ids in
                if let id = ids.first { model.loadSegmentToMarks(id) }
            }

            VStack(spacing: 6) {
                Button("Invert All Segments") { model.invertSegments() }
                    .frame(maxWidth: .infinity)
                    .disabled(model.info == nil)
                HStack {
                    Button("Remove Selected") { model.removeSelected() }
                        .frame(maxWidth: .infinity)
                        .disabled(model.selection.isEmpty)
                    Button("Clear All") { model.clearSegments() }
                        .frame(maxWidth: .infinity)
                        .disabled(model.segments.isEmpty)
                }
            }
            .buttonStyle(.bordered)

            InfoBox()
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct InfoBox: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        GroupBox("Info") {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    Text("Time").foregroundStyle(.secondary)
                    Text("MB").foregroundStyle(.secondary)
                }
                row("Cursor:", model.cursor, model.estimatedBytes(model.cursor))
                row("Program:", model.info?.duration ?? 0, model.info?.sizeBytes ?? 0)
                let sel = model.markedRange?.duration ?? 0
                row("Selection:", sel, model.estimatedBytes(sel))
                row("Output:", model.outputDuration, model.estimatedBytes(model.outputDuration))
            }
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity)

            if let info = model.info {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Video: \(info.videoCodec) \(info.width)×\(info.height)\(info.interlaced ? "i" : "p") → \(info.displayWidth)×\(info.displayHeight)")
                    Text(String(format: "Frame rate: %.3f fps", info.fps))
                    Text("Audio: \(info.audioDescriptions.isEmpty ? "none" : info.audioDescriptions.joined(separator: ", "))")
                    Text("Container: \(info.formatName)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            }
        }
    }

    private func row(_ label: String, _ t: Double, _ bytes: Double) -> some View {
        GridRow {
            Text(label).font(.callout)
            Text(model.info == nil ? "" : model.fmt(t))
            Text(model.info == nil ? "" : TimeFmt.mb(bytes))
        }
    }
}
