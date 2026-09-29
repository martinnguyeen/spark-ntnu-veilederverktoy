class SparkCapture extends AudioWorkletProcessor {
  constructor() {
    super(); this.samples = new Float32Array(16000 * 15); this.used = 0;
    this.port.onmessage = e => { if (e.data === 'flush') { this.flush(); this.port.postMessage({ flushed: true }); } };
  }
  flush() { if (this.used) { const data = this.samples.slice(0, this.used); this.port.postMessage({ samples: data }, [data.buffer]); this.used = 0; } }
  process(inputs) {
    const channels = inputs[0]; if (!channels?.length) return true;
    for (let i = 0; i < channels[0].length; i++) {
      let sample = 0; for (const channel of channels) sample += channel[i] / channels.length;
      this.samples[this.used++] = sample;
      if (this.used === this.samples.length) this.flush();
    }
    return true;
  }
}
registerProcessor('spark-capture', SparkCapture);
