import AppKit
import ScreenCaptureKit
import AVFoundation

@MainActor
final class Recorder: NSObject, ObservableObject, SCRecordingOutputDelegate, SCStreamDelegate {
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var startedAt: Date?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var destination: URL?
    var onFinish: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    func start(to url: URL, systemAudio: Bool, fps: Int = 30, maxWidth: Int = 3840) async {
        guard !isBusy, !isRecording else { return }
        isBusy = true
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw NSError(domain: "Stillframe", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display is available."])
            }
            let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let config = SCStreamConfiguration()
            // Even dimensions, within H.264 limits; preserves the display aspect ratio.
            let scale = min(1, Double(maxWidth) / Double(display.width), Double(maxWidth) * 9 / 16 / Double(display.height))
            config.width = max(2, Int(Double(display.width) * scale) / 2 * 2)
            config.height = max(2, Int(Double(display.height) * scale) / 2 * 2)
            config.minimumFrameInterval = CMTime(value: 1, timescale: Int32([15, 30, 60].contains(fps) ? fps : 30))
            config.showsCursor = true
            config.capturesAudio = systemAudio
            config.excludesCurrentProcessAudio = true
            let settings = SCRecordingOutputConfiguration()
            settings.outputURL = url
            settings.outputFileType = .mp4
            settings.videoCodecType = .h264
            let recording = SCRecordingOutput(configuration: settings, delegate: self)
            let capture = SCStream(filter: filter, configuration: config, delegate: self)
            try capture.addRecordingOutput(recording)
            destination = url; output = recording; stream = capture
            try await capture.startCapture()
            // Remain busy until the recording delegate confirms that writing started.
        } catch {
            reset()
            onError?("Could not start recording. Allow Stillframe in System Settings → Privacy & Security → Screen & System Audio Recording.\n\n\(error.localizedDescription)")
        }
    }

    func stop() async {
        guard let stream, !isBusy else { return }
        isBusy = true
        do { try await stream.stopCapture() }
        catch { reset(); onError?(error.localizedDescription) }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard self.output === recordingOutput else { return }
            self.isRecording = true; self.isBusy = false; self.startedAt = Date()
        }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard self.output === recordingOutput else { return }
            let url = self.destination
            self.reset()
            if let url { self.onFinish?(url) }
        }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.output === recordingOutput else { return }
            let active = self.stream
            self.reset()
            try? await active?.stopCapture()
            self.onError?(error.localizedDescription)
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.reset(); self.onError?(error.localizedDescription)
        }
    }
    private func reset() {
        stream = nil; output = nil; destination = nil
        isRecording = false; isBusy = false; startedAt = nil
    }
}
