import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard NSApp.keyWindow?.attachedSheet == nil, NSApp.modalWindow == nil else { return e }
            return EditorModel.shared.handleKey(e) ? nil : e
        }
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }),
           FileManager.default.fileExists(atPath: path) {
            EditorModel.shared.open(URL(fileURLWithPath: path))
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let u = urls.first { EditorModel.shared.open(u) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { EditorModel.shared.stopPlayback() }
}

@main
struct K24CutterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = EditorModel.shared

    init() { SelfTest.runIfRequested() }

    var body: some Scene {
        Window("K24 Cutter", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1500, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { model.openPanel() }.keyboardShortcut("o")
                Divider()
                Button("Export Segments…") { model.showExport = true }
                    .keyboardShortcut("e")
                    .disabled(model.info == nil)
            }
            CommandMenu("Edit Cuts") {
                Button("Set Start Mark  [ / I") { model.setMarkIn() }
                Button("Set End Mark  ] / O") { model.setMarkOut() }
                Button("Add Segment  A") { model.addSegment() }
                Button("Update Selected Segment") { model.updateSelectedSegment() }
                Button("Clear Marks") { model.clearMarks() }
                Divider()
                Button("Remove Selected Segments") { model.removeSelected() }
                Button("Invert Segments") { model.invertSegments() }
                Button("Clear All Segments") { model.clearSegments() }
            }
            CommandMenu("Playback") {
                Button("Play / Pause  Space") { model.togglePlay() }
                Button("Next Frame  →") { model.step(frames: 1) }
                Button("Previous Frame  ←") { model.step(frames: -1) }
                Button("Forward 1s  ⇧→") { model.jump(seconds: 1) }
                Button("Back 1s  ⇧←") { model.jump(seconds: -1) }
                Button("Forward 10s  ⌥→ / L") { model.jump(seconds: 10) }
                Button("Back 10s  ⌥← / J") { model.jump(seconds: -10) }
                Button("Go to Start  Home") { model.goToStart() }
                Button("Go to End  End") { model.goToEnd() }
            }
        }
    }
}
