import { Matrix } from '../../../maths/matrix/Matrix';
import type { Container } from '../Container';
import type { Bounds } from './Bounds';
/**
 * Gets the global bounds of a container, including all its children
 * @param target - The target container to get the bounds from
 * @param skipUpdateTransform - If true, the transform will not be updated before calculating bounds.
 * @param bounds - The output bounds object.
 * @returns The bounds.
 * @internal
 */
export declare function getGlobalBounds(target: Container, skipUpdateTransform: boolean, bounds: Bounds): Bounds;
/**
 * @param target
 * @param parentTransform
 * @internal
 */
export declare function updateTransformBackwards(target: Container, parentTransform: Matrix): Matrix;
