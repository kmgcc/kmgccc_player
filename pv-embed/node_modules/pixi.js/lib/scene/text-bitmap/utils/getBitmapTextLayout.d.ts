import type { TextStyle } from '../../text/TextStyle';
import type { AbstractBitmapFont } from '../AbstractBitmapFont';
/**
 * The layout data for a bitmap text.
 * This contains the width, height, scale, offsetY and lines of text.
 * Each line contains its width, character positions, characters, space width and spaces index.
 * @category text
 * @internal
 */
export interface BitmapTextLayoutData {
    width: number;
    height: number;
    scale: number;
    offsetY: number;
    lines: {
        width: number;
        charPositions: number[];
        chars: string[];
        spaceWidth: number;
        spacesIndex: number[];
    }[];
}
/**
 * @param chars
 * @param style
 * @param font
 * @param trimEnd
 * @internal
 */
export declare function getBitmapTextLayout(chars: string[], style: TextStyle, font: AbstractBitmapFont<any>, trimEnd: boolean): BitmapTextLayoutData;
