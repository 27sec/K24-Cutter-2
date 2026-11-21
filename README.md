# K24 Cutter

macOS app (Swift / SwiftUI) for cutting TV recordings (.ts / .m2ts / .mp4 / .mkv) **without re-encoding**. It uses ffmpeg stream copy. The layout follows VideoReDo.

## Build
    brew install ffmpeg        # needs ffmpeg + ffprobe
    ./build_app.sh             # build + install to /Applications/K24 Cutter 2.app
    ./build_app.sh --no-install   # build only (dist/)
    swift tools/make_icon.swift   # regenerate icon

## Usage
1. Open a file (⌘O) or drag it onto the window.
2. Move to the start point, press `[` / `I` (or the ⇤ button) = Trim Start.
3. Move to the end point, press `]` / `O` (or the ⇥ button) = Trim End.
4. Press `A` / "Add Segment" to add it to the Segment list. Repeat for every part you want to keep.
5. Click "Export…" and choose the container (same as source / TS / MP4 / MKV) and whether to join into one file or write one file per segment.

## Keyboard shortcuts
Space = play/pause · ←/→ = 1 frame · ⇧←/→ = 1 s · ⌥←/→ or J/L = 10 s · PgUp/PgDn = 1 min · Home/End
Double-click a segment = load it into the marks for editing, then "Update Segment" · Delete = remove selected segments

Note: stream copy can only cut on keyframes (GOP), so each segment may start up to ~0.5 s before the mark.
