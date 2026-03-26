import { AbstractRenderer } from '../shared/system/AbstractRenderer';
import { GlBufferSystem } from './buffer/GlBufferSystem';
import { GlContextSystem } from './context/GlContextSystem';
import { GlGeometrySystem } from './geometry/GlGeometrySystem';
import { GlBackBufferSystem } from './GlBackBufferSystem';
import { GlColorMaskSystem } from './GlColorMaskSystem';
import { GlEncoderSystem } from './GlEncoderSystem';
import { GlLimitsSystem } from './GlLimitsSystem';
import { GlStencilSystem } from './GlStencilSystem';
import { GlUboSystem } from './GlUboSystem';
import { GlRenderTargetSystem } from './renderTarget/GlRenderTargetSystem';
import { GlShaderSystem } from './shader/GlShaderSystem';
import { GlUniformGroupSystem } from './shader/GlUniformGroupSystem';
import { GlStateSystem } from './state/GlStateSystem';
import { GlTextureSystem } from './texture/GlTextureSystem';
import type { ICanvas } from '../../../environment/canvas/ICanvas';
import type { SharedRendererOptions } from '../shared/system/SharedSystems';
import type { ExtractRendererOptions, ExtractSystemTypes } from '../shared/system/utils/typeUtils';
import type { GlRenderingContext } from './context/GlRenderingContext';
declare const DefaultWebGLSystems: (typeof import("../..").BackgroundSystem | typeof import("../..").GlobalUniformSystem | typeof import("../..").HelloSystem | typeof import("../..").ViewSystem | typeof import("../../..").RenderGroupSystem | typeof import("../..").GCSystem | typeof import("../..").TextureGCSystem | typeof import("../..").GenerateTextureSystem | typeof import("../..").ExtractSystem | typeof import("../../..").RendererInitHook | typeof import("../..").RenderableGCSystem | typeof import("../..").SchedulerSystem | typeof GlUboSystem | typeof GlBackBufferSystem | typeof GlContextSystem | typeof GlLimitsSystem | typeof GlBufferSystem | typeof GlTextureSystem | typeof GlRenderTargetSystem | typeof GlGeometrySystem | typeof GlUniformGroupSystem | typeof GlShaderSystem | typeof GlEncoderSystem | typeof GlStateSystem | typeof GlStencilSystem | typeof GlColorMaskSystem)[];
declare const DefaultWebGLPipes: (typeof import("../..").BlendModePipe | typeof import("../..").BatcherPipe | typeof import("../../..").SpritePipe | typeof import("../../..").RenderGroupPipe | typeof import("../..").AlphaMaskPipe | typeof import("../..").StencilMaskPipe | typeof import("../..").ColorMaskPipe | typeof import("../../..").CustomRenderPipe)[];
/**
 * The default WebGL renderer, uses WebGL2 contexts.
 * @category rendering
 * @standard
 * @interface
 */
export type WebGLSystems = ExtractSystemTypes<typeof DefaultWebGLSystems> & PixiMixins.RendererSystems & PixiMixins.WebGLSystems;
/**
 * The default WebGL renderer, uses WebGL2 contexts.
 * @internal
 */
export type WebGLPipes = ExtractSystemTypes<typeof DefaultWebGLPipes> & PixiMixins.RendererPipes & PixiMixins.WebGLPipes;
/**
 * Options for WebGLRenderer.
 * @category rendering
 * @standard
 */
export interface WebGLOptions extends SharedRendererOptions, ExtractRendererOptions<typeof DefaultWebGLSystems>, PixiMixins.WebGLOptions {
}
export interface WebGLRenderer<T extends ICanvas = HTMLCanvasElement> extends AbstractRenderer<WebGLPipes, WebGLOptions, T>, WebGLSystems {
}
/**
 * The WebGL PixiJS Renderer. This renderer allows you to use the most common graphics API, WebGL (and WebGL2).
 *
 * ```ts
 * // Create a new renderer
 * const renderer = new WebGLRenderer();
 * await renderer.init();
 *
 * // Add the renderer to the stage
 * document.body.appendChild(renderer.canvas);
 *
 * // Create a new stage
 * const stage = new Container();
 *
 * // Render the stage
 * renderer.render(stage);
 * ```
 *
 * You can use {@link autoDetectRenderer} to create a renderer that will automatically detect the best
 * renderer for the environment.
 *
 *
 * ```ts
 * // Create a new renderer
 * const renderer = await rendering.autoDetectRenderer({
 *    preference:'webgl',
 * });
 * ```
 *
 * The renderer is composed of systems that manage specific tasks. The following systems are added by default
 * whenever you create a WebGL renderer:
 *
 * | WebGL Core Systems                          | Systems that are specific to the WebGL renderer                               |
 * | ------------------------------------------- | ----------------------------------------------------------------------------- |
 * | {@link GlUboSystem}               | This manages WebGL2 uniform buffer objects feature for shaders                |
 * | {@link GlBackBufferSystem}        | manages the back buffer, used so that we can pixi can pixels from the screen  |
 * | {@link GlContextSystem}           | This manages the WebGL context and its extensions                             |
 * | {@link GlBufferSystem}            | This manages buffers and their GPU resources, keeps everything in sync        |
 * | {@link GlTextureSystem}           | This manages textures and their GPU resources, keeps everything in sync       |
 * | {@link GlRenderTargetSystem}      | This manages what we render too. For example the screen, or another texture   |
 * | {@link GlGeometrySystem}          | This manages geometry, used for drawing meshes via the GPU                    |
 * | {@link GlUniformGroupSystem}      | This manages uniform groups. Syncing shader properties with the GPU           |
 * | {@link GlShaderSystem}            | This manages shaders, programs that run on the GPU to output lovely pixels    |
 * | {@link GlEncoderSystem}           | This manages encoders, a WebGPU Paradigm, use it to draw a mesh + shader      |
 * | {@link GlStateSystem}             | This manages the state of the WebGL context. eg the various flags that can be set blend modes / depthTesting etc |
 * | {@link GlStencilSystem}           | This manages the stencil buffer. Used primarily for masking                   |
 * | {@link GlColorMaskSystem}         | This manages the color mask. Used for color masking                           |
 *
 * The breadth of the API surface provided by the renderer is contained within these systems.
 * @category rendering
 * @property {GlUboSystem} ubo - UboSystem instance.
 * @property {GlBackBufferSystem} backBuffer - BackBufferSystem instance.
 * @property {GlContextSystem} context - ContextSystem instance.
 * @property {GlBufferSystem} buffer - BufferSystem instance.
 * @property {GlTextureSystem} texture - TextureSystem instance.
 * @property {GlRenderTargetSystem} renderTarget - RenderTargetSystem instance.
 * @property {GlGeometrySystem} geometry - GeometrySystem instance.
 * @property {GlUniformGroupSystem} uniformGroup - UniformGroupSystem instance.
 * @property {GlShaderSystem} shader - ShaderSystem instance.
 * @property {GlEncoderSystem} encoder - EncoderSystem instance.
 * @property {GlStateSystem} state - StateSystem instance.
 * @property {GlStencilSystem} stencil - StencilSystem instance.
 * @property {GlColorMaskSystem} colorMask - ColorMaskSystem instance.
 * @extends AbstractRenderer
 * @standard
 */
export declare class WebGLRenderer<T extends ICanvas = HTMLCanvasElement> extends AbstractRenderer<WebGLPipes, WebGLOptions, T> implements WebGLSystems {
    gl: GlRenderingContext;
    constructor();
}
export {};
