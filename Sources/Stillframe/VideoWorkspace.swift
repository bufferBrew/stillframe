import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct VideoWorkspace: View {
    let url: URL
    var exportOriginal: () -> Void
    var reportError: (String) -> Void
    var reportSuccess: (String) -> Void
    @State private var player: AVPlayer?
    @State private var duration = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var gifFPS = 10
    @State private var gifSize = 720
    @State private var isExporting = false
    @State private var progress = 0.0
    @State private var task: Task<Void, Never>?
    @State private var loadError: String?
    private var valid: Bool { duration > 0 && start >= 0 && end <= duration + 0.001 && end - start >= 0.05 }
    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
            if let loadError { Text(loadError).foregroundStyle(.red).padding(16) }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Trim & Export", systemImage: "scissors").font(.headline)
                    Spacer()
                    Text("Original recording is preserved").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Start").frame(width: 40, alignment: .leading)
                    Slider(value: $start, in: 0...max(0.05, duration), onEditingChanged: { editing in if !editing { seek(start) } }).accessibilityLabel("Clip start")
                    TextField("Start seconds", value: $start, format: .number.precision(.fractionLength(2))).frame(width: 70).textFieldStyle(.roundedBorder).accessibilityLabel("Clip start in seconds")
                    Text("s").foregroundStyle(.secondary)
                }
                HStack {
                    Text("End").frame(width: 40, alignment: .leading)
                    Slider(value: $end, in: 0...max(0.05, duration), onEditingChanged: { editing in if !editing { seek(end) } }).accessibilityLabel("Clip end")
                    TextField("End seconds", value: $end, format: .number.precision(.fractionLength(2))).frame(width: 70).textFieldStyle(.roundedBorder).accessibilityLabel("Clip end in seconds")
                    Text("s").foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Preview clip") {
                        seek(start)
                        player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 60000)
                        player?.play()
                    }.disabled(!valid)
                    Button("Reset") { start = 0; end = duration; player?.currentItem?.forwardPlaybackEndTime = .invalid; seek(0) }
                    Spacer()
                    Text(valid ? String(format: "%.2f seconds", end - start) : "Choose a valid range").font(.caption).foregroundStyle(valid ? Color.secondary : Color.red)
                }
                Divider()
                HStack {
                    Picker("GIF", selection: $gifFPS) { Text("5 fps").tag(5); Text("10 fps").tag(10); Text("15 fps").tag(15) }.frame(width: 135)
                    Picker("Size", selection: $gifSize) { Text("480 px").tag(480); Text("720 px").tag(720); Text("1080 px").tag(1080) }.frame(width: 145)
                    Spacer()
                    Button("Export GIF…") { beginExport(gif: true) }.disabled(!valid || end - start > 30)
                        .help("Animated GIF export supports clips up to 30 seconds")
                    Button("Export Clip…") { beginExport(gif: false) }.buttonStyle(.borderedProminent).disabled(!valid)
                }
                HStack {
                    Text("GIFs are silent; choose a clip of up to 30 seconds.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Original MP4…", action: exportOriginal)
                }
            }.padding(16).disabled(isExporting || duration == 0)
            if isExporting {
                HStack {
                    if progress > 0 { ProgressView(value: progress).frame(maxWidth: 220) } else { ProgressView().controlSize(.small) }
                    Text(progress > 0 ? "Exporting \(Int(progress * 100))%" : "Exporting video…").font(.caption)
                    Spacer()
                    Button("Cancel") { task?.cancel() }
                }.padding(16)
            }
        }
        .task(id: url) {
            task?.cancel(); task = nil; isExporting = false; progress = 0
            player?.pause(); player = AVPlayer(url: url); duration = 0; loadError = nil
            do {
                let value = try await AVURLAsset(url: url).load(.duration).seconds
                try Task.checkCancellation()
                guard value.isFinite, value > 0 else { throw MediaExportError.unsupported }
                duration = value; start = 0; end = value
            } catch is CancellationError { } catch { loadError = error.localizedDescription }
        }
        .onDisappear { player?.pause(); task?.cancel() }
    }
    private func seek(_ value: Double) {
        guard value.isFinite else { return }
        player?.pause(); player?.seek(to: CMTime(seconds: max(0, min(duration, value)), preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func beginExport(gif: Bool) {
        guard valid, !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = gif ? [.gif] : [.mpeg4Movie]
        panel.nameFieldStringValue = gif ? "Recording.gif" : "Recording clip.mp4"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        player?.pause(); isExporting = true; progress = 0
        let source = url, clip = VideoClip(start: start, end: end), fps = gifFPS, size = gifSize
        task = Task { @MainActor in
            do {
                try await VideoExporter.export(source: source, destination: target, clip: clip, gif: gif, fps: fps, maxSize: size) { value in
                    await MainActor.run { progress = value }
                }
                reportSuccess("Saved \(target.lastPathComponent)")
            } catch is CancellationError { reportSuccess("Export cancelled") }
            catch { if !Task.isCancelled { reportError(error.localizedDescription) } }
            isExporting = false; task = nil
        }
    }
}
