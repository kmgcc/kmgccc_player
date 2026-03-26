import type { ICanvas } from '../../../../environment/canvas/ICanvas';
import type { TextStyle } from '../../TextStyle';
import type { CanBreakCharsFn, MeasureTextFn, WordWrapSplitFn } from './types';
/**
 * Function type for checking if words can be broken.
 * @internal
 */
type CanBreakWordsFn = (token: string, breakWords: boolean) => boolean;
/**
 * Applies newlines to a string to have it optimally fit into the horizontal
 * bounds set by the Text object's wordWrapWidth property.
 * @param text - String to apply word wrapping to
 * @param style - the style to use when wrapping
 * @param canvas - specification of the canvas to use for measuring.
 * @param measureTextFn - Function to measure text width
 * @param canBreakWordsFn - Function to check if words can be broken
 * @param canBreakCharsFn - Function to check if characters can be broken
 * @param wordWrapSplitFn - Function to split words into characters
 * @returns New string with new lines applied where required
 * @internal
 */
export declare function wordWrap(text: string, style: TextStyle, canvas: ICanvas, measureTextFn: MeasureTextFn, canBreakWordsFn: CanBreakWordsFn, canBreakCharsFn: CanBreakCharsFn, wordWrapSplitFn: WordWrapSplitFn): string;
export {};
