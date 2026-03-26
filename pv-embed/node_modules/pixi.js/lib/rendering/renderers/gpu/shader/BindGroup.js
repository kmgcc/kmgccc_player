'use strict';

"use strict";
class BindGroup {
  /**
   * Create a new instance eof the Bind Group.
   * @param resources - The resources that are bound together for use by a shader.
   */
  constructor(resources) {
    /** The resources that are bound together for use by a shader. */
    this.resources = /* @__PURE__ */ Object.create(null);
    this._dirty = true;
    let index = 0;
    for (const i in resources) {
      const resource = resources[i];
      this.setResource(resource, index++);
    }
    this._updateKey();
  }
  /**
   * Updates the key if its flagged as dirty. This is used internally to
   * match this bind group to a WebGPU BindGroup.
   * @internal
   */
  _updateKey() {
    if (!this._dirty) return;
    this._dirty = false;
    const keyParts = [];
    let index = 0;
    for (const i in this.resources) {
      keyParts[index++] = this.resources[i]._resourceId;
    }
    this._key = keyParts.join("|");
  }
  /**
   * Set a resource at a given index. this function will
   * ensure that listeners will be removed from the current resource
   * and added to the new resource.
   * @param resource - The resource to set.
   * @param index - The index to set the resource at.
   */
  setResource(resource, index) {
    const currentResource = this.resources[index];
    if (resource === currentResource) return;
    currentResource?.off?.("change", this.onResourceChange, this);
    resource.on?.("change", this.onResourceChange, this);
    this.resources[index] = resource;
    this._dirty = true;
  }
  /**
   * Returns the resource at the current specified index.
   * @param index - The index of the resource to get.
   * @returns - The resource at the specified index.
   */
  getResource(index) {
    return this.resources[index];
  }
  /**
   * Used internally to 'touch' each resource, to ensure that the GC
   * knows that all resources in this bind group are still being used.
   * @param now - The current time in milliseconds.
   * @param tick - The current tick.
   * @internal
   */
  _touch(now, tick) {
    const resources = this.resources;
    for (const i in resources) {
      resources[i]._gcLastUsed = now;
      resources[i]._touched = tick;
    }
  }
  /** Destroys this bind group and removes all listeners. */
  destroy() {
    const resources = this.resources;
    for (const i in resources) {
      const resource = resources[i];
      resource?.off?.("change", this.onResourceChange, this);
    }
    this.resources = null;
  }
  onResourceChange(resource) {
    this._dirty = true;
    if (resource.destroyed) {
      this.destroy();
    } else {
      this._updateKey();
    }
  }
}

exports.BindGroup = BindGroup;
//# sourceMappingURL=BindGroup.js.map
