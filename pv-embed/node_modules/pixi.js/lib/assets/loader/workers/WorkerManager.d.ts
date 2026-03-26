import type { TextureSourceOptions } from '../../../rendering/renderers/shared/texture/sources/TextureSource';
import type { ResolvedAsset } from '../../types';
/** @internal */
declare class WorkerManagerClass {
    /**
     * Hash map storing resolve/reject functions for pending worker requests.
     * Keyed by UUID to match responses with their corresponding promises.
     */
    private _resolveHash;
    /** Pool of available workers ready for use */
    private readonly _workerPool;
    /** Queue of pending work items waiting for available workers */
    private readonly _queue;
    /** Whether the worker manager has been initialized */
    private _initialized;
    /** Current number of created workers (used to enforce MAX_WORKERS limit) */
    private _createdWorkers;
    /** Cached promise for ImageBitmap support check */
    private _isImageBitmapSupported?;
    constructor();
    /**
     * Checks if ImageBitmap is supported in the current environment.
     *
     * This method uses a dedicated worker to test ImageBitmap support
     * and caches the result for subsequent calls.
     * @returns Promise that resolves to true if ImageBitmap is supported, false otherwise
     */
    isImageBitmapSupported(): Promise<boolean>;
    /**
     * Loads an image as an ImageBitmap using a web worker.
     * @param src - The source URL or path of the image to load
     * @param asset - Optional resolved asset containing additional texture source options
     * @returns Promise that resolves to the loaded ImageBitmap
     * @example
     * ```typescript
     * const bitmap = await WorkerManager.loadImageBitmap('image.png');
     * const bitmapWithOptions = await WorkerManager.loadImageBitmap('image.png', asset);
     * ```
     */
    loadImageBitmap(src: string, asset?: ResolvedAsset<TextureSourceOptions<any>>): Promise<ImageBitmap>;
    /**
     * Initializes the worker pool if not already initialized.
     * Currently a no-op but reserved for future initialization logic.
     */
    private _initWorkers;
    /**
     * Gets an available worker from the pool or creates a new one if needed.
     *
     * Workers are created up to the MAX_WORKERS limit (based on navigator.hardwareConcurrency).
     * Each worker is configured with a message handler for processing results.
     * @returns Available worker or undefined if pool is at capacity and no workers are free
     */
    private _getWorker;
    /**
     * Returns a worker to the pool after completing a task.
     * @param worker - The worker to return to the pool
     */
    private _returnWorker;
    /**
     * Handles completion of a worker task by resolving or rejecting the corresponding promise.
     * @param data - Result data from the worker containing uuid, data, and optional error
     */
    private _complete;
    /**
     * Executes a task using the worker pool system.
     *
     * Queues the task and processes it when a worker becomes available.
     * @param id - Identifier for the type of task to run
     * @param args - Arguments to pass to the worker
     * @returns Promise that resolves with the worker's result
     */
    private _run;
    /**
     * Processes the next item in the queue if workers are available.
     *
     * This method is called after worker initialization and when workers
     * complete tasks to continue processing the queue.
     */
    private _next;
    /**
     * Resets the worker manager, terminating all workers and clearing the queue.
     *
     * This method:
     * - Terminates all active workers
     * - Rejects all pending promises with an error
     * - Clears all internal state
     * - Resets initialization flags
     *
     * This should be called when the worker manager is no longer needed
     * to prevent memory leaks and ensure proper cleanup.
     * @example
     * ```typescript
     * // Clean up when shutting down
     * WorkerManager.reset();
     * ```
     */
    reset(): void;
}
/**
 * Manages a pool of web workers for loading ImageBitmap objects asynchronously.
 *
 * This class provides a thread-safe way to load images using web workers,
 * automatically managing worker creation, pooling, and cleanup. It supports
 * checking ImageBitmap support and queuing multiple load requests.
 *
 * > [!IMPORTANT] You should not need to use this class directly
 * > However, you can call `WorkerManager.reset()` to clean up all workers when they are no longer needed.
 * @category assets
 * @advanced
 */
declare const WorkerManager: WorkerManagerClass;
export { WorkerManager, };
