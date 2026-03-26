import { ExtensionType } from '../../../../extensions/Extensions';
import { RenderGroup } from '../../../../scene/container/RenderGroup';
import type { Renderer } from '../../types';
import type { Instruction } from '../instructions/Instruction';
import type { InstructionSet } from '../instructions/InstructionSet';
import type { InstructionPipe } from '../instructions/RenderPipe';
import type { Renderable } from '../Renderable';
import type { BLEND_MODES } from '../state/const';
interface AdvancedBlendInstruction extends Instruction {
    renderPipeId: 'blendMode';
    blendMode: BLEND_MODES;
    activeBlend: Renderable[];
}
/**
 * This Pipe handles the blend mode switching of the renderer.
 * It will insert instructions into the {@link InstructionSet} to switch the blend mode according to the
 * blend modes of the scene graph.
 *
 * This pipe is were wwe handle Advanced blend modes. Advanced blend modes essentially wrap the renderables
 * in a filter that applies the blend mode.
 *
 * You only need to use this class if you are building your own render instruction set rather than letting PixiJS build
 * the instruction set for you by traversing the scene graph
 * @category rendering
 * @internal
 */
export declare class BlendModePipe implements InstructionPipe<AdvancedBlendInstruction> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes, ExtensionType.CanvasPipes];
        readonly name: "blendMode";
    };
    private _renderer;
    private _renderableList?;
    private _activeBlendMode;
    private readonly _blendModeStack;
    private _isAdvanced;
    private _filterHash;
    constructor(renderer: Renderer);
    prerender(): void;
    /**
     * Push a blend mode onto the internal stack and apply it to the instruction set if needed.
     * @param renderable - The renderable or {@link RenderGroup} associated with the change.
     * @param blendMode - The blend mode to activate.
     * @param instructionSet - The instruction set being built.
     */
    pushBlendMode(renderable: Renderable | RenderGroup, blendMode: BLEND_MODES, instructionSet: InstructionSet): void;
    /**
     * Pop the last blend mode from the stack and apply the new top-of-stack mode.
     * @param instructionSet - The instruction set being built.
     */
    popBlendMode(instructionSet: InstructionSet): void;
    /**
     * Ensure a blend mode switch is added to the instruction set when the mode changes.
     * If an advanced blend mode is active, subsequent renderables will be collected so they can be
     * rendered within a single filter pass.
     * @param renderable - The renderable or {@link RenderGroup} to associate with the change, or null when unwinding.
     * @param blendMode - The target blend mode.
     * @param instructionSet - The instruction set being built.
     */
    setBlendMode(renderable: Renderable | RenderGroup | null, blendMode: BLEND_MODES, instructionSet: InstructionSet): void;
    private _beginAdvancedBlendMode;
    private _ensureFilterEffect;
    private _endAdvancedBlendMode;
    /**
     * called when the instruction build process is starting this will reset internally to the default blend mode
     * @internal
     */
    buildStart(): void;
    /**
     * called when the instruction build process is finished, ensuring that if there is an advanced blend mode
     * active, we add the final render instructions added to the instruction set
     * @param instructionSet - The instruction set we are adding to
     * @internal
     */
    buildEnd(instructionSet: InstructionSet): void;
    /** @internal */
    destroy(): void;
}
export {};
