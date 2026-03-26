import { type Renderer } from '../../rendering/renderers/types';
import { Graphics } from '../graphics/shared/Graphics';
import { type SdfShader } from '../text/sdfShader/SdfShader';
import { type GPUData } from '../view/ViewContainer';
import type { InstructionSet } from '../../rendering/renderers/shared/instructions/InstructionSet';
import type { RenderPipe } from '../../rendering/renderers/shared/instructions/RenderPipe';
import type { BitmapText } from './BitmapText';
/** @internal */
export declare class BitmapTextGraphics extends Graphics implements GPUData {
    destroy(): void;
}
/** @internal */
export declare abstract class AbstractBitmapTextPipe implements RenderPipe<BitmapText> {
    protected _renderer: Renderer;
    private readonly _managedBitmapTexts;
    constructor(renderer: Renderer);
    validateRenderable(bitmapText: BitmapText): boolean;
    addRenderable(bitmapText: BitmapText, instructionSet: InstructionSet): void;
    updateRenderable(bitmapText: BitmapText): void;
    protected abstract getSdfShader(): SdfShader | null;
    private _updateContext;
    private _getGpuBitmapText;
    initGpuText(bitmapText: BitmapText): BitmapTextGraphics;
    private _updateDistanceField;
    destroy(): void;
}
