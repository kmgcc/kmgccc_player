import { type ExtensionMetadata, ExtensionType } from '../../extensions/Extensions';
import type { Application } from '../../app/Application';
import type { System } from '../../rendering/renderers/shared/system/System';
import type { Renderer } from '../../rendering/renderers/types';
declare global {
    var __PIXI_APP_INIT__: undefined | ((arg: Application | Renderer, version: string) => void);
    var __PIXI_RENDERER_INIT__: undefined | ((arg: Application | Renderer, version: string) => void);
}
/**
 * Calls global __PIXI_APP_INIT__ hook with the application instance, after the application is initialized.
 * @category app
 * @internal
 */
export declare class ApplicationInitHook {
    /** @ignore */
    static extension: ExtensionMetadata;
    static init(): void;
    static destroy(): void;
}
/**
 * Calls global __PIXI_RENDERER_INIT__ hook with the renderer instance, after the renderer is initialized.
 * @category rendering
 * @internal
 */
export declare class RendererInitHook implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem];
        readonly name: "initHook";
        readonly priority: -10;
    };
    private _renderer;
    constructor(renderer: Renderer);
    init(): void;
    destroy(): void;
}
