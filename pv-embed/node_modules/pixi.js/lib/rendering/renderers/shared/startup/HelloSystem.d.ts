import { ExtensionType } from '../../../../extensions/Extensions';
import { type Renderer } from '../../types';
import type { System } from '../system/System';
/**
 * Options for the startup system.
 * @property {boolean} [hello=false] - Whether to log the version and type information of renderer to console.
 * @category rendering
 * @advanced
 */
export interface HelloSystemOptions {
    /**
     * Whether to log the version and type information of renderer to console.
     * @default false
     */
    hello: boolean;
}
/**
 * A simple system responsible for initiating the renderer.
 * @category rendering
 * @advanced
 */
export declare class HelloSystem implements System<HelloSystemOptions> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem, ExtensionType.CanvasSystem];
        readonly name: "hello";
        readonly priority: -2;
    };
    /** The default options for the system. */
    static defaultOptions: HelloSystemOptions;
    private readonly _renderer;
    constructor(renderer: Renderer);
    /**
     * It all starts here! This initiates every system, passing in the options for any system by name.
     * @param options - the config for the renderer and all its systems
     */
    init(options: HelloSystemOptions): void;
}
