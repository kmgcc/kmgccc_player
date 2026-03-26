import { UPDATE_PRIORITY } from '../ticker/const.mjs';
import { Ticker } from '../ticker/Ticker.mjs';

"use strict";
class EventsTickerClass {
  constructor() {
    /** The frequency that fake events will be fired. */
    this.interactionFrequency = 10;
    this._deltaTime = 0;
    this._didMove = false;
    this._tickerAdded = false;
    this._pauseUpdate = true;
  }
  /**
   * Initializes the event ticker.
   * @param events - The event system.
   */
  init(events) {
    this.removeTickerListener();
    this.events = events;
    this.interactionFrequency = 10;
    this._deltaTime = 0;
    this._didMove = false;
    this._tickerAdded = false;
    this._pauseUpdate = true;
  }
  /** Whether to pause the update checks or not. */
  get pauseUpdate() {
    return this._pauseUpdate;
  }
  set pauseUpdate(paused) {
    this._pauseUpdate = paused;
  }
  /** Adds the ticker listener. */
  addTickerListener() {
    if (this._tickerAdded || !this.domElement) {
      return;
    }
    Ticker.system.add(this._tickerUpdate, this, UPDATE_PRIORITY.INTERACTION);
    this._tickerAdded = true;
  }
  /** Removes the ticker listener. */
  removeTickerListener() {
    if (!this._tickerAdded) {
      return;
    }
    Ticker.system.remove(this._tickerUpdate, this);
    this._tickerAdded = false;
  }
  /** Sets flag to not fire extra events when the user has already moved there mouse */
  pointerMoved() {
    this._didMove = true;
  }
  /** Updates the state of interactive objects. */
  _update() {
    if (!this.domElement || this._pauseUpdate) {
      return;
    }
    if (this._didMove) {
      this._didMove = false;
      return;
    }
    const rootPointerEvent = this.events["_rootPointerEvent"];
    if (this.events.supportsTouchEvents && rootPointerEvent.pointerType === "touch") {
      return;
    }
    globalThis.document.dispatchEvent(this.events.supportsPointerEvents ? new PointerEvent("pointermove", {
      clientX: rootPointerEvent.clientX,
      clientY: rootPointerEvent.clientY,
      pointerType: rootPointerEvent.pointerType,
      pointerId: rootPointerEvent.pointerId
    }) : new MouseEvent("mousemove", {
      clientX: rootPointerEvent.clientX,
      clientY: rootPointerEvent.clientY
    }));
  }
  /**
   * Updates the state of interactive objects if at least {@link interactionFrequency}
   * milliseconds have passed since the last invocation.
   *
   * Invoked by a throttled ticker update from {@link Ticker.system}.
   * @param ticker - The throttled ticker.
   */
  _tickerUpdate(ticker) {
    this._deltaTime += ticker.deltaTime;
    if (this._deltaTime < this.interactionFrequency) {
      return;
    }
    this._deltaTime = 0;
    this._update();
  }
  /** Destroys the event ticker. */
  destroy() {
    this.removeTickerListener();
    this.events = null;
    this.domElement = null;
    this._deltaTime = 0;
    this._didMove = false;
    this._tickerAdded = false;
    this._pauseUpdate = true;
  }
}
const EventsTicker = new EventsTickerClass();

export { EventsTicker };
//# sourceMappingURL=EventTicker.mjs.map
