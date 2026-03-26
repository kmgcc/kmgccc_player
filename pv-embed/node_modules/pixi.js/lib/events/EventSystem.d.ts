import { EventBoundary } from './EventBoundary';
import { FederatedPointerEvent } from './FederatedPointerEvent';
import { FederatedWheelEvent } from './FederatedWheelEvent';
import type { ExtensionMetadata } from '../extensions/Extensions';
import type { PointData } from '../maths/point/PointData';
import type { System } from '../rendering/renderers/shared/system/System';
import type { Renderer } from '../rendering/renderers/types';
import type { EventMode } from './FederatedEventTarget';
/**
 * Options for configuring the PixiJS event system. These options control how the event system
 * handles different types of interactions and event propagation.
 * @example
 * ```ts
 * // Basic event system configuration
 * const app = new Application();
 * await app.init({
 *     // Configure default interaction mode
 *     eventMode: 'static',
 *
 *     // Configure event features
 *     eventFeatures: {
 *         move: true,           // Enable pointer movement events
 *         globalMove: false,    // Disable global move events
 *         click: true,          // Enable click events
 *         wheel: true          // Enable wheel/scroll events
 *     }
 * });
 *
 * // Access event system after initialization
 * const eventSystem = app.renderer.events;
 * console.log(eventSystem.features); // Check enabled features
 * ```
 * @see {@link EventSystem} For the main event system implementation
 * @see {@link EventMode} For interaction mode details
 * @see {@link EventSystemFeatures} For all available feature options
 * @advanced
 * @category events
 */
export interface EventSystemOptions {
    /**
     * The default event mode for all display objects.
     * Controls how objects respond to interaction events.
     *
     * Possible values:
     * - `'none'`: No interaction events
     * - `'passive'`: Only container's children receive events (default)
     * - `'auto'`: Receives events when parent is interactive
     * - `'static'`: Standard interaction events
     * - `'dynamic'`: Like static but with additional synthetic events
     * @default 'passive'
     */
    eventMode?: EventMode;
    /**
     * Configuration for enabling/disabling specific event features.
     * Use this to optimize performance by turning off unused functionality.
     * @example
     * ```ts
     * const app = new Application();
     * await app.init({
     *     eventFeatures: {
     *         // Core interaction events
     *         move: true,        // Pointer/mouse/touch movement
     *         click: true,       // Click/tap events
     *         wheel: true,       // Mouse wheel/scroll events
     *         // Global tracking
     *         globalMove: false  // Global pointer movement
     *     }
     * });
     * ```
     */
    eventFeatures?: Partial<EventSystemFeatures>;
}
/**
 * The event features that are enabled by the EventSystem. These features control
 * different types of interaction events in your PixiJS application.
 * @example
 * ```ts
 * // Configure features during application initialization
 * const app = new Application();
 * await app.init({
 *     eventFeatures: {
 *         // Basic interaction events
 *         move: true,        // Enable pointer movement tracking
 *         click: true,       // Enable click/tap events
 *         wheel: true,       // Enable mouse wheel/scroll events
 *         // Advanced features
 *         globalMove: false  // Disable global move tracking for performance
 *     }
 * });
 *
 * // Or configure after initialization
 * app.renderer.events.features.move = false;      // Disable movement events
 * app.renderer.events.features.globalMove = true; // Enable global tracking
 * ```
 * @since 7.2.0
 * @category events
 * @advanced
 */
