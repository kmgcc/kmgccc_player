import { type BatchableSprite } from '../../sprite/BatchableSprite';
import { type AbstractText } from '../AbstractText';
import { type TextStyle, type TextStyleOptions } from '../TextStyle';
/**
 * Updates the bounds of the given batchable sprite based on the provided text object.
 *
 * This function adjusts the bounds of the batchable sprite to match the dimensions
 * and anchor point of the text's texture. Additionally, it compensates for any padding
 * specified in the text's style to ensure the text is rendered correctly on screen.
 * @param {BatchableSprite} batchableSprite - The sprite whose bounds need to be updated.
 * @param {AbstractText} text - The text object containing the texture and style information.
 * @internal
 */
export declare function updateTextBounds(batchableSprite: BatchableSprite, text: AbstractText<TextStyle, TextStyleOptions>): void;
