import { type TextStyleRun } from './parseTaggedText';
import type { ICanvasRenderingContext2D } from '../../../../environment/canvas/ICanvasRenderingContext2D';
import type { TextStyle } from '../../TextStyle';
import type { CanBreakCharsFn, FontMetrics, MeasureTextFn, WordWrapSplitFn } from './types';
/**
 * Function type for measuring font metrics.
 * @internal
 */
type MeasureFontFn = (font: string) => FontMetrics;
/**
 * Result of measuring tagged text.
 * @internal
 */
interface TaggedMeasurementResult {
    /** Total width including stroke and shadow */
    width: number;
    /** Total height including shadow */
    height: number;
    /** Array of line text (for compatibility) */
    lines: string[];
    /** Per-line widths */
    lineWidths: number[];
    /** Base line height from style */
    lineHeight: number;
    /** Maximum line width */
    maxLineWidth: number;
    /** Font properties from base style */
    fontProperties: FontMetrics;
    /** Per-line style runs */
    runsByLine: TextStyleRun[][];
    /** Per-line ascent values */
    lineAscents: number[];
    /** Per-line descent values */
    lineDescents: number[];
    /** Per-line heights */
    lineHeights: number[];
    /** Whether any run has drop shadow */
    hasDropShadow: boolean;
}
/**
 * Styled token with continuation flag for word wrapping.
 * @internal
 */
interface StyledToken {
    token: string;
    style: TextStyle;
    continuesFromPrevious: boolean;
}
/**
 * Measures tagged text with multiple styles.
 * Handles per-run font measurement and per-line metrics.
 * @param text - The tagged text to measure
 * @param style - The base text style containing tagStyles
 * @param wordWrap - Whether to apply word wrapping
 * @param context - The canvas 2D context
 * @param measureTextFn - Function to measure text width
 * @param measureFontFn - Function to measure font metrics
 * @param canBreakCharsFn - Function to check if characters can be broken
 * @param wordWrapSplitFn - Function to split words into characters
 * @returns TaggedMeasurementResult with all measurement data
 * @internal
 */
export declare function measureTaggedText(text: string, style: TextStyle, wordWrap: boolean, context: ICanvasRenderingContext2D, measureTextFn: MeasureTextFn, measureFontFn: MeasureFontFn, canBreakCharsFn: CanBreakCharsFn, wordWrapSplitFn: WordWrapSplitFn): TaggedMeasurementResult;
/**
 * Applies word wrapping to tagged text lines.
 * Breaks runs at word boundaries while maintaining style information.
 * @param runsByLine - Array of run arrays, one per line
 * @param style - The base text style
 * @param context - The canvas 2D context
 * @param measureTextFn - Function to measure text width
 * @param canBreakCharsFn - Function to check if characters can be broken
 * @param wordWrapSplitFn - Function to split words into characters
 * @returns New runsByLine array with word wrap applied
 * @internal
 */
export declare function wordWrapTaggedLines(runsByLine: TextStyleRun[][], style: TextStyle, context: ICanvasRenderingContext2D, measureTextFn: MeasureTextFn, canBreakCharsFn: CanBreakCharsFn, wordWrapSplitFn: WordWrapSplitFn): TextStyleRun[][];
/**
 * Tokenizes an array of TextStyleRuns into individual styled tokens.
 * Each token is a word, space, or newline with its associated style.
 * Tracks whether adjacent tokens across run boundaries form a continuous word.
 * @param runs - The runs to tokenize
 * @returns Array of styled tokens with continuation flags
 * @internal
 */
export declare function tokenizeTaggedRuns(runs: TextStyleRun[]): StyledToken[];
export {};
