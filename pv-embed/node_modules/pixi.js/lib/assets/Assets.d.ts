import { Cache } from './cache/Cache';
import { Loader, type LoadOptions } from './loader/Loader';
import { type LoadTextureConfig } from './loader/parsers/textures/loadTextures';
import { Resolver } from './resolver/Resolver';
import type { FormatDetectionParser } from './detections/types';
import type { LoadSVGConfig } from './loader/parsers/textures/loadSVG';
import type { BundleIdentifierOptions } from './resolver/Resolver';
import type { ArrayOr, AssetsBundle, AssetsManifest, ResolvedAsset, UnresolvedAsset } from './types';
/**
 * Callback function for tracking asset loading progress. The function is called repeatedly
 * during the loading process with a progress value between 0.0 and 1.0.
 * @param progress - The loading progress from 0.0 (started) to 1.0 (complete)
 * @returns void
 * @example
 * ```ts
 * // Basic progress logging
 * const onProgress = (progress: number) => {
 *     console.log(`Loading: ${Math.round(progress * 100)}%`);
 * };
 *
 * // Update loading bar
 * const onProgress = (progress: number) => {
 *     loadingBar.width = progress * 100;
 *     loadingText.text = `${Math.round(progress * 100)}%`;
 * };
 *
 * // Load assets with progress tracking
 * await Assets.load(['sprite1.png', 'sprite2.png'], onProgress);
 *
 * // Load bundle with progress tracking
 * await Assets.loadBundle('levelAssets', (progress) => {
 *     // Progress is normalized (0.0 - 1.0)
 *     updateLoadingScreen(progress);
 * });
 * ```
 * > [!IMPORTANT] Do not rely on the progress callback to determine when all assets are loaded.
 * > Use the returned promise from `Assets.load()` or `Assets.loadBundle()` to know when loading is complete.
 * @category assets
 * @standard
 */
export type ProgressCallback = (progress: number) => void;
/**
 * Extensible preferences that can be used, for instance, when configuring loaders.
 * @since 7.2.0
 * @advanced
 * @category assets
 */
export interface AssetsPreferences extends LoadTextureConfig, LoadSVGConfig, PixiMixins.AssetsPreferences {
}
/**
 * Options for initializing the Assets class. These options configure how assets are loaded,
 * resolved, and managed in your PixiJS application.
 * @category assets
 * @standard
 */
