'use strict';

"use strict";
class SystemRunner {
  /**
   * @param name - The function name that will be executed on the listeners added to this Runner.
   */
  constructor(name) {
    this.items = [];
    this._name = name;
  }
  /* jsdoc/check-param-names */
  /**
   * Dispatch/Broadcast Runner to all listeners added to the queue.
   * @param {...any} params - (optional) parameters to pass to each listener
   */
  /* jsdoc/check-param-names */
  emit(a0, a1, a2, a3, a4, a5, a6, a7) {
    const { name, items } = this;
    for (let i = 0, len = items.length; i < len; i++) {
      items[i][name](a0, a1, a2, a3, a4, a5, a6, a7);
    }
    return this;
  }
  /**
   * Add a listener to the Runner
   *
   * Runners do not need to have scope or functions passed to them.
   * All that is required is to pass the listening object and ensure that it has contains a function that has the same name
   * as the name provided to the Runner when it was created.
   *
   * Eg A listener passed to this Runner will require a 'complete' function.
   *
   * ```ts
   * import { Runner } from 'pixi.js';
   *
   * const complete = new Runner('complete');
   * ```
   *
   * The scope used will be the object itself.
   * @param {any} item - The object that will be listening.
   */
  add(item) {
    if (item[this._name]) {
      this.remove(item);
      this.items.push(item);
    }
    return this;
  }
  /**
   * Remove a single listener from the dispatch queue.
   * @param {any} item - The listener that you would like to remove.
   */
  remove(item) {
    const index = this.items.indexOf(item);
    if (index !== -1) {
      this.items.splice(index, 1);
    }
    return this;
  }
  /**
   * Check to see if the listener is already in the Runner
   * @param {any} item - The listener that you would like to check.
   */
  contains(item) {
    return this.items.indexOf(item) !== -1;
  }
  /** Remove all listeners from the Runner */
  removeAll() {
    this.items.length = 0;
    return this;
  }
  /** Remove all references, don't use after this. */
  destroy() {
    this.removeAll();
    this.items = null;
    this._name = null;
  }
  /**
   * `true` if there are no this Runner contains no listeners
   * @readonly
   */
  get empty() {
    return this.items.length === 0;
  }
  /**
   * The name of the runner.
   * @readonly
   */
  get name() {
    return this._name;
  }
}

exports.SystemRunner = SystemRunner;
//# sourceMappingURL=SystemRunner.js.map
