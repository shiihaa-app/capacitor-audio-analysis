import Foundation
import Capacitor
import AVFoundation
import Accelerate

/// Native audio analysis plugin for Capacitor iOS.
///
/// # Why this exists
/// WKWebView has a known bug: `AnalyserNode.getByteFrequencyData()` returns all-zero or garbage data
/// when the source is a `getUserMedia` stream. This makes Web Audio API unusable for real-time
/// microphone analysis inside any Capacitor (or Cordova) iOS app.
///
/// # Solution
/// This plugin bypasses the Web Audio API entirely. It uses `AVAudioEngine` to install a tap
/// directly on the input node, runs a Hann-windowed FFT via Accelerate's vDSP, and computes
/// RMS energy, breath-band energy, and spectral centroid in native Swift.
///
/// # Events
/// Emits `audioData` events with `rms`, `rawRms`, `bandEnergy`, `centroid`, and `sampleRate` fields.
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

    // MARK: - FFT state (reused across buffers)

    /// FFT length (power of two). 2048 → ~23 Hz bin resolution at 48 kHz — ample for breath VAD.
    private let fftSize: Int = 2048
    private var fftLog2n: vDSP_Length = 11   // log2(2048)
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float] = []

    // Scratch buffers (allocated once in `start`, reused in the audio thread).
    private var windowed: [Float] = []
    private var realp: [Float] = []
    private var imagp: [Float] = []
    private var magSquared: [Float] = []

    // Breath-band bin indices, computed once sample rate is known.
    private var bandStartBin: Int = 0
    private var bandEndBin: Int = 0

    // Centroid search range bin indices (80–4000 Hz — excludes DC/rumble and sibilant hiss).
    private var centroidStartBin: Int = 0
    private var centroidEndBin: Int = 0

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

        // Initialise FFT infrastructure once per capture session.
        setupFFT(sampleRate: sampleRate)

        // Local captures for the audio thread (no self-references past the weak self).
        let fftSize = self.fftSize
        let bandStartBin = self.bandStartBin
        let bandEndBin = self.bandEndBin
        let centroidStartBin = self.centroidStartBin
        let centroidEndBin = self.centroidEndBin
        let nyquist = Float(sampleRate * 0.5)
        let binWidth = Float(sampleRate) / Float(fftSize)

        /// Install a tap on the input node. The closure is called on a background audio thread.
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isRunning else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            // ── Step 1: RMS over the full tap buffer (with software gain). ────────────────
            var sumSquares: Float = 0.0
            for i in 0..<frameLength {
                let sample = channelData[i] * softwareGain
                sumSquares += sample * sample
            }
            let rawRms = sqrtf(sumSquares / Float(max(frameLength, 1)))

            // ── Step 2: Copy up to fftSize samples, apply Hann window. ────────────────────
            // If the buffer is smaller than fftSize we zero-pad (rare — tapBufferSize is 4096).
            let copyCount = min(frameLength, fftSize)
            if copyCount < fftSize {
                // Zero-fill tail
                for i in copyCount..<fftSize { self.windowed[i] = 0 }
            }
            vDSP_vmul(channelData, 1, self.hannWindow, 1, &self.windowed, 1, vDSP_Length(copyCount))

            // ── Step 3: Real FFT via vDSP. ────────────────────────────────────────────────
            guard let fftSetup = self.fftSetup else { return }

            // Pack interleaved real array into split-complex form
            self.windowed.withUnsafeBufferPointer { winPtr in
                winPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                    var split = DSPSplitComplex(realp: &self.realp, imagp: &self.imagp)
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))

                    // Forward FFT
                    vDSP_fft_zrip(fftSetup, &split, 1, self.fftLog2n, FFTDirection(FFT_FORWARD))

                    // Magnitude squared per bin (skip unpacking scale — we only need relative weights)
                    vDSP_zvmags(&split, 1, &self.magSquared, 1, vDSP_Length(fftSize / 2))
                }
            }

            // ── Step 4: Breath-band energy (150–2500 Hz) from FFT magnitudes. ─────────────
            var bandSum: Float = 0
            if bandEndBin > bandStartBin {
                vDSP_sve(&self.magSquared[bandStartBin], 1, &bandSum, vDSP_Length(bandEndBin - bandStartBin))
            }
            // Normalise: sqrt of mean power → amplitude-like scale, comparable to rawRms.
            let bandCount = Float(max(bandEndBin - bandStartBin, 1))
            let bandEnergy = sqrtf(bandSum / bandCount) / Float(fftSize)

            // ── Step 5: Spectral centroid over 80–4000 Hz. ────────────────────────────────
            var numerator: Float = 0
            var denominator: Float = 0
            for bin in centroidStartBin..<centroidEndBin {
                let power = self.magSquared[bin]
                let freq = Float(bin) * binWidth
                numerator += freq * power
                denominator += power
            }
            // If the spectrum is essentially silent in the search band, report 0 — JS side treats
            // 0 as "no meaningful centroid, don't trust this frame".
            let centroid: Float = denominator > 1e-9 ? min(numerator / denominator, nyquist) : 0.0

            // ── Step 6: Smoothed RMS (EMA). ───────────────────────────────────────────────
            self.smoothedRMS = self.smoothedRMS * (1.0 - self.smoothingAlpha) + rawRms * self.smoothingAlpha

            // ── Step 7: Emit event to JavaScript. ─────────────────────────────────────────
            self.notifyListeners("audioData", data: [
                "rms": self.smoothedRMS,
                "rawRms": rawRms,
                "bandEnergy": bandEnergy,
                "centroid": centroid,
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

    /// Allocate FFT setup, window, and scratch buffers. Called once per `start`.
    private func setupFFT(sampleRate: Double) {
        // FFTSetup is tied to log2(n); recreate if size ever changes (currently fixed).
        if fftSetup == nil {
            fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))
        }

        // Hann window, length fftSize
        hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Scratch
        windowed = [Float](repeating: 0, count: fftSize)
        realp = [Float](repeating: 0, count: fftSize / 2)
        imagp = [Float](repeating: 0, count: fftSize / 2)
        magSquared = [Float](repeating: 0, count: fftSize / 2)

        // Precompute bin ranges (bin k → frequency k * sampleRate / fftSize).
        let binWidth = sampleRate / Double(fftSize)
        let nyquistBin = fftSize / 2

        // Breath band: 150–2500 Hz
        bandStartBin = max(1, Int((150.0 / binWidth).rounded()))
        bandEndBin = min(nyquistBin, Int((2500.0 / binWidth).rounded()))

        // Centroid search: 80–4000 Hz (excludes DC/rumble and sibilant hiss > 4 kHz).
        centroidStartBin = max(1, Int((80.0 / binWidth).rounded()))
        centroidEndBin = min(nyquistBin, Int((4000.0 / binWidth).rounded()))
    }

    /// Tear down the audio engine and reset state.
    private func stopCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRunning = false
        smoothedRMS = 0.0

        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
            fftSetup = nil
        }
        hannWindow.removeAll(keepingCapacity: false)
        windowed.removeAll(keepingCapacity: false)
        realp.removeAll(keepingCapacity: false)
        imagp.removeAll(keepingCapacity: false)
        magSquared.removeAll(keepingCapacity: false)
    }

    deinit {
        stopCapture()
    }
}
