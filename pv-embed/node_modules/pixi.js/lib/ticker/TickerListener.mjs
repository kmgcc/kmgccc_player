"use strict";
class TickerListener {
  /**
   * Constructor
   * @private
   * @param fn - The listener function to be added for one update
   * @param context - The listener context
   * @param priority - The priority for emitting
   * @param once - If the handler should fire once
   */
  constructor(fn, context = null, priority = 0, once = false) {
    /** The next item in chain. */
    this.next = null;
    /** The previous item in chain. */
    this.previous = null;
    /** `true` if this listener has been destroyed already. */
    this._destroyed = false;
    this._fn = fn;
    this._context = context;
    this.priority = priority;
    this._once = once;
  }
  /**
   * Simple compare function to figure out if a function and context match.
   * @param fn - The listener function to be added for one update
   * @param context - The listener context
   * @returns `true` if the listener match the arguments
   */
  match(fn, context = null) {
    return this._fn === fn && this._context === context;
  }
  /**
   * Emit by calling the current function.
   * @param ticker - The ticker emitting.
   * @returns Next ticker
   */
  emit(ticker) {
    if (this._fn) {
      if (this._context) {
        this._fn.call(this._context, ticker);
      } else {
        this._fn(ticker);
      }
    }
    const redirect = this.next;
    if (this._once) {
      this.destroy(true);
    }
    if (this._destroyed) {
      this.next = null;
    }
    return redirect;
  }
  /**
   * Connect to the list.
   * @param previous - Input node, previous listener
   */
  connect(previous) {
    this.previous = previous;
    if (previous.next) {
      previous.next.previous = this;
    }
    this.next = previous.next;
    previous.next = this;
  }
  /**
   * Destroy and don't use after this.
   * @param hard - `true` to remove the `next` reference, this
   *        is considered a hard destroy. Soft destroy maintains the next reference.
   * @returns The listener to redirect while emitting or removing.
   */
  destroy(hard = false) {
    this._destroyed = true;
    this._fn = null;
    this._context = null;
    if (this.previous) {
      this.previous.next = this.next;
    }
    if (this.next) {
      this.next.previous = this.previous;
    }
    const redirect = this.next;
    this.next = hard ? null : redirect;
    this.previous = null;
    return redirect;
  }
}

export { TickerListener };
//# sourceMappingURL=TickerListener.mjs.map
