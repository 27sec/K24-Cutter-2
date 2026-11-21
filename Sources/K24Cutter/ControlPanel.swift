import SwiftUI

struct ControlPanel: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 10) {
            TimelineBar()
                .frame(height: 34)

            // Marks + current time
            HStack(spacing: 14) {
                Button { if let t = model.markIn { model.seek(to: t) } } label: {
                    Text(model.fmt(model.markIn)).font(.system(.body, design: .monospaced))
                }
                .buttonStyle(.plain)
                .frame(width: 120, alignment: .trailing)
                .help("Start mark — click to go there")

                Button { model.setMarkIn() } label: { Image(systemName: "chevron.left.to.line") }
                    .help("Set START mark at cursor  ( [ or I )")

                TimeField()

                Button { model.setMarkOut() } label: { Image(systemName: "chevron.right.to.line") }
                    .help("Set END mark at cursor  ( ] or O )")

                Button { if let t = model.markOut { model.seek(to: t) } } label: {
                    Text(model.fmt(model.markOut)).font(.system(.body, design: .monospaced))
                }
                .buttonStyle(.plain)
                .frame(width: 120, alignment: .leading)
                .help("End mark — click to go there")
            }
            .controlSize(.large)

            // Transport
            HStack(spacing: 10) {
                group {
                    tb("backward.end.fill", "Go to start (Home)") { model.goToStart() }
                    tb("gobackward.60", "Back 1 minute (PgUp)") { model.jump(seconds: -60) }
                }
                group {
                    jb(-10, "Back 10 s (⌥← / J)")
                    jb(-5, "Back 5 s")
                    jb(-1, "Back 1 s (⇧←)")
                }
                group {
                    tb("backward.frame.fill", "Previous frame (←)") { model.step(frames: -1) }
                }
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Play / Pause (Space)")
                group {
                    tb("forward.frame.fill", "Next frame (→)") { model.step(frames: 1) }
                }
                group {
                    jb(1, "Forward 1 s (⇧→)")
                    jb(5, "Forward 5 s")
                    jb(10, "Forward 10 s (⌥→ / L)")
                }
                group {
                    tb("goforward.60", "Forward 1 minute (PgDn)") { model.jump(seconds: 60) }
                    tb("forward.end.fill", "Go to end (End)") { model.goToEnd() }
                }
            }

            // Actions
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                    Slider(value: $model.volume, in: 0...1).frame(width: 110)
                }
                Spacer()
                Button("Clear Marks") { model.clearMarks() }
                    .disabled(model.markIn == nil && model.markOut == nil)
                Button("Update Segment") { model.updateSelectedSegment() }
                    .disabled(model.selection.count != 1 || model.markedRange == nil)
                    .help("Replace the selected segment with the current START/END marks")
                Button {
                    model.addSegment()
                } label: { Label("Add Segment (A)", systemImage: "plus.rectangle.on.rectangle") }
                    .disabled(model.markedRange == nil)
                Button {
                    model.stopPlayback()
                    model.showExport = true
                } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.exportSegments.isEmpty)
                Spacer().frame(width: 130)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .disabled(model.info == nil)
    }

    @ViewBuilder private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 4) { c() }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }

    /// Jump button labelled with its offset, e.g. "−5s" / "+10s".
    private func jb(_ secs: Int, _ help: String) -> some View {
        Button { model.jump(seconds: Double(secs)) } label: {
            Text(secs < 0 ? "−\(-secs)s" : "+\(secs)s")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 34, height: 26)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func tb(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 30, height: 26)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// NSTextField that only becomes first responder when clicked, so AppKit never
/// auto-focuses it (e.g. after a sheet closes) and steals the editing shortcuts.
final class ClickToEditField: NSTextField {
    var allowFocus = false
    override var acceptsFirstResponder: Bool { allowFocus && super.acceptsFirstResponder }
    override func mouseDown(with event: NSEvent) {
        allowFocus = true
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) {   // Esc leaves the field
        window?.makeFirstResponder(nil)
    }
}

/// Editable current-time field (HH:MM:SS.ff). Shows the cursor when not being edited.
struct TimeField: NSViewRepresentable {
    @EnvironmentObject var model: EditorModel

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: EditorModel
        var editing = false
        init(model: EditorModel) { self.model = model }
        func controlTextDidBeginEditing(_ obj: Notification) { editing = true }
        func controlTextDidEndEditing(_ obj: Notification) {
            editing = false
            guard let f = obj.object as? NSTextField else { return }
            (f as? ClickToEditField)?.allowFocus = false
            let movement = obj.userInfo?["NSTextMovement"] as? Int
            if movement == NSTextMovement.return.rawValue {
                if let t = TimeFmt.parse(f.stringValue, fps: model.fps) { model.seek(to: t) } else { NSSound.beep() }
                f.window?.makeFirstResponder(nil)
            }
            f.stringValue = model.fmt(model.cursor)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let f = ClickToEditField()
        f.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        f.alignment = .center
        f.bezelStyle = .roundedBezel
        f.delegate = context.coordinator
        f.toolTip = "Type a time (HH:MM:SS.ff or seconds) and press Return to jump"
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: 160).isActive = true
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.model = model
        if !context.coordinator.editing {
            let s = model.fmt(model.cursor)
            if f.stringValue != s { f.stringValue = s }
        }
    }
}

