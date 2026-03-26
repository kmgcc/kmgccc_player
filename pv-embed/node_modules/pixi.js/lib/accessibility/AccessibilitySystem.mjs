import { CanvasObserver } from '../dom/CanvasObserver.mjs';
import { FederatedEvent } from '../events/FederatedEvent.mjs';
import { ExtensionType } from '../extensions/Extensions.mjs';
import { isMobile } from '../utils/browser/isMobile.mjs';
import { removeItems } from '../utils/data/removeItems.mjs';

"use strict";
const KEY_CODE_TAB = 9;
const DIV_TOUCH_SIZE = 100;
const DIV_TOUCH_POS_X = 0;
const DIV_TOUCH_POS_Y = 0;
const DIV_TOUCH_ZINDEX = 2;
const DIV_HOOK_SIZE = 1;
const DIV_HOOK_POS_X = -1e3;
const DIV_HOOK_POS_Y = -1e3;
const DIV_HOOK_ZINDEX = 2;
const _AccessibilitySystem = class _AccessibilitySystem {
  // eslint-disable-next-line jsdoc/require-param
  /**
   * @param {WebGLRenderer|WebGPURenderer} renderer - A reference to the current renderer
   */
  constructor(renderer, _mobileInfo = isMobile) {
    this._mobileInfo = _mobileInfo;
    /** Whether accessibility divs are visible for debugging */
    this.debug = false;
    /** Whether to activate on tab key press */
    this._activateOnTab = true;
    /** Whether to deactivate accessibility when mouse moves */
    this._deactivateOnMouseMove = true;
    /** Internal variable, see isActive getter. */
    this._isActive = false;
    /** Internal variable, see isMobileAccessibility getter. */
    this._isMobileAccessibility = false;
    /** This is the dom element that will sit over the PixiJS element. This is where the div overlays will go. */
    this._div = null;
    /** A simple pool for storing divs. */
    this._pools = {};
    /** This is a tick used to check if an object is no longer being rendered. */
    this._renderId = 0;
    /** The array of currently active accessible items. */
    this._children = [];
    /** Count to throttle div updates on android devices. */
    this._androidUpdateCount = 0;
    /**  The frequency to update the div elements. */
    this._androidUpdateFrequency = 500;
    // eslint-disable-next-line @typescript-eslint/prefer-readonly
    this._isRunningTests = false;
    /** Bound function references for proper event listener removal */
    this._boundOnKeyDown = this._onKeyDown.bind(this);
    this._boundOnMouseMove = this._onMouseMove.bind(this);
    this._hookDiv = null;
    if (_mobileInfo.tablet || _mobileInfo.phone) {
      this._createTouchHook();
    }
    this._renderer = renderer;
  }
  /**
   * Value of `true` if accessibility is currently active and accessibility layers are showing.
   * @type {boolean}
   * @readonly
   */
  get isActive() {
    return this._isActive;
  }
  /**
   * Value of `true` if accessibility is enabled for touch devices.
   * @type {boolean}
   * @readonly
   */
  get isMobileAccessibility() {
    return this._isMobileAccessibility;
  }
  /**
   * Button element for handling touch hooks.
   * @readonly
   */
  get hookDiv() {
    return this._hookDiv;
  }
  /**
   * The DOM element that will sit over the PixiJS element. This is where the div overlays will go.
   * @readonly
   */
  get div() {
    return this._div;
  }
  /**
   * Creates the touch hooks.
   * @private
   */
  _createTouchHook() {
    const hookDiv = document.createElement("button");
    hookDiv.style.width = `${DIV_HOOK_SIZE}px`;
    hookDiv.style.height = `${DIV_HOOK_SIZE}px`;
    hookDiv.style.position = "absolute";
    hookDiv.style.top = `${DIV_HOOK_POS_X}px`;
    hookDiv.style.left = `${DIV_HOOK_POS_Y}px`;
    hookDiv.style.zIndex = DIV_HOOK_ZINDEX.toString();
    hookDiv.style.backgroundColor = "#FF0000";
    hookDiv.title = "select to enable accessibility for this content";
    hookDiv.addEventListener("focus", () => {
      this._isMobileAccessibility = true;
      this._activate();
      this._destroyTouchHook();
    });
    document.body.appendChild(hookDiv);
    this._hookDiv = hookDiv;
  }
  /**
   * Destroys the touch hooks.
   * @private
   */
  _destroyTouchHook() {
    if (!this._hookDiv) {
      return;
    }
    document.body.removeChild(this._hookDiv);
    this._hookDiv = null;
  }
  /**
   * Activating will cause the Accessibility layer to be shown.
   * This is called when a user presses the tab key.
   * @private
   */
  _activate() {
    if (this._isActive) {
      return;
    }
    this._isActive = true;
    if (!this._div) {
      this._div = document.createElement("div");
      this._div.style.position = "absolute";
      this._div.style.top = `${DIV_TOUCH_POS_X}px`;
      this._div.style.left = `${DIV_TOUCH_POS_Y}px`;
      this._div.style.pointerEvents = "none";
      this._div.style.zIndex = DIV_TOUCH_ZINDEX.toString();
      this._canvasObserver = new CanvasObserver({
        domElement: this._div,
        renderer: this._renderer
      });
    }
    if (this._activateOnTab) {
      globalThis.addEventListener("keydown", this._boundOnKeyDown, false);
    }
    if (this._deactivateOnMouseMove) {
      globalThis.document.addEventListener("mousemove", this._boundOnMouseMove, true);
    }
    const canvas = this._renderer.view.canvas;
    if (!canvas.parentNode) {
      const observer = new MutationObserver(() => {
        if (canvas.parentNode) {
          observer.disconnect();
          this._canvasObserver.ensureAttached();
          this._initAccessibilitySetup();
        }
      });
      observer.observe(document.body, { childList: true, subtree: true });
    } else {
      this._canvasObserver.ensureAttached();
      this._initAccessibilitySetup();
    }
  }
  // New method to handle initialization after div is ready
  _initAccessibilitySetup() {
    this._renderer.runners.postrender.add(this);
    if (this._renderer.lastObjectRendered) {
      this._updateAccessibleObjects(this._renderer.lastObjectRendered);
    }
  }
  /**
   * Deactivates the accessibility system. Removes listeners and accessibility elements.
   * @private
   */
  _deactivate() {
    if (!this._isActive || this._isMobileAccessibility) {
      return;
    }
    this._isActive = false;
    globalThis.document.removeEventListener("mousemove", this._boundOnMouseMove, true);
    if (this._activateOnTab) {
      globalThis.addEventListener("keydown", this._boundOnKeyDown, false);
    }
    this._renderer.runners.postrender.remove(this);
    for (const child of this._children) {
      if (child._accessibleDiv?.parentNode) {
        child._accessibleDiv.parentNode.removeChild(child._accessibleDiv);
        child._accessibleDiv = null;
      }
      child._accessibleActive = false;
    }
    for (const accessibleType in this._pools) {
      const pool = this._pools[accessibleType];
      pool.forEach((div) => {
        if (div.parentNode) {
          div.parentNode.removeChild(div);
        }
      });
      delete this._pools[accessibleType];
    }
    if (this._div?.parentNode) {
      this._div.parentNode.removeChild(this._div);
    }
    this._pools = {};
    this._children = [];
  }
  /**
   * This recursive function will run through the scene graph and add any new accessible objects to the DOM layer.
   * @private
   * @param {Container} container - The Container to check.
   */
  _updateAccessibleObjects(container) {
    if (!container.visible || !container.accessibleChildren) {
      return;
    }
    if (container.accessible) {
      if (!container._accessibleActive) {
        this._addChild(container);
      }
      container._renderId = this._renderId;
    }
    const children = container.children;
    if (children) {
      for (let i = 0; i < children.length; i++) {
        this._updateAccessibleObjects(children[i]);
      }
    }
  }
  /**
   * Runner init called, view is available at this point.
   * @ignore
   */
  init(options) {
    const defaultOpts = _AccessibilitySystem.defaultOptions;
    const mergedOptions = {
      accessibilityOptions: {
        ...defaultOpts,
        ...options?.accessibilityOptions || {}
      }
    };
    this.debug = mergedOptions.accessibilityOptions.debug;
    this._activateOnTab = mergedOptions.accessibilityOptions.activateOnTab;
    this._deactivateOnMouseMove = mergedOptions.accessibilityOptions.deactivateOnMouseMove;
    if (mergedOptions.accessibilityOptions.enabledByDefault) {
      this._activate();
    }
    this._renderer.runners.postrender.remove(this);
  }
  /**
   * Updates the accessibility layer during rendering.
   * - Removes divs for containers no longer in the scene
   * - Updates the position and dimensions of the root div
   * - Updates positions of active accessibility divs
   * Only fires while the accessibility system is active.
   * @ignore
   */
  postrender() {
    const now = performance.now();
    if (this._mobileInfo.android.device && now < this._androidUpdateCount) {
      return;
    }
    this._androidUpdateCount = now + this._androidUpdateFrequency;
    if ((!this._renderer.renderingToScreen || !this._renderer.view.canvas) && !this._isRunningTests) {
      return;
    }
    const activeIds = /* @__PURE__ */ new Set();
    if (this._renderer.lastObjectRendered) {
      this._updateAccessibleObjects(this._renderer.lastObjectRendered);
      for (const child of this._children) {
        if (child._renderId === this._renderId) {
          activeIds.add(this._children.indexOf(child));
        }
      }
    }
    for (let i = this._children.length - 1; i >= 0; i--) {
      const child = this._children[i];
      if (!activeIds.has(i)) {
        if (child._accessibleDiv && child._accessibleDiv.parentNode) {
          child._accessibleDiv.parentNode.removeChild(child._accessibleDiv);
          const pool = this._getPool(child.accessibleType);
          pool.push(child._accessibleDiv);
          child._accessibleDiv = null;
        }
        child._accessibleActive = false;
        removeItems(this._children, i, 1);
      }
    }
    if (this._renderer.renderingToScreen) {
      this._canvasObserver.ensureAttached();
    }
    for (let i = 0; i < this._children.length; i++) {
      const child = this._children[i];
      if (!child._accessibleActive || !child._accessibleDiv) {
        continue;
      }
      const div = child._accessibleDiv;
      const hitArea = child.hitArea || child.getBounds().rectangle;
      if (child.hitArea) {
        const wt = child.worldTransform;
        div.style.left = `${wt.tx + hitArea.x * wt.a}px`;
        div.style.top = `${wt.ty + hitArea.y * wt.d}px`;
        div.style.width = `${hitArea.width * wt.a}px`;
        div.style.height = `${hitArea.height * wt.d}px`;
      } else {
        this._capHitArea(hitArea);
        div.style.left = `${hitArea.x}px`;
        div.style.top = `${hitArea.y}px`;
        div.style.width = `${hitArea.width}px`;
        div.style.height = `${hitArea.height}px`;
      }
    }
    this._renderId++;
  }
  /**
   * private function that will visually add the information to the
   * accessibility div
   * @param {HTMLElement} div -
   */
  _updateDebugHTML(div) {
    div.innerHTML = `type: ${div.type}</br> title : ${div.title}</br> tabIndex: ${div.tabIndex}`;
  }
  /**
   * Adjust the hit area based on the bounds of a display object
   * @param {Rectangle} hitArea - Bounds of the child
   */
  _capHitArea(hitArea) {
    if (hitArea.x < 0) {
      hitArea.width += hitArea.x;
      hitArea.x = 0;
    }
    if (hitArea.y < 0) {
      hitArea.height += hitArea.y;
      hitArea.y = 0;
    }
    const { width: viewWidth, height: viewHeight } = this._renderer;
    if (hitArea.x + hitArea.width > viewWidth) {
      hitArea.width = viewWidth - hitArea.x;
    }
    if (hitArea.y + hitArea.height > viewHeight) {
      hitArea.height = viewHeight - hitArea.y;
    }
  }
  /**
   * Creates or reuses a div element for a Container and adds it to the accessibility layer.
   * Sets up ARIA attributes, event listeners, and positioning based on the container's properties.
   * @private
   * @param {Container} container - The child to make accessible.
   */
  _addChild(container) {
    const pool = this._getPool(container.accessibleType);
    let div = pool.pop();
    if (div) {
      div.innerHTML = "";
      div.removeAttribute("title");
      div.removeAttribute("aria-label");
      div.tabIndex = 0;
    } else {
      if (container.accessibleType === "button") {
        div = document.createElement("button");
      } else {
        div = document.createElement(container.accessibleType);
        div.style.cssText = `
                        color: transparent;
                        pointer-events: none;
                        padding: 0;
                        margin: 0;
                        border: 0;
                        outline: 0;
                        background: transparent;
                        box-sizing: border-box;
                        user-select: none;
                        -webkit-user-select: none;
                        -moz-user-select: none;
                        -ms-user-select: none;
                    `;
        if (container.accessibleText) {
          div.innerText = container.accessibleText;
        }
      }
      div.style.width = `${DIV_TOUCH_SIZE}px`;
      div.style.height = `${DIV_TOUCH_SIZE}px`;
      div.style.backgroundColor = this.debug ? "rgba(255,255,255,0.5)" : "transparent";
      div.style.position = "absolute";
      div.style.zIndex = DIV_TOUCH_ZINDEX.toString();
      div.style.borderStyle = "none";
      if (navigator.userAgent.toLowerCase().includes("chrome")) {
        div.setAttribute("aria-live", "off");
      } else {
        div.setAttribute("aria-live", "polite");
      }
      if (navigator.userAgent.match(/rv:.*Gecko\//)) {
        div.setAttribute("aria-relevant", "additions");
      } else {
        div.setAttribute("aria-relevant", "text");
      }
      div.addEventListener("click", this._onClick.bind(this));
      div.addEventListener("focus", this._onFocus.bind(this));
      div.addEventListener("focusout", this._onFocusOut.bind(this));
    }
    div.style.pointerEvents = container.accessiblePointerEvents;
    div.type = container.accessibleType;
    if (container.accessibleTitle && container.accessibleTitle !== null) {
      div.title = container.accessibleTitle;
    } else if (!container.accessibleHint || container.accessibleHint === null) {
      div.title = `container ${container.tabIndex}`;
    }
    if (container.accessibleHint && container.accessibleHint !== null) {
      div.setAttribute("aria-label", container.accessibleHint);
    }
    if (container.interactive) {
      div.tabIndex = container.tabIndex;
    } else {
      div.tabIndex = 0;
    }
    if (this.debug) {
      this._updateDebugHTML(div);
    }
    container._accessibleActive = true;
    container._accessibleDiv = div;
    div.container = container;
    this._children.push(container);
    this._div.appendChild(container._accessibleDiv);
  }
  /**
   * Dispatch events with the EventSystem.
   * @param e
   * @param type
   * @private
   */
  _dispatchEvent(e, type) {
    const { container: target } = e.target;
    const boundary = this._renderer.events.rootBoundary;
    const event = Object.assign(new FederatedEvent(boundary), { target });
    boundary.rootTarget = this._renderer.lastObjectRendered;
    type.forEach((type2) => boundary.dispatchEvent(event, type2));
  }
  /**
   * Maps the div button press to pixi's EventSystem (click)
   * @private
   * @param {MouseEvent} e - The click event.
   */
  _onClick(e) {
    this._dispatchEvent(e, ["click", "pointertap", "tap"]);
  }
  /**
   * Maps the div focus events to pixi's EventSystem (mouseover)
   * @private
   * @param {FocusEvent} e - The focus event.
   */
  _onFocus(e) {
    if (!e.target.getAttribute("aria-live")) {
      e.target.setAttribute("aria-live", "assertive");
    }
    this._dispatchEvent(e, ["mouseover"]);
  }
  /**
   * Maps the div focus events to pixi's EventSystem (mouseout)
   * @private
   * @param {FocusEvent} e - The focusout event.
   */
  _onFocusOut(e) {
    if (!e.target.getAttribute("aria-live")) {
      e.target.setAttribute("aria-live", "polite");
    }
    this._dispatchEvent(e, ["mouseout"]);
  }
  /**
   * Is called when a key is pressed
   * @private
   * @param {KeyboardEvent} e - The keydown event.
   */
  _onKeyDown(e) {
    if (e.keyCode !== KEY_CODE_TAB || !this._activateOnTab) {
      return;
    }
    this._activate();
  }
  /**
   * Is called when the mouse moves across the renderer element
   * @private
   * @param {MouseEvent} e - The mouse event.
   */
  _onMouseMove(e) {
    if (e.movementX === 0 && e.movementY === 0) {
      return;
    }
    this._deactivate();
  }
  /**
   * Destroys the accessibility system. Removes all elements and listeners.
   * > [!IMPORTANT] This is typically called automatically when the {@link Application} is destroyed.
   * > A typically user should not need to call this method directly.
   */
  destroy() {
    this._deactivate();
    this._destroyTouchHook();
    this._canvasObserver?.destroy();
    this._canvasObserver = null;
    this._div = null;
    this._pools = null;
    this._children = null;
    this._renderer = null;
    this._hookDiv = null;
    globalThis.removeEventListener("keydown", this._boundOnKeyDown);
    this._boundOnKeyDown = null;
    globalThis.document.removeEventListener("mousemove", this._boundOnMouseMove, true);
    this._boundOnMouseMove = null;
  }
  /**
   * Enables or disables the accessibility system.
   * @param enabled - Whether to enable or disable accessibility.
   * @example
   * ```js
   * app.renderer.accessibility.setAccessibilityEnabled(true); // Enable accessibility
   * app.renderer.accessibility.setAccessibilityEnabled(false); // Disable accessibility
   * ```
   */
  setAccessibilityEnabled(enabled) {
    if (enabled) {
      this._activate();
    } else {
      this._deactivate();
    }
  }
  _getPool(accessibleType) {
    if (!this._pools[accessibleType]) {
      this._pools[accessibleType] = [];
    }
    return this._pools[accessibleType];
  }
};
/** @ignore */
_AccessibilitySystem.extension = {
  type: [
    ExtensionType.WebGLSystem,
    ExtensionType.WebGPUSystem
  ],
  name: "accessibility"
};
/**
 * The default options used by the system.
 * You can set these before initializing the {@link Application} to change the default behavior.
 * @example
 * ```js
 * import { AccessibilitySystem } from 'pixi.js';
 *
 * AccessibilitySystem.defaultOptions.enabledByDefault = true;
 *
 * const app = new Application()
 * app.init()
 * ```
 */
_AccessibilitySystem.defaultOptions = {
  /**
   * Whether to enable accessibility features on initialization
   * @default false
   */
  enabledByDefault: false,
  /**
   * Whether to visually show the accessibility divs for debugging
   * @default false
   */
  debug: false,
  /**
   * Whether to activate accessibility when tab key is pressed
   * @default true
   */
  activateOnTab: true,
  /**
   * Whether to deactivate accessibility when mouse moves
   * @default true
   */
  deactivateOnMouseMove: true
};
let AccessibilitySystem = _AccessibilitySystem;

export { AccessibilitySystem };
//# sourceMappingURL=AccessibilitySystem.mjs.map