export interface AssetInitOptions {
    /**
     * Base path prepended to all asset URLs. Useful for CDN hosting.
     * @example
     * ```ts
     * await Assets.init({
     *     basePath: 'https://my-cdn.com/assets/'
     * });
     *
     * // Now you can load assets like this:
     * // Will load from: https://my-cdn.com/assets/images/sprite.png
     * const texture = await Assets.load('images/sprite.png');
     * ```
     */
    basePath?: string;
    /**
     * URL parameters to append to all asset URLs.
     * Useful for cache-busting or version control.
     * @example
     * ```ts
     * // As a string
     * await Assets.init({
     *     defaultSearchParams: 'version=1.0.0'
     * });
     *
     * // As an object
     * await Assets.init({
     *     defaultSearchParams: {
     *         version: '1.0.0',
     *         t: Date.now()
     *     }
     * });
     * ```
     * @advanced
     */
    defaultSearchParams?: string | Record<string, any>;
    /**
     * A manifest defining all your application's assets.
     * Can be a URL to a JSON file or a manifest object.
     * @example
     * ```ts
     * // Using a manifest object
     * await Assets.init({
     *     manifest: {
     *         bundles: [{
     *             name: 'game-screen',
     *             assets: [
     *                 {
     *                     alias: 'hero',
     *                     src: 'hero.{png,webp}'
     *                 },
     *                 {
     *                     alias: 'map',
     *                     src: 'map.json'
     *                 }
     *             ]
     *         }]
     *     }
     * });
     *
     * // Using a URL to manifest
     * await Assets.init({
     *     manifest: 'assets/manifest.json'
     * });
     *
     * // loading a bundle from the manifest
     * await Assets.loadBundle('game-screen');
     *
     * // load individual assets from the manifest
     * const heroTexture = await Assets.load('hero');
     * ```
     */
    manifest?: string | AssetsManifest;
    /**
     * Configure texture loading preferences.
     * Useful for optimizing asset delivery based on device capabilities.
     * @example
     * ```ts
     * await Assets.init({
     *     texturePreference: {
     *         // Prefer high-res textures on retina displays
     *         resolution: window.devicePixelRatio,
     *
     *         // Prefer modern formats, fallback to traditional
     *         format: ['avif', 'webp', 'png']
     *     }
     * });
     * ```
     */
    texturePreference?: {
        /** Preferred texture resolution(s). Can be a single number or array of resolutions in order of preference. */
        resolution?: number | number[];
        /** Preferred texture formats in order of preference. Default: ['avif', 'webp', 'png', 'jpg', 'jpeg'] */
        format?: ArrayOr<string>;
    };
    /**
     * Skip browser format detection for faster initialization.
     * Only use if you know exactly what formats your target browsers support.
     * @example
     * ```ts
     * await Assets.init({
     *     skipDetections: true,
     *     texturePreference: {
     *         format: ['webp', 'png'] // Must explicitly set formats
     *     }
     * });
     * ```
     * @advanced
     */
    skipDetections?: boolean;
    /**
     * Override how bundle IDs are generated and resolved.
     *
     * This allows you to customize how assets are grouped and accessed via bundles and allow for
     * multiple bundles to share the same asset keys.
     * @advanced
     * @example
     * ```ts
     * const manifest = {
     *     bundles: [
     *         {
     *             name: 'bunny1',
     *             assets: [
     *                 {
     *                     alias: ['character', 'character2'],
     *                     src: 'textures/bunny.png',
     *                 },
     *             ],
     *         },
     *         {
     *             name: 'bunny2',
     *             assets: [
     *                 {
     *                     alias: ['character', 'character2'],
     *                     src: 'textures/bunny-2.png',
     *                 },
     *             ],
     *         },
     *     ]
     * };
     *
     * const bundleIdentifier: BundleIdentifierOptions = {
     *     connector: ':',
     * };
     *
     * await Assets.init({ manifest, basePath, bundleIdentifier });
     *
     * const resources = await Assets.loadBundle('bunny1');
     * const resources2 = await Assets.loadBundle('bunny2');
     *
     * console.log(resources.character === resources2.character); // false
     * ```
     */
    bundleIdentifier?: BundleIdentifierOptions;
    /**
     * Optional preferences for asset loading behavior.
     * @example
     * ```ts
     * await Assets.init({
     *     preferences: {
     *         crossOrigin: 'anonymous',
     *         parseAsGraphicsContext: false
     *     }
     * });
     * ```
     */
    preferences?: Partial<AssetsPreferences>;
    /**
     * Options for defining the loading behavior of assets.
     * @example
     * ```ts
     * await Assets.init({
     *    loadOptions: {
     *       onProgress: (progress) => console.log(`Loading: ${Math.round(progress * 100)}%`),
     *       onError: (error, asset) => console.error(`Error loading ${asset.src}: ${error.message}`),
     *       strategy: 'retry',
     *       retryCount: 5,
     *       retryDelay: 500,
     *   }
     * });
     * ```
     * @remarks
     * - `onProgress` callback receives values from 0.0 to 1.0
     * - `onError` callback is invoked for individual asset load failures
     * - `strategy` can be 'throw' (default), 'retry', or 'skip'
     * - `retryCount` sets how many times to retry failed assets (default 3)
     * - `retryDelay` sets the delay between retries in milliseconds (default 250ms)
     * @see {@link LoadOptions} For all available load options
     */
    loadOptions?: Partial<LoadOptions>;
}
/** @internal */
export declare class AssetsClass {
    /**
     * The URL resolver for assets. Maps various asset keys and URLs to their final loadable form.
     * @advanced
     */
    resolver: Resolver;
    /**
     *  The loader responsible for loading all assets. Handles different file types
     * and transformations.
     * @advanced
     */
    loader: Loader;
    /**
     * The global cache for all loaded assets. Manages storage and retrieval of
     * processed assets.
     * @example
     * ```ts
     * // Check if an asset is cached
     * if (Assets.cache.has('myTexture')) {
     *     const texture = Assets.cache.get('myTexture');
     * }
     * ```
     * @see {@link Cache} For detailed cache documentation
     */
    cache: typeof Cache;
    /** takes care of loading assets in the background */
    private readonly _backgroundLoader;
    private readonly _detections;
    private _initialized;
    constructor();
    /**
     * Initializes the Assets class with configuration options. While not required,
     * calling this before loading assets is recommended to set up default behaviors.
     * @param options - Configuration options for the Assets system
     * @example
     * ```ts
     * // Basic initialization (optional as Assets.load will call this automatically)
     * await Assets.init();
     *
     * // With CDN configuration
     * await Assets.init({
     *     basePath: 'https://my-cdn.com/assets/',
     *     defaultSearchParams: { version: '1.0.0' }
     * });
     *
     * // With manifest and preferences
     * await Assets.init({
     *     manifest: {
     *         bundles: [{
     *             name: 'game-screen',
     *             assets: [
     *                 {
     *                     alias: 'hero',
     *                     src: 'hero.{png,webp}',
     *                     data: { scaleMode: SCALE_MODES.NEAREST }
     *                 },
     *                 {
     *                     alias: 'map',
     *                     src: 'map.json'
     *                 }
     *             ]
     *         }]
     *     },
     *     // Optimize for device capabilities
     *     texturePreference: {
     *         resolution: window.devicePixelRatio,
     *         format: ['webp', 'png']
     *     },
     *     // Set global preferences
     *     preferences: {
     *         crossOrigin: 'anonymous',
     *     }
     * });
     *
     * // Load assets after initialization
     * const heroTexture = await Assets.load('hero');
     * ```
     * @remarks
     * - Can be called only once; subsequent calls will be ignored with a warning
     * - Format detection runs automatically unless `skipDetections` is true
     * - The manifest can be a URL to a JSON file or an inline object
     * @see {@link AssetInitOptions} For all available initialization options
     * @see {@link AssetsManifest} For manifest format details
     */
    init(options?: AssetInitOptions): Promise<void>;
    /**
     * Registers assets with the Assets resolver. This method maps keys (aliases) to asset sources,
     * allowing you to load assets using friendly names instead of direct URLs.
     * @param assets - The unresolved assets to add to the resolver
     * @example
     * ```ts
     * // Basic usage - single asset
     * Assets.add({
     *     alias: 'myTexture',
     *     src: 'assets/texture.png'
     * });
     * const texture = await Assets.load('myTexture');
     *
     * // Multiple aliases for the same asset
     * Assets.add({
     *     alias: ['hero', 'player'],
     *     src: 'hero.png'
     * });
     * const hero1 = await Assets.load('hero');
     * const hero2 = await Assets.load('player'); // Same texture
     *
     * // Multiple format support
     * Assets.add({
     *     alias: 'character',
     *     src: 'character.{webp,png}' // Will choose best format
     * });
     * Assets.add({
     *     alias: 'character',
     *     src: ['character.webp', 'character.png'], // Explicitly specify formats
     * });
     *
     * // With texture options
     * Assets.add({
     *     alias: 'sprite',
     *     src: 'sprite.png',
     *     data: { scaleMode: 'nearest' }
     * });
     *
     * // Multiple assets at once
     * Assets.add([
     *     { alias: 'bg', src: 'background.png' },
     *     { alias: 'music', src: 'music.mp3' },
     *     { alias: 'spritesheet', src: 'sheet.json', data: { ignoreMultiPack: false } }
     * ]);
     * ```
     * @remarks
     * - Assets are resolved when loaded, not when added
     * - Multiple formats use the best available format for the browser
     * - Adding with same alias overwrites previous definition
     * - The `data` property is passed to the asset loader
     * @see {@link Resolver} For details on asset resolution
     * @see {@link LoaderParser} For asset-specific data options
     * @advanced
     */
    add(assets: (ArrayOr<UnresolvedAsset>)): void;
    /**
     * Loads one or more assets and returns a promise that resolves with the loaded content.
     * Assets are cached, so subsequent loads will return the same instance of the asset without re-fetching.
     * @param urls - Single URL/alias or array of URLs/aliases to load
     * @param onProgress - Optional callback for load progress (0.0 to 1.0)
     * @returns Promise that resolves with loaded asset(s)
     * @example
     * ```ts
     * // Load a single asset
     * const texture = await Assets.load('images/sprite.png');
     *
     * // Load using an alias
     * const heroTexture = await Assets.load({ alias: 'hero', src: 'images/hero.png' });
     *
     * // Load multiple assets
     * const assets = await Assets.load([
     *     'images/background.png',
     *     'images/character.png',
     *     'fonts/game.fnt'
     * ]);
     * console.log(assets['images/background.png']); // Access by URL
     *
     * // Load with progress tracking
     * const textures = await Assets.load(['sprite1.png', 'sprite2.png'],
     *     (progress) => console.log(`Loading: ${Math.round(progress * 100)}%`)
     * );
     *
     * // Load with format preference
     * const characterTexture = await Assets.load({
     *     alias: 'character',
     *     src: 'character.{webp,png}' // Will choose best format
     * });
     *
     * // Load with custom options
     * const spriteTexture = await Assets.load({
     *     alias: 'sprite',
     *     src: 'sprite.png',
     *     data: {
     *         scaleMode: SCALE_MODES.NEAREST,
     *         mipmap: MIPMAP_MODES.ON
     *     }
     * });
     *
     * // Load with a specific loader, can be useful if your asset does not have an extension
     * const image = await Assets.load({
     *    alias: 'imageWithoutExtension',
     *    src: 'images/imageWithoutExtension',
     *    parser: 'texture' // Use the JSON loader
     * });
     * ```
     * @remarks
     * - Assets are cached automatically to prevent duplicate loading
     * - URLs are resolved to the best format for the current browser
     * - Asset types are detected automatically based on file extension
     * - Progress callback receives values from 0.0 to 1.0
     * - You can define with loader to use for an asset by specifying the `parser` property, which is useful for assets that do not have a file extension.
     * @throws {Error} If the asset cannot be loaded or parsed
     * @see {@link Assets.add} For registering assets with aliases
     * @see {@link Assets.backgroundLoad} For loading assets in the background
     * @see {@link Assets.unload} For releasing loaded assets
     */
    load<T = any>(urls: string | UnresolvedAsset, onProgress?: ProgressCallback | LoadOptions): Promise<T>;
    load<T = any>(urls: string[] | UnresolvedAsset[], onProgress?: ProgressCallback | LoadOptions): Promise<Record<string, T>>;
    /**
     * Registers a bundle of assets that can be loaded as a group. Bundles are useful for organizing
     * assets into logical groups, such as game levels or UI screens.
     * @param bundleId - Unique identifier for the bundle
     * @param assets - Assets to include in the bundle
     * @example
     * ```ts
     * // Add a bundle using array format
     * Assets.addBundle('animals', [
     *     { alias: 'bunny', src: 'bunny.png' },
     *     { alias: 'chicken', src: 'chicken.png' },
     *     { alias: 'thumper', src: 'thumper.png' },
     * ]);
     *
     * // Add a bundle using object format
     * Assets.addBundle('animals', {
     *     bunny: 'bunny.png',
     *     chicken: 'chicken.png',
     *     thumper: 'thumper.png',
     * });
     *
     * // Add a bundle with advanced options
     * Assets.addBundle('ui', [
     *     {
     *         alias: 'button',
     *         src: 'button.{webp,png}',
     *         data: { scaleMode: 'nearest' }
     *     },
     *     {
     *         alias: ['logo', 'brand'],  // Multiple aliases
     *         src: 'logo.svg',
     *         data: { resolution: 2 }
     *     }
     * ]);
     *
     * // Load the bundle
     * await Assets.loadBundle('animals');
     *
     * // Use the loaded assets
     * const bunny = Sprite.from('bunny');
     * const chicken = Sprite.from('chicken');
     * ```
     * @remarks
     * - Bundle IDs must be unique
     * - Assets in bundles are not loaded until `loadBundle` is called
     * - Bundles can be background loaded using `backgroundLoadBundle`
     * - Assets in bundles can be loaded individually using their aliases
     * @see {@link Assets.loadBundle} For loading bundles
     * @see {@link Assets.backgroundLoadBundle} For background loading bundles
     * @see {@link Assets.unloadBundle} For unloading bundles
     * @see {@link AssetsManifest} For manifest format details
     */
    addBundle(bundleId: string, assets: AssetsBundle['assets']): void;
    /**
     * Loads a bundle or multiple bundles of assets. Bundles are collections of related assets
     * that can be loaded together.
     * @param bundleIds - Single bundle ID or array of bundle IDs to load
     * @param onProgress - Optional callback for load progress (0.0 to 1.0)
     * @returns Promise that resolves with the loaded bundle assets
     * @example
     * ```ts
     * // Define bundles in your manifest
     * const manifest = {
     *     bundles: [
     *         {
     *             name: 'load-screen',
     *             assets: [
     *                 {
     *                     alias: 'background',
     *                     src: 'sunset.png',
     *                 },
     *                 {
     *                     alias: 'bar',
     *                     src: 'load-bar.{png,webp}', // use an array of individual assets
     *                 },
     *             ],
     *         },
     *         {
     *             name: 'game-screen',
     *             assets: [
     *                 {
     *                     alias: 'character',
     *                     src: 'robot.png',
     *                 },
     *                 {
     *                     alias: 'enemy',
     *                     src: 'bad-guy.png',
     *                 },
     *             ],
     *         },
     *     ]
     * };
     *
     * // Initialize with manifest
     * await Assets.init({ manifest });
     *
     * // Or add bundles programmatically
     * Assets.addBundle('load-screen', [...]);
     * Assets.loadBundle('load-screen');
     *
     * // Load a single bundle
     * await Assets.loadBundle('load-screen');
     * const bg = Sprite.from('background'); // Uses alias from bundle
     *
     * // Load multiple bundles
     * await Assets.loadBundle([
     *     'load-screen',
     *     'game-screen'
     * ]);
     *
     * // Load with progress tracking
     * await Assets.loadBundle('game-screen', (progress) => {
     *     console.log(`Loading: ${Math.round(progress * 100)}%`);
     * });
     * ```
     * @remarks
     * - Bundle assets are cached automatically
     * - Bundles can be pre-loaded using `backgroundLoadBundle`
     * - Assets in bundles can be accessed by their aliases
     * - Progress callback receives values from 0.0 to 1.0
     * @throws {Error} If the bundle ID doesn't exist in the manifest
     * @see {@link Assets.addBundle} For adding bundles programmatically
     * @see {@link Assets.backgroundLoadBundle} For background loading bundles
     * @see {@link Assets.unloadBundle} For unloading bundles
     * @see {@link AssetsManifest} For manifest format details
     */
    loadBundle(bundleIds: ArrayOr<string>, onProgress?: ProgressCallback): Promise<any>;
    /**
     * Initiates background loading of assets. This allows assets to be loaded passively while other operations
     * continue, making them instantly available when needed later.
     *
     * Background loading is useful for:
     * - Preloading game levels while in a menu
     * - Loading non-critical assets during gameplay
     * - Reducing visible loading screens
     * @param urls - Single URL/alias or array of URLs/aliases to load in the background
     * @example
     * ```ts
     * // Basic background loading
     * Assets.backgroundLoad('images/level2-assets.png');
     *
     * // Background load multiple assets
     * Assets.backgroundLoad([
     *     'images/sprite1.png',
     *     'images/sprite2.png',
     *     'images/background.png'
     * ]);
     *
     * // Later, when you need the assets
     * const textures = await Assets.load([
     *     'images/sprite1.png',
     *     'images/sprite2.png'
     * ]); // Resolves immediately if background loading completed
     * ```
     * @remarks
     * - Background loading happens one asset at a time to avoid blocking the main thread
     * - Loading can be interrupted safely by calling `Assets.load()`
     * - Assets are cached as they complete loading
     * - No progress tracking is available for background loading
     */
    backgroundLoad(urls: ArrayOr<string>): Promise<void>;
    /**
     * Initiates background loading of asset bundles. Similar to backgroundLoad but works with
     * predefined bundles of assets.
     *
     * Perfect for:
     * - Preloading level bundles during gameplay
     * - Loading UI assets during splash screens
     * - Preparing assets for upcoming game states
     * @param bundleIds - Single bundle ID or array of bundle IDs to load in the background
     * @example
     * ```ts
     * // Define bundles in your manifest
     * await Assets.init({
     *     manifest: {
     *         bundles: [
     *             {
     *               name: 'home',
     *               assets: [
     *                 {
     *                     alias: 'background',
     *                     src: 'images/home-bg.png',
     *                 },
     *                 {
     *                     alias: 'logo',
     *                     src: 'images/logo.png',
     *                 }
     *              ]
     *            },
     *            {
     *             name: 'level-1',
     *             assets: [
     *                 {
     *                     alias: 'background',
     *                     src: 'images/level1/bg.png',
     *                 },
     *                 {
     *                     alias: 'sprites',
     *                     src: 'images/level1/sprites.json'
     *                 }
     *             ]
     *         }]
     *     }
     * });
     *
     * // Load the home screen assets right away
     * await Assets.loadBundle('home');
     * showHomeScreen();
     *
     * // Start background loading while showing home screen
     * Assets.backgroundLoadBundle('level-1');
     *
     * // When player starts level, load completes faster
     * await Assets.loadBundle('level-1');
     * hideHomeScreen();
     * startLevel();
     * ```
     * @remarks
     * - Bundle assets are loaded one at a time
     * - Loading can be interrupted safely by calling `Assets.loadBundle()`
     * - Assets are cached as they complete loading
     * - Requires bundles to be registered via manifest or `addBundle`
     * @see {@link Assets.addBundle} For adding bundles programmatically
     * @see {@link Assets.loadBundle} For immediate bundle loading
     * @see {@link AssetsManifest} For manifest format details
     */
    backgroundLoadBundle(bundleIds: ArrayOr<string>): Promise<void>;
    /**
     * Only intended for development purposes.
     * This will wipe the resolver and caches.
     * You will need to reinitialize the Asset
     * @internal
     */
    reset(): void;
    /**
     * Instantly gets an asset already loaded from the cache. Returns undefined if the asset hasn't been loaded yet.
     * @param keys - The key or keys for the assets to retrieve
     * @returns The cached asset(s) or undefined if not loaded
     * @example
     * ```ts
     * // Get a single cached asset
     * const texture = Assets.get('hero');
     * if (texture) {
     *     const sprite = new Sprite(texture);
     * }
     *
     * // Get multiple cached assets
     * const textures = Assets.get([
     *     'hero',
     *     'background',
     *     'enemy'
     * ]);
     *
     * // Safe pattern with loading fallback
     * let texture = Assets.get('hero');
     * if (!texture) {
     *     texture = await Assets.load('hero');
     * }
     *
     * // Working with bundles
     * await Assets.loadBundle('game-ui');
     * const uiAssets = Assets.get([
     *     'button',
     *     'panel',
     *     'icons'
     * ]);
     * ```
     * @remarks
     * - Returns undefined if asset isn't loaded
     * - No automatic loading - use `Assets.load()` for that
     * - Cached assets are shared instances
     * - Faster than `load()` for already cached assets
     *
     * > [!TIP]
     * > When in doubt, use `Assets.load()` instead. It will return cached
     * > assets instantly if they're already loaded.
     * @see {@link Assets.load} For loading assets that aren't cached
     * @see {@link Assets.cache} For direct cache access
     */
    get<T = any>(keys: string): T;
    get<T = any>(keys: string[]): Record<string, T>;
    /**
     * helper function to map resolved assets back to loaded assets
     * @param resolveResults - the resolve results from the resolver
     * @param progressOrLoadOptions - the progress callback or load options
     */
    private _mapLoadToResolve;
    /**
     * Unloads assets and releases them from memory. This method ensures proper cleanup of
     * loaded assets when they're no longer needed.
     * @param urls - Single URL/alias or array of URLs/aliases to unload
     * @example
     * ```ts
     * // Unload a single asset
     * await Assets.unload('images/sprite.png');
     *
     * // Unload using an alias
     * await Assets.unload('hero'); // Unloads the asset registered with 'hero' alias
     *
     * // Unload multiple assets
     * await Assets.unload([
     *     'images/background.png',
     *     'images/character.png',
     *     'hero'
     * ]);
     *
     * // Unload and handle creation of new instances
     * await Assets.unload('hero');
     * const newHero = await Assets.load('hero'); // Will load fresh from source
     * ```
     * @remarks
     * > [!WARNING]
     * > Make sure assets aren't being used before unloading:
     * > - Remove sprites using the texture
     * > - Clear any references to the asset
     * > - Textures will be destroyed and can't be used after unloading
     * @throws {Error} If the asset is not found in cache
     */
    unload(urls: ArrayOr<string> | ResolvedAsset | ResolvedAsset[]): Promise<void>;
    /**
     * Unloads all assets in a bundle. Use this to free memory when a bundle's assets
     * are no longer needed, such as when switching game levels.
     * @param bundleIds - Single bundle ID or array of bundle IDs to unload
     * @example
     * ```ts
     * // Define and load a bundle
     * Assets.addBundle('level-1', {
     *     background: 'level1/bg.png',
     *     sprites: 'level1/sprites.json',
     *     music: 'level1/music.mp3'
     * });
     *
     * // Load the bundle
     * const level1 = await Assets.loadBundle('level-1');
     *
     * // Use the assets
     * const background = Sprite.from(level1.background);
     *
     * // When done with the level, unload everything
     * await Assets.unloadBundle('level-1');
     * // background sprite is now invalid!
     *
     * // Unload multiple bundles
     * await Assets.unloadBundle([
     *     'level-1',
     *     'level-2',
     *     'ui-elements'
     * ]);
     * ```
     * @remarks
     * > [!WARNING]
     * > - All assets in the bundle will be destroyed
     * > - Bundle needs to be reloaded to use assets again
     * > - Make sure no sprites or other objects are using the assets
     * @throws {Error} If the bundle is not found
     * @see {@link Assets.addBundle} For adding bundles
     * @see {@link Assets.loadBundle} For loading bundles
     */
    unloadBundle(bundleIds: ArrayOr<string>): Promise<void>;
    private _unloadFromResolved;
    /**
     * Detects the supported formats for the browser, and returns an array of supported formats, respecting
     * the users preferred formats order.
     * @param options - the options to use when detecting formats
     * @param options.preferredFormats - the preferred formats to use
     * @param options.skipDetections - if we should skip the detections altogether
     * @param options.detections - the detections to use
     * @returns - the detected formats
     */
    private _detectFormats;
    /**
     * All the detection parsers currently added to the Assets class.
     * @advanced
     */
    get detections(): FormatDetectionParser[];
    /**
     * Sets global preferences for asset loading behavior. This method configures how assets
     * are loaded and processed across all parsers.
     * @param preferences - Asset loading preferences
     * @example
     * ```ts
     * // Basic preferences
     * Assets.setPreferences({
     *     crossOrigin: 'anonymous',
     *     parseAsGraphicsContext: false
     * });
     * ```
     * @remarks
     * Preferences are applied to all compatible parsers and affect future asset loading.
     * Common preferences include:
     * - `crossOrigin`: CORS setting for loaded assets
     * - `preferWorkers`: Whether to use web workers for loading textures
     * - `preferCreateImageBitmap`: Use `createImageBitmap` for texture creation. Turning this off will use the `Image` constructor instead.
     * @see {@link AssetsPreferences} For all available preferences
     */
    setPreferences(preferences: Partial<AssetsPreferences>): void;
}
/**
 * The global Assets class is a singleton that manages loading, caching, and unloading of all resources
 * in your PixiJS application.
 *
 * Key responsibilities:
 * - **URL Resolution**: Maps URLs/keys to browser-compatible resources
 * - **Resource Loading**: Handles loading and transformation of assets
 * - **Asset Caching**: Manages a global cache to prevent duplicate loads
 * - **Memory Management**: Provides unloading capabilities to free memory
 *
 * Advanced Features:
 * - **Asset Bundles**: Group and manage related assets together
 * - **Background Loading**: Load assets before they're needed over time
 * - **Format Detection**: Automatically select optimal asset formats
 *
 * Supported Asset Types:
 * | Type                | Extensions                                                       | Loaders                                                               |
 * | ------------------- | ---------------------------------------------------------------- | --------------------------------------------------------------------- |
 * | Textures            | `.png`, `.jpg`, `.gif`, `.webp`, `.avif`, `.svg`                 | {@link loadTextures}, {@link loadSvg}                                 |
 * | Video Textures      | `.mp4`, `.m4v`, `.webm`, `.ogg`, `.ogv`, `.h264`, `.avi`, `.mov` | {@link loadVideoTextures}                                             |
 * | Sprite Sheets       | `.json`                                                          | {@link spritesheetAsset}                                              |
 * | Bitmap Fonts        | `.fnt`, `.xml`, `.txt`                                           | {@link loadBitmapFont}                                                |
 * | Web Fonts           | `.ttf`, `.otf`, `.woff`, `.woff2`                                | {@link loadWebFont}                                                   |
 * | JSON                | `.json`                                                          | {@link loadJson}                                                      |
 * | Text                | `.txt`                                                           | {@link loadTxt}                                                       |
 * | Compressed Textures | `.basis`, `.dds`, `.ktx`, `.ktx2`                                | {@link loadBasis}, {@link loadDDS}, {@link loadKTX}, {@link loadKTX2} |
 * > [!NOTE] Some loaders allow for custom configuration, please refer to the specific loader documentation for details.
 * @example
 * ```typescript
 * import { Assets } from 'pixi.js';
 *
 * // Initialize with options (optional). You can call Assets.load directly without init.
 * await Assets.init({
 *     // Base path for all asset URLs
 *     basePath: 'https://my-cdn.com/assets/',
 *     // Manifest object that defines all assets
 *     manifest: {
 *        bundles: [{ name: 'gameAssets', assets: [] }, ...],
 *     }, *
 *     // Preferred texture settings
 *     texturePreference: {
 *         resolution: window.devicePixelRatio,
 *         format: ['avif', 'webp', 'png']
 *     }
 * });
 *
 * // Basic loading
 * const texture = await Assets.load('images/sprite.png');
 *
 * // Load multiple assets
 * const assets = await Assets.load([
 *     'images/bg.png',
 *     'images/character.png',
 *     'fonts/game.fnt'
 * ]);
 *
 * // Using aliases + multiple formats
 * await Assets.load({ alias: 'hero', src: 'images/hero.{webp,png}' });
 * const sprite = Sprite.from('hero'); // Uses the best available format
 *
 * // background loading
 * Assets.backgroundLoad(['images/level1.json', 'images/level2.json']); // Loads in the background one at a time
 *
 * // Load a bundle of assets from the manifest
 * const levelAssets = await Assets.loadBundle('gameAssets');
 * // Background loading of a bundle. This will load assets in the background one at a time.
 * // Can be interrupted at any time by calling Assets.loadBundle('gameAssets') again.
 * Assets.backgroundLoadBundle('resultsAssets');
 *
 * // Memory management
 * await Assets.unload('hero');
 * await Assets.unloadBundle('levelOne');
 * ```
 * @remarks
 * - Assets are cached automatically and only loaded once
 * - Background loading helps eliminate loading screens
 * - Format detection ensures optimal asset delivery
 * - Bundle management simplifies resource organization
 *
 * > [!IMPORTANT]
 * > When unloading assets, ensure they aren't being used elsewhere
 * > in your application to prevent missing texture references.
 * @see {@link AssetInitOptions} For initialization options
 * @see {@link AssetsPreferences} For advanced preferences
 * @see {@link BackgroundLoader} For background loading capabilities
 * @see {@link AssetsManifest} For manifest-based asset management
 * @see {@link Loader} For the underlying loading system
 * @see {@link Cache} For the caching system
 * @see {@link Resolver} For URL resolution details
 * @category assets
 * @class
 * @standard
 */
export declare const Assets: AssetsClass;
