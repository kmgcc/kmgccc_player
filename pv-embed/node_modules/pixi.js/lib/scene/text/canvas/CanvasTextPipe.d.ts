import { ExtensionType } from '../../../extensions/Extensions';
import { BatchableText } from './BatchableText';
import type { InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet';
import type { RenderPipe } from '../../../rendering/renderers/shared/instructions/RenderPipe';
import type { Renderer } from '../../../rendering/renderers/types';
import type { Text } from '../Text';
/** @internal */
export declare class CanvasTextPipe implements RenderPipe<Text> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes, ExtensionType.CanvasPipes];
        readonly name: "text";
    };
    private _renderer;
    private readonly _managedTexts;
    constructor(renderer: Renderer);
    protected resolutionChange(): void;
    validateRenderable(text: Text): boolean;
    addRenderable(text: Text, instructionSet: InstructionSet): void;
    updateRenderable(text: Text): void;
    private _updateGpuText;
    private _getGpuText;
    initGpuText(text: Text): BatchableText;
    protected onTextUnload(text: Text): void;
    destroy(): void;
}
