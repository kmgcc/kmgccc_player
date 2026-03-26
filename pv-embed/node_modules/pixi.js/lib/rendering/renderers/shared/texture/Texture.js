'use strict';

var EventEmitter = require('eventemitter3');
var groupD8 = require('../../../../maths/matrix/groupD8.js');
var Rectangle = require('../../../../maths/shapes/Rectangle.js');
var uid = require('../../../../utils/data/uid.js');
var deprecation = require('../../../../utils/logging/deprecation.js');
var NOOP = require('../../../../utils/misc/NOOP.js');
var BufferImageSource = require('./sources/BufferImageSource.js');
var TextureSource = require('./sources/TextureSource.js');
var TextureMatrix = require('./TextureMatrix.js');

"use strict";
class Texture extends EventEmitter {
  /**
   * @param {TextureOptions} options - Options for the texture
   */
  constructor({
    source,
    label,
    frame,
    orig,
    trim,
    defaultAnchor,
    defaultBorders,
    rotate,
    dynamic
  } = {}) {
    super();
    /** unique id for this texture */
    this.uid = uid.uid("texture");
    /** A uvs object based on the given frame and the texture source */
    this.uvs = { x0: 0, y0: 0, x1: 0, y1: 0, x2: 0, y2: 0, x3: 0, y3: 0 };
    /**
     * This is the area of the BaseTexture image to actually copy to the Canvas / WebGL when rendering,
     * irrespective of the actual frame size or placement (which can be influenced by trimmed texture atlases)
     */
    this.frame = new Rectangle.Rectangle();
    /**
     * Does this Texture have any frame data assigned to it?
     *
     * This mode is enabled automatically if no frame was passed inside constructor.
     *
     * In this mode texture is subscribed to baseTexture events, and fires `update` on any change.
     *
     * Beware, after loading or resize of baseTexture event can fired two times!
     * If you want more control, subscribe on baseTexture itself.
     * @example
     * texture.on('update', () => {});
     */
    this.noFrame = false;
    /**
     * Set to true if you plan on modifying the uvs of this texture.
     * When this is the case, sprites and other objects using the texture will
     * make sure to listen for changes to the uvs and update their vertices accordingly.
     */
    this.dynamic = false;
    /** is it a texture? yes! used for type checking */
    this.isTexture = true;
    this.label = label;
    this.source = source?.source ?? new TextureSource.TextureSource();
    this.noFrame = !frame;
    if (frame) {
      this.frame.copyFrom(frame);
    } else {
      const { width, height } = this._source;
      this.frame.width = width;
      this.frame.height = height;
    }
    this.orig = orig || this.frame;
    this.trim = trim;
    this.rotate = rotate ?? 0;
    this.defaultAnchor = defaultAnchor;
    this.defaultBorders = defaultBorders;
    this.destroyed = false;
    this.dynamic = dynamic || false;
    this.updateUvs();
  }
  set source(value) {
    if (this._source) {
      this._source.off("resize", this.update, this);
    }
    this._source = value;
    value.on("resize", this.update, this);
    this.emit("update", this);
  }
  /** the underlying source of the texture (equivalent of baseTexture in v7) */
  get source() {
    return this._source;
  }
  /** returns a TextureMatrix instance for this texture. By default, that object is not created because its heavy. */
  get textureMatrix() {
    if (!this._textureMatrix) {
      this._textureMatrix = new TextureMatrix.TextureMatrix(this);
    }
    return this._textureMatrix;
  }
  /** The width of the Texture in pixels. */
  get width() {
    return this.orig.width;
  }
  /** The height of the Texture in pixels. */
  get height() {
    return this.orig.height;
  }
  /** Call this function when you have modified the frame of this texture. */
  updateUvs() {
    const { uvs, frame } = this;
    const { width, height } = this._source;
    const nX = frame.x / width;
    const nY = frame.y / height;
    const nW = frame.width / width;
    const nH = frame.height / height;
    let rotate = this.rotate;
    if (rotate) {
      const w2 = nW / 2;
      const h2 = nH / 2;
      const cX = nX + w2;
      const cY = nY + h2;
      rotate = groupD8.groupD8.add(rotate, groupD8.groupD8.NW);
      uvs.x0 = cX + w2 * groupD8.groupD8.uX(rotate);
      uvs.y0 = cY + h2 * groupD8.groupD8.uY(rotate);
      rotate = groupD8.groupD8.add(rotate, 2);
      uvs.x1 = cX + w2 * groupD8.groupD8.uX(rotate);
      uvs.y1 = cY + h2 * groupD8.groupD8.uY(rotate);
      rotate = groupD8.groupD8.add(rotate, 2);
      uvs.x2 = cX + w2 * groupD8.groupD8.uX(rotate);
      uvs.y2 = cY + h2 * groupD8.groupD8.uY(rotate);
      rotate = groupD8.groupD8.add(rotate, 2);
      uvs.x3 = cX + w2 * groupD8.groupD8.uX(rotate);
      uvs.y3 = cY + h2 * groupD8.groupD8.uY(rotate);
    } else {
      uvs.x0 = nX;
      uvs.y0 = nY;
      uvs.x1 = nX + nW;
      uvs.y1 = nY;
      uvs.x2 = nX + nW;
      uvs.y2 = nY + nH;
      uvs.x3 = nX;
      uvs.y3 = nY + nH;
    }
  }
  /**
   * Destroys this texture
   * @param destroySource - Destroy the source when the texture is destroyed.
   */
  destroy(destroySource = false) {
    if (this._source) {
      this._source.off("resize", this.update, this);
      if (destroySource) {
        this._source.destroy();
        this._source = null;
      }
    }
    this._textureMatrix = null;
    this.destroyed = true;
    this.emit("destroy", this);
    this.removeAllListeners();
  }
  /**
   * Call this if you have modified the `texture outside` of the constructor.
   *
   * If you have modified this texture's source, you must separately call `texture.source.update()` to see those changes.
   */
  update() {
    if (this.noFrame) {
      this.frame.width = this._source.width;
      this.frame.height = this._source.height;
    }
    this.updateUvs();
    this.emit("update", this);
  }
  /** @deprecated since 8.0.0 */
  get baseTexture() {
    deprecation.deprecation(deprecation.v8_0_0, "Texture.baseTexture is now Texture.source");
    return this._source;
  }
}
Texture.EMPTY = new Texture({
  label: "EMPTY",
  source: new TextureSource.TextureSource({
    label: "EMPTY"
  })
});
Texture.EMPTY.destroy = NOOP.NOOP;
Texture.WHITE = new Texture({
  source: new BufferImageSource.BufferImageSource({
    resource: new Uint8Array([255, 255, 255, 255]),
    width: 1,
    height: 1,
    alphaMode: "premultiply-alpha-on-upload",
    label: "WHITE"
  }),
  label: "WHITE"
});
Texture.WHITE.destroy = NOOP.NOOP;

exports.Texture = Texture;
//# sourceMappingURL=Texture.js.map
