import type { Matrix } from '../../../maths/matrix/Matrix';
import type { Container } from '../Container';
/**
 * Updates the local transform of a container based on its properties.
 * @param lt - The matrix to update with the local transform values.
 * @param container - The container whose local transform is being updated.
 * @deprecated
 * @internal
 */
export declare function updateLocalTransform(lt: Matrix, container: Container): void;
