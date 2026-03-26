'use strict';

var Container = require('../scene/container/Container.js');
var _const = require('../ticker/const.js');
var Ticker = require('../ticker/Ticker.js');

"use strict";
const _PrepareBase = class _PrepareBase {
  /**
   * @param {Renderer} renderer - A reference to the current renderer
   */
  constructor(renderer) {
    /** called per frame by the ticker, defer processing to next tick */
    this._tick = () => {
      if (this._destroyed) return;
      this.timeout = setTimeout(this._processQueue, 0);
    };
    /** process the queue up to max item limit per frame */
    this._processQueue = () => {
      if (this._destroyed) return;
      const { queue } = this;
      let itemsProcessed = 0;
      while (queue.length && itemsProcessed < _PrepareBase.uploadsPerFrame) {
        const queueItem = queue.shift();
        this.uploadQueueItem(queueItem);
        itemsProcessed++;
      }
      if (queue.length) {
        Ticker.Ticker.system.addOnce(this._tick, this, _const.UPDATE_PRIORITY.UTILITY);
      } else {
        this._resolve();
      }
    };
    this.renderer = renderer;
    this.queue = [];
    this.resolves = [];
  }
  /**
   * Return a copy of the queue
   * @returns {PrepareQueueItem[]} The queue
   */
  getQueue() {
    return [...this.queue];
  }
  /**
   * Add a textures or graphics resource to the queue
   * @param {PrepareSourceItem | PrepareSourceItem[]} resource
   */
  add(resource) {
    const resourceArray = Array.isArray(resource) ? resource : [resource];
    for (const resourceItem of resourceArray) {
      if (resourceItem instanceof Container.Container) {
        this._addContainer(resourceItem);
      } else {
        this.resolveQueueItem(resourceItem, this.queue);
      }
    }
    return this;
  }
  /**
   * Recursively add a container and its children to the queue
   * @param {Container} container - The container to add to the queue
   */
  _addContainer(container) {
    this.resolveQueueItem(container, this.queue);
    for (const child of container.children) {
      this._addContainer(child);
    }
  }
  /**
   * Upload all the textures and graphics to the GPU (optionally add more resources to the queue first)
   * @param {PrepareSourceItem | PrepareSourceItem[] | undefined} resource
   */
  upload(resource) {
    if (resource) {
      this.add(resource);
    }
    return new Promise((resolve) => {
      if (this.queue.length) {
        this.resolves.push(resolve);
        this.dedupeQueue();
        Ticker.Ticker.system.addOnce(this._tick, this, _const.UPDATE_PRIORITY.UTILITY);
      } else {
        resolve();
      }
    });
  }
  /** eliminate duplicates before processing */
  dedupeQueue() {
    const hash = /* @__PURE__ */ Object.create(null);
    let nextUnique = 0;
    for (let i = 0; i < this.queue.length; i++) {
      const current = this.queue[i];
      if (!hash[current.uid]) {
        hash[current.uid] = true;
        this.queue[nextUnique++] = current;
      }
    }
    this.queue.length = nextUnique;
  }
  destroy() {
    this._destroyed = true;
    clearTimeout(this.timeout);
  }
  /** Call all the resolve callbacks */
  _resolve() {
    const { resolves } = this;
    const array = resolves.slice(0);
    resolves.length = 0;
    for (const resolve of array) {
      resolve();
    }
  }
};
/** The number of uploads to process per frame */
_PrepareBase.uploadsPerFrame = 4;
let PrepareBase = _PrepareBase;

exports.PrepareBase = PrepareBase;
//# sourceMappingURL=PrepareBase.js.map
