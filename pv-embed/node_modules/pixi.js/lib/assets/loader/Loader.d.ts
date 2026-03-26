import { type ProgressCallback } from '../Assets';
import type { ResolvedAsset } from '../types';
import type { LoaderParser } from './parsers/LoaderParser';
import type { PromiseAndParser } from './types';
/**
 * Options for loading assets with the Loader
 * @example
 * ```ts
 * await Assets.load(['file1.png', 'file2.png'], {
 *   onProgress: (progress) => console.log(`Progress: ${progress * 100}%`),
 *   onError: (error, url) => console.error(`Error loading ${url}: ${error.message}`),
 *   strategy: 'retry', // 'throw' | 'skip' | 'retry'
 *   retryCount: 5, // Number of retry attempts if strategy is 'retry'
 *   retryDelay: 500, // Delay in ms between retries
 * });
 * ```
 * @category assets
 * @standard
 */
export interface LoadOptions {
    /**
     * Callback for progress updates during loading
     * @param progress - A number between 0 and 1 indicating the load progress
     * @example
     * ```ts
     * const options: LoadOptions = {
     *   onProgress: (progress) => {
     *     console.log(`Loading progress: ${progress * 100}%`);
     *   },
     * };
     * await Assets.load('image.png', options);
     * ```
     */
    onProgress?: (progress: number) => void;
    /**
     * Callback for handling errors during loading
     * @param error - The error that occurred
     * @param url - The URL of the asset that failed to load
     * @example
     * ```ts
     * const options: LoadOptions = {
     *   onError: (error, url) => {
     *     console.error(`Failed to load ${url}: ${error.message}`);
     *   },
     * };
     * await Assets.load('missing-file.png', options);
     * ```
     */
    onError?: (error: Error, url: string | ResolvedAsset) => void;
    /**
     * Strategy to handle load failures
     * - 'throw': Immediately throw an error and stop loading (default)
     * - 'skip': Skip the failed asset and continue loading others
     * - 'retry': Retry loading the asset a specified number of times
     * @default 'throw'
     * @example
     * ```ts
     * const options: LoadOptions = {
     *   strategy: 'skip',
     * };
     * await Assets.load('sometimes-fails.png', options);
     * ```
     */
    strategy?: 'throw' | 'skip' | 'retry';
    /**
     * Number of retry attempts if strategy is 'retry'
     * @default 3
     * @example
     * ```ts
     * const options: LoadOptions = {
     *   strategy: 'retry',
     *   retryCount: 5, // Retry up to 5 times
     * };
     * await Assets.load('unstable-asset.png', options);
     * ```
     */
    retryCount?: number;
    /**
     * Delay in milliseconds between retry attempts
     * @default 250
     * @example
     * ```ts
     * const options: LoadOptions = {
     *   strategy: 'retry',
     *   retryDelay: 1000, // Wait 1 second between retries
     * };
     * await Assets.load('sometimes-fails.png', options);
     * ```
     */
    retryDelay?: number;
}
/**
 * The Loader is responsible for loading all assets, such as images, spritesheets, audio files, etc.
 * It does not do anything clever with URLs - it just loads stuff!
 * Behind the scenes all things are cached using promises. This means it's impossible to load an asset more than once.
 * Through the use of LoaderParsers, the loader can understand how to load any kind of file!
 *
 * It is not intended that this class is created by developers - its part of the Asset class
 * This is the second major system of PixiJS' main Assets class
 * @category assets
 * @advanced
 */
export declare class Loader {
    /**
     * Default options for loading assets
     * @example
     * ```ts
     * // Change default load options globally
     * Loader.defaultOptions = {
     *   strategy: 'skip', // Change default strategy to 'skip'
     *   retryCount: 5,   // Change default retry count to 5
     *   retryDelay: 500, // Change default retry delay to 500ms
     * };
     * ```
     */
    static defaultOptions: LoadOptions;
    /**
     * Options for loading assets with the loader.
     * These options will be used as defaults for all load calls made with this loader instance.
     * They can be overridden by passing options directly to the load method.
     * @example
     * ```ts
     * // Create a loader with custom default options
     * const loader = new Loader();
     * loader.loadOptions = {
     *   strategy: 'skip', // Default strategy to 'skip'
     *   retryCount: 5,   // Default retry count to 5
     *   retryDelay: 500, // Default retry delay to 500ms
     * };
     *
     * // This load call will use the loader's default options
     * await loader.load('image1.png');
     */
    loadOptions: LoadOptions;
    private readonly _parsers;
    private _parserHash;
    private _parsersValidated;
    /**
     * All loader parsers registered
     * @type {assets.LoaderParser[]}
     */
    parsers: LoaderParser<any, any, Record<string, any>>[];
    /** Cache loading promises that ae currently active */
    promiseCache: Record<string, PromiseAndParser>;
    /** function used for testing */
    reset(): void;
    /**
     * Used internally to generate a promise for the asset to be loaded.
     * @param url - The URL to be loaded
     * @param data - any custom additional information relevant to the asset being loaded
     * @returns - a promise that will resolve to an Asset for example a Texture of a JSON object
     */
    private _getLoadPromiseAndParser;
    /**
     * Loads one or more assets using the parsers added to the Loader.
     * @example
     * // Single asset:
     * const asset = await Loader.load('cool.png');
     * console.log(asset);
     *
     * // Multiple assets:
     * const assets = await Loader.load(['cool.png', 'cooler.png']);
     * console.log(assets);
     * @param assetsToLoadIn - urls that you want to load, or a single one!
     * @param onProgress - For multiple asset loading only, an optional function that is called
     * when progress on asset loading is made. The function is passed a single parameter, `progress`,
     * which represents the percentage (0.0 - 1.0) of the assets loaded. Do not use this function
     * to detect when assets are complete and available, instead use the Promise returned by this function.
     */
    load<T = any>(assetsToLoadIn: string | ResolvedAsset, onProgress?: ProgressCallback | LoadOptions): Promise<T>;
    load<T = any>(assetsToLoadIn: string[] | ResolvedAsset[], onProgress?: ProgressCallback | LoadOptions): Promise<Record<string, T>>;
    /**
     * Unloads one or more assets. Any unloaded assets will be destroyed, freeing up memory for your app.
     * The parser that created the asset, will be the one that unloads it.
     * @example
     * // Single asset:
     * const asset = await Loader.load('cool.png');
     *
     * await Loader.unload('cool.png');
     *
     * console.log(asset.destroyed); // true
     * @param assetsToUnloadIn - urls that you want to unload, or a single one!
     */
    unload(assetsToUnloadIn: string | string[] | ResolvedAsset | ResolvedAsset[]): Promise<void>;
    /** validates our parsers, right now it only checks for name conflicts but we can add more here as required! */
    private _validateParsers;
    private _loadAssetWithRetry;
}
