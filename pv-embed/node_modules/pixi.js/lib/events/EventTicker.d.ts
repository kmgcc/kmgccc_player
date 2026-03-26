import type { EventSystem } from './EventSystem';
/** @advanced */
declare class EventsTickerClass {
    /** The event system. */
    events: EventSystem;
    /** The DOM element to listen to events on. */
    domElement: HTMLElement;
    /** The frequency that fake events will be fired. */
    interactionFrequency: number;
    private _deltaTime;
    private _didMove;
    private _tickerAdded;
    private _pauseUpdate;
    /**
     * Initializes the event ticker.
     * @param events - The event system.
     */
    init(events: EventSystem): void;
    /** Whether to pause the update checks or not. */
    get pauseUpdate(): boolean;
    set pauseUpdate(paused: boolean);
    /** Adds the ticker listener. */
    addTickerListener(): void;
    /** Removes the ticker listener. */
    removeTickerListener(): void;
    /** Sets flag to not fire extra events when the user has already moved there mouse */
    pointerMoved(): void;
    /** Updates the state of interactive objects. */
    private _update;
    /**
     * Updates the state of interactive objects if at least {@link interactionFrequency}
     * milliseconds have passed since the last invocation.
     *
     * Invoked by a throttled ticker update from {@link Ticker.system}.
     * @param ticker - The throttled ticker.
     */
    private _tickerUpdate;
    /** Destroys the event ticker. */
    destroy(): void;
}
/**
 * This class handles automatic firing of PointerEvents
 * in the case where the pointer is stationary for too long.
 * This is to ensure that hit-tests are still run on moving objects.
 * @since 7.2.0
 * @category events
 * @class
 * @advanced
 */
export declare const EventsTicker: EventsTickerClass;
export {};
