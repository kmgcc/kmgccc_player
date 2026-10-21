// AudioWorklet wrapper around the shared engine. Output 0 is the stereo
// program; output 1 is the harmonic bus (mono) for the spectrum view.

import { VirtualBassEngine, DEFAULTS } from './dsp/engine.js';

class VirtualBassProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.engine = new VirtualBassEngine(sampleRate, { ...DEFAULTS });
    this.meterEvery = Math.round(sampleRate * 0.05);
    this.sinceMeter = 0;
    this.capture = null;
    this.port.onmessage = (e) => {
      const m = e.data;
      if (m.type === 'params') {
        this.engine.setParams(m.params);
        this.port.postMessage({ type: 'info', info: this.engine.info() });
      }
    };
    this.port.postMessage({ type: 'info', info: this.engine.info() });
  }

  process(inputs, outputs) {
    const input = inputs[0];
    const out = outputs[0];
    const harm = outputs[1] && outputs[1][0];
    const n = out[0].length;
    const inL = input && input[0] ? input[0] : new Float32Array(n);
    const inR = input && input[1] ? input[1] : inL;
    if (harm) {
      if (!this.capture) this.capture = { harm, gain: new Float32Array(n), i: 0 };
      this.capture.harm = harm;
      this.capture.i = 0;
      this.engine.capture = this.capture;
    }
    this.engine.process(inL, inR, out[0], out[1] || out[0], n);
    this.sinceMeter += n;
    if (this.sinceMeter >= this.meterEvery) {
      this.sinceMeter = 0;
      this.port.postMessage({ type: 'meters', meters: this.engine.readMeters() });
    }
    return true;
  }
}

registerProcessor('virtual-bass', VirtualBassProcessor);