// MARK: - Timeline

struct TimelineBar: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let dur = max(model.info?.duration ?? 1, 0.001)
            let w = geo.size.width
            let h = geo.size.height
            let x: (Double) -> CGFloat = { CGFloat($0 / dur) * w }

            Canvas { ctx, size in
                let bar = CGRect(x: 0, y: 8, width: size.width, height: size.height - 16)
                ctx.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(Color(red: 0.75, green: 0.25, blue: 0.25)))
                for s in model.segments {
                    let r = CGRect(x: x(s.start), y: bar.minY, width: max(1, x(s.end) - x(s.start)), height: bar.height)
                    ctx.fill(Path(r), with: .color(model.selection.contains(s.id) ? Color(red: 0.2, green: 0.9, blue: 0.35) : Color(red: 0.15, green: 0.68, blue: 0.25)))
                }
                if let i = model.markIn {
                    let o = model.markOut ?? model.cursor
                    if o > i {
                        let r = CGRect(x: x(i), y: bar.minY, width: max(1, x(o) - x(i)), height: bar.height)
                        ctx.fill(Path(r), with: .color(Color.blue.opacity(0.55)))
                    }
                    bracket(&ctx, x(i), size.height, left: true)
                }
                if let o = model.markOut { bracket(&ctx, x(o), size.height, left: false) }
                // cursor
                let cx = x(model.cursor)
                ctx.fill(Path(roundedRect: CGRect(x: cx - 4, y: 2, width: 8, height: size.height - 4), cornerRadius: 2),
                         with: .color(.white))
                ctx.stroke(Path(roundedRect: CGRect(x: cx - 4, y: 2, width: 8, height: size.height - 4), cornerRadius: 2),
                           with: .color(.black.opacity(0.6)), lineWidth: 1)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let t = Double(min(max(0, g.location.x), w) / w) * dur
                model.seek(to: t)
            })
        }
        .help("Red = removed, green = segments to keep, blue = current START→END selection")
    }

    private func bracket(_ ctx: inout GraphicsContext, _ x: CGFloat, _ h: CGFloat, left: Bool) {
        var p = Path()
        let d: CGFloat = left ? 5 : -5
        p.move(to: CGPoint(x: x + d, y: 1))
        p.addLine(to: CGPoint(x: x, y: 1))
        p.addLine(to: CGPoint(x: x, y: h - 1))
        p.addLine(to: CGPoint(x: x + d, y: h - 1))
        ctx.stroke(p, with: .color(.primary), lineWidth: 2)
    }
}
