import { TextureStyle, type TextureStyleOptions } from '../../rendering/renderers/shared/texture/TextureStyle';
import { AbstractText } from '../text/AbstractText';
import { type BatchableHTMLText } from './BatchableHTMLText';
import { HTMLTextStyle } from './HTMLTextStyle';
import './init';
import type { View } from '../../rendering/renderers/shared/view/View';
import type { TextOptions, TextString } from '../text/AbstractText';
import type { HTMLTextStyleOptions } from './HTMLTextStyle';
/**
 * Constructor options used for `HTMLText` instances. Extends the base text options
 * with HTML-specific features and texture styling capabilities.
 * @example
 * ```ts
 * // Basic HTML text
 * const basicText = new HTMLText({
 *     text: '<b>Bold</b> and <i>Italic</i> text',
 *     style: {
 *         fontSize: 24,
 *         fill: 0xff1010
 *     }
 * });
 *
 * // Rich HTML text with styling
 * const richText = new HTMLText({
 *     text: '<custom>Custom Tag</custom>',
 *     style: {
 *         fontFamily: 'Arial',
 *         fontSize: 32,
 *         fill: 0x4a4a4a,
 *         align: 'center',
 *         tagStyles: {
 *             custom: {
 *                 fontSize: 32,
 *                 fill: '#00ff00',
 *                 fontStyle: 'italic'
 *             }
 *         }
 *     }
 *     textureStyle: {
 *         scaleMode: 'linear',
 *     }
 * });
 * ```
 * @category text
 * @standard
 */
export interface HTMLTextOptions extends TextOptions<HTMLTextStyle, HTMLTextStyleOptions>, PixiMixins.HTMLTextOptions {
    /**
     * Optional texture style to use for the text texture. This allows fine control over
     * how the text is rendered to a texture before being displayed.
     *
     * The texture style can affect:
     * - Scale mode (nearest/linear)
     * - Resolution
     * - Format (rgb/rgba)
     * - Alpha handling
     * @example
     * ```ts
     * const text = new HTMLText({
     *     text: 'Crisp Text',
     *     textureStyle: {
     *         scaleMode: 'nearest', // Pixel-perfect scaling
     *     }
     * });
     * ```
     * @advanced
     */
    textureStyle?: TextureStyle | TextureStyleOptions;
    /**
     * Whether to generate mipmaps for the text texture.
     * Improves rendering quality when the text is scaled down.
     * @default undefined - Falls back to TextureSource.defaultOptions.autoGenerateMipmaps
     */
    autoGenerateMipmaps?: boolean;
}
export interface HTMLText extends PixiMixins.HTMLText, AbstractText<HTMLTextStyle, HTMLTextStyleOptions, HTMLTextOptions, BatchableHTMLText> {
}
/**
 * A HTMLText object creates text using HTML/CSS rendering with SVG foreignObject.
 * This allows for rich text formatting using standard HTML tags and CSS styling.
 *
 * Key features:
 * - HTML tag support (&lt;strong&gt;, &lt;em&gt;, etc.)
 * - CSS styling and custom style overrides
 * - Emoji and special character support
 * - Line breaking and word wrapping
 * - SVG-based rendering
 * @example
 * ```ts
 * import { HTMLText } from 'pixi.js';
 *
 * // Basic HTML text with tags
 * const text = new HTMLText({
 *     text: '<h1>Title</h1><p>This is a <strong>bold</strong> and <em>italic</em> text.</p>',
 *     style: {
 *         fontFamily: 'Arial',
 *         fontSize: 24,
 *         fill: 0xff1010,
 *         align: 'center',
 *     }
 * });
 *
 * // Rich HTML text with custom styling
 * const richText = new HTMLText({
 *     text: `
 *         <div class="title">Welcome</div>
 *         <div class="content">
 *             This text supports:
 *             <ul>
 *                 <li>✨ Emojis</li>
 *                 <li>🎨 Custom CSS</li>
 *                 <li>📏 Auto-sizing</li>
 *             </ul>
 *         </div>
 *     `,
 *     style: {
 *         fontSize: 24,
 *         fill: '#334455',
 *         cssOverrides: [
 *             '.title { font-size: 32px; color: red; }',
 *             '.content { line-height: 1.5; }'
 *         ],
 *         wordWrap: true,
 *         wordWrapWidth: 300,
 *     }
 * });
 *
 * // Text with custom texture settings
 * const crispText = new HTMLText({
 *     text: '<div style="padding: 10px">High Quality Text</div>',
 *     style: {
 *         fontSize: 24,
 *         fill: '#4a4a4a',
 *     },
 *     textureStyle: {
 *         scaleMode: 'nearest',
 *     }
 * });
 * ```
 *
 * Platform Considerations:
 * - Rendering may vary slightly between browsers
 * - Requires browser support for foreignObject
 * - Performance similar to Canvas text
 * - Memory usage comparable to Canvas text
 * @category text
 * @standard
 * @see {@link HTMLTextStyle} For detailed style options
 * @see {@link Text} For canvas-based text rendering
 * @see {@link BitmapText} For high-performance static text
 */
export declare class HTMLText extends AbstractText<HTMLTextStyle, HTMLTextStyleOptions, HTMLTextOptions, BatchableHTMLText> implements View {
    /** @internal */
    readonly renderPipeId: string;
    /**
     * Optional texture style to use for the text.
     * > [!NOTE] HTMLText is not updated when this property is updated,
     * > you must update the text manually by calling `text.onViewUpdate()`
     * @advanced
     */
    textureStyle?: TextureStyle;
    /**
     * Whether to generate mipmaps for the text texture.
     * Improves rendering quality when the text is scaled down.
     * > [!NOTE] HTMLText is not updated when this property is updated,
     * > you must update the text manually by calling `text.onViewUpdate()`
     * @default undefined - Falls back to TextureSource.defaultOptions.autoGenerateMipmaps
     */
    autoGenerateMipmaps?: boolean;
    /**
     * @param {HTMLTextOptions} options - The options of the html text.
     */
    constructor(options?: HTMLTextOptions);
    /** @deprecated since 8.0.0 */
    constructor(text?: TextString, options?: Partial<HTMLTextStyle>);
    /** @private */
    protected updateBounds(): void;
    get text(): string;
    /**
     * The text content to display. Use '\n' for line breaks.
     * Accepts strings, numbers, or objects with toString() method.
     * @example
     * ```ts
     * const text = new HTMLText({
     *     text: 'Hello Pixi!',
     * });
     * const multilineText = new HTMLText({
     *     text: 'Line 1\nLine 2\nLine 3',
     * });
     * const numberText = new HTMLText({
     *     text: 12345, // Will be converted to '12345'
     * });
     * const objectText = new HTMLText({
     *     text: { toString: () => 'Object Text' }, // Custom toString
     * });
     *
     * // Update text dynamically
     * text.text = 'Updated Text'; // Re-renders with new text
     * text.text = 67890; // Updates to '67890'
     * text.text = { toString: () => 'Dynamic Text' }; // Uses custom toString method
     * // Clear text
     * text.text = ''; // Clears the text
     * ```
     * @default ''
     */
    set text(text: TextString);
    /**
     * Sanitise text - replace `<br>` with `<br/>`, `&nbsp;` with `&#160;`
     * @param text
     * @see https://www.sitepoint.com/community/t/xhtml-1-0-transitional-xml-parsing-error-entity-nbsp-not-defined/3392/3
     */
    private _sanitiseText;
    private _removeInvalidHtmlTags;
}