export interface EventSystemFeatures {
    /**
     * Enables pointer events associated with pointer movement.
     *
     * When enabled, these events will fire:
     * - `pointermove` / `mousemove` / `touchmove`
     * - `pointerout` / `mouseout`
     * - `pointerover` / `mouseover`
     * @example
     * ```ts
     * // Enable movement events
     * app.renderer.events.features.move = true;
     *
     * // Listen for movement
     * sprite.on('pointermove', (event) => {
     *     console.log('Pointer position:', event.global.x, event.global.y);
     * });
     * ```
     * @default true
     */
    move: boolean;
    /**
     * Enables global pointer move events that fire regardless of target.
     *
     * When enabled, these events will fire:
     * - `globalpointermove`
     * - `globalmousemove`
     * - `globaltouchmove`
     * @example
     * ```ts
     * // Enable global tracking
     * app.renderer.events.features.globalMove = true;
     *
     * // Track pointer globally
     * sprite.on('globalpointermove', (event) => {
     *     // Fires even when pointer is not over sprite
     *     console.log('Global position:', event.global.x, event.global.y);
     * });
     * ```
     * @default true
     */
    globalMove: boolean;
    /**
     * Enables pointer events associated with clicking/tapping.
     *
     * When enabled, these events will fire:
     * - `pointerdown` / `mousedown` / `touchstart` / `rightdown`
     * - `pointerup` / `mouseup` / `touchend` / `rightup`
     * - `pointerupoutside` / `mouseupoutside` / `touchendoutside` / `rightupoutside`
     * - `click` / `tap`
     * @example
     * ```ts
     * // Enable click events
     * app.renderer.events.features.click = true;
     *
     * // Handle clicks
     * sprite.on('click', (event) => {
     *     console.log('Clicked at:', event.global.x, event.global.y);
     * });
     * ```
     * @default true
     */
    click: boolean;
    /**
     * Enables mouse wheel/scroll events.
     * @example
     * ```ts
     * // Enable wheel events
     * app.renderer.events.features.wheel = true;
     *
     * // Handle scrolling
     * sprite.on('wheel', (event) => {
     *     // Zoom based on scroll direction
     *     const scale = 1 + (event.deltaY / 1000);
     *     sprite.scale.set(sprite.scale.x * scale);
     * });
     * ```
     * @default true
     */
    wheel: boolean;
}
/**
 * The system for handling UI events in PixiJS applications. This class manages mouse, touch, and pointer events,
 * normalizing them into a consistent event model.
 * @example
 * ```ts
 * // Access event system through renderer
 * const eventSystem = app.renderer.events;
 *
 * // Configure event features
 * eventSystem.features.globalMove = false;  // Disable global move events
 * eventSystem.features.click = true;        // Enable click events
 *
 * // Set custom cursor styles
 * eventSystem.cursorStyles.default = 'pointer';
 * eventSystem.cursorStyles.grab = 'grab';
 *
 * // Get current pointer position
 * const pointer = eventSystem.pointer;
 * console.log(pointer.global.x, pointer.global.y);
 * ```
 *
 * Features:
 * - Normalizes browser events into consistent format
 * - Supports mouse, touch, and pointer events
 * - Handles event delegation and bubbling
 * - Provides cursor management
 * - Configurable event features
 * @see {@link EventBoundary} For event propagation and handling
 * @see {@link FederatedEvent} For the base event class
 * @see {@link EventMode} For interaction modes
 * @category events
 * @standard
 */
