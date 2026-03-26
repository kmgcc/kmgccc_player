/**
 * Path utilities for working with URLs and file paths in a cross-platform way.
 * All paths that are passed in will become normalized to have posix separators.
 * ```js
 * import { path } from 'pixi.js';
 *
 * path.normalize('http://www.example.com/foo/bar/../baz'); // http://www.example.com/foo/baz
 * ```
 * @category utils
 * @advanced
 */
export interface Path {
    /**
     * Converts a path to posix format.
     * @param path - The path to convert to posix
     */
    toPosix: (path: string) => string;
    /**
     * Checks if the path is a URL e.g. http://, https://
     * @param path - The path to check
     */
    isUrl: (path: string) => boolean;
    /**
     * Checks if the path is a data URL
     * @param path - The path to check
     */
    isDataUrl: (path: string) => boolean;
    /**
     * Checks if the path is a blob URL
     * @param path - The path to check
     */
    isBlobUrl: (path: string) => boolean;
    /**
     * Checks if the path has a protocol e.g. http://, https://, file:///, data:, blob:, C:/
     * This will return true for windows file paths
     * @param path - The path to check
     */
    hasProtocol: (path: string) => boolean;
    /**
     * Returns the protocol of the path e.g. http://, https://, file:///, data:, blob:, C:/
     * @param path - The path to get the protocol from
     */
    getProtocol: (path: string) => string;
    /**
     * Converts URL to an absolute path.
     * When loading from a Web Worker, we must use absolute paths.
     * If the URL is already absolute we return it as is
     * If it's not, we convert it
     * @param url - The URL to test
     * @param baseUrl - The base URL to use
     * @param rootUrl - The root URL to use
     */
    toAbsolute: (url: string, baseUrl?: string, rootUrl?: string) => string;
    /**
     * Normalizes the given path, resolving '..' and '.' segments
     * @param path - The path to normalize
     */
    normalize: (path: string) => string;
    /**
     * Determines if path is an absolute path.
     * Absolute paths can be urls, data urls, or paths on disk
     * @param path - The path to test
     */
    isAbsolute: (path: string) => boolean;
    /**
     * Joins all given path segments together using the platform-specific separator as a delimiter,
     * then normalizes the resulting path
     * @param paths - The segments of the path to join
     */
    join: (...paths: string[]) => string;
    /**
     * Returns the directory name of a path
     * @param path - The path to parse
     */
    dirname: (path: string) => string;
    /**
     * Returns the root of the path e.g. /, C:/, file:///, http://domain.com/
     * @param path - The path to parse
     */
    rootname: (path: string) => string;
    /**
     * Returns the last portion of a path
     * @param path - The path to test
     * @param ext - Optional extension to remove
     */
    basename: (path: string, ext?: string) => string;
    /**
     * Returns the extension of the path, from the last occurrence of the . (period) character to end of string in the last
     * portion of the path. If there is no . in the last portion of the path, or if there are no . characters other than
     * the first character of the basename of path, an empty string is returned.
     * @param path - The path to parse
     */
    extname: (path: string) => string;
    /**
     * Parses a path into an object containing the 'root', `dir`, `base`, `ext`, and `name` properties.
     * @param path - The path to parse
     */
    parse: (path: string) => {
        root?: string;
        dir?: string;
        base?: string;
        ext?: string;
        name?: string;
    };
    sep: string;
    delimiter: string;
    joinExtensions: string[];
}
/**
 * Path utilities for working with URLs and file paths in a cross-platform way.
 * All paths that are passed in will become normalized to have posix separators.
 * @example
 * ```ts
 * import { path } from 'pixi.js';
 *
 * // Basic path normalization
 * path.normalize('http://www.example.com/foo/bar/../baz');
 * // -> 'http://www.example.com/foo/baz'
 *
 * // Working with file paths
 * path.join('assets', 'images', 'sprite.png');
 * // -> 'assets/images/sprite.png'
 *
 * // URL handling
 * path.toAbsolute('images/texture.png', 'http://example.com/assets/');
 * // -> 'http://example.com/assets/images/texture.png'
 * ```
 * @remarks
 * - Normalizes to POSIX separators (forward slashes)
 * - Handles URLs, data URLs, and file paths
 * - Supports path composition and decomposition
 * - Common in asset loading and URL management
 * @category utils
 * @standard
 * @see {@link Path} For full API reference
 * @see {@link DOMAdapter} For platform-specific path handling
 */
export declare const path: Path;
