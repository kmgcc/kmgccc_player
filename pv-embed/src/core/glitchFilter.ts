// PV Embed Core - Glitch Filter
// 简化的故障效果滤镜

import * as PIXI from 'pixi.js';

const GLITCH_FRAGMENT = `
  precision highp float;
  varying vec2 vTextureCoord;
  uniform sampler2D uTexture;
  uniform float uTime;
  uniform float uIntensity;
  uniform vec2 uResolution;
  
  float rand(vec2 co) {
    return fract(sin(dot(co.xy, vec2(12.9898, 78.233))) * 43758.5453);
  }
  
  void main(void) {
    vec2 uv = vTextureCoord;
    vec4 color = texture2D(uTexture, uv);
    
    if (uIntensity <= 0.0) {
      gl_FragColor = color;
      return;
    }
    
    float intensity = uIntensity * 0.5;
    
    // 随机位移
    float noise = rand(vec2(floor(uv.y * 50.0), uTime * 10.0));
    if (noise > 0.85) {
      float shift = (rand(vec2(uTime)) - 0.5) * intensity * 0.3;
      uv.x += shift;
    }
    
    // RGB分离
    float rgbShift = intensity * 0.02;
    float r = texture2D(uTexture, uv + vec2(rgbShift, 0.0)).r;
    float g = texture2D(uTexture, uv).g;
    float b = texture2D(uTexture, uv - vec2(rgbShift, 0.0)).b;
    
    // 扫描线
    float scanline = sin(uv.y * 400.0 + uTime * 5.0) * 0.5 + 0.5;
    scanline = mix(1.0, scanline, intensity * 0.3);
    
    gl_FragColor = vec4(r, g, b, color.a) * scanline;
  }
`;

export class GlitchFilter extends PIXI.Filter {
  private _time = 0;
  private _intensity = 0;
  
  constructor() {
    super({
      gl: {
        fragment: GLITCH_FRAGMENT,
        vertex: PIXI.Filter.defaultVertexShader
      },
      resources: {
        glitchUniforms: {
          uTime: { value: 0, type: 'f32' },
          uIntensity: { value: 0, type: 'f32' },
          uResolution: { value: [1, 1], type: 'vec2<f32>' }
        }
      }
    });
  }
  
  set time(value: number) {
    this._time = value;
    this.resources.glitchUniforms.uniforms.uTime = value;
  }
  
  set intensity(value: number) {
    this._intensity = value;
    this.resources.glitchUniforms.uniforms.uIntensity = value;
  }
  
  get intensity(): number {
    return this._intensity;
  }
  
  set resolution(value: [number, number]) {
    this.resources.glitchUniforms.uniforms.uResolution = value;
  }
}
