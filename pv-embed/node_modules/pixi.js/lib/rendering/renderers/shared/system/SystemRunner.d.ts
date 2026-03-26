/**
 * SystemRunner is used internally by the renderers as an efficient way for systems to
 * be notified about what the renderer is up to during the rendering phase.
 *
 * ```ts
 * import { SystemRunner } from 'pixi.js';
 *
 * const myObject = {
 *     loaded: new SystemRunner('loaded')
 * }
 *
 * const listener = {
 *     loaded: function(){
 *         // thin
 *     }
 * }
 *
 * myObject.loaded.add(listener);
 *
 * myObject.loaded.emit();
 * ```
 *
 * Or for handling calling the same function on many items
 * ```ts
 * import { SystemRunner } from 'pixi.js';
 *
 * const myGame = {
 *     update: new SystemRunner('update')
 * }
 *
 * const gameObject = {
 *     update: function(time){
 *         // update my gamey state
 *     }
 * }
 *
 * myGame.update.add(gameObject);
 *
 * myGame.update.emit(time);
 * ```
 * @category rendering
 * @internal
 */
export declare class SystemRunner {
    items: any[];
    private _name;
    /**
     * @param name - The function name that will be executed on the listeners added to this Runner.
     */
    constructor(name: string);
    /**
     * Dispatch/Broadcast Runner to all listeners added to the queue.
     * @param {...any} params - (optional) parameters to pass to each listener
     */
    emit(a0?: unknown, a1?: unknown, a2?: unknown, a3?: unknown, a4?: unknown, a5?: unknown, a6?: unknown, a7?: unknown): this;
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
    add(item: unknown): this;
    /**
     * Remove a single listener from the dispatch queue.
     * @param {any} item - The listener that you would like to remove.
     */
    remove(item: unknown): this;
    /**
     * Check to see if the listener is already in the Runner
     * @param {any} item - The listener that you would like to check.
     */
    contains(item: unknown): boolean;
    /** Remove all listeners from the Runner */
    removeAll(): this;
    /** Remove all references, don't use after this. */
    destroy(): void;
    /**
     * `true` if there are no this Runner contains no listeners
     * @readonly
     */
    get empty(): boolean;
    /**
     * The name of the runner.
     * @readonly
     */
    get name(): string;
}
