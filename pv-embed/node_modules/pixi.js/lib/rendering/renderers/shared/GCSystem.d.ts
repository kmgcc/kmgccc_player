import { ExtensionType } from '../../../extensions/Extensions';
import { type GPUDataOwner, type Renderer } from '../types';
import { type Renderable } from './Renderable';
import { type RenderOptions } from './system/AbstractRenderer';
import type EventEmitter from 'eventemitter3';
import type { System } from './system/System';
/**
 * Data stored on a GC-managed resource.
 * @category rendering
 * @advanced
 */
export interface GCData {
    /** Index in the managed resources array */
    index?: number;
    /** Type of the resource */
    type: 'resource' | 'renderable';
}
/**
 * Interface for resources that can be garbage collected.
 * @category rendering
 * @advanced
 */
export interface GCable extends GPUDataOwner {
    /** Timestamp of last use */
    _gcLastUsed: number;
    /** GC tracking data, null if not being tracked */
    _gcData?: GCData | null;
    /** If set to true, the resource will be garbage collected automatically when it is not used. */
    autoGarbageCollect?: boolean;
    /** An optional callback for when an item is touched */
    _onTouch?(now: number): void;
}
type GCableEventEmitter = GCable & Pick<EventEmitter, 'once' | 'off'>;
interface GCResourceHashEntry {
    context: any;
    hash: string;
    type: GCData['type'];
    priority: number;
}
/**
 * Options for the {@link GCSystem}.
 * @category rendering
 * @advanced
 */
export interface GCSystemOptions {
    /**
     * If set to true, this will enable the garbage collector.
     * @default true
     */
    gcActive: boolean;
    /**
     * The maximum time in milliseconds a resource can be unused before being garbage collected.
     * @default 60000
     */
    gcMaxUnusedTime: number;
    /**
     * How frequently to run garbage collection in milliseconds.
     * @default 30000
     */
    gcFrequency: number;
}
/**
 * A unified garbage collection system for managing GPU resources.
 * Resources register themselves with a cleanup callback and are automatically
 * cleaned up when they haven't been used for a specified amount of time.
 * @example
 * ```ts
 * // Register a resource for GC
 * gc.addResource(myResource, () => {
 *     // cleanup logic here
 *     myResource.unload();
 * });
 *
 * // Touch the resource when used (resets idle timer)
 * gc.touch(myResource);
 *
 * // Remove from GC tracking (e.g., on manual destroy)
 * gc.removeResource(myResource);
 * ```
 * @category rendering
 * @advanced
 */
export declare class GCSystem implements System<GCSystemOptions> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem, ExtensionType.CanvasSystem];
        readonly name: "gc";
        readonly priority: 0;
    };
    /** Default options for the GCSystem */
    static defaultOptions: GCSystemOptions;
    /** Maximum time in ms a resource can be unused before being garbage collected */
    maxUnusedTime: number;
    /** Reference to the renderer this system belongs to */
    private _renderer;
    /** Array of resources being tracked for garbage collection */
    private readonly _managedResources;
    private readonly _managedResourceHashes;
    private readonly _managedCollections;
    /** ID of the GC scheduler handler */
    private _handler;
    private _collectionsHandler;
    /** How frequently GC runs in ms */
    private _frequency;
    /** Current timestamp used for age calculations */
    now: number;
    private _ready;
    /**
     * Creates a new GCSystem instance.
     * @param renderer - The renderer this garbage collection system works for
     */
    constructor(renderer: Renderer);
    /**
     * Initializes the garbage collection system with the provided options.
     * @param options - Configuration options
     */
    init(options: GCSystemOptions): void;
    /**
     * Gets whether the garbage collection system is currently enabled.
     * @returns True if GC is enabled, false otherwise
     */
    get enabled(): boolean;
    /**
     * Enables or disables the garbage collection system.
     * When enabled, schedules periodic cleanup of resources.
     * When disabled, cancels all scheduled cleanups.
     */
    set enabled(value: boolean);
    /**
     * Called before rendering. Updates the current timestamp.
     * @param options - The render options
     * @param options.container - The container to render
     */
    protected prerender({ container }: RenderOptions): void;
    /** Performs garbage collection after rendering. */
    protected postrender(): void;
    /**
     * Updates the GC tick counter for a render group and its children.
     * @param renderGroup - The render group to update
     * @param gcTick - The new tick value
     */
    private _updateInstructionGCTick;
    /**
     * Registers a collection for garbage collection tracking.
     * @param context - The object containing the collection
     * @param collection - The property name on context that holds the collection
     * @param type - The type of collection to track ('hash' or 'array')
     */
    addCollection(context: any, collection: string, type: 'hash' | 'array'): void;
    /**
     * Registers a resource for garbage collection tracking.
     * @param resource - The resource to track
     * @param type - The type of resource to track
     */
    addResource(resource: GCableEventEmitter, type: GCData['type']): void;
    /**
     * Removes a resource from garbage collection tracking.
     * Call this when manually destroying a resource.
     * @param resource - The resource to stop tracking
     */
    removeResource(resource: GCable): void;
    /**
     * Registers a hash-based resource collection for garbage collection tracking.
     * Resources in the hash will be automatically tracked and cleaned up when unused.
     * @param context - The object containing the hash property
     * @param hash - The property name on context that holds the resource hash
     * @param type - The type of resources in the hash ('resource' or 'renderable')
     * @param priority - Processing priority (lower values are processed first)
     */
    addResourceHash(context: any, hash: string, type: GCData['type'], priority?: number): void;
    /**
     * Performs garbage collection by cleaning up unused resources.
     * Removes resources that haven't been used for longer than maxUnusedTime.
     */
    run(): void;
    protected updateRenderableGCTick(renderable: Renderable & GCable, now: number): void;
    protected runOnResource(resource: GCableEventEmitter, now: number, writeIndex: number): number;
    /**
     * Creates a clone of the hash, copying all non-null entries up to (but not including) the stop key.
     * @param hashValue - The original hash to clone from
     * @param stopKey - The key to stop at (exclusive)
     * @returns A new hash object with copied entries
     */
    private _createHashClone;
    protected runOnHash(hashEntry: GCResourceHashEntry, now: number): void;
    /** Cleans up the garbage collection system. Disables GC and removes all tracked resources. */
    destroy(): void;
}
export {};
