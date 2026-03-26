import type { Matrix } from '../../../../../maths/matrix/Matrix';
/**
 * Transforms the vertices in an array with the given matrix.
 * @param vertices - the vertices to transform
 * @param m - the matrix to apply to the vertices
 * @param offset - the offset of the vertices (defaults to 0)
 * @param stride - the stride of the vertices (defaults to 2)
 * @param size - the size of the vertices (defaults to vertices.length / stride - offset)
 * @category rendering
 * @internal
 */
export declare function transformVertices(vertices: number[], m: Matrix, offset?: number, stride?: number, size?: number): void;
