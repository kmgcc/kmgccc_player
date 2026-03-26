import { type SplitOptions } from '../../text-split/SplitText';
import { type TextSplitOutput } from '../../text-split/types';
import { Text } from '../Text';
/**
 * Splits a Text object into segments based on the text's layout and style,
 * and adds these segments as individual Text objects to a specified container.
 *
 * This function handles word wrapping, alignment, and letter spacing,
 * ensuring that each segment is rendered correctly according to the original text's style.
 * It uses the CanvasTextMetrics to measure text dimensions and segment the text into lines.
 * @param options - Configuration options for the text split operation.
 * @returns An array of Text objects representing the split segments.
 * @internal
 */
export declare function canvasTextSplit(options: Pick<SplitOptions, 'text' | 'style'> & {
    chars: Text[];
}): TextSplitOutput<Text>;
