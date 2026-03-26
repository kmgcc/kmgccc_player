'use strict';

var checkImageBitmap_worker = require('../../../_virtual/checkImageBitmap.worker.js');
var loadImageBitmap_worker = require('../../../_virtual/loadImageBitmap.worker.js');

"use strict";
let UUID = 0;
let MAX_WORKERS;
class WorkerManagerClass {
  constructor() {
    /** Whether the worker manager has been initialized */
    this._initialized = false;
    /** Current number of created workers (used to enforce MAX_WORKERS limit) */
    this._createdWorkers = 0;
    this._workerPool = [];
    this._queue = [];
    this._resolveHash = {};
  }
  /**
   * Checks if ImageBitmap is supported in the current environment.
   *
   * This method uses a dedicated worker to test ImageBitmap support
   * and caches the result for subsequent calls.
   * @returns Promise that resolves to true if ImageBitmap is supported, false otherwise
   */
  isImageBitmapSupported() {
    if (this._isImageBitmapSupported !== void 0) return this._isImageBitmapSupported;
    this._isImageBitmapSupported = new Promise((resolve) => {
      const { worker } = new checkImageBitmap_worker.default();
      worker.addEventListener("message", (event) => {
        worker.terminate();
        checkImageBitmap_worker.default.revokeObjectURL();
        resolve(event.data);
      });
    });
    return this._isImageBitmapSupported;
  }
  /**
   * Loads an image as an ImageBitmap using a web worker.
   * @param src - The source URL or path of the image to load
   * @param asset - Optional resolved asset containing additional texture source options
   * @returns Promise that resolves to the loaded ImageBitmap
   * @example
   * ```typescript
   * const bitmap = await WorkerManager.loadImageBitmap('image.png');
   * const bitmapWithOptions = await WorkerManager.loadImageBitmap('image.png', asset);
   * ```
   */
  loadImageBitmap(src, asset) {
    return this._run("loadImageBitmap", [src, asset?.data?.alphaMode]);
  }
  /**
   * Initializes the worker pool if not already initialized.
   * Currently a no-op but reserved for future initialization logic.
   */
  async _initWorkers() {
    if (this._initialized) return;
    this._initialized = true;
  }
  /**
   * Gets an available worker from the pool or creates a new one if needed.
   *
   * Workers are created up to the MAX_WORKERS limit (based on navigator.hardwareConcurrency).
   * Each worker is configured with a message handler for processing results.
   * @returns Available worker or undefined if pool is at capacity and no workers are free
   */
  _getWorker() {
    if (MAX_WORKERS === void 0) {
      MAX_WORKERS = navigator.hardwareConcurrency || 4;
    }
    let worker = this._workerPool.pop();
    if (!worker && this._createdWorkers < MAX_WORKERS) {
      this._createdWorkers++;
      worker = new loadImageBitmap_worker.default().worker;
      worker.addEventListener("message", (event) => {
        this._complete(event.data);
        this._returnWorker(event.target);
        this._next();
      });
    }
    return worker;
  }
  /**
   * Returns a worker to the pool after completing a task.
   * @param worker - The worker to return to the pool
   */
  _returnWorker(worker) {
    this._workerPool.push(worker);
  }
  /**
   * Handles completion of a worker task by resolving or rejecting the corresponding promise.
   * @param data - Result data from the worker containing uuid, data, and optional error
   */
  _complete(data) {
    if (!this._resolveHash[data.uuid]) {
      return;
    }
    if (data.error !== void 0) {
      this._resolveHash[data.uuid].reject(data.error);
    } else {
      this._resolveHash[data.uuid].resolve(data.data);
    }
    delete this._resolveHash[data.uuid];
  }
  /**
   * Executes a task using the worker pool system.
   *
   * Queues the task and processes it when a worker becomes available.
   * @param id - Identifier for the type of task to run
   * @param args - Arguments to pass to the worker
   * @returns Promise that resolves with the worker's result
   */
  async _run(id, args) {
    await this._initWorkers();
    const promise = new Promise((resolve, reject) => {
      this._queue.push({ id, arguments: args, resolve, reject });
    });
    this._next();
    return promise;
  }
  /**
   * Processes the next item in the queue if workers are available.
   *
   * This method is called after worker initialization and when workers
   * complete tasks to continue processing the queue.
   */
  _next() {
    if (!this._queue.length) return;
    const worker = this._getWorker();
    if (!worker) {
      return;
    }
    const toDo = this._queue.pop();
    const id = toDo.id;
    this._resolveHash[UUID] = { resolve: toDo.resolve, reject: toDo.reject };
    worker.postMessage({
      data: toDo.arguments,
      uuid: UUID++,
      id
    });
  }
  /**
   * Resets the worker manager, terminating all workers and clearing the queue.
   *
   * This method:
   * - Terminates all active workers
   * - Rejects all pending promises with an error
   * - Clears all internal state
   * - Resets initialization flags
   *
   * This should be called when the worker manager is no longer needed
   * to prevent memory leaks and ensure proper cleanup.
   * @example
   * ```typescript
   * // Clean up when shutting down
   * WorkerManager.reset();
   * ```
   */
  reset() {
    this._workerPool.forEach((worker) => worker.terminate());
    this._workerPool.length = 0;
    Object.values(this._resolveHash).forEach(({ reject }) => {
      reject?.(new Error("WorkerManager has been reset before completion"));
    });
    this._resolveHash = {};
    this._queue.length = 0;
    this._initialized = false;
    this._createdWorkers = 0;
  }
}
const WorkerManager = new WorkerManagerClass();

exports.WorkerManager = WorkerManager;
//# sourceMappingURL=WorkerManager.js.map
