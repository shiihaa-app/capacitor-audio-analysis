import { registerPlugin } from '@capacitor/core';
import type { AudioAnalysisPlugin } from './definitions';

/**
 * The AudioAnalysis plugin instance.
 *
 * On iOS (inside WKWebView/Capacitor), this resolves to the native Swift plugin
 * backed by AVAudioEngine. On web browsers, it falls back to the Web Audio API
 * implementation (getUserMedia + AnalyserNode).
 *
 * @example
 * import { AudioAnalysis } from '@shiihaa/capacitor-audio-analysis';
 *
 * await AudioAnalysis.start({ gain: 8.0, bufferSize: 4096 });
 *
 * const handle = await AudioAnalysis.addListener('audioData', (data) => {
 *   console.log('rms:', data.rms);
 * });
 *
 * // Later:
 * await AudioAnalysis.stop();
 * handle.remove();
 */
const AudioAnalysis = registerPlugin<AudioAnalysisPlugin>('AudioAnalysis', {
  web: () => import('./web').then((m) => new m.AudioAnalysisWeb()),
});

export * from './definitions';
export { AudioAnalysis };
