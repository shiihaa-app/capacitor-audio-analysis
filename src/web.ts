import { WebPlugin } from '@capacitor/core';
import type { AudioAnalysisOptions, AudioAnalysisPlugin, AudioData } from './definitions';

/**
 * Web implementation of AudioAnalysisPlugin.
 *
 * Uses the standard getUserMedia + Web Audio API (AnalyserNode).
 * This works correctly in Chrome, Firefox, and Edge but NOT in WKWebView on iOS —
 * which is the exact reason the native iOS implementation exists.
 *
 * Use this implementation for browser-based development and testing only.
 */
export class AudioAnalysisWeb extends WebPlugin implements AudioAnalysisPlugin {
  private audioContext: AudioContext | null = null;
  private analyser: AnalyserNode | null = null;
  private mediaStream: MediaStream | null = null;
  private source: MediaStreamAudioSourceNode | null = null;
  private animationFrameId: number | null = null;
  private _isCapturing = false;

  async start(options?: AudioAnalysisOptions): Promise<{ started: boolean }> {
    if (this._isCapturing) {
      return { started: true };
    }

    const gain = options?.gain ?? 8.0;
    const bufferSize = options?.bufferSize ?? 4096;

    // Request microphone access
    this.mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });

    // Create audio context at the requested (or default) sample rate
    this.audioContext = new AudioContext({
      sampleRate: options?.sampleRate ?? 44100,
    });

    this.analyser = this.audioContext.createAnalyser();
    this.analyser.fftSize = bufferSize;
    this.analyser.smoothingTimeConstant = 0.7; // matches smoothingAlpha in native

    // Apply software gain to match the native plugin behaviour
    const gainNode = this.audioContext.createGain();
    gainNode.gain.value = gain;

    this.source = this.audioContext.createMediaStreamSource(this.mediaStream);
    this.source.connect(gainNode);
    gainNode.connect(this.analyser);

    const actualSampleRate = this.audioContext.sampleRate;
    const dataArray = new Float32Array(this.analyser.fftSize);

    this._isCapturing = true;

    const tick = () => {
      if (!this._isCapturing || !this.analyser) return;

      this.analyser.getFloatTimeDomainData(dataArray);

      // Raw RMS
      let sumSquares = 0;
      for (let i = 0; i < dataArray.length; i++) {
        sumSquares += dataArray[i] * dataArray[i];
      }
      const rawRms = Math.sqrt(sumSquares / dataArray.length);

      // Smoothed RMS (the analyser's smoothingTimeConstant approximates native smoothing)
      const rms = rawRms; // already smoothed via analyser; expose rawRms separately

      // Band energy approximation (mean absolute value — mirrors native implementation)
      let absSum = 0;
      for (let i = 0; i < dataArray.length; i++) {
        absSum += Math.abs(dataArray[i]);
      }
      const bandEnergy = absSum / dataArray.length;

      const data: AudioData = {
        rms,
        rawRms,
        bandEnergy,
        sampleRate: actualSampleRate,
      };

      this.notifyListeners('audioData', data);

      this.animationFrameId = requestAnimationFrame(tick);
    };

    this.animationFrameId = requestAnimationFrame(tick);

    return { started: true };
  }

  async stop(): Promise<{ stopped: boolean }> {
    this._isCapturing = false;

    if (this.animationFrameId !== null) {
      cancelAnimationFrame(this.animationFrameId);
      this.animationFrameId = null;
    }

    this.source?.disconnect();
    this.source = null;

    this.analyser?.disconnect();
    this.analyser = null;

    if (this.audioContext) {
      await this.audioContext.close();
      this.audioContext = null;
    }

    this.mediaStream?.getTracks().forEach((track) => track.stop());
    this.mediaStream = null;

    return { stopped: true };
  }

  async isCapturing(): Promise<{ capturing: boolean }> {
    return { capturing: this._isCapturing };
  }
}
