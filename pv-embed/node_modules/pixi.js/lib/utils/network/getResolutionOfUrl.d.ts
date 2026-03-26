/**
 * get the resolution / device pixel ratio of an asset by looking for the prefix
 * used by spritesheets and image urls
 * @category utils
 * @internal
 * @param {string} url - the image path
 * @param {number} [defaultValue=1] - the defaultValue if no filename prefix is set.
 * @returns {number} resolution / device pixel ratio of an asset
 */
export declare function getResolutionOfUrl(url: string, defaultValue?: number): number;
