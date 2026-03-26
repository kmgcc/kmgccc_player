import { Cache } from '../../assets/cache/Cache.mjs';
import { ObservablePoint } from '../../maths/point/ObservablePoint.mjs';
import { Texture } from '../../rendering/renderers/shared/texture/Texture.mjs';
import { deprecation, v8_0_0 } from '../../utils/logging/deprecation.mjs';
import { Transform } from '../../utils/misc/Transform.mjs';
import { ViewContainer } from '../view/ViewContainer.mjs';
import './init.mjs';

"use strict";
const _TilingSprite = class _TilingSprite extends ViewContainer {
  constructor(...args) {
    let options = args[0] || {};
    if (options instanceof Texture) {
      options = { texture: options };
    }
    if (args.length > 1) {
      deprecation(v8_0_0, "use new TilingSprite({ texture, width:100, height:100 }) instead");
      options.width = args[1];
      options.height = args[2];
    }
    options = { ..._TilingSprite.defaultOptions, ...options };
    const {
      texture,
      anchor,
      tilePosition,
      tileScale,
      tileRotation,
      width,
      height,
      applyAnchorToTexture,
      roundPixels,
      ...rest
    } = options ?? {};
    super({
      label: "TilingSprite",
      ...rest
    });
    /** @internal */
    this.renderPipeId = "tilingSprite";
    /** @advanced */
    this.batched = true;
    this.allowChildren = false;
    this._anchor = new ObservablePoint(
      {
        _onUpdate: () => {
          this.onViewUpdate();
        }
      }
    );
    this.applyAnchorToTexture = applyAnchorToTexture;
    this.texture = texture;
    this._width = width ?? texture.width;
    this._height = height ?? texture.height;
    this._tileTransform = new Transform({
      observer: {
        _onUpdate: () => this.onViewUpdate()
      }
    });
    if (anchor) this.anchor = anchor;
    this.tilePosition = tilePosition;
    this.tileScale = tileScale;
    this.tileRotation = tileRotation;
    this.roundPixels = roundPixels ?? false;
  }
  /**
   * Creates a new tiling sprite based on a source texture or image path.
   * This is a convenience method that automatically creates and manages textures.
   * @example
   * ```ts
   * // Create a new tiling sprite from an image path
   * const pattern = TilingSprite.from('pattern.png');
   * pattern.width = 300; // Set the width of the tiling area
   * pattern.height = 200; // Set the height of the tiling area
   *
   * // Create from options
   * const texture = Texture.from('pattern.png');
   * const pattern = TilingSprite.from(texture, {
   *     width: 300,
   *     height: 200,
   *     tileScale: { x: 0.5, y: 0.5 }
   * });
   * ```
   * @param source - The source to create the sprite from. Can be a path to an image or a texture
   * @param options - Additional options for the tiling sprite
   * @returns A new tiling sprite based on the source
   * @see {@link Texture.from} For texture creation details
   * @see {@link Assets} For asset loading and management
   */
  static from(source, options = {}) {
    if (typeof source === "string") {
      return new _TilingSprite({
        texture: Cache.get(source),
        ...options
      });
    }
    return new _TilingSprite({
      texture: source,
      ...options
    });
  }
  /**
   * @see {@link TilingSpriteOptions.applyAnchorToTexture}
   * @deprecated since 8.0.0
   * @advanced
   */
  get uvRespectAnchor() {
    deprecation(v8_0_0, "uvRespectAnchor is deprecated, please use applyAnchorToTexture instead");
    return this.applyAnchorToTexture;
  }
  /** @advanced */
  set uvRespectAnchor(value) {
    deprecation(v8_0_0, "uvRespectAnchor is deprecated, please use applyAnchorToTexture instead");
    this.applyAnchorToTexture = value;
  }
  /**
   * Changes frame clamping in corresponding textureMatrix
   * Change to -0.5 to add a pixel to the edge, recommended for transparent trimmed textures in atlas
   * @default 0.5
   * @type {number}
   * @advanced
   */
  get clampMargin() {
    return this._texture.textureMatrix.clampMargin;
  }
  /** @advanced */
  set clampMargin(value) {
    this._texture.textureMatrix.clampMargin = value;
  }
  /**
   * The anchor sets the origin point of the sprite. The default value is taken from the {@link Texture}
   * and passed to the constructor.
   *
   * - The default is `(0,0)`, this means the sprite's origin is the top left.
   * - Setting the anchor to `(0.5,0.5)` means the sprite's origin is centered.
   * - Setting the anchor to `(1,1)` would mean the sprite's origin point will be the bottom right corner.
   *
   * If you pass only single parameter, it will set both x and y to the same value as shown in the example below.
   * @example
   * ```ts
   * // Center the anchor point
   * sprite.anchor = 0.5; // Sets both x and y to 0.5
   * sprite.position.set(400, 300); // Sprite will be centered at this position
   *
   * // Set specific x/y anchor points
   * sprite.anchor = {
   *     x: 1, // Right edge
   *     y: 0  // Top edge
   * };
   *
   * // Using individual coordinates
   * sprite.anchor.set(0.5, 1); // Center-bottom
   *
   * // For rotation around center
   * sprite.anchor.set(0.5);
   * sprite.rotation = Math.PI / 4; // 45 degrees around center
   *
   * // For scaling from center
   * sprite.anchor.set(0.5);
   * sprite.scale.set(2); // Scales from center point
   * ```
   */
  get anchor() {
    return this._anchor;
  }
  set anchor(value) {
    typeof value === "number" ? this._anchor.set(value) : this._anchor.copyFrom(value);
  }
  /**
   * The offset of the tiling texture.
   * Used to scroll or position the repeated pattern.
   * @example
   * ```ts
   * // Offset the tiling pattern by 100 pixels in both x and y directions
   * tilingSprite.tilePosition = { x: 100, y: 100 };
   * ```
   * @default {x: 0, y: 0}
   */
  get tilePosition() {
    return this._tileTransform.position;
  }
  set tilePosition(value) {
    this._tileTransform.position.copyFrom(value);
  }
  /**
   * Scale of the tiling texture.
   * Affects the size of each repeated instance of the texture.
   * @example
   * ```ts
   * // Scale the texture by 1.5 in both x and y directions
   * tilingSprite.tileScale = { x: 1.5, y: 1.5 };
   * ```
   * @default {x: 1, y: 1}
   */
  get tileScale() {
    return this._tileTransform.scale;
  }
  set tileScale(value) {
    typeof value === "number" ? this._tileTransform.scale.set(value) : this._tileTransform.scale.copyFrom(value);
  }
  set tileRotation(value) {
    this._tileTransform.rotation = value;
  }
  /**
   * Rotation of the tiling texture in radians.
   * This controls the rotation applied to the texture before tiling.
   * @example
   * ```ts
   * // Rotate the texture by 45 degrees (in radians)
   * tilingSprite.tileRotation = Math.PI / 4; // 45 degrees
   * ```
   * @default 0
   */
  get tileRotation() {
    return this._tileTransform.rotation;
  }
  /**
   * The transform object that controls the tiling texture's position, scale, and rotation.
   * This transform is independent of the sprite's own transform properties.
   * @example
   * ```ts
   * // Access transform properties directly
   * sprite.tileTransform.position.set(100, 50);
   * sprite.tileTransform.scale.set(2);
   * sprite.tileTransform.rotation = Math.PI / 4;
   *
   * // Create smooth scrolling animation
   * app.ticker.add(() => {
   *     sprite.tileTransform.position.x += 1;
   *     sprite.tileTransform.rotation += 0.01;
   * });
   *
   * // Reset transform
   * sprite.tileTransform.position.set(0);
   * sprite.tileTransform.scale.set(1);
   * sprite.tileTransform.rotation = 0;
   * ```
   * @returns {Transform} The transform object for the tiling texture
   * @see {@link Transform} For transform operations
   * @see {@link TilingSprite#tilePosition} For position control
   * @see {@link TilingSprite#tileScale} For scale control
   * @see {@link TilingSprite#tileRotation} For rotation control
   * @advanced
   */
  get tileTransform() {
    return this._tileTransform;
  }
  set texture(value) {
    value || (value = Texture.EMPTY);
    const currentTexture = this._texture;
    if (currentTexture === value) return;
    if (currentTexture && currentTexture.dynamic) currentTexture.off("update", this.onViewUpdate, this);
    if (value.dynamic) value.on("update", this.onViewUpdate, this);
    this._texture = value;
    this.onViewUpdate();
  }
  /**
   * The texture to use for tiling.
   * This is the image that will be repeated across the sprite.
   * @example
   * ```ts
   * // Use a texture from the asset cache
   * tilingSprite.texture = Texture.from('assets/pattern.png');
   * ```
   * @default Texture.WHITE
   */
  get texture() {
    return this._texture;
  }
  /**
   * The width of the tiling area. This defines how wide the area is that the texture will be tiled across.
   * @example
   * ```ts
   * // Create a tiling sprite
   * const sprite = new TilingSprite({
   *     texture: Texture.from('pattern.png'),
   *     width: 500,
   *     height: 300
   * });
   *
   * // Adjust width dynamically
   * sprite.width = 800; // Expands tiling area
   *
   * // Update on resize
   * window.addEventListener('resize', () => {
   *     sprite.width = app.screen.width;
   * });
   * ```
   * @see {@link TilingSprite#setSize} For setting both width and height efficiently
   * @see {@link TilingSprite#height} For setting height
   */
  set width(value) {
    this._width = value;
    this.onViewUpdate();
  }
  get width() {
    return this._width;
  }
  set height(value) {
    this._height = value;
    this.onViewUpdate();
  }
  /**
   * The height of the tiling area. This defines how tall the area is that the texture will be tiled across.
   * @example
   * ```ts
   * // Create a tiling sprite
   * const sprite = new TilingSprite({
   *     texture: Texture.from('pattern.png'),
   *     width: 500,
   *     height: 300
   * });
   *
   * // Adjust width dynamically
   * sprite.height = 800; // Expands tiling area
   *
   * // Update on resize
   * window.addEventListener('resize', () => {
   *     sprite.height = app.screen.height;
   * });
   * ```
   * @see {@link TilingSprite#setSize} For setting both width and height efficiently
   * @see {@link TilingSprite#width} For setting width
   */
  get height() {
    return this._height;
  }
  /**
   * Sets the size of the TilingSprite to the specified width and height.
   * This is faster than setting width and height separately as it only triggers one update.
   * @example
   * ```ts
   * // Set specific dimensions
   * sprite.setSize(300, 200); // Width: 300, Height: 200
   *
   * // Set uniform size (square)
   * sprite.setSize(400); // Width: 400, Height: 400
   *
   * // Set size using object
   * sprite.setSize({
   *     width: 500,
   *     height: 300
   * });
   * ```
   * @param value - This can be either a number for uniform sizing or a Size object with width/height properties
   * @param height - The height to set. Defaults to the value of `width` if not provided
   * @see {@link TilingSprite#width} For setting width only
   * @see {@link TilingSprite#height} For setting height only
   */
  setSize(value, height) {
    if (typeof value === "object") {
      height = value.height ?? value.width;
      value = value.width;
    }
    this._width = value;
    this._height = height ?? value;
    this.onViewUpdate();
  }
  /**
   * Retrieves the size of the TilingSprite as a {@link Size} object.
   * This method is more efficient than getting width and height separately as it only allocates one object.
   * @example
   * ```ts
   * // Get basic size
   * const size = sprite.getSize();
   * console.log(`Size: ${size.width}x${size.height}`);
   *
   * // Reuse existing size object
   * const reuseSize = { width: 0, height: 0 };
   * sprite.getSize(reuseSize);
   * ```
   * @param out - Optional object to store the size in, to avoid allocating a new object
   * @returns The size of the TilingSprite
   * @see {@link TilingSprite#width} For getting just the width
   * @see {@link TilingSprite#height} For getting just the height
   * @see {@link TilingSprite#setSize} For setting both width and height efficiently
   */
  getSize(out) {
    out || (out = {});
    out.width = this._width;
    out.height = this._height;
    return out;
  }
  /** @private */
  updateBounds() {
    const bounds = this._bounds;
    const anchor = this._anchor;
    const width = this._width;
    const height = this._height;
    bounds.minX = -anchor._x * width;
    bounds.maxX = bounds.minX + width;
    bounds.minY = -anchor._y * height;
    bounds.maxY = bounds.minY + height;
  }
  /**
   * Checks if the object contains the given point in local coordinates.
   * Takes into account the anchor offset when determining boundaries.
   * @example
   * ```ts
   * // Create a tiling sprite
   * const sprite = new TilingSprite({
   *     texture: Texture.from('pattern.png'),
   *     width: 200,
   *     height: 100,
   *     anchor: 0.5 // Center anchor
   * });
   *
   * // Basic point check
   * const contains = sprite.containsPoint({ x: 50, y: 25 });
   * console.log('Point is inside:', contains);
   *
   * // Check with different anchors
   * sprite.anchor.set(0); // Top-left anchor
   * console.log('Contains point:', sprite.containsPoint({ x: 150, y: 75 }));
   * ```
   * @param point - The point to check in local coordinates
   * @returns True if the point is within the sprite's bounds
   * @see {@link TilingSprite#toLocal} For converting global coordinates to local
   * @see {@link TilingSprite#anchor} For understanding boundary calculations
   */
  containsPoint(point) {
    const width = this._width;
    const height = this._height;
    const x1 = -width * this._anchor._x;
    let y1 = 0;
    if (point.x >= x1 && point.x <= x1 + width) {
      y1 = -height * this._anchor._y;
      if (point.y >= y1 && point.y <= y1 + height) return true;
    }
    return false;
  }
  /**
   * Destroys this sprite renderable and optionally its texture.
   * @param options - Options parameter. A boolean will act as if all options
   *  have been set to that value
   * @example
   * tilingSprite.destroy();
   * tilingSprite.destroy(true);
   * tilingSprite.destroy({ texture: true, textureSource: true });
   */
  destroy(options = false) {
    super.destroy(options);
    this._anchor = null;
    this._tileTransform = null;
    this._bounds = null;
    const destroyTexture = typeof options === "boolean" ? options : options?.texture;
    if (destroyTexture) {
      const destroyTextureSource = typeof options === "boolean" ? options : options?.textureSource;
      this._texture.destroy(destroyTextureSource);
    }
    this._texture = null;
  }
};
/**
 * Default options used when creating a TilingSprite instance.
 * These values are used as fallbacks when specific options are not provided.
 * @example
 * ```ts
 * // Override default options globally
 * TilingSprite.defaultOptions.texture = Texture.from('defaultPattern.png');
 * TilingSprite.defaultOptions.tileScale = { x: 2, y: 2 };
 *
 * // Create sprite using default options
 * const sprite = new TilingSprite();
 * // Will use defaultPattern.png and scale 2x
 * ```
 * @type {TilingSpriteOptions}
 * @see {@link TilingSpriteOptions} For all available options
 * @see {@link TilingSprite.from} For creating sprites with custom options
 * @see {@link Texture.EMPTY} For the default empty texture
 */
_TilingSprite.defaultOptions = {
  /** The texture to use for the sprite. */
  texture: Texture.EMPTY,
  /** The anchor point of the sprite */
  anchor: { x: 0, y: 0 },
  /** The offset of the image that is being tiled. */
  tilePosition: { x: 0, y: 0 },
  /** Scaling of the image that is being tiled. */
  tileScale: { x: 1, y: 1 },
  /** The rotation of the image that is being tiled. */
  tileRotation: 0,
  /**
   * Flags whether the tiling pattern should originate from the origin instead of the top-left corner in
   * local space.
   *
   * This will make the texture coordinates assigned to each vertex dependent on the value of the anchor. Without
   * this, the top-left corner always gets the (0, 0) texture coordinate.
   * @default false
   */
  applyAnchorToTexture: false
};
let TilingSprite = _TilingSprite;

export { TilingSprite };
//# sourceMappingURL=TilingSprite.mjs.map
