'use strict';

"use strict";
class BackgroundLoader {
  /**
   * @param loader
   * @param verbose - should the loader log to the console
   */
  constructor(loader, verbose = false) {
    this._loader = loader;
    this._assetList = [];
    this._isLoading = false;
    this._maxConcurrent = 1;
    this.verbose = verbose;
  }
  /**
   * Adds assets to the background loading queue. Assets are loaded one at a time to minimize
   * performance impact.
   * @param assetUrls - Array of resolved assets to load in the background
   * @example
   * ```ts
   * // Add assets to background load queue
   * backgroundLoader.add([
   *     { src: 'images/level1/bg.png' },
   *     { src: 'images/level1/characters.json' }
   * ]);
   *
   * // Assets will load sequentially in the background
   * // The loader automatically pauses when high-priority loads occur
   * // e.g. Assets.load() is called
   * ```
   * @remarks
   * - Assets are loaded one at a time to minimize performance impact
   * - Loading automatically pauses when Assets.load() is called
   * - No progress tracking is available for background loading
   * - Assets are cached as they complete loading
   * @internal
   */
  add(assetUrls) {
    assetUrls.forEach((a) => {
      this._assetList.push(a);
    });
    if (this.verbose) {
      console.log("[BackgroundLoader] assets: ", this._assetList);
    }
    if (this._isActive && !this._isLoading) {
      void this._next();
    }
  }
  /**
   * Loads the next set of assets. Will try to load as many assets as it can at the same time.
   *
   * The max assets it will try to load at one time will be 4.
   */
  async _next() {
    if (this._assetList.length && this._isActive) {
      this._isLoading = true;
      const toLoad = [];
      const toLoadAmount = Math.min(this._assetList.length, this._maxConcurrent);
      for (let i = 0; i < toLoadAmount; i++) {
        toLoad.push(this._assetList.pop());
      }
      await this._loader.load(toLoad);
      this._isLoading = false;
      void this._next();
    }
  }
  /**
   * Controls the active state of the background loader. When active, the loader will
   * continue processing its queue. When inactive, loading is paused.
   * @returns Whether the background loader is currently active
   * @example
   * ```ts
   * // Pause background loading
   * backgroundLoader.active = false;
   *
   * // Resume background loading
   * backgroundLoader.active = true;
   *
   * // Check current state
   * console.log(backgroundLoader.active); // true/false
   *
   * // Common use case: Pause during intensive operations
   * backgroundLoader.active = false;  // Pause background loading
   * ... // Perform high-priority tasks
   * backgroundLoader.active = true;   // Resume background loading
   * ```
   * @remarks
   * - Setting to true resumes loading immediately
   * - Setting to false pauses after current asset completes
   * - Background loading is automatically paused during `Assets.load()`
   * - Assets already being loaded will complete even when set to false
   */
  get active() {
    return this._isActive;
  }
  set active(value) {
    if (this._isActive === value) return;
    this._isActive = value;
    if (value && !this._isLoading) {
      void this._next();
    }
  }
}

exports.BackgroundLoader = BackgroundLoader;
//# sourceMappingURL=BackgroundLoader.js.map
