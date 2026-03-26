import type { ObservablePoint } from '../../maths/point/ObservablePoint';
import type { Texture } from '../../rendering/renderers/shared/texture/Texture';
import type { BoundsData } from '../../scene/container/bounds/Bounds';
/**
 * Updates the bounds of a quad (a rectangular area) based on the provided texture and anchor point.
 *
 * This function calculates the minimum and maximum x and y coordinates of the bounds, taking into
 * account the texture's original dimensions and any trimming that may have been applied to it.
 * @param {BoundsData} bounds - The bounds object to be updated. It contains minX, maxX, minY, and maxY properties.
 * @param {ObservablePoint} anchor - The anchor point of the texture, which affects the positioning of the bounds.
 * @param {Texture} texture - The texture whose dimensions and trimming information are used to update the bounds.
 * @internal
 */
export declare function updateQuadBounds(bounds: BoundsData, anchor: ObservablePoint, texture: Texture): void;
