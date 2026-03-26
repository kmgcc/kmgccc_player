import type { Ticker, TickerCallback } from './Ticker';
/**
 * Internal class for handling the priority sorting of ticker handlers.
 * @private
 * @class
 */
export declare class TickerListener<T = any> {
    /** The current priority. */
    priority: number;
    /** The next item in chain. */
    next: TickerListener;
    /** The previous item in chain. */
    previous: TickerListener;
    /** The handler function to execute. */
    private _fn;
    /** The calling to execute. */
    private _context;
    /** If this should only execute once. */
    private readonly _once;
    /** `true` if this listener has been destroyed already. */
    private _destroyed;
    /**
     * Constructor
     * @private
     * @param fn - The listener function to be added for one update
     * @param context - The listener context
     * @param priority - The priority for emitting
     * @param once - If the handler should fire once
     */
    constructor(fn: TickerCallback<T>, context?: T, priority?: number, once?: boolean);
    /**
     * Simple compare function to figure out if a function and context match.
     * @param fn - The listener function to be added for one update
     * @param context - The listener context
     * @returns `true` if the listener match the arguments
     */
    match(fn: TickerCallback<T>, context?: any): boolean;
    /**
     * Emit by calling the current function.
     * @param ticker - The ticker emitting.
     * @returns Next ticker
     */
    emit(ticker: Ticker): TickerListener;
    /**
     * Connect to the list.
     * @param previous - Input node, previous listener
     */
    connect(previous: TickerListener): void;
    /**
     * Destroy and don't use after this.
     * @param hard - `true` to remove the `next` reference, this
     *        is considered a hard destroy. Soft destroy maintains the next reference.
     * @returns The listener to redirect while emitting or removing.
     */
    destroy(hard?: boolean): TickerListener;
}
