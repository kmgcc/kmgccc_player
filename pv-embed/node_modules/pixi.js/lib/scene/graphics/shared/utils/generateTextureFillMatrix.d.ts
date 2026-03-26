import { Matrix } from '../../../../maths/matrix/Matrix';
import type { ShapePrimitive } from '../../../../maths/shapes/ShapePrimitive';
import type { FillStyle, StrokeStyle } from '../FillTypes';
/**
 * Generates a texture matrix for mapping textures onto shapes.
 * This function handles both local and global texture space mapping.
 *
 * In local space, the texture is mapped to fit exactly within the bounds of the shape.
 * In global space, the texture is mapped using its own dimensions and position.
 * @param out - The matrix to store the result in
 * @param style - The fill style containing texture and mapping properties
 * @param shape - The shape to map the texture onto
 * @param matrix - Optional transform matrix to apply
 * @returns The generated texture matrix for UV mapping
 * @example
 * ```ts
 * const matrix = new Matrix();
 * const textureMatrix = generateTextureMatrix(matrix, fillStyle, shape);
 * // textureMatrix now contains the proper UV mapping for the texture
 * ```
 * @internal
 */
export declare function generateTextureMatrix(out: Matrix, style: FillStyle | StrokeStyle, shape: ShapePrimitive, matrix?: Matrix): Matrix;
