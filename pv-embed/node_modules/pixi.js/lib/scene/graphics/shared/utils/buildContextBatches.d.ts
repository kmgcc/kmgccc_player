import type { ShapeBuildCommand } from '../buildCommands/ShapeBuildCommand';
import type { GraphicsContext } from '../GraphicsContext';
import type { GpuGraphicsContext } from '../GraphicsContextSystem';
/**
 * A record of shape builders, keyed by shape type.
 * @category scene
 * @advanced
 */
export declare const shapeBuilders: Record<string, ShapeBuildCommand>;
/**
 * @param context
 * @param gpuContext
 * @internal
 */
export declare function buildContextBatches(context: GraphicsContext, gpuContext: GpuGraphicsContext): void;
