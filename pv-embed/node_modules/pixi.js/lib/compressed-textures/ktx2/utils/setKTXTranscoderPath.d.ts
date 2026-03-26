/**
 * The urls for the KTX transcoder library.
 * These can be set to custom paths if needed.
 * @category assets
 * @advanced
 */
export declare const ktxTranscoderUrls: {
    jsUrl: string;
    wasmUrl: string;
};
/**
 * Sets the paths for the KTX transcoder library.
 * @param config - Partial configuration object to set custom paths for the KTX transcoder.
 * This allows you to override the default URLs for the KTX transcoder library.
 * @category assets
 * @advanced
 */
export declare function setKTXTranscoderPath(config: Partial<typeof ktxTranscoderUrls>): void;
