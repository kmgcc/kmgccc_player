import { ExtensionType } from '../extensions/Extensions.mjs';
import { EventBoundary } from './EventBoundary.mjs';
import { EventsTicker } from './EventTicker.mjs';
import { FederatedPointerEvent } from './FederatedPointerEvent.mjs';
import { FederatedWheelEvent } from './FederatedWheelEvent.mjs';

"use strict";
const MOUSE_POINTER_ID = 1;
const TOUCH_TO_POINTER = {
  touchstart: "pointerdown",
  touchend: "pointerup",
  touchendoutside: "pointerupoutside",
  touchmove: "pointermove",
  touchcancel: "pointercancel"
};
const _EventSystem = class _EventSystem {
  /**
   * @param {Renderer} renderer
   */
  constructor(renderer) {
    /**
     * Indicates whether the current device supports touch events according to the W3C Touch Events spec.
     * This is used to determine the appropriate event handling strategy.
     * @see {@link https://www.w3.org/TR/touch-events/} W3C Touch Events Specification
     * @readonly
     * @default 'ontouchstart' in globalThis
     */
    this.supportsTouchEvents = "ontouchstart" in globalThis;
    /**
     * Indicates whether the current device supports pointer events according to the W3C Pointer Events spec.
     * Used to optimize event handling and provide more consistent cross-device interaction.
     * @see {@link https://www.w3.org/TR/pointerevents/} W3C Pointer Events Specification
     * @readonly
     * @default !!globalThis.PointerEvent
     */
    this.supportsPointerEvents = !!globalThis.PointerEvent;
    /**
     * The DOM element to which the root event listeners are bound. This is automatically set to
     * the renderer's {@link Renderer#view view}.
     */
    this.domElement = null;
    /** The resolution used to convert between the DOM client space into world space. */
    this.resolution = 1;
    this.renderer = renderer;
    this.rootBoundary = new EventBoundary(null);
    EventsTicker.init(this);
    this.autoPreventDefault = true;
    this._eventsAdded = false;
    this._rootPointerEvent = new FederatedPointerEvent(null);
    this._rootWheelEvent = new FederatedWheelEvent(null);
    this.cursorStyles = {
      default: "inherit",
      pointer: "pointer"
    };
    this.features = new Proxy({ ..._EventSystem.defaultEventFeatures }, {
      set: (target, key, value) => {
        if (key === "globalMove") {
          this.rootBoundary.enableGlobalMoveEvents = value;
        }
        target[key] = value;
        return true;
      }
    });
    this._onPointerDown = this._onPointerDown.bind(this);
    this._onPointerMove = this._onPointerMove.bind(this);
    this._onPointerUp = this._onPointerUp.bind(this);
    this._onPointerOverOut = this._onPointerOverOut.bind(this);
    this.onWheel = this.onWheel.bind(this);
  }
  /**
   * The default interaction mode for all display objects.
   * @see Container.eventMode
   * @type {EventMode}
   * @readonly
   * @since 7.2.0
   */
  static get defaultEventMode() {
    return this._defaultEventMode;
  }
  /**
   * Runner init called, view is available at this point.
   * @ignore
   */
  init(options) {
    const { canvas, resolution } = this.renderer;
    this.setTargetElement(canvas);
    this.resolution = resolution;
    _EventSystem._defaultEventMode = options.eventMode ?? "passive";
    Object.assign(this.features, options.eventFeatures ?? {});
    this.rootBoundary.enableGlobalMoveEvents = this.features.globalMove;
  }
  /**
   * Handle changing resolution.
   * @ignore
   */
  resolutionChange(resolution) {
    this.resolution = resolution;
  }
  /** Destroys all event listeners and detaches the renderer. */
  destroy() {
    EventsTicker.destroy();
    this.setTargetElement(null);
    this.renderer = null;
    this._currentCursor = null;
  }
  /**
   * Sets the current cursor mode, handling any callbacks or CSS style changes.
   * The cursor can be a CSS cursor string, a custom callback function, or a key from the cursorStyles dictionary.
   * @param mode - Cursor mode to set. Can be:
   * - A CSS cursor string (e.g., 'pointer', 'grab')
   * - A key from the cursorStyles dictionary
   * - null/undefined to reset to default
   * @example
   * ```ts
   * // Using predefined cursor styles
   * app.renderer.events.setCursor('pointer');    // Set standard pointer cursor
   * app.renderer.events.setCursor('grab');       // Set grab cursor
   * app.renderer.events.setCursor(null);         // Reset to default
   *
   * // Using custom cursor styles
   * app.renderer.events.cursorStyles.custom = 'url("cursor.png"), auto';
   * app.renderer.events.setCursor('custom');     // Apply custom cursor
   *
   * // Using callback-based cursor
   * app.renderer.events.cursorStyles.dynamic = (mode) => {
   *     document.body.style.cursor = mode === 'hover' ? 'pointer' : 'default';
   * };
   * app.renderer.events.setCursor('dynamic');    // Trigger cursor callback
   * ```
   * @remarks
   * - Has no effect on OffscreenCanvas except for callback-based cursors
   * - Caches current cursor to avoid unnecessary DOM updates
   * - Supports CSS cursor values, style objects, and callback functions
   * @see {@link EventSystem.cursorStyles} For defining custom cursor styles
   * @see {@link https://developer.mozilla.org/en-US/docs/Web/CSS/cursor} MDN Cursor Reference
   */
  setCursor(mode) {
    mode || (mode = "default");
    let applyStyles = true;
    if (globalThis.OffscreenCanvas && this.domElement instanceof OffscreenCanvas) {
      applyStyles = false;
    }
    if (this._currentCursor === mode) {
      return;
    }
    this._currentCursor = mode;
    const style = this.cursorStyles[mode];
    if (style) {
      switch (typeof style) {
        case "string":
          if (applyStyles) {
            this.domElement.style.cursor = style;
          }
          break;
        case "function":
          style(mode);
          break;
        case "object":
          if (applyStyles) {
            Object.assign(this.domElement.style, style);
          }
          break;
      }
    } else if (applyStyles && typeof mode === "string" && !Object.prototype.hasOwnProperty.call(this.cursorStyles, mode)) {
      this.domElement.style.cursor = mode;
    }
  }
  /**
   * The global pointer event instance containing the most recent pointer state.
   * This is useful for accessing pointer information without listening to events.
   * @example
   * ```ts
   * // Access current pointer position at any time
   * const eventSystem = app.renderer.events;
   * const pointer = eventSystem.pointer;
   *
   * // Get global coordinates
   * console.log('Position:', pointer.global.x, pointer.global.y);
   *
   * // Check button state
   * console.log('Buttons pressed:', pointer.buttons);
   *
   * // Get pointer type and pressure
   * console.log('Type:', pointer.pointerType);
   * console.log('Pressure:', pointer.pressure);
   * ```
   * @readonly
   * @since 7.2.0
   * @see {@link FederatedPointerEvent} For all available pointer properties
   */
  get pointer() {
    return this._rootPointerEvent;
  }
  /**
   * Event handler for pointer down events on {@link EventSystem#domElement this.domElement}.
   * @param nativeEvent - The native mouse/pointer/touch event.
   */
  _onPointerDown(nativeEvent) {
    if (!this.features.click) return;
    this.rootBoundary.rootTarget = this.renderer.lastObjectRendered;
    const events = this._normalizeToPointerData(nativeEvent);
    if (this.autoPreventDefault && events[0].isNormalized) {
      const cancelable = nativeEvent.cancelable || !("cancelable" in nativeEvent);
      if (cancelable) {
        nativeEvent.preventDefault();
      }
    }
    for (let i = 0, j = events.length; i < j; i++) {
      const nativeEvent2 = events[i];
      const federatedEvent = this._bootstrapEvent(this._rootPointerEvent, nativeEvent2);
      this.rootBoundary.mapEvent(federatedEvent);
    }
    this.setCursor(this.rootBoundary.cursor);
  }
  /**
   * Event handler for pointer move events on on {@link EventSystem#domElement this.domElement}.
   * @param nativeEvent - The native mouse/pointer/touch events.
   */
  _onPointerMove(nativeEvent) {
    if (!this.features.move) return;
    this.rootBoundary.rootTarget = this.renderer.lastObjectRendered;
    EventsTicker.pointerMoved();
    const normalizedEvents = this._normalizeToPointerData(nativeEvent);
    for (let i = 0, j = normalizedEvents.length; i < j; i++) {
      const event = this._bootstrapEvent(this._rootPointerEvent, normalizedEvents[i]);
      this.rootBoundary.mapEvent(event);
    }
    this.setCursor(this.rootBoundary.cursor);
  }
  /**
   * Event handler for pointer up events on {@link EventSystem#domElement this.domElement}.
   * @param nativeEvent - The native mouse/pointer/touch event.
   */
  _onPointerUp(nativeEvent) {
    if (!this.features.click) return;
    this.rootBoundary.rootTarget = this.renderer.lastObjectRendered;
    let target = nativeEvent.target;
    if (nativeEvent.composedPath && nativeEvent.composedPath().length > 0) {
      target = nativeEvent.composedPath()[0];
    }
    const outside = target !== this.domElement ? "outside" : "";
    const normalizedEvents = this._normalizeToPointerData(nativeEvent);
    for (let i = 0, j = normalizedEvents.length; i < j; i++) {
      const event = this._bootstrapEvent(this._rootPointerEvent, normalizedEvents[i]);
      event.type += outside;
      this.rootBoundary.mapEvent(event);
    }
    this.setCursor(this.rootBoundary.cursor);
  }
  /**
   * Event handler for pointer over & out events on {@link EventSystem#domElement this.domElement}.
   * @param nativeEvent - The native mouse/pointer/touch event.
   */
  _onPointerOverOut(nativeEvent) {
    if (!this.features.click) return;
    this.rootBoundary.rootTarget = this.renderer.lastObjectRendered;
    const normalizedEvents = this._normalizeToPointerData(nativeEvent);
    for (let i = 0, j = normalizedEvents.length; i < j; i++) {
      const event = this._bootstrapEvent(this._rootPointerEvent, normalizedEvents[i]);
      this.rootBoundary.mapEvent(event);
    }
    this.setCursor(this.rootBoundary.cursor);
  }
  /**
   * Passive handler for `wheel` events on {@link EventSystem.domElement this.domElement}.
   * @param nativeEvent - The native wheel event.
   */
  onWheel(nativeEvent) {
    if (!this.features.wheel) return;
    const wheelEvent = this.normalizeWheelEvent(nativeEvent);
    this.rootBoundary.rootTarget = this.renderer.lastObjectRendered;
    this.rootBoundary.mapEvent(wheelEvent);
  }
  /**
   * Sets the {@link EventSystem#domElement domElement} and binds event listeners.
   * This method manages the DOM event bindings for the event system, allowing you to
   * change or remove the target element that receives input events.
   * > [!IMPORTANT] This will default to the canvas element of the renderer, so you
   * > should not need to call this unless you are using a custom element.
   * @param element - The new DOM element to bind events to, or null to remove all event bindings
   * @example
   * ```ts
   * // Set a new canvas element as the target
   * const canvas = document.createElement('canvas');
   * app.renderer.events.setTargetElement(canvas);
   *
   * // Remove all event bindings
   * app.renderer.events.setTargetElement(null);
   *
   * // Switch to a different canvas
   * const newCanvas = document.querySelector('#game-canvas');
   * app.renderer.events.setTargetElement(newCanvas);
   * ```
   * @remarks
   * - Automatically removes event listeners from previous element
   * - Required for the event system to function
   * - Safe to call multiple times
   * @see {@link EventSystem#domElement} The current DOM element
   * @see {@link EventsTicker} For the ticker system that tracks pointer movement
   */
  setTargetElement(element) {
    this._removeEvents();
    this.domElement = element;
    EventsTicker.domElement = element;
    this._addEvents();
  }
  /** Register event listeners on {@link Renderer#domElement this.domElement}. */
  _addEvents() {
    if (this._eventsAdded || !this.domElement) {
      return;
    }
    EventsTicker.addTickerListener();
    const style = this.domElement.style;
    if (style) {
      if (globalThis.navigator.msPointerEnabled) {
        style.msContentZooming = "none";
        style.msTouchAction = "none";
      } else if (this.supportsPointerEvents) {
        style.touchAction = "none";
      }
    }
    if (this.supportsPointerEvents) {
      globalThis.document.addEventListener("pointermove", this._onPointerMove, true);
      this.domElement.addEventListener("pointerdown", this._onPointerDown, true);
      this.domElement.addEventListener("pointerleave", this._onPointerOverOut, true);
      this.domElement.addEventListener("pointerover", this._onPointerOverOut, true);
      globalThis.addEventListener("pointerup", this._onPointerUp, true);
    } else {
      globalThis.document.addEventListener("mousemove", this._onPointerMove, true);
      this.domElement.addEventListener("mousedown", this._onPointerDown, true);
      this.domElement.addEventListener("mouseout", this._onPointerOverOut, true);
      this.domElement.addEventListener("mouseover", this._onPointerOverOut, true);
      globalThis.addEventListener("mouseup", this._onPointerUp, true);
      if (this.supportsTouchEvents) {
        this.domElement.addEventListener("touchstart", this._onPointerDown, true);
        this.domElement.addEventListener("touchend", this._onPointerUp, true);
        this.domElement.addEventListener("touchmove", this._onPointerMove, true);
      }
    }
    this.domElement.addEventListener("wheel", this.onWheel, {
      passive: true,
      capture: true
    });
    this._eventsAdded = true;
  }
  /** Unregister event listeners on {@link EventSystem#domElement this.domElement}. */
  _removeEvents() {
    if (!this._eventsAdded || !this.domElement) {
      return;
    }
    EventsTicker.removeTickerListener();
    const style = this.domElement.style;
    if (style) {
      if (globalThis.navigator.msPointerEnabled) {
        style.msContentZooming = "";
        style.msTouchAction = "";
      } else if (this.supportsPointerEvents) {
        style.touchAction = "";
      }
    }
    if (this.supportsPointerEvents) {
      globalThis.document.removeEventListener("pointermove", this._onPointerMove, true);
      this.domElement.removeEventListener("pointerdown", this._onPointerDown, true);
      this.domElement.removeEventListener("pointerleave", this._onPointerOverOut, true);
      this.domElement.removeEventListener("pointerover", this._onPointerOverOut, true);
      globalThis.removeEventListener("pointerup", this._onPointerUp, true);
    } else {
      globalThis.document.removeEventListener("mousemove", this._onPointerMove, true);
      this.domElement.removeEventListener("mousedown", this._onPointerDown, true);
      this.domElement.removeEventListener("mouseout", this._onPointerOverOut, true);
      this.domElement.removeEventListener("mouseover", this._onPointerOverOut, true);
      globalThis.removeEventListener("mouseup", this._onPointerUp, true);
      if (this.supportsTouchEvents) {
        this.domElement.removeEventListener("touchstart", this._onPointerDown, true);
        this.domElement.removeEventListener("touchend", this._onPointerUp, true);
        this.domElement.removeEventListener("touchmove", this._onPointerMove, true);
      }
    }
    this.domElement.removeEventListener("wheel", this.onWheel, true);
    this.domElement = null;
    this._eventsAdded = false;
  }
  /**
   * Maps coordinates from DOM/screen space into PixiJS normalized coordinates.
   * This takes into account the current scale, position, and resolution of the DOM element.
   * @param point - The point to store the mapped coordinates in
   * @param x - The x coordinate in DOM/client space
   * @param y - The y coordinate in DOM/client space
   * @example
   * ```ts
   * // Map mouse coordinates to PixiJS space
   * const point = new Point();
   * app.renderer.events.mapPositionToPoint(
   *     point,
   *     event.clientX,
   *     event.clientY
   * );
   * console.log('Mapped position:', point.x, point.y);
   *
   * // Using with pointer events
   * sprite.on('pointermove', (event) => {
   *     // event.global already contains mapped coordinates
   *     console.log('Global:', event.global.x, event.global.y);
   *
   *     // Map to local coordinates
   *     const local = event.getLocalPosition(sprite);
   *     console.log('Local:', local.x, local.y);
   * });
   * ```
   * @remarks
   * - Accounts for element scaling and positioning
   * - Adjusts for device pixel ratio/resolution
   */
  mapPositionToPoint(point, x, y) {
    const rect = this.domElement.isConnected ? this.domElement.getBoundingClientRect() : {
      x: 0,
      y: 0,
      width: this.domElement.width,
      height: this.domElement.height,
      left: 0,
      top: 0
    };
    const resolutionMultiplier = 1 / this.resolution;
    point.x = (x - rect.left) * (this.domElement.width / rect.width) * resolutionMultiplier;
    point.y = (y - rect.top) * (this.domElement.height / rect.height) * resolutionMultiplier;
  }
  /**
   * Ensures that the original event object contains all data that a regular pointer event would have
   * @param event - The original event data from a touch or mouse event
   * @returns An array containing a single normalized pointer event, in the case of a pointer
   *  or mouse event, or a multiple normalized pointer events if there are multiple changed touches
   */
  _normalizeToPointerData(event) {
    const normalizedEvents = [];
    if (this.supportsTouchEvents && event instanceof TouchEvent) {
      for (let i = 0, li = event.changedTouches.length; i < li; i++) {
        const touch = event.changedTouches[i];
        if (typeof touch.button === "undefined") touch.button = 0;
        if (typeof touch.buttons === "undefined") touch.buttons = 1;
        if (typeof touch.isPrimary === "undefined") {
          touch.isPrimary = event.touches.length === 1 && event.type === "touchstart";
        }
        if (typeof touch.width === "undefined") touch.width = touch.radiusX || 1;
        if (typeof touch.height === "undefined") touch.height = touch.radiusY || 1;
        if (typeof touch.tiltX === "undefined") touch.tiltX = 0;
        if (typeof touch.tiltY === "undefined") touch.tiltY = 0;
        if (typeof touch.pointerType === "undefined") touch.pointerType = "touch";
        if (typeof touch.pointerId === "undefined") touch.pointerId = touch.identifier || 0;
        if (typeof touch.pressure === "undefined") touch.pressure = touch.force || 0.5;
        if (typeof touch.twist === "undefined") touch.twist = 0;
        if (typeof touch.tangentialPressure === "undefined") touch.tangentialPressure = 0;
        if (typeof touch.layerX === "undefined") touch.layerX = touch.offsetX = touch.clientX;
        if (typeof touch.layerY === "undefined") touch.layerY = touch.offsetY = touch.clientY;
        touch.isNormalized = true;
        touch.type = event.type;
        touch.altKey ?? (touch.altKey = event.altKey);
        touch.ctrlKey ?? (touch.ctrlKey = event.ctrlKey);
        touch.metaKey ?? (touch.metaKey = event.metaKey);
        touch.shiftKey ?? (touch.shiftKey = event.shiftKey);
        normalizedEvents.push(touch);
      }
    } else if (!globalThis.MouseEvent || event instanceof MouseEvent && (!this.supportsPointerEvents || !(event instanceof globalThis.PointerEvent))) {
      const tempEvent = event;
      if (typeof tempEvent.isPrimary === "undefined") tempEvent.isPrimary = true;
      if (typeof tempEvent.width === "undefined") tempEvent.width = 1;
      if (typeof tempEvent.height === "undefined") tempEvent.height = 1;
      if (typeof tempEvent.tiltX === "undefined") tempEvent.tiltX = 0;
      if (typeof tempEvent.tiltY === "undefined") tempEvent.tiltY = 0;
      if (typeof tempEvent.pointerType === "undefined") tempEvent.pointerType = "mouse";
      if (typeof tempEvent.pointerId === "undefined") tempEvent.pointerId = MOUSE_POINTER_ID;
      if (typeof tempEvent.pressure === "undefined") tempEvent.pressure = 0.5;
      if (typeof tempEvent.twist === "undefined") tempEvent.twist = 0;
      if (typeof tempEvent.tangentialPressure === "undefined") tempEvent.tangentialPressure = 0;
      tempEvent.isNormalized = true;
      normalizedEvents.push(tempEvent);
    } else {
      normalizedEvents.push(event);
    }
    return normalizedEvents;
  }
  /**
   * Normalizes the native {@link https://w3c.github.io/uievents/#interface-wheelevent WheelEvent}.
   *
   * The returned {@link FederatedWheelEvent} is a shared instance. It will not persist across
   * multiple native wheel events.
   * @param nativeEvent - The native wheel event that occurred on the canvas.
   * @returns A federated wheel event.
   */
  normalizeWheelEvent(nativeEvent) {
    const event = this._rootWheelEvent;
    this._transferMouseData(event, nativeEvent);
    event.deltaX = nativeEvent.deltaX;
    event.deltaY = nativeEvent.deltaY;
    event.deltaZ = nativeEvent.deltaZ;
    event.deltaMode = nativeEvent.deltaMode;
    this.mapPositionToPoint(event.screen, nativeEvent.clientX, nativeEvent.clientY);
    event.global.copyFrom(event.screen);
    event.offset.copyFrom(event.screen);
    event.nativeEvent = nativeEvent;
    event.type = nativeEvent.type;
    return event;
  }
  /**
   * Normalizes the `nativeEvent` into a federateed {@link FederatedPointerEvent}.
   * @param event
   * @param nativeEvent
   */
  _bootstrapEvent(event, nativeEvent) {
    event.originalEvent = null;
    event.nativeEvent = nativeEvent;
    event.pointerId = nativeEvent.pointerId;
    event.width = nativeEvent.width;
    event.height = nativeEvent.height;
    event.isPrimary = nativeEvent.isPrimary;
    event.pointerType = nativeEvent.pointerType;
    event.pressure = nativeEvent.pressure;
    event.tangentialPressure = nativeEvent.tangentialPressure;
    event.tiltX = nativeEvent.tiltX;
    event.tiltY = nativeEvent.tiltY;
    event.twist = nativeEvent.twist;
    this._transferMouseData(event, nativeEvent);
    this.mapPositionToPoint(event.screen, nativeEvent.clientX, nativeEvent.clientY);
    event.global.copyFrom(event.screen);
    event.offset.copyFrom(event.screen);
    event.isTrusted = nativeEvent.isTrusted;
    if (event.type === "pointerleave") {
      event.type = "pointerout";
    }
    if (event.type.startsWith("mouse")) {
      event.type = event.type.replace("mouse", "pointer");
    }
    if (event.type.startsWith("touch")) {
      event.type = TOUCH_TO_POINTER[event.type] || event.type;
    }
    return event;
  }
  /**
   * Transfers base & mouse event data from the `nativeEvent` to the federated event.
   * @param event
   * @param nativeEvent
   */
  _transferMouseData(event, nativeEvent) {
    event.isTrusted = nativeEvent.isTrusted;
    event.srcElement = nativeEvent.srcElement;
    event.timeStamp = performance.now();
    event.type = nativeEvent.type;
    event.altKey = nativeEvent.altKey;
    event.button = nativeEvent.button;
    event.buttons = nativeEvent.buttons;
    event.client.x = nativeEvent.clientX;
    event.client.y = nativeEvent.clientY;
    event.ctrlKey = nativeEvent.ctrlKey;
    event.metaKey = nativeEvent.metaKey;
    event.movement.x = nativeEvent.movementX;
    event.movement.y = nativeEvent.movementY;
    event.page.x = nativeEvent.pageX;
    event.page.y = nativeEvent.pageY;
    event.relatedTarget = null;
    event.shiftKey = nativeEvent.shiftKey;
  }
};
/** @ignore */
_EventSystem.extension = {
  name: "events",
  type: [
    ExtensionType.WebGLSystem,
    ExtensionType.CanvasSystem,
    ExtensionType.WebGPUSystem
  ],
  priority: -1
};
/**
 * The event features that are enabled by the EventSystem
 * @since 7.2.0
 * @example
 * ```ts
 * import { EventSystem, EventSystemFeatures } from 'pixi.js';
 * // Access the default event features
 * EventSystem.defaultEventFeatures = {
 *     // Enable pointer movement events
 *     move: true,
 *     // Enable global pointer move events
 *     globalMove: true,
 *     // Enable click events
 *     click: true,
 *     // Enable wheel events
 *     wheel: true,
 * };
 * ```
 */
_EventSystem.defaultEventFeatures = {
  /** Enables pointer events associated with pointer movement. */
  move: true,
  /** Enables global pointer move events. */
  globalMove: true,
  /** Enables pointer events associated with clicking. */
  click: true,
  /** Enables wheel events. */
  wheel: true
};
let EventSystem = _EventSystem;

export { EventSystem };
//# sourceMappingURL=EventSystem.mjs.map
