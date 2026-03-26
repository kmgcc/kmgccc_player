import { Matrix } from '../../../maths/matrix/Matrix';
import type { Container } from '../Container';
import type { Bounds } from './Bounds';
/**
 * @param target
 * @param bounds
 * @param relativeMatrix
 * @internal
 */
export declare function getLocalBounds(target: Container, bounds: Bounds, relativeMatrix?: Matrix): Bounds;
