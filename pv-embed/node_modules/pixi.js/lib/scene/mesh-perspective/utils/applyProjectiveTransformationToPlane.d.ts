import type { ArrayFixed } from '../../../utils/types';
import type { PlaneGeometry } from '../../mesh-plane/PlaneGeometry';
/**
 * Apply a projective transformation to a plane geometry
 * @param width - The width of the plane
 * @param height - The height of the plane
 * @param geometry - The plane geometry to apply the transformation to
 * @param transformationMatrix - The transformation matrix to apply
 * @internal
 */
export declare function applyProjectiveTransformationToPlane(width: number, height: number, geometry: PlaneGeometry, transformationMatrix: ArrayFixed<number, 9>): void;
