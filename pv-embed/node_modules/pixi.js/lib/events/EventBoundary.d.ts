import EventEmitter from 'eventemitter3';
import { Point } from '../maths/point/Point';
import { FederatedPointerEvent } from './FederatedPointerEvent';
import { FederatedWheelEvent } from './FederatedWheelEvent';
import type { Container } from '../scene/container/Container';
import type { TrackingData } from './EventBoundaryTypes';
import type { FederatedEvent } from './FederatedEvent';
import type { Cursor, EventMode } from './FederatedEventTarget';
/**
 * Event boundaries are "barriers" where events coming from an upstream scene are modified before downstream propagation.
 *
 * ## Root event boundary
 *
 * The {@link EventSystem#rootBoundary rootBoundary} handles events coming from the &lt;canvas /&gt;.
 * {@link EventSystem} handles the normalization from native {@link https://dom.spec.whatwg.org/#event Events}
 * into {@link FederatedEvent FederatedEvents}. The rootBoundary then does the hit-testing and event dispatch
 * for the upstream normalized event.
 *
 * ## Additional event boundaries
 *
 * An additional event boundary may be desired within an application's scene graph. For example, if a portion of the scene is
 * is flat with many children at one level - a spatial hash maybe needed to accelerate hit testing. In this scenario, the
 * container can be detached from the scene and glued using a custom event boundary.
 *
 * ```ts
 * import { Container } from 'pixi.js';
 * import { EventBoundary } from 'pixi.js';
 * import { SpatialHash } from 'pixi-spatial-hash';
 *
 * class HashedHitTestingEventBoundary
 * {
 *     private spatialHash: SpatialHash;
 *
 *     constructor(scene: Container, spatialHash: SpatialHash)
 *     {
 *         super(scene);
 *         this.spatialHash = spatialHash;
 *     }
 *
 *     hitTestRecursive(...)
 *     {
 *         // TODO: If target === this.rootTarget, then use spatial hash to get a
 *         // list of possible children that match the given (x,y) coordinates.
 *     }
 * }
 *
 * class VastScene extends Container
 * {
 *     protected eventBoundary: EventBoundary;
 *     protected scene: Container;
 *     protected spatialHash: SpatialHash;
 *
 *     constructor()
 *     {
 *         this.scene = new Container();
 *         this.spatialHash = new SpatialHash();
 *         this.eventBoundary = new HashedHitTestingEventBoundary(this.scene, this.spatialHash);
 *
 *         // Populate this.scene with a ton of children, while updating this.spatialHash
 *     }
 * }
 * ```
 * @category events
 * @advanced
 */