export declare class EventSystem implements System<EventSystemOptions> {
    /** @ignore */
    static extension: ExtensionMetadata;
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
    static defaultEventFeatures: EventSystemFeatures;
    private static _defaultEventMode;
    /**
     * The default interaction mode for all display objects.
     * @see Container.eventMode
     * @type {EventMode}
     * @readonly
     * @since 7.2.0
     */
    static get defaultEventMode(): EventMode;
    /**
     * The {@link EventBoundary} for the stage.
     *
     * The {@link EventBoundary#rootTarget rootTarget} of this root boundary is automatically set to
     * the last rendered object before any event processing is initiated. This means the main scene
     * needs to be rendered atleast once before UI events will start propagating.
     *
     * The root boundary should only be changed during initialization. Otherwise, any state held by the
     * event boundary may be lost (like hovered & pressed Containers).
     * @advanced
     */
    readonly rootBoundary: EventBoundary;
    /**
     * Indicates whether the current device supports touch events according to the W3C Touch Events spec.
     * This is used to determine the appropriate event handling strategy.
     * @see {@link https://www.w3.org/TR/touch-events/} W3C Touch Events Specification
     * @readonly
     * @default 'ontouchstart' in globalThis
     */
    readonly supportsTouchEvents: boolean;
    /**
     * Indicates whether the current device supports pointer events according to the W3C Pointer Events spec.
     * Used to optimize event handling and provide more consistent cross-device interaction.
     * @see {@link https://www.w3.org/TR/pointerevents/} W3C Pointer Events Specification
     * @readonly
     * @default !!globalThis.PointerEvent
     */
    readonly supportsPointerEvents: boolean;
    /**
     * Controls whether default browser actions are automatically prevented on pointer events.
     * When true, prevents default browser actions from occurring on pointer events.
     * @remarks
     * - Does not apply to pointer events for backwards compatibility
     * - preventDefault on pointer events stops mouse events from firing
     * - For every pointer event, there will always be either a mouse or touch event alongside it
     * - Setting this to false allows default browser actions (text selection, dragging images, etc.)
     * @example
     * ```ts
     * // Allow default browser actions
     * app.renderer.events.autoPreventDefault = false;
     *
     * // Block default actions (default)
     * app.renderer.events.autoPreventDefault = true;
     *
     * // Example with text selection
     * const text = new Text('Selectable text');
     * text.eventMode = 'static';
     * app.renderer.events.autoPreventDefault = false; // Allow text selection
     * ```
     * @default true
     */
    autoPreventDefault: boolean;
    /**
     * Dictionary of custom cursor styles that can be used across the application.
     * Used to define how different cursor modes are handled when interacting with display objects.
     * @example
     * ```ts
     * // Access event system through renderer
     * const eventSystem = app.renderer.events;
     *
     * // Set string-based cursor styles
     * eventSystem.cursorStyles.default = 'pointer';
     * eventSystem.cursorStyles.hover = 'grab';
     * eventSystem.cursorStyles.drag = 'grabbing';
     *
     * // Use CSS object for complex styling
     * eventSystem.cursorStyles.custom = {
     *     cursor: 'url("custom.png") 2 2, auto',
     *     userSelect: 'none'
     * };
     *
     * // Use a url for custom cursors
     * const defaultIcon = 'url(\'https://pixijs.com/assets/bunny.png\'),auto';
     * eventSystem.cursorStyles.icon = defaultIcon;
     *
     * // Use callback function for dynamic cursors
     * eventSystem.cursorStyles.dynamic = (mode) => {
     *     // Update cursor based on mode
     *     document.body.style.cursor = mode === 'hover'
     *         ? 'pointer'
     *         : 'default';
     * };
     *
     * // Apply cursor style to a sprite
     * sprite.cursor = 'hover'; // Will use the hover style defined above
     * sprite.cursor = 'icon'; // Will apply the icon cursor
     * sprite.cursor = 'custom'; // Will apply the custom CSS styles
     * sprite.cursor = 'drag'; // Will apply the grabbing cursor
     * sprite.cursor = 'default'; // Will apply the default pointer cursor
     * sprite.cursor = 'dynamic'; // Will call the dynamic function
     * ```
     * @remarks
     * - Strings are treated as CSS cursor values
     * - Objects are applied as CSS styles to the DOM element
     * - Functions are called directly for custom cursor handling
     * - Default styles for 'default' and 'pointer' are provided
     * @default
     * ```ts
     * {
     *     default: 'inherit',
     *     pointer: 'pointer' // Default cursor styles
     * }
     * ```
     */
    cursorStyles: Record<string, string | ((mode: string) => void) | CSSStyleDeclaration>;
    /**
     * The DOM element to which the root event listeners are bound. This is automatically set to
     * the renderer's {@link Renderer#view view}.
     */
    domElement: HTMLElement;
    /** The resolution used to convert between the DOM client space into world space. */
    resolution: number;
    /** The renderer managing this {@link EventSystem}. */
    renderer: Renderer;
    /**
     * The event features that are enabled by the EventSystem
     * @since 7.2.0
     * @example
     * const app = new Application()
     * app.renderer.events.features.globalMove = false
     *
     * // to override all features use Object.assign
     * Object.assign(app.renderer.events.features, {
     *  move: false,
     *  globalMove: false,
     *  click: false,
     *  wheel: false,
     * })
     */
    readonly features: EventSystemFeatures;
    private _currentCursor;
    private readonly _rootPointerEvent;
    private readonly _rootWheelEvent;
    private _eventsAdded;
    /**
     * @param {Renderer} renderer
     */
    constructor(renderer: Renderer);
    /**
     * Runner init called, view is available at this point.
     * @ignore
     */
    init(options: EventSystemOptions): void;
    /**
     * Handle changing resolution.
     * @ignore
     */
    resolutionChange(resolution: number): void;
    /** Destroys all event listeners and detaches the renderer. */
    destroy(): void;
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
    setCursor(mode: string): void;
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
    get pointer(): Readonly<FederatedPointerEvent>;
    /**
     * Event handler for pointer down events on {@link EventSystem#domElement this.domElement}.
     * @param nativeEvent - The native mouse/pointer/touch event.
     */
    private _onPointerDown;
    /**
     * Event handler for pointer move events on on {@link EventSystem#domElement this.domElement}.
     * @param nativeEvent - The native mouse/pointer/touch events.
     */
    private _onPointerMove;
    /**
     * Event handler for pointer up events on {@link EventSystem#domElement this.domElement}.
     * @param nativeEvent - The native mouse/pointer/touch event.
     */
    private _onPointerUp;
    /**
     * Event handler for pointer over & out events on {@link EventSystem#domElement this.domElement}.
     * @param nativeEvent - The native mouse/pointer/touch event.
     */
    private _onPointerOverOut;
    /**
     * Passive handler for `wheel` events on {@link EventSystem.domElement this.domElement}.
     * @param nativeEvent - The native wheel event.
     */
    protected onWheel(nativeEvent: WheelEvent): void;
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
    setTargetElement(element: HTMLElement): void;
    /** Register event listeners on {@link Renderer#domElement this.domElement}. */
    private _addEvents;
    /** Unregister event listeners on {@link EventSystem#domElement this.domElement}. */
    private _removeEvents;
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
    mapPositionToPoint(point: PointData, x: number, y: number): void;
    /**
     * Ensures that the original event object contains all data that a regular pointer event would have
     * @param event - The original event data from a touch or mouse event
     * @returns An array containing a single normalized pointer event, in the case of a pointer
     *  or mouse event, or a multiple normalized pointer events if there are multiple changed touches
     */
    private _normalizeToPointerData;
    /**
     * Normalizes the native {@link https://w3c.github.io/uievents/#interface-wheelevent WheelEvent}.
     *
     * The returned {@link FederatedWheelEvent} is a shared instance. It will not persist across
     * multiple native wheel events.
     * @param nativeEvent - The native wheel event that occurred on the canvas.
     * @returns A federated wheel event.
     */
    protected normalizeWheelEvent(nativeEvent: WheelEvent): FederatedWheelEvent;
    /**
     * Normalizes the `nativeEvent` into a federateed {@link FederatedPointerEvent}.
     * @param event
     * @param nativeEvent
     */
    private _bootstrapEvent;
    /**
     * Transfers base & mouse event data from the `nativeEvent` to the federated event.
     * @param event
     * @param nativeEvent
     */
    private _transferMouseData;
}
