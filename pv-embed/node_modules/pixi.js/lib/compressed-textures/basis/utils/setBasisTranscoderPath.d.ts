/**
 * The urls for the Basis transcoder files.
 * These can be set to custom paths if needed.
 * @category assets
 * @advanced
 */
export declare const basisTranscoderUrls: {
    jsUrl: string;
    wasmUrl: string;
};
/**
 * Sets the Basis transcoder paths.
 * This allows you to override the default paths for the Basis transcoder files.
 * @param config - The configuration object containing the new paths.
 * @category assets
 * @advanced
 */
export declare function setBasisTranscoderPath(config: Partial<typeof basisTranscoderUrls>): void;