export declare class EventBoundary {
    /**
     * The root event-target residing below the event boundary.
     * All events are dispatched trickling down and bubbling up to this `rootTarget`.
     */
    rootTarget: Container;
    /**
     * Emits events after they were dispatched into the scene graph.
     *
     * This can be used for global events listening, regardless of the scene graph being used. It should
     * not be used by interactive libraries for normal use.
     *
     * Special events that do not bubble all the way to the root target are not emitted from here,
     * e.g. pointerenter, pointerleave, click.
     */
    dispatch: EventEmitter;
    /** The cursor preferred by the event targets underneath this boundary. */
    cursor: Cursor | (string & {});
    /**
     * This flag would emit `pointermove`, `touchmove`, and `mousemove` events on all Containers.
     *
     * The `moveOnAll` semantics mirror those of earlier versions of PixiJS. This was disabled in favor of
     * the Pointer Event API's approach.
     */
    moveOnAll: boolean;
    /** Enables the global move events. `globalpointermove`, `globaltouchmove`, and `globalmousemove` */
    enableGlobalMoveEvents: boolean;
    /**
     * Maps event types to forwarding handles for them.
     *
     * {@link EventBoundary EventBoundary} provides mapping for "pointerdown", "pointermove",
     * "pointerout", "pointerleave", "pointerover", "pointerup", and "pointerupoutside" by default.
     * @see EventBoundary#addEventMapping
     */
    protected mappingTable: Record<string, Array<{
        fn: (e: FederatedEvent) => void;
        priority: number;
    }>>;
    /**
     * State object for mapping methods.
     * @see EventBoundary#trackingData
     */
    protected mappingState: Record<string, any>;
    /**
     * The event pool maps event constructors to an free pool of instances of those specific events.
     * @see EventBoundary#allocateEvent
     * @see EventBoundary#freeEvent
     */
    protected eventPool: Map<typeof FederatedEvent, FederatedEvent[]>;
    /** Every interactive element gathered from the scene. Only used in `pointermove` */
    private readonly _allInteractiveElements;
    /** Every element that passed the hit test. Only used in `pointermove` */
    private _hitElements;
    /** Whether or not to collect all the interactive elements from the scene. Enabled in `pointermove` */
    private _isPointerMoveEvent;
    /**
     * @param rootTarget - The holder of the event boundary.
     */
    constructor(rootTarget?: Container);
    /**
     * Adds an event mapping for the event `type` handled by `fn`.
     *
     * Event mappings can be used to implement additional or custom events. They take an event
     * coming from the upstream scene (or directly from the {@link EventSystem}) and dispatch new downstream events
     * generally trickling down and bubbling up to {@link EventBoundary.rootTarget this.rootTarget}.
     *
     * To modify the semantics of existing events, the built-in mapping methods of EventBoundary should be overridden
     * instead.
     * @param type - The type of upstream event to map.
     * @param fn - The mapping method. The context of this function must be bound manually, if desired.
     */
    addEventMapping(type: string, fn: (e: FederatedEvent) => void): void;
    /**
     * Dispatches the given event
     * @param e - The event to dispatch.
     * @param type - The type of event to dispatch. Defaults to `e.type`.
     */
    dispatchEvent(e: FederatedEvent, type?: string): void;
    /**
     * Maps the given upstream event through the event boundary and propagates it downstream.
     * @param e - The event to map.
     */
    mapEvent(e: FederatedEvent): void;
    /**
     * Finds the Container that is the target of a event at the given coordinates.
     *
     * The passed (x,y) coordinates are in the world space above this event boundary.
     * @param x - The x coordinate of the event.
     * @param y - The y coordinate of the event.
     */
    hitTest(x: number, y: number): Container;
    /**
     * Propagate the passed event from from {@link EventBoundary.rootTarget this.rootTarget} to its
     * target `e.target`.
     * @param e - The event to propagate.
     * @param type - The type of event to propagate. Defaults to `e.type`.
     */
    propagate(e: FederatedEvent, type?: string): void;
    /**
     * Emits the event `e` to all interactive containers. The event is propagated in the bubbling phase always.
     *
     * This is used in the `globalpointermove` event.
     * @param e - The emitted event.
     * @param type - The listeners to notify.
     * @param targets - The targets to notify.
     */
    all(e: FederatedEvent, type?: string | string[], targets?: Container<import("../scene/container/Container").ContainerChild>[]): void;
    /**
     * Finds the propagation path from {@link EventBoundary.rootTarget rootTarget} to the passed
     * `target`. The last element in the path is `target`.
     * @param target - The target to find the propagation path to.
     */
    propagationPath(target: Container): Container[];
    protected hitTestMoveRecursive(currentTarget: Container, eventMode: EventMode, location: Point, testFn: (object: Container, pt: Point) => boolean, pruneFn: (object: Container, pt: Point) => boolean, ignore?: boolean): Container[];
    /**
     * Recursive implementation for {@link EventBoundary.hitTest hitTest}.
     * @param currentTarget - The Container that is to be hit tested.
     * @param eventMode - The event mode for the `currentTarget` or one of its parents.
     * @param location - The location that is being tested for overlap.
     * @param testFn - Callback that determines whether the target passes hit testing. This callback
     *  can assume that `pruneFn` failed to prune the container.
     * @param pruneFn - Callback that determiness whether the target and all of its children
     *  cannot pass the hit test. It is used as a preliminary optimization to prune entire subtrees
     *  of the scene graph.
     * @returns An array holding the hit testing target and all its ancestors in order. The first element
     *  is the target itself and the last is {@link EventBoundary.rootTarget rootTarget}. This is the opposite
     *  order w.r.t. the propagation path. If no hit testing target is found, null is returned.
     */
    protected hitTestRecursive(currentTarget: Container, eventMode: EventMode, location: Point, testFn: (object: Container, pt: Point) => boolean, pruneFn: (object: Container, pt: Point) => boolean): Container[];
    private _isInteractive;
    private _interactivePrune;
    /**
     * Checks whether the container or any of its children cannot pass the hit test at all.
     *
     * {@link EventBoundary}'s implementation uses the {@link Container.hitArea hitArea}
     * and {@link Container._maskEffect} for pruning.
     * @param container - The container to prune.
     * @param location - The location to test for overlap.
     */
    protected hitPruneFn(container: Container, location: Point): boolean;
    /**
     * Checks whether the container passes hit testing for the given location.
     * @param container - The container to test.
     * @param location - The location to test for overlap.
     * @returns - Whether `container` passes hit testing for `location`.
     */
    protected hitTestFn(container: Container, location: Point): boolean;
    /**
     * Notify all the listeners to the event's `currentTarget`.
     *
     * If the `currentTarget` contains the property `on<type>`, then it is called here,
     * simulating the behavior from version 6.x and prior.
     * @param e - The event passed to the target.
     * @param type - The type of event to notify. Defaults to `e.type`.
     */
    protected notifyTarget(e: FederatedEvent, type?: string): void;
    /**
     * Maps the upstream `pointerdown` events to a downstream `pointerdown` event.
     *
     * `touchstart`, `rightdown`, `mousedown` events are also dispatched for specific pointer types.
     * @param from - The upstream `pointerdown` event.
     */
    protected mapPointerDown(from: FederatedEvent): void;
    /**
     * Maps the upstream `pointermove` to downstream `pointerout`, `pointerover`, and `pointermove` events, in that order.
     *
     * The tracking data for the specific pointer has an updated `overTarget`. `mouseout`, `mouseover`,
     * `mousemove`, and `touchmove` events are fired as well for specific pointer types.
     * @param from - The upstream `pointermove` event.
     */
    protected mapPointerMove(from: FederatedEvent): void;
    /**
     * Maps the upstream `pointerover` to downstream `pointerover` and `pointerenter` events, in that order.
     *
     * The tracking data for the specific pointer gets a new `overTarget`.
     * @param from - The upstream `pointerover` event.
     */
    protected mapPointerOver(from: FederatedEvent): void;
    /**
     * Maps the upstream `pointerout` to downstream `pointerout`, `pointerleave` events, in that order.
     *
     * The tracking data for the specific pointer is cleared of a `overTarget`.
     * @param from - The upstream `pointerout` event.
     */
    protected mapPointerOut(from: FederatedEvent): void;
    /**
     * Maps the upstream `pointerup` event to downstream `pointerup`, `pointerupoutside`,
     * and `click`/`rightclick`/`pointertap` events, in that order.
     *
     * The `pointerupoutside` event bubbles from the original `pointerdown` target to the most specific
     * ancestor of the `pointerdown` and `pointerup` targets, which is also the `click` event's target. `touchend`,
     * `rightup`, `mouseup`, `touchendoutside`, `rightupoutside`, `mouseupoutside`, and `tap` are fired as well for
     * specific pointer types.
     * @param from - The upstream `pointerup` event.
     */
    protected mapPointerUp(from: FederatedEvent): void;
    /**
     * Maps the upstream `pointerupoutside` event to a downstream `pointerupoutside` event, bubbling from the original
     * `pointerdown` target to `rootTarget`.
     *
     * (The most specific ancestor of the `pointerdown` event and the `pointerup` event must the
     * `{@link EventBoundary}'s root because the `pointerup` event occurred outside of the boundary.)
     *
     * `touchendoutside`, `mouseupoutside`, and `rightupoutside` events are fired as well for specific pointer
     * types. The tracking data for the specific pointer is cleared of a `pressTarget`.
     * @param from - The upstream `pointerupoutside` event.
     */
    protected mapPointerUpOutside(from: FederatedEvent): void;
    /**
     * Maps the upstream `wheel` event to a downstream `wheel` event.
     * @param from - The upstream `wheel` event.
     */
    protected mapWheel(from: FederatedEvent): void;
    /**
     * Finds the most specific event-target in the given propagation path that is still mounted in the scene graph.
     *
     * This is used to find the correct `pointerup` and `pointerout` target in the case that the original `pointerdown`
     * or `pointerover` target was unmounted from the scene graph.
     * @param propagationPath - The propagation path was valid in the past.
     * @returns - The most specific event-target still mounted at the same location in the scene graph.
     */
    protected findMountedTarget(propagationPath: Container[]): Container;
    /**
     * Creates an event whose `originalEvent` is `from`, with an optional `type` and `target` override.
     *
     * The event is allocated using {@link EventBoundary#allocateEvent this.allocateEvent}.
     * @param from - The `originalEvent` for the returned event.
     * @param [type=from.type] - The type of the returned event.
     * @param target - The target of the returned event.
     */
    protected createPointerEvent(from: FederatedPointerEvent, type?: string, target?: Container): FederatedPointerEvent;
    /**
     * Creates a wheel event whose `originalEvent` is `from`.
     *
     * The event is allocated using {@link EventBoundary#allocateEvent this.allocateEvent}.
     * @param from - The upstream wheel event.
     */
    protected createWheelEvent(from: FederatedWheelEvent): FederatedWheelEvent;
    /**
     * Clones the event `from`, with an optional `type` override.
     *
     * The event is allocated using {@link EventBoundary#allocateEvent this.allocateEvent}.
     * @param from - The event to clone.
     * @param [type=from.type] - The type of the returned event.
     */
    protected clonePointerEvent(from: FederatedPointerEvent, type?: string): FederatedPointerEvent;
    /**
     * Copies wheel {@link FederatedWheelEvent} data from `from` into `to`.
     *
     * The following properties are copied:
     * + deltaMode
     * + deltaX
     * + deltaY
     * + deltaZ
     * @param from - The event to copy data from.
     * @param to - The event to copy data into.
     */
    protected copyWheelData(from: FederatedWheelEvent, to: FederatedWheelEvent): void;
    /**
     * Copies pointer {@link FederatedPointerEvent} data from `from` into `to`.
     *
     * The following properties are copied:
     * + pointerId
     * + width
     * + height
     * + isPrimary
     * + pointerType
     * + pressure
     * + tangentialPressure
     * + tiltX
     * + tiltY
     * @param from - The event to copy data from.
     * @param to - The event to copy data into.
     */
    protected copyPointerData(from: FederatedEvent, to: FederatedEvent): void;
    /**
     * Copies mouse {@link FederatedMouseEvent} data from `from` to `to`.
     *
     * The following properties are copied:
     * + altKey
     * + button
     * + buttons
     * + clientX
     * + clientY
     * + metaKey
     * + movementX
     * + movementY
     * + pageX
     * + pageY
     * + x
     * + y
     * + screen
     * + shiftKey
     * + global
     * @param from - The event to copy data from.
     * @param to - The event to copy data into.
     */
    protected copyMouseData(from: FederatedEvent, to: FederatedEvent): void;
    /**
     * Copies base {@link FederatedEvent} data from `from` into `to`.
     *
     * The following properties are copied:
     * + isTrusted
     * + srcElement
     * + timeStamp
     * + type
     * @param from - The event to copy data from.
     * @param to - The event to copy data into.
     */
    protected copyData(from: FederatedEvent, to: FederatedEvent): void;
    /**
     * @param id - The pointer ID.
     * @returns The tracking data stored for the given pointer. If no data exists, a blank
     *  state will be created.
     */
    protected trackingData(id: number): TrackingData;
    /**
     * Allocate a specific type of event from {@link EventBoundary#eventPool this.eventPool}.
     *
     * This allocation is constructor-agnostic, as long as it only takes one argument - this event
     * boundary.
     * @param constructor - The event's constructor.
     * @returns An event of the given type.
     */
    protected allocateEvent<T extends FederatedEvent>(constructor: {
        new (boundary: EventBoundary): T;
    }): T;
    /**
     * Frees the event and puts it back into the event pool.
     *
     * It is illegal to reuse the event until it is allocated again, using `this.allocateEvent`.
     *
     * It is also advised that events not allocated from {@link EventBoundary#allocateEvent this.allocateEvent}
     * not be freed. This is because of the possibility that the same event is freed twice, which can cause
     * it to be allocated twice & result in overwriting.
     * @param event - The event to be freed.
     * @throws Error if the event is managed by another event boundary.
     */
    protected freeEvent<T extends FederatedEvent>(event: T): void;
    /**
     * Similar to {@link EventEmitter.emit}, except it stops if the `propagationImmediatelyStopped` flag
     * is set on the event.
     * @param e - The event to call each listener with.
     * @param type - The event key.
     */
    private _notifyListeners;
}
