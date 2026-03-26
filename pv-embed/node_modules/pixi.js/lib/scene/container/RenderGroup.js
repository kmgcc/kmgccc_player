'use strict';

var Matrix = require('../../maths/matrix/Matrix.js');
var InstructionSet = require('../../rendering/renderers/shared/instructions/InstructionSet.js');
var TexturePool = require('../../rendering/renderers/shared/texture/TexturePool.js');

"use strict";
class RenderGroup {
  constructor() {
    this.renderPipeId = "renderGroup";
    this.root = null;
    this.canBundle = false;
    this.renderGroupParent = null;
    this.renderGroupChildren = [];
    this.worldTransform = new Matrix.Matrix();
    this.worldColorAlpha = 4294967295;
    this.worldColor = 16777215;
    this.worldAlpha = 1;
    // these updates are transform changes..
    this.childrenToUpdate = /* @__PURE__ */ Object.create(null);
    this.updateTick = 0;
    this.gcTick = 0;
    // these update are renderable changes..
    this.childrenRenderablesToUpdate = { list: [], index: 0 };
    // other
    this.structureDidChange = true;
    this.instructionSet = new InstructionSet.InstructionSet();
    this._onRenderContainers = [];
    /**
     * Indicates if the cached texture needs to be updated.
     * @default true
     */
    this.textureNeedsUpdate = true;
    /**
     * Indicates if the container should be cached as a texture.
     * @default false
     */
    this.isCachedAsTexture = false;
    this._matrixDirty = 7;
  }
  init(root) {
    this.root = root;
    if (root._onRender) this.addOnRender(root);
    root.didChange = true;
    const children = root.children;
    for (let i = 0; i < children.length; i++) {
      const child = children[i];
      child._updateFlags = 15;
      this.addChild(child);
    }
  }
  enableCacheAsTexture(options = {}) {
    this.textureOptions = options;
    this.isCachedAsTexture = true;
    this.textureNeedsUpdate = true;
  }
  disableCacheAsTexture() {
    this.isCachedAsTexture = false;
    if (this.texture) {
      TexturePool.TexturePool.returnTexture(this.texture, true);
      this.texture = null;
    }
  }
  updateCacheTexture() {
    this.textureNeedsUpdate = true;
    const cachedParent = this._parentCacheAsTextureRenderGroup;
    if (cachedParent && !cachedParent.textureNeedsUpdate) {
      cachedParent.updateCacheTexture();
    }
  }
  reset() {
    this.renderGroupChildren.length = 0;
    for (const i in this.childrenToUpdate) {
      const childrenAtDepth = this.childrenToUpdate[i];
      childrenAtDepth.list.fill(null);
      childrenAtDepth.index = 0;
    }
    this.childrenRenderablesToUpdate.index = 0;
    this.childrenRenderablesToUpdate.list.fill(null);
    this.root = null;
    this.updateTick = 0;
    this.structureDidChange = true;
    this._onRenderContainers.length = 0;
    this.renderGroupParent = null;
    this.disableCacheAsTexture();
  }
  get localTransform() {
    return this.root.localTransform;
  }
  addRenderGroupChild(renderGroupChild) {
    if (renderGroupChild.renderGroupParent) {
      renderGroupChild.renderGroupParent._removeRenderGroupChild(renderGroupChild);
    }
    renderGroupChild.renderGroupParent = this;
    this.renderGroupChildren.push(renderGroupChild);
  }
  _removeRenderGroupChild(renderGroupChild) {
    const index = this.renderGroupChildren.indexOf(renderGroupChild);
    if (index > -1) {
      this.renderGroupChildren.splice(index, 1);
    }
    renderGroupChild.renderGroupParent = null;
  }
  addChild(child) {
    this.structureDidChange = true;
    child.parentRenderGroup = this;
    child.updateTick = -1;
    if (child.parent === this.root) {
      child.relativeRenderGroupDepth = 1;
    } else {
      child.relativeRenderGroupDepth = child.parent.relativeRenderGroupDepth + 1;
    }
    child.didChange = true;
    this.onChildUpdate(child);
    if (child.renderGroup) {
      this.addRenderGroupChild(child.renderGroup);
      return;
    }
    if (child._onRender) this.addOnRender(child);
    const children = child.children;
    for (let i = 0; i < children.length; i++) {
      this.addChild(children[i]);
    }
  }
  removeChild(child) {
    this.structureDidChange = true;
    if (child._onRender) {
      if (!child.renderGroup) {
        this.removeOnRender(child);
      }
    }
    child.parentRenderGroup = null;
    if (child.renderGroup) {
      this._removeRenderGroupChild(child.renderGroup);
      return;
    }
    const children = child.children;
    for (let i = 0; i < children.length; i++) {
      this.removeChild(children[i]);
    }
  }
  removeChildren(children) {
    for (let i = 0; i < children.length; i++) {
      this.removeChild(children[i]);
    }
  }
  onChildUpdate(child) {
    let childrenToUpdate = this.childrenToUpdate[child.relativeRenderGroupDepth];
    if (!childrenToUpdate) {
      childrenToUpdate = this.childrenToUpdate[child.relativeRenderGroupDepth] = {
        index: 0,
        list: []
      };
    }
    childrenToUpdate.list[childrenToUpdate.index++] = child;
  }
  updateRenderable(renderable) {
    if (renderable.globalDisplayStatus < 7) return;
    this.instructionSet.renderPipes[renderable.renderPipeId].updateRenderable(renderable);
    renderable.didViewUpdate = false;
  }
  onChildViewUpdate(child) {
    this.childrenRenderablesToUpdate.list[this.childrenRenderablesToUpdate.index++] = child;
  }
  get isRenderable() {
    return this.root.localDisplayStatus === 7 && this.worldAlpha > 0;
  }
  /**
   * adding a container to the onRender list will make sure the user function
   * passed in to the user defined 'onRender` callBack
   * @param container - the container to add to the onRender list
   */
  addOnRender(container) {
    this._onRenderContainers.push(container);
  }
  removeOnRender(container) {
    this._onRenderContainers.splice(this._onRenderContainers.indexOf(container), 1);
  }
  runOnRender(renderer) {
    for (let i = 0; i < this._onRenderContainers.length; i++) {
      this._onRenderContainers[i]._onRender(renderer);
    }
  }
  destroy() {
    this.disableCacheAsTexture();
    this.renderGroupParent = null;
    this.root = null;
    this.childrenRenderablesToUpdate = null;
    this.childrenToUpdate = null;
    this.renderGroupChildren = null;
    this._onRenderContainers = null;
    this.instructionSet = null;
  }
  getChildren(out = []) {
    const children = this.root.children;
    for (let i = 0; i < children.length; i++) {
      this._getChildren(children[i], out);
    }
    return out;
  }
  _getChildren(container, out = []) {
    out.push(container);
    if (container.renderGroup) return out;
    const children = container.children;
    for (let i = 0; i < children.length; i++) {
      this._getChildren(children[i], out);
    }
    return out;
  }
  invalidateMatrices() {
    this._matrixDirty = 7;
  }
  /**
   * Returns the inverse of the world transform matrix.
   * @returns {Matrix} The inverse of the world transform matrix.
   */
  get inverseWorldTransform() {
    if ((this._matrixDirty & 1) === 0) return this._inverseWorldTransform;
    this._matrixDirty &= ~1;
    this._inverseWorldTransform || (this._inverseWorldTransform = new Matrix.Matrix());
    return this._inverseWorldTransform.copyFrom(this.worldTransform).invert();
  }
  /**
   * Returns the inverse of the texture offset transform matrix.
   * @returns {Matrix} The inverse of the texture offset transform matrix.
   */
  get textureOffsetInverseTransform() {
    if ((this._matrixDirty & 2) === 0) return this._textureOffsetInverseTransform;
    this._matrixDirty &= ~2;
    this._textureOffsetInverseTransform || (this._textureOffsetInverseTransform = new Matrix.Matrix());
    return this._textureOffsetInverseTransform.copyFrom(this.inverseWorldTransform).translate(
      -this._textureBounds.x,
      -this._textureBounds.y
    );
  }
  /**
   * Returns the inverse of the parent texture transform matrix.
   * This is used to properly transform coordinates when rendering into cached textures.
   * @returns {Matrix} The inverse of the parent texture transform matrix.
   */
  get inverseParentTextureTransform() {
    if ((this._matrixDirty & 4) === 0) return this._inverseParentTextureTransform;
    this._matrixDirty &= ~4;
    const parentCacheAsTexture = this._parentCacheAsTextureRenderGroup;
    if (parentCacheAsTexture) {
      this._inverseParentTextureTransform || (this._inverseParentTextureTransform = new Matrix.Matrix());
      return this._inverseParentTextureTransform.copyFrom(this.worldTransform).prepend(parentCacheAsTexture.inverseWorldTransform).translate(
        -parentCacheAsTexture._textureBounds.x,
        -parentCacheAsTexture._textureBounds.y
      );
    }
    return this.worldTransform;
  }
  /**
   * Returns a matrix that transforms coordinates to the correct coordinate space of the texture being rendered to.
   * This is the texture offset inverse transform of the closest parent RenderGroup that is cached as a texture.
   * @returns {Matrix | null} The transform matrix for the cached texture coordinate space,
   * or null if no parent is cached as texture.
   */
  get cacheToLocalTransform() {
    if (this.isCachedAsTexture) {
      return this.textureOffsetInverseTransform;
    }
    if (!this._parentCacheAsTextureRenderGroup) return null;
    return this._parentCacheAsTextureRenderGroup.textureOffsetInverseTransform;
  }
}

exports.RenderGroup = RenderGroup;
//# sourceMappingURL=RenderGroup.js.map
