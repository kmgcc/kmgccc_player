import { TextureSource } from './TextureSource';
import type { ExtensionMetadata } from '../../../../../extensions/Extensions';
import type { Dict } from '../../../../../utils/types';
import type { ALPHA_MODES } from '../const';
import type { TextureSourceOptions } from './TextureSource';
/**
 * The type of resource used for video textures.
 * This is typically an HTMLVideoElement.
 * @category rendering
 * @advanced
 */
export type VideoResource = HTMLVideoElement;
/**
 * Options for video sources.
 * @category rendering
 * @advanced
 */
export interface VideoSourceOptions extends TextureSourceOptions<VideoResource> {
    /** If true, the video will start loading immediately. */
    autoLoad?: boolean;
    /** If true, the video will start playing as soon as it is loaded. */
    autoPlay?: boolean;
    /** The number of times a second to update the texture from the video. Leave at 0 to update at every render. */
    updateFPS?: number;
    /** If true, the video will be loaded with the `crossorigin` attribute. */
    crossorigin?: boolean | string;
    /** If true, the video will loop when it ends. */
    loop?: boolean;
    /** If true, the video will be muted. */
    muted?: boolean;
    /** If true, the video will play inline. */
    playsinline?: boolean;
    /** If true, the video will be preloaded. */
    preload?: boolean;
    /** The time in milliseconds to wait for the video to preload before timing out. */
    preloadTimeoutMs?: number;
    /** The alpha mode of the video. */
    alphaMode?: ALPHA_MODES;
}
/**
 * A texture source that uses a video as its resource.
 * It automatically resizes the texture based on the video dimensions.
 * It also provides methods to control playback and handle video events.
 * This class supports automatic loading, playback, and frame updates.
 * It can also handle cross-origin videos and provides options for looping, muting, and inline playback.
 * @category rendering
 * @advanced
 */
export declare class VideoSource extends TextureSource<VideoResource> {
    static extension: ExtensionMetadata;
    /** The default options for video sources. */
    static defaultOptions: VideoSourceOptions;
    /** Whether or not the video is ready to play. */
    isReady: boolean;
    /** The upload method for this texture. */
    uploadMethodId: string;
    /**
     * When set to true will automatically play videos used by this texture once
     * they are loaded. If false, it will not modify the playing state.
     * @default true
     */
    protected autoPlay: boolean;
    /**
     * `true` to use Ticker.shared to auto update the base texture.
     * @default true
     */
    private _autoUpdate;
    /**
     * `true` if the instance is currently connected to Ticker.shared to auto update the base texture.
     * @default false
     */
    private _isConnectedToTicker;
    /**
     * Promise when loading.
     * @default null
     */
    private _load;
    private _msToNextUpdate;
    private _preloadTimeout;
    /** Callback when completed with load. */
    private _resolve;
    private _reject;
    private _updateFPS;
    private _videoFrameRequestCallbackHandle;
    constructor(options: VideoSourceOptions);
    /** Update the video frame if the source is not destroyed and meets certain conditions. */
    protected updateFrame(): void;
    /** Callback to update the video frame and potentially request the next frame update. */
    private _videoFrameRequestCallback;
    /**
     * Checks if the resource has valid dimensions.
     * @returns {boolean} True if width and height are set, otherwise false.
     */
    get isValid(): boolean;
    /**
     * Start preloading the video resource.
     * @returns {Promise<this>} Handle the validate event
     */
    load(): Promise<this>;
    /**
     * Handle video error events.
     * @param event - The error event
     */
    private _onError;
    /**
     * Checks if the underlying source is playing.
     * @returns True if playing.
     */
    private _isSourcePlaying;
    /**
     * Checks if the underlying source is ready for playing.
     * @returns True if ready.
     */
    private _isSourceReady;
    /** Runs the update loop when the video is ready to play. */
    private _onPlayStart;
    /** Stops the update loop when a pause event is triggered. */
    private _onPlayStop;
    /** Handles behavior when the video completes seeking to the current playback position. */
    private _onSeeked;
    private _onCanPlay;
    private _onCanPlayThrough;
    /** Fired when the video is loaded and ready to play. */
    private _mediaReady;
    /** Cleans up resources and event listeners associated with this texture. */
    destroy(): void;
    /** Should the base texture automatically update itself, set to true by default. */
    get autoUpdate(): boolean;
    set autoUpdate(value: boolean);
    /**
     * How many times a second to update the texture from the video.
     * Leave at 0 to update at every render.
     * A lower fps can help performance, as updating the texture at 60fps on a 30ps video may not be efficient.
     */
    get updateFPS(): number;
    set updateFPS(value: number);
    /**
     * Configures the updating mechanism based on the current state and settings.
     *
     * This method decides between using the browser's native video frame callback or a custom ticker
     * for updating the video frame. It ensures optimal performance and responsiveness
     * based on the video's state, playback status, and the desired frames-per-second setting.
     *
     * - If `_autoUpdate` is enabled and the video source is playing:
     *   - It will prefer the native video frame callback if available and no specific FPS is set.
     *   - Otherwise, it will use a custom ticker for manual updates.
     * - If `_autoUpdate` is disabled or the video isn't playing, any active update mechanisms are halted.
     */
    private _configureAutoUpdate;
    /**
     * Map of video MIME types that can't be directly derived from file extensions.
     * @readonly
     */
    static MIME_TYPES: Dict<string>;
    static test(resource: any): resource is VideoResource;
}
