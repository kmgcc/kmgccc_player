"use strict";
class GCManagedHash {
  constructor(options) {
    // Exposed directly for GC system access
    this.items = /* @__PURE__ */ Object.create(null);
    const { renderer, type, onUnload, priority, name } = options;
    this._renderer = renderer;
    renderer.gc.addResourceHash(this, "items", type, priority ?? 0);
    this._onUnload = onUnload;
    this.name = name;
  }
  /**
   * Add an item to the hash. No-op if already added.
   * @param item
   * @returns true if the item was added, false if it was already in the hash
   */
  add(item) {
    if (this.items[item.uid]) return false;
    this.items[item.uid] = item;
    item.once("unload", this.remove, this);
    item._gcLastUsed = this._renderer.gc.now;
    return true;
  }
  remove(item, ...args) {
    if (!this.items[item.uid]) return;
    const gpuData = item._gpuData[this._renderer.uid];
    if (!gpuData) return;
    this._onUnload?.(item, ...args);
    gpuData.destroy();
    item._gpuData[this._renderer.uid] = null;
    this.items[item.uid] = null;
  }
  removeAll(...args) {
    Object.values(this.items).forEach((item) => item && this.remove(item, ...args));
  }
  destroy(...args) {
    this.removeAll(...args);
    this.items = /* @__PURE__ */ Object.create(null);
    this._renderer = null;
    this._onUnload = null;
  }
}

export { GCManagedHash };
//# sourceMappingURL=GCManagedHash.mjs.map
