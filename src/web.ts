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
    const timeDomain = new Float32Array(this.analyser.fftSize);
    const freqBinCount = this.analyser.frequencyBinCount;
    const freqDomain = new Float32Array(freqBinCount); // dB values
    const binWidth = actualSampleRate / this.analyser.fftSize;

    // Precompute band/centroid bin ranges — mirror native implementation.
    const bandStartBin = Math.max(1, Math.round(150 / binWidth));
    const bandEndBin = Math.min(freqBinCount, Math.round(2500 / binWidth));
    const centroidStartBin = Math.max(1, Math.round(80 / binWidth));
    const centroidEndBin = Math.min(freqBinCount, Math.round(4000 / binWidth));

    this._isCapturing = true;

    const tick = () => {
      if (!this._isCapturing || !this.analyser) return;

      // Time-domain → RMS
      this.analyser.getFloatTimeDomainData(timeDomain);
      let sumSquares = 0;
      for (let i = 0; i < timeDomain.length; i++) {
        sumSquares += timeDomain[i] * timeDomain[i];
      }
      const rawRms = Math.sqrt(sumSquares / timeDomain.length);
      const rms = rawRms; // already smoothed via analyser; expose rawRms separately

      // Frequency-domain (dB, range approx −100…0) → linear power for centroid + band energy
      this.analyser.getFloatFrequencyData(freqDomain);

      let bandPowerSum = 0;
      for (let bin = bandStartBin; bin < bandEndBin; bin++) {
        bandPowerSum += Math.pow(10, freqDomain[bin] / 10);
      }
      const bandEnergy = Math.sqrt(bandPowerSum / Math.max(bandEndBin - bandStartBin, 1));

      let num = 0;
      let den = 0;
      for (let bin = centroidStartBin; bin < centroidEndBin; bin++) {
        const power = Math.pow(10, freqDomain[bin] / 10);
        num += bin * binWidth * power;
        den += power;
      }
      const centroid = den > 1e-9 ? Math.min(num / den, actualSampleRate / 2) : 0;

      const data: AudioData = {
        rms,
        rawRms,
        bandEnergy,
        centroid,
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
