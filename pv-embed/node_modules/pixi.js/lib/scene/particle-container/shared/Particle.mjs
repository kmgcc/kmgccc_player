import { Color } from '../../../color/Color.mjs';
import { Texture } from '../../../rendering/renderers/shared/texture/Texture.mjs';
import { bgr2rgb } from '../../container/container-mixins/getGlobalMixin.mjs';
import { assignWithIgnore } from '../../container/utils/assignWithIgnore.mjs';

"use strict";
const _Particle = class _Particle {
  constructor(options) {
    if (options instanceof Texture) {
      this.texture = options;
      assignWithIgnore(this, _Particle.defaultOptions, {});
    } else {
      const combined = { ..._Particle.defaultOptions, ...options };
      assignWithIgnore(this, combined, {});
    }
  }
  /**
   * The transparency of the particle. Values range from 0 (fully transparent)
   * to 1 (fully opaque). Values outside this range are clamped.
   * @example
   * ```ts
   * // Create a semi-transparent particle
   * const particle = new Particle({
   *     texture: Texture.from('particle.png'),
   *     alpha: 0.5
   * });
   *
   * // Fade out
   * particle.alpha *= 0.9;
   *
   * // Fade in
   * particle.alpha = Math.min(particle.alpha + 0.1, 1);
   *
   * // Values are clamped to valid range
   * particle.alpha = 1.5; // Becomes 1.0
   * particle.alpha = -0.5; // Becomes 0.0
   *
   * // Animate transparency
   * app.ticker.add((delta) => {
   *     const time = performance.now() / 1000;
   *     particle.alpha = 0.5 + Math.sin(time) * 0.5; // Pulse between 0-1
   * });
   * ```
   * @default 1
   * @see {@link Particle#tint} For controlling particle color
   * @see {@link Particle#color} For the combined color and alpha value
   */
  get alpha() {
    return this._alpha;
  }
  set alpha(value) {
    this._alpha = Math.min(Math.max(value, 0), 1);
    this._updateColor();
  }
  /**
   * The tint color of the particle. Can be set using hex numbers or CSS color strings.
   * The tint is multiplied with the texture color to create the final particle color.
   * @example
   * ```ts
   * // Create a red particle
   * const particle = new Particle({
   *     texture: Texture.from('particle.png'),
   *     tint: 0xff0000
   * });
   *
   * // Use CSS color strings
   * particle.tint = '#00ff00';  // Green
   * particle.tint = 'blue';     // Blue
   *
   * // Animate tint color
   * app.ticker.add(() => {
   *     const time = performance.now() / 1000;
   *
   *     // Cycle through hues
   *     const hue = (time * 50) % 360;
   *     particle.tint = `hsl(${hue}, 100%, 50%)`;
   * });
   *
   * // Reset to white (no tint)
   * particle.tint = 0xffffff;
   * ```
   * @type {ColorSource} Hex number or CSS color string
   * @default 0xffffff
   * @see {@link Particle#alpha} For controlling transparency
   * @see {@link Particle#color} For the combined color and alpha value
   * @see {@link Color} For supported color formats
   */
  get tint() {
    return bgr2rgb(this._tint);
  }
  set tint(value) {
    this._tint = Color.shared.setValue(value ?? 16777215).toBgrNumber();
    this._updateColor();
  }
  _updateColor() {
    this.color = this._tint + ((this._alpha * 255 | 0) << 24);
  }
};
/**
 * Default options used when creating new particles. These values are applied when specific
 * options aren't provided in the constructor.
 * @example
 * ```ts
 * // Override defaults globally
 * Particle.defaultOptions = {
 *     ...Particle.defaultOptions,
 *     anchorX: 0.5,
 *     anchorY: 0.5,
 *     alpha: 0.8
 * };
 *
 * // New particles use modified defaults
 * const centeredParticle = new Particle(texture);
 * console.log(centeredParticle.anchorX); // 0.5
 * console.log(centeredParticle.alpha); // 0.8
 * ```
 * @see {@link ParticleOptions} For all available options
 * @see {@link Particle} For the particle implementation
 */
_Particle.defaultOptions = {
  anchorX: 0,
  anchorY: 0,
  x: 0,
  y: 0,
  scaleX: 1,
  scaleY: 1,
  rotation: 0,
  tint: 16777215,
  alpha: 1
};
let Particle = _Particle;

export { Particle };
//# sourceMappingURL=Particle.mjs.map
