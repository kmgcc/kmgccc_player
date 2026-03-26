// PV Embed Core - Beat Provider
// 简化版节拍系统，支持手动BPM和外部驱动

export class BeatProvider {
  private _bpm = 120;
  private _isPlaying = false;
  private _startTime = 0;
  private _pauseTime = 0;
  private _offset = 0;
  private _audioContext: AudioContext | null = null;
  private _analyser: AnalyserNode | null = null;
  private _sourceNode: MediaElementAudioSourceNode | null = null;
  private _audioElement: HTMLAudioElement | null = null;
  private _isAudioMode = false;
  private _currentTime = 0;
  private _duration = 0;
  
  // 节拍检测参数
  private lastBeatTime = 0;
  private beatEnergyThreshold = 0.15;
  private decayFactor = 0.95;
  private energyBuffer = 0;
  
  set bpm(val: number) {
    this._bpm = Math.max(30, Math.min(300, val));
  }
  
  get bpm(): number {
    return this._bpm;
  }
  
  get isAudioMode(): boolean {
    return this._isAudioMode;
  }
  
  get currentTime(): number {
    if (this._isAudioMode && this._audioElement) {
      return this._audioElement.currentTime;
    }
    if (!this._isPlaying) return this._pauseTime;
    return (performance.now() - this._startTime) / 1000 + this._offset;
  }
  
  get duration(): number {
    return this._duration;
  }
  
  get paused(): boolean {
    return !this._isPlaying;
  }
  
  play() {
    if (this._isPlaying) return;
    this._startTime = performance.now();
    this._isPlaying = true;
    
    if (this._audioElement && this._audioElement.paused) {
      this._audioElement.play().catch(() => {});
    }
  }
  
  pause() {
    if (!this._isPlaying) return;
    this._pauseTime = this.currentTime;
    this._isPlaying = false;
    
    if (this._audioElement && !this._audioElement.paused) {
      this._audioElement.pause();
    }
  }
  
  seek(time: number) {
    const t = Math.max(0, time);
    if (this._isAudioMode && this._audioElement) {
      this._audioElement.currentTime = t;
    } else {
      this._offset = t;
      this._startTime = performance.now();
      this._pauseTime = t;
    }
  }
  
  // 加载音频文件（可选，用于音频分析）
  async loadAudio(file: File): Promise<void> {
    const url = URL.createObjectURL(file);
    
    if (!this._audioElement) {
      this._audioElement = new Audio();
      this._audioElement.crossOrigin = 'anonymous';
    }
    
    this._audioElement.src = url;
    await this._audioElement.play();
    
    // 设置音频分析
    if (!this._audioContext) {
      this._audioContext = new AudioContext();
    }
    
    if (!this._analyser) {
      this._analyser = this._audioContext.createAnalyser();
      this._analyser.fftSize = 256;
    }
    
    if (this._sourceNode) {
      this._sourceNode.disconnect();
    }
    
    this._sourceNode = this._audioContext.createMediaElementSource(this._audioElement);
    this._sourceNode.connect(this._analyser);
    this._analyser.connect(this._audioContext.destination);
    
    this._isAudioMode = true;
    this._duration = this._audioElement.duration || 0;
    this._isPlaying = true;
    
    // 清理
    this._audioElement.addEventListener('ended', () => {
      URL.revokeObjectURL(url);
    }, { once: true });
  }
  
  // 获取节拍强度（0-1）
  getIntensity(time: number): number {
    if (this._isAudioMode && this._analyser) {
      return this.getAudioIntensity();
    }
    return this.getSimulatedIntensity(time);
  }
  
  private getAudioIntensity(): number {
    if (!this._analyser) return 0;
    
    const dataArray = new Uint8Array(this._analyser.frequencyBinCount);
    this._analyser.getByteFrequencyData(dataArray);
    
    // 计算低频能量
    let bassEnergy = 0;
    const bassRange = Math.floor(dataArray.length * 0.15);
    for (let i = 0; i < bassRange; i++) {
      bassEnergy += dataArray[i];
    }
    bassEnergy /= bassRange * 255;
    
    // 峰值检测
    this.energyBuffer = Math.max(bassEnergy, this.energyBuffer * this.decayFactor);
    
    if (bassEnergy > this.energyBuffer * 1.15 && bassEnergy > this.beatEnergyThreshold) {
      this.lastBeatTime = performance.now();
      return Math.min(1, bassEnergy * 1.5);
    }
    
    return this.energyBuffer * 0.5;
  }
  
  private getSimulatedIntensity(time: number): number {
    // 基于BPM的模拟节拍
    const beatDuration = 60 / this._bpm;
    const beatPhase = (time % beatDuration) / beatDuration;
    
    // 简单的冲击曲线
    if (beatPhase < 0.1) {
      return 1 - (beatPhase / 0.1);
    }
    return 0;
  }
}
