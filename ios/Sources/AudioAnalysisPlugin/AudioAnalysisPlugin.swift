import Foundation
import Capacitor
import AVFoundation

/// Native audio analysis plugin for Capacitor iOS.
///
/// # Why this exists
/// WKWebView has a known bug: `AnalyserNode.getByteFrequencyData()` returns all-zero or garbage data
/// when the source is a `getUserMedia` stream. This makes Web Audio API unusable for real-time
/// microphone analysis inside any Capacitor (or Cordova) iOS app.
///
/// # Solution
/// This plugin bypasses the Web Audio API entirely. It uses `AVAudioEngine` to install a tap
/// directly on the input node, computes RMS energy and a breath-band energy estimate in native Swift,
/// and pushes results to JavaScript via Capacitor's `notifyListeners` mechanism.
///
/// # Events
/// Emits `audioData` events with `rms`, `rawRms`, `bandEnergy`, and `sampleRate` fields.
@objc(AudioAnalysisPlugin)
public class AudioAnalysisPlugin: CAPPlugin, CAPBridgedPlugin {

    /// The plugin identifier used internally by Capacitor.
    public let identifier = "AudioAnalysisPlugin"

    /// The JavaScript bridge name. Access via `AudioAnalysis` in TypeScript.
    public let jsName = "AudioAnalysis"

    /// Exposed plugin methods.
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isCapturing", returnType: CAPPluginReturnPromise)
    ]

    // MARK: - Private state

    private var audioEngine: AVAudioEngine?
    private var isRunning = false

    /// Exponentially smoothed RMS. Updated on every audio buffer.
    private var smoothedRMS: Float = 0.0

    /// Smoothing factor α for the EMA: output = (1−α)·prev + α·current.
    /// Lower values = more smoothing (slower response).
    private let smoothingAlpha: Float = 0.3

    // MARK: - Plugin methods

    /// Start audio capture and analysis.
    ///
    /// Accepts optional call options:
    /// - `gain` (Double, default 8.0): software gain multiplier applied before RMS computation.
    /// - `bufferSize` (Int, default 4096): AVAudioEngine tap buffer size in frames.
    /// - `sampleRate` (Double, default from hardware): not currently used to override hardware rate;
    ///   reported in emitted events for informational purposes.
    @objc func start(_ call: CAPPluginCall) {
        if isRunning {
            call.resolve(["started": true])
            return
        }

        // Read configurable options
        let softwareGain = Float(call.getFloat("gain") ?? 8.0)
        let bufferSize = AVAudioFrameCount(call.getInt("bufferSize") ?? 4096)

        // Configure audio session.
        // Use .default mode (not .measurement) to keep automatic gain control enabled —
        // .measurement mode disables AGC and produces a very quiet signal for normal use.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try session.setActive(true)
        } catch {
            call.reject("Audio session error: \(error.localizedDescription)")
            return
        }

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            call.reject("Could not create audio engine")
            return
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate

        /// Install a tap on the input node. The closure is called on a background audio thread.
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isRunning else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            // Step 1: Compute RMS with software gain applied.
            var sumSquares: Float = 0.0
            for i in 0..<frameLength {
                let sample = channelData[i] * softwareGain
                sumSquares += sample * sample
            }
            let rawRms = sqrtf(sumSquares / Float(frameLength))

            // Step 2: Compute breath-band energy approximation (150–2500 Hz).
            // A full FFT is more accurate but overkill for breath/biofeedback detection.
            // We use mean absolute value as a lightweight proxy for band energy.
            var absSum: Float = 0.0
            for i in 0..<frameLength {
                absSum += abs(channelData[i])
            }
            let bandEnergy = absSum / max(Float(frameLength), 1.0)

            // Step 3: Apply exponential moving average smoothing to RMS.
            self.smoothedRMS = self.smoothedRMS * (1.0 - self.smoothingAlpha) + rawRms * self.smoothingAlpha

            // Step 4: Emit event to JavaScript.
            self.notifyListeners("audioData", data: [
                "rms": self.smoothedRMS,
                "rawRms": rawRms,
                "bandEnergy": bandEnergy,
                "sampleRate": sampleRate
            ])
        }

        do {
            try engine.start()
            isRunning = true
            call.resolve(["started": true])
        } catch {
            call.reject("Engine start error: \(error.localizedDescription)")
        }
    }

    /// Stop audio capture and release all audio resources.
    @objc func stop(_ call: CAPPluginCall) {
        stopCapture()
        call.resolve(["stopped": true])
    }

    /// Returns whether audio capture is currently active.
    @objc func isCapturing(_ call: CAPPluginCall) {
        call.resolve(["capturing": isRunning])
    }

    // MARK: - Private helpers

    /// Tear down the audio engine and reset state.
    private func stopCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRunning = false
        smoothedRMS = 0.0
    }

    deinit {
        stopCapture()
    }
}
