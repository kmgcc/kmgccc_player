import { Point } from '../maths/point/Point.mjs';

"use strict";
class FederatedEvent {
  /**
   * @param manager - The event boundary which manages this event. Propagation can only occur
   *  within the boundary's jurisdiction.
   */
  constructor(manager) {
    /** Flags whether this event bubbles. This will take effect only if it is set before propagation. */
    this.bubbles = true;
    /** @deprecated since 7.0.0 */
    this.cancelBubble = true;
    /**
     * Flags whether this event can be canceled using {@link FederatedEvent.preventDefault}. This is always
     * false (for now).
     */
    this.cancelable = false;
    /**
     * Flag added for compatibility with DOM `Event`. It is not used in the Federated Events
     * API.
     * @see https://dom.spec.whatwg.org/#dom-event-composed
     * @ignore
     */
    this.composed = false;
    /** Flags whether the default response of the user agent was prevent through this event. */
    this.defaultPrevented = false;
    /**
     * The propagation phase.
     * @default {@link FederatedEvent.NONE}
     */
    this.eventPhase = FederatedEvent.prototype.NONE;
    /** Flags whether propagation was stopped. */
    this.propagationStopped = false;
    /** Flags whether propagation was immediately stopped. */
    this.propagationImmediatelyStopped = false;
    /** The coordinates of the event relative to the nearest DOM layer. This is a non-standard property. */
    this.layer = new Point();
    /** The coordinates of the event relative to the DOM document. This is a non-standard property. */
    this.page = new Point();
    /**
     * The event propagation phase NONE that indicates that the event is not in any phase.
     * @default 0
     * @advanced
     */
    this.NONE = 0;
    /**
     * The event propagation phase CAPTURING_PHASE that indicates that the event is in the capturing phase.
     * @default 1
     * @advanced
     */
    this.CAPTURING_PHASE = 1;
    /**
     * The event propagation phase AT_TARGET that indicates that the event is at the target.
     * @default 2
     * @advanced
     */
    this.AT_TARGET = 2;
    /**
     * The event propagation phase BUBBLING_PHASE that indicates that the event is in the bubbling phase.
     * @default 3
     * @advanced
     */
    this.BUBBLING_PHASE = 3;
    this.manager = manager;
  }
  /** @readonly */
  get layerX() {
    return this.layer.x;
  }
  /** @readonly */
  get layerY() {
    return this.layer.y;
  }
  /** @readonly */
  get pageX() {
    return this.page.x;
  }
  /** @readonly */
  get pageY() {
    return this.page.y;
  }
  /**
   * Fallback for the deprecated `InteractionEvent.data`.
   * @deprecated since 7.0.0
   */
  get data() {
    return this;
  }
  /**
   * The propagation path for this event. Alias for {@link EventBoundary.propagationPath}.
   * @advanced
   */
  composedPath() {
    if (this.manager && (!this.path || this.path[this.path.length - 1] !== this.target)) {
      this.path = this.target ? this.manager.propagationPath(this.target) : [];
    }
    return this.path;
  }
  /**
   * Unimplemented method included for implementing the DOM interface `Event`. It will throw an `Error`.
   * @deprecated
   * @ignore
   * @param _type
   * @param _bubbles
   * @param _cancelable
   */
  initEvent(_type, _bubbles, _cancelable) {
    throw new Error("initEvent() is a legacy DOM API. It is not implemented in the Federated Events API.");
  }
  /**
   * Unimplemented method included for implementing the DOM interface `UIEvent`. It will throw an `Error`.
   * @ignore
   * @deprecated
   * @param _typeArg
   * @param _bubblesArg
   * @param _cancelableArg
   * @param _viewArg
   * @param _detailArg
   */
  initUIEvent(_typeArg, _bubblesArg, _cancelableArg, _viewArg, _detailArg) {
    throw new Error("initUIEvent() is a legacy DOM API. It is not implemented in the Federated Events API.");
  }
  /**
   * Prevent default behavior of both PixiJS and the user agent.
   * @example
   * ```ts
   * sprite.on('click', (event) => {
   *     // Prevent both browser's default click behavior
   *     // and PixiJS's default handling
   *     event.preventDefault();
   *
   *     // Custom handling
   *     customClickHandler();
   * });
   * ```
   * @remarks
   * - Only works if the native event is cancelable
   * - Does not stop event propagation
   */
  preventDefault() {
    if (this.nativeEvent instanceof Event && this.nativeEvent.cancelable) {
      this.nativeEvent.preventDefault();
    }
    this.defaultPrevented = true;
  }
  /**
   * Stop this event from propagating to any additional listeners, including those
   * on the current target and any following targets in the propagation path.
   * @example
   * ```ts
   * container.on('pointerdown', (event) => {
   *     // Stop all further event handling
   *     event.stopImmediatePropagation();
   *
   *     // These handlers won't be called:
   *     // - Other pointerdown listeners on this container
   *     // - Any pointerdown listeners on parent containers
   * });
   * ```
   * @remarks
   * - Immediately stops all event propagation
   * - Prevents other listeners on same target from being called
   * - More aggressive than stopPropagation()
   */
  stopImmediatePropagation() {
    this.propagationImmediatelyStopped = true;
  }
  /**
   * Stop this event from propagating to the next target in the propagation path.
   * The rest of the listeners on the current target will still be notified.
   * @example
   * ```ts
   * child.on('pointermove', (event) => {
   *     // Handle event on child
   *     updateChild();
   *
   *     // Prevent parent handlers from being called
   *     event.stopPropagation();
   * });
   *
   * // This won't be called if child handles the event
   * parent.on('pointermove', (event) => {
   *     updateParent();
   * });
   * ```
   * @remarks
   * - Stops event bubbling to parent containers
   * - Does not prevent other listeners on same target
   * - Less aggressive than stopImmediatePropagation()
   */
  stopPropagation() {
    this.propagationStopped = true;
  }
}

export { FederatedEvent };
//# sourceMappingURL=FederatedEvent.mjs.map
