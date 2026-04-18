import type { PluginListenerHandle } from '@capacitor/core';

/**
 * Options for starting audio capture.
 */
export interface AudioAnalysisOptions {
  /**
   * Target sample rate in Hz.
   * The actual rate is determined by the hardware; this is passed as a hint.
   * Default: 44100
   */
  sampleRate?: number;

  /**
   * Audio buffer size in frames used for each analysis window.
   * Larger values give more frequency resolution but higher latency.
   * Default: 4096
   */
  bufferSize?: number;

  /**
   * Software gain multiplier applied to raw microphone samples before RMS computation.
   * Increase to amplify quiet signals (e.g. breath). Values above 20 may saturate.
   * Default: 8.0
   */
  gain?: number;
}

/**
 * Audio analysis data emitted on each buffer.
 * Sent via the 'audioData' event roughly every bufferSize/sampleRate seconds.
 */
export interface AudioData {
  /**
   * Exponentially smoothed RMS energy in [0, 1] range (with gain applied).
   * Use this as the primary signal for breath/volume detection.
   */
  rms: number;

  /**
   * Unsmoothed RMS of the current buffer (with gain applied).
   * Useful for detecting sharp transients.
   */
  rawRms: number;

  /**
   * Energy in the breath frequency band (~150–2500 Hz) computed via FFT.
   * Scaled roughly in the same range as `rawRms` for comparability.
   */
  bandEnergy: number;

  /**
   * Spectral centroid in Hz — the energy-weighted centre frequency of the signal
   * within the 80–4000 Hz search band. Use to distinguish breath (typ. 200–800 Hz)
   * from traffic/rumble (<150 Hz) and sibilant/metallic noise (>2000 Hz).
   *
   * Returns 0 when the spectrum is effectively silent (no meaningful centroid).
   */
  centroid: number;

  /**
   * Actual hardware sample rate in Hz (e.g. 44100 or 48000).
   */
  sampleRate: number;
}

/**
 * @capacitor/plugin-audio-analysis
 *
 * Native audio analysis plugin for Capacitor iOS.
 *
 * On iOS, this plugin uses AVAudioEngine to capture microphone data and compute
 * real-time RMS and frequency energy, bypassing the WKWebView Web Audio API bug
 * where AnalyserNode returns garbage data on getUserMedia streams.
 *
 * On web (Chrome/Edge), it falls back to the standard getUserMedia + Web Audio API.
 */
export interface AudioAnalysisPlugin {
  /**
   * Start audio capture and analysis.
   * Requests microphone permission if not already granted.
   * Emits 'audioData' events on each processed buffer.
   *
   * @param options - Optional configuration for gain, buffer size, and sample rate.
   * @returns Promise resolving to `{ started: true }` once the engine is running.
   */
  start(options?: AudioAnalysisOptions): Promise<{ started: boolean }>;

  /**
   * Stop audio capture and tear down the audio engine.
   *
   * @returns Promise resolving to `{ stopped: true }`.
   */
  stop(): Promise<{ stopped: boolean }>;

  /**
   * Query whether audio capture is currently active.
   *
   * @returns Promise resolving to `{ capturing: boolean }`.
   */
  isCapturing(): Promise<{ capturing: boolean }>;

  /**
   * Register a listener for real-time audio data events.
   *
   * @param eventName - Must be 'audioData'.
   * @param listenerFunc - Callback receiving an AudioData object on each buffer.
   * @returns A PluginListenerHandle with a `remove()` method to unsubscribe.
   *
   * @example
   * const handle = await AudioAnalysis.addListener('audioData', (data) => {
   *   console.log('RMS:', data.rms, 'Band energy:', data.bandEnergy, 'Centroid:', data.centroid);
   * });
   * // Later:
   * handle.remove();
   */
  addListener(
    eventName: 'audioData',
    listenerFunc: (data: AudioData) => void,
  ): Promise<PluginListenerHandle>;
}
