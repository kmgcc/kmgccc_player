import { ExtensionType } from '../../../../extensions/Extensions';
import { Rectangle } from '../../../../maths/shapes/Rectangle';
import { RenderTarget } from '../renderTarget/RenderTarget';
import type { ICanvas } from '../../../../environment/canvas/ICanvas';
import type { TypeOrBool } from '../../../../scene/container/destroyTypes';
import type { System } from '../system/System';
import type { CanvasSource } from '../texture/sources/CanvasSource';
import type { Texture } from '../texture/Texture';
/**
 * Options passed to the ViewSystem
 * @category rendering
 * @advanced
 */
export interface ViewSystemOptions {
    /**
     * The width of the screen.
     * @default 800
     */
    width?: number;
    /**
     * The height of the screen.
     * @default 600
     */
    height?: number;
    /** The canvas to use as a view, optional. */
    canvas?: ICanvas;
    /**
     * Alias for `canvas`.
     * @deprecated since 8.0.0
     */
    view?: ICanvas;
    /**
     * Resizes renderer view in CSS pixels to allow for resolutions other than 1.
     *
     * This is only supported for HTMLCanvasElement
     * and will be ignored if the canvas is an OffscreenCanvas.
     */
    autoDensity?: boolean;
    /** The resolution / device pixel ratio of the renderer. */
    resolution?: number;
    /** Whether to enable anti-aliasing. This may affect performance. */
    antialias?: boolean;
    /** Whether to ensure the main view has can make use of the depth buffer. Always true for WebGL renderer. */
    depth?: boolean;
}
/**
 * Options for destroying the ViewSystem.
 * @category rendering
 * @advanced
 */
export interface ViewSystemDestroyOptions {
    /** Whether to remove the view element from the DOM. Defaults to `false`. */
    removeView?: boolean;
}
/**
 * The view system manages the main canvas that is attached to the DOM.
 * This main role is to deal with how the holding the view reference and dealing with how it is resized.
 * @category rendering
 * @advanced
 */
export declare class ViewSystem implements System<ViewSystemOptions, TypeOrBool<ViewSystemDestroyOptions>> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem, ExtensionType.CanvasSystem];
        readonly name: "view";
        readonly priority: 0;
    };
    /** The default options for the view system. */
    static defaultOptions: ViewSystemOptions;
    /** The canvas element that everything is drawn to. */
    canvas: ICanvas;
    /** The texture that is used to draw the canvas to the screen. */
    texture: Texture<CanvasSource>;
    /**
     * Whether CSS dimensions of canvas view should be resized to screen dimensions automatically.
     * This is only supported for HTMLCanvasElement and will be ignored if the canvas is an OffscreenCanvas.
     * @type {boolean}
     */
    get autoDensity(): boolean;
    set autoDensity(value: boolean);
    /** Whether to enable anti-aliasing. This may affect performance. */
    antialias: boolean;
    /**
     * Measurements of the screen. (0, 0, screenWidth, screenHeight).
     *
     * Its safe to use as filterArea or hitArea for the whole stage.
     */
    screen: Rectangle;
    /** The render target that the view is drawn to. */
    renderTarget: RenderTarget;
    /** The resolution / device pixel ratio of the renderer. */
    get resolution(): number;
    set resolution(value: number);
    /**
     * initiates the view system
     * @param options - the options for the view
     */
    init(options: ViewSystemOptions): void;
    /**
     * Resizes the screen and canvas to the specified dimensions.
     * @param desiredScreenWidth - The new width of the screen.
     * @param desiredScreenHeight - The new height of the screen.
     * @param resolution
     */
    resize(desiredScreenWidth: number, desiredScreenHeight: number, resolution: number): void;
    /**
     * Destroys this System and optionally removes the canvas from the dom.
     * @param {options | false} options - The options for destroying the view, or "false".
     * @example
     * viewSystem.destroy();
     * viewSystem.destroy(true);
     * viewSystem.destroy({ removeView: true });
     */
    destroy(options?: TypeOrBool<ViewSystemDestroyOptions>): void;
}
