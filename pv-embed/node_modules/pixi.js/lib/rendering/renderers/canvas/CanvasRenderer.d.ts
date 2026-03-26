import { CustomRenderPipe } from '../../../scene/container/CustomRenderPipe';
import { RenderGroupPipe } from '../../../scene/container/RenderGroupPipe';
import { SpritePipe } from '../../../scene/sprite/SpritePipe';
import { BatcherPipe } from '../../batcher/shared/BatcherPipe';
import { AlphaMaskPipe } from '../../mask/alpha/AlphaMaskPipe';
import { CanvasColorMaskPipe } from '../../mask/color/CanvasColorMaskPipe';
import { CanvasStencilMaskPipe } from '../../mask/stencil/CanvasStencilMaskPipe';
import { BlendModePipe } from '../shared/blendModes/BlendModePipe';
import { AbstractRenderer } from '../shared/system/AbstractRenderer';
import { CanvasContextSystem } from './CanvasContextSystem';
import { CanvasLimitsSystem } from './CanvasLimitsSystem';
import { CanvasRenderTargetSystem } from './renderTarget/CanvasRenderTargetSystem';
import { CanvasTextureSystem } from './texture/CanvasTextureSystem';
import type { ICanvas } from '../../../environment/canvas/ICanvas';
import type { SharedRendererOptions } from '../shared/system/SharedSystems';
import type { ExtractRendererOptions, ExtractSystemTypes } from '../shared/system/utils/typeUtils';
declare const DefaultCanvasSystems: (typeof import("../..").BackgroundSystem | typeof import("../..").GlobalUniformSystem | typeof import("../..").HelloSystem | typeof import("../..").ViewSystem | typeof import("../../..").RenderGroupSystem | typeof import("../..").GCSystem | typeof import("../..").TextureGCSystem | typeof import("../..").GenerateTextureSystem | typeof import("../..").ExtractSystem | typeof import("../../..").RendererInitHook | typeof import("../..").RenderableGCSystem | typeof import("../..").SchedulerSystem | typeof CanvasContextSystem | typeof CanvasLimitsSystem | typeof CanvasTextureSystem | typeof CanvasRenderTargetSystem)[];
declare const DefaultCanvasPipes: (typeof BlendModePipe | typeof BatcherPipe | typeof SpritePipe | typeof RenderGroupPipe | typeof AlphaMaskPipe | typeof CustomRenderPipe | typeof CanvasStencilMaskPipe | typeof CanvasColorMaskPipe)[];
/**
 * The default Canvas systems. These are the systems that are added by default to the CanvasRenderer.
 * @category rendering
 * @standard
 * @interface
 */
export type CanvasSystems = ExtractSystemTypes<typeof DefaultCanvasSystems> & PixiMixins.RendererSystems & PixiMixins.CanvasSystems;
/**
 * The Canvas renderer pipes. These are used to render the scene.
 * @see {@link CanvasRenderer}
 * @internal
 */
export type CanvasPipes = ExtractSystemTypes<typeof DefaultCanvasPipes> & PixiMixins.RendererPipes & PixiMixins.CanvasPipes;
/**
 * Options for CanvasRenderer.
 * @category rendering
 * @standard
 */
export interface CanvasOptions extends SharedRendererOptions, ExtractRendererOptions<typeof DefaultCanvasSystems>, PixiMixins.CanvasOptions {
}
export interface CanvasRenderer<T extends ICanvas = HTMLCanvasElement> extends AbstractRenderer<CanvasPipes, CanvasOptions, T>, CanvasSystems {
}
/**
 * The Canvas PixiJS Renderer. This renderer allows you to use the HTML Canvas 2D context.
 * @category rendering
 * @standard
 */
export declare class CanvasRenderer<T extends ICanvas = HTMLCanvasElement> extends AbstractRenderer<CanvasPipes, CanvasOptions, T> implements CanvasSystems {
    constructor();
}
export {};
