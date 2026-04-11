# @shiihaa/capacitor-audio-analysis

![Used in production by shii·haa](https://img.shields.io/badge/used%20in%20production-shii%C2%B7haa-01696F?style=flat-square)
![npm](https://img.shields.io/npm/v/@shiihaa/capacitor-audio-analysis?style=flat-square)
![license](https://img.shields.io/npm/l/@shiihaa/capacitor-audio-analysis?style=flat-square)
![platform](https://img.shields.io/badge/platform-iOS%20%7C%20Web-lightgrey?style=flat-square)

Native audio analysis for Capacitor iOS — bypasses the broken WKWebView Web Audio API. Real-time RMS and frequency energy from the device microphone via AVAudioEngine.

---

## The Problem

WKWebView has a well-known bug: `AnalyserNode.getByteFrequencyData()` and `getFloatFrequencyData()` return **all-zero or garbage data** when the audio source is a `getUserMedia` stream. This affects every Capacitor and Cordova iOS app.

The following code works perfectly in Chrome and Safari desktop, but silently fails inside WKWebView (the runtime used by all iOS apps including Capacitor):

```typescript
// ❌ Broken on iOS WKWebView
const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
const ctx = new AudioContext();
const source = ctx.createMediaStreamSource(stream);
const analyser = ctx.createAnalyser();
source.connect(analyser);

const data = new Uint8Array(analyser.frequencyBinCount);
analyser.getByteFrequencyData(data);
// data is all zeros — even when the mic is picking up sound
console.log(data); // [0, 0, 0, 0, 0, ...]
```

This bug has been [reported to WebKit](https://bugs.webkit.org/show_bug.cgi?id=230902) and affects all iOS versions through at least iOS 18. There is no pure JavaScript workaround.

---

## The Solution

This plugin bypasses the Web Audio API entirely by using **AVAudioEngine** natively. Audio buffers are processed in Swift and only the computed metrics (RMS, band energy) are sent to JavaScript as Capacitor events.

```
Microphone
    │
    ▼
AVAudioEngine.inputNode
    │  (installTap — native audio thread)
    ▼
Buffer processing (Swift)
  ├─ Apply software gain
  ├─ Compute raw RMS
  ├─ Apply EMA smoothing → smoothedRMS
  └─ Compute mean absolute value (band energy proxy)
    │
    ▼
notifyListeners("audioData", { rms, rawRms, bandEnergy, sampleRate })
    │
    ▼
JavaScript addListener('audioData', callback)
```

---

## Comparison

| Feature | `getUserMedia` + AnalyserNode | This plugin |
|---|---|---|
| Works in Chrome / Edge | ✅ | ✅ (web fallback) |
| Works in WKWebView (iOS) | ❌ Returns zeros | ✅ Native AVAudioEngine |
| Real-time RMS energy | ❌ | ✅ |
| Breath frequency band energy | ❌ | ✅ |
| Smoothed output | ❌ | ✅ EMA smoothing |
| Configurable gain | ❌ | ✅ |
| Capacitor permission handling | ❌ | ✅ |

---

## Installation

```bash
npm install @shiihaa/capacitor-audio-analysis
npx cap sync
```

### iOS setup

Add the `NSMicrophoneUsageDescription` key to your app's `ios/App/App/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to analyze breathing patterns.</string>
```

The plugin will request microphone permission automatically when `start()` is first called. No additional code is needed.

---

## Usage

```typescript
import { AudioAnalysis } from '@shiihaa/capacitor-audio-analysis';

// Start capture
await AudioAnalysis.start({
  gain: 8.0,       // amplify quiet mic signals (default: 8.0)
  bufferSize: 4096, // frames per analysis window (default: 4096)
});

// Listen for real-time data (~every 93ms at 44100Hz with bufferSize 4096)
const handle = await AudioAnalysis.addListener('audioData', (data) => {
  console.log('RMS:', data.rms);           // smoothed 0–1
  console.log('Raw RMS:', data.rawRms);    // unsmoothed 0–1
  console.log('Band energy:', data.bandEnergy); // breath band proxy
  console.log('Sample rate:', data.sampleRate); // e.g. 44100
});

// Check if currently capturing
const { capturing } = await AudioAnalysis.isCapturing();
console.log('Capturing:', capturing);

// Stop capture and clean up
await AudioAnalysis.stop();
handle.remove();
```

### React / Vue integration example

```typescript
import { useEffect, useRef } from 'react';
import { AudioAnalysis } from '@shiihaa/capacitor-audio-analysis';
import type { PluginListenerHandle } from '@capacitor/core';

function useAudioAnalysis(active: boolean) {
  const handleRef = useRef<PluginListenerHandle | null>(null);

  useEffect(() => {
    if (!active) {
      AudioAnalysis.stop();
      handleRef.current?.remove();
      return;
    }

    (async () => {
      handleRef.current = await AudioAnalysis.addListener('audioData', (data) => {
        // Update your state / visualisation here
        console.log('rms:', data.rms);
      });
      await AudioAnalysis.start({ gain: 8.0 });
    })();

    return () => {
      AudioAnalysis.stop();
      handleRef.current?.remove();
    };
  }, [active]);
}
```

---

## API Reference

### `start(options?)`

Start audio capture and begin emitting `audioData` events.

**Options** (`AudioAnalysisOptions`):

| Option | Type | Default | Description |
|---|---|---|---|
| `gain` | `number` | `8.0` | Software gain multiplier applied before RMS computation. Increase for quiet environments. Values above 20 may saturate. |
| `bufferSize` | `number` | `4096` | Buffer size in audio frames. Controls the analysis window (~93ms at 44100Hz). |
| `sampleRate` | `number` | hardware default | Target sample rate hint. The actual rate is determined by the hardware. |

**Returns:** `Promise<{ started: boolean }>`

---

### `stop()`

Stop audio capture and release all audio resources (engine, tap, session).

**Returns:** `Promise<{ stopped: boolean }>`

---

### `isCapturing()`

Returns whether audio capture is currently active.

**Returns:** `Promise<{ capturing: boolean }>`

---

### `addListener('audioData', callback)`

Register a listener for audio data events. Called on every processed buffer.

**Callback receives** (`AudioData`):

| Field | Type | Description |
|---|---|---|
| `rms` | `number` | Exponentially smoothed RMS energy, 0–1 (with gain applied). Primary signal for breath/volume detection. |
| `rawRms` | `number` | Unsmoothed RMS of the current buffer (with gain applied). Use for transient detection. |
| `bandEnergy` | `number` | Mean absolute amplitude — a lightweight proxy for energy in the breath frequency band (~150–2500 Hz). |
| `sampleRate` | `number` | Actual hardware sample rate in Hz (e.g. 44100 or 48000). |

**Returns:** `Promise<PluginListenerHandle>`

Call `handle.remove()` to unsubscribe.

---

## How It Works

### Native iOS (AVAudioEngine)

1. **Session setup** — `AVAudioSession` is configured with `.playAndRecord` category and `.default` mode. The `.default` mode preserves automatic gain control; `.measurement` mode (which disables AGC) produces an unusably quiet signal for normal microphone input.
2. **Engine tap** — `installTap(onBus:bufferSize:format:)` registers a closure that is called on a background audio thread with each new buffer.
3. **RMS computation** — Each sample is multiplied by the configured gain, then root-mean-square is computed across the buffer.
4. **Band energy** — Mean absolute value is computed as a lightweight proxy for breath-frequency content. Sufficient for breath detection without the overhead of a full FFT.
5. **EMA smoothing** — `smoothedRMS = (1 − α) × prev + α × rawRms` with α = 0.3.
6. **Event dispatch** — `notifyListeners("audioData", data)` sends the result dictionary to all registered JavaScript listeners via the Capacitor bridge.

### Web fallback (getUserMedia + Web Audio API)

The web implementation uses `getUserMedia` + `AnalyserNode`. It works correctly in Chrome, Firefox, and Edge. It does **not** work in WKWebView — which is exactly why the native plugin exists.

The web fallback is provided so you can develop and test in a browser without an iOS device.

---

## Credits

Built by [shii·haa](https://shiihaa.app) — a breathwork and biofeedback app.

The plugin was created to solve a real production problem: iOS WKWebView's broken AnalyserNode made it impossible to do real-time breath detection using the Web Audio API. AVAudioEngine provides the reliability and latency characteristics required for live biofeedback.

![Used in production by shii·haa](https://img.shields.io/badge/used%20in%20production-shii%C2%B7haa-01696F?style=flat-square)

---

## License

MIT © [Felix Zeller](mailto:felix@shiihaa.app)
