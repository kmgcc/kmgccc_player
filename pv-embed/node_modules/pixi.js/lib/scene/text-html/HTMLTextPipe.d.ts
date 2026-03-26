import { ExtensionType } from '../../extensions/Extensions';
import { BatchableHTMLText } from './BatchableHTMLText';
import type { InstructionSet } from '../../rendering/renderers/shared/instructions/InstructionSet';
import type { RenderPipe } from '../../rendering/renderers/shared/instructions/RenderPipe';
import type { Renderer } from '../../rendering/renderers/types';
import type { HTMLText } from './HTMLText';
/**
 * The HTMLTextPipe class is responsible for rendering HTML text.
 * @internal
 */
export declare class HTMLTextPipe implements RenderPipe<HTMLText> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes, ExtensionType.CanvasPipes];
        readonly name: "htmlText";
    };
    private _renderer;
    private readonly _managedTexts;
    constructor(renderer: Renderer);
    protected resolutionChange(): void;
    validateRenderable(htmlText: HTMLText): boolean;
    addRenderable(htmlText: HTMLText, instructionSet: InstructionSet): void;
    updateRenderable(htmlText: HTMLText): void;
    private _updateGpuText;
    private _getGpuText;
    initGpuText(htmlText: HTMLText): BatchableHTMLText;
    protected onTextUnload(text: HTMLText): void;
    destroy(): void;
}
