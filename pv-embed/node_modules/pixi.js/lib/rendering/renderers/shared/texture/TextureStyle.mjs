import EventEmitter from 'eventemitter3';
import { uid } from '../../../../utils/data/uid.mjs';
import { deprecation, v8_0_0 } from '../../../../utils/logging/deprecation.mjs';

"use strict";
const idHash = /* @__PURE__ */ Object.create(null);
function createResourceIdFromString(value) {
  const id = idHash[value];
  if (id === void 0) {
    idHash[value] = uid("resource");
  }
  return id;
}
const _TextureStyle = class _TextureStyle extends EventEmitter {
  /**
   * @param options - options for the style
   */
  constructor(options = {}) {
    super();
    /** @internal */
    this._resourceType = "textureSampler";
    /** @internal */
    this._touched = 0;
    /**
     * Specifies the maximum anisotropy value clamp used by the sampler.
     * Note: Most implementations support {@link TextureStyle#maxAnisotropy} values in range
     * between 1 and 16, inclusive. The used value of {@link TextureStyle#maxAnisotropy} will
     * be clamped to the maximum value that the platform supports.
     * @internal
     */
    this._maxAnisotropy = 1;
    /**
     * Has the style been destroyed?
     * @readonly
     */
    this.destroyed = false;
    options = { ..._TextureStyle.defaultOptions, ...options };
    this.addressMode = options.addressMode;
    this.addressModeU = options.addressModeU ?? this.addressModeU;
    this.addressModeV = options.addressModeV ?? this.addressModeV;
    this.addressModeW = options.addressModeW ?? this.addressModeW;
    this.scaleMode = options.scaleMode;
    this.magFilter = options.magFilter ?? this.magFilter;
    this.minFilter = options.minFilter ?? this.minFilter;
    this.mipmapFilter = options.mipmapFilter ?? this.mipmapFilter;
    this.lodMinClamp = options.lodMinClamp;
    this.lodMaxClamp = options.lodMaxClamp;
    this.compare = options.compare;
    this.maxAnisotropy = options.maxAnisotropy ?? 1;
  }
  set addressMode(value) {
    this.addressModeU = value;
    this.addressModeV = value;
    this.addressModeW = value;
  }
  /** setting this will set wrapModeU,wrapModeV and wrapModeW all at once! */
  get addressMode() {
    return this.addressModeU;
  }
  set wrapMode(value) {
    deprecation(v8_0_0, "TextureStyle.wrapMode is now TextureStyle.addressMode");
    this.addressMode = value;
  }
  get wrapMode() {
    return this.addressMode;
  }
  set scaleMode(value) {
    this.magFilter = value;
    this.minFilter = value;
    this.mipmapFilter = value;
  }
  /** setting this will set magFilter,minFilter and mipmapFilter all at once!  */
  get scaleMode() {
    return this.magFilter;
  }
  /** Specifies the maximum anisotropy value clamp used by the sampler. */
  set maxAnisotropy(value) {
    this._maxAnisotropy = Math.min(value, 16);
    if (this._maxAnisotropy > 1) {
      this.scaleMode = "linear";
    }
  }
  get maxAnisotropy() {
    return this._maxAnisotropy;
  }
  // TODO - move this to WebGL?
  get _resourceId() {
    return this._sharedResourceId || this._generateResourceId();
  }
  update() {
    this._sharedResourceId = null;
    this.emit("change", this);
  }
  _generateResourceId() {
    const bigKey = `${this.addressModeU}-${this.addressModeV}-${this.addressModeW}-${this.magFilter}-${this.minFilter}-${this.mipmapFilter}-${this.lodMinClamp}-${this.lodMaxClamp}-${this.compare}-${this._maxAnisotropy}`;
    this._sharedResourceId = createResourceIdFromString(bigKey);
    return this._resourceId;
  }
  /** Destroys the style */
  destroy() {
    this.destroyed = true;
    this.emit("destroy", this);
    this.emit("change", this);
    this.removeAllListeners();
  }
};
/** default options for the style */
_TextureStyle.defaultOptions = {
  addressMode: "clamp-to-edge",
  scaleMode: "linear"
};
let TextureStyle = _TextureStyle;

export { TextureStyle };
//# sourceMappingURL=TextureStyle.mjs.map
