import type { TextStyle } from '../../TextStyle';
/**
 * Represents a run of text with a specific style.
 * Used internally for tagged text rendering.
 * @internal
 */
export interface TextStyleRun {
    /** The text content of this run */
    text: string;
    /** The computed style for this run (base style merged with tag overrides) */
    style: TextStyle;
}
/**
 * Checks whether the given style has tagStyles defined with at least one entry.
 * @param style - The TextStyle to check
 * @returns True if tagStyles is defined and has entries
 * @internal
 */
export declare function hasTagStyles(style: TextStyle): boolean;
/**
 * Checks whether the text contains potential tag markup.
 * This is a quick check before attempting to parse.
 * @param text - The text to check
 * @returns True if text contains '<' character
 * @internal
 */
export declare function hasTagMarkup(text: string): boolean;
/**
 * Parses text with tag markup into an array of styled runs.
 * Supports simple open/close tags like `<red>text</red>`.
 * Nested tags are supported via a stack - inner tags inherit from outer tags.
 * Unknown tags (not in tagStyles) are treated as literal text.
 * @param text - The text to parse
 * @param style - The base TextStyle containing tagStyles
 * @returns Array of TextStyleRun objects
 * @internal
 */
export declare function parseTaggedText(text: string, style: TextStyle): TextStyleRun[];
/**
 * Extracts plain text from tagged text (strips all tags).
 * Useful for cache keys and debugging.
 * @param text - The tagged text
 * @param style - The TextStyle containing tagStyles
 * @returns Plain text with tags removed
 * @internal
 */
export declare function getPlainText(text: string, style: TextStyle): string;
