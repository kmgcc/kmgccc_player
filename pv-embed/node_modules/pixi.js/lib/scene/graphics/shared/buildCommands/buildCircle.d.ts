import { ExtensionType } from '../../../../extensions/Extensions';
import type { Circle } from '../../../../maths/shapes/Circle';
import type { Ellipse } from '../../../../maths/shapes/Ellipse';
import type { RoundedRectangle } from '../../../../maths/shapes/RoundedRectangle';
import type { ShapeBuildCommand } from './ShapeBuildCommand';
/** @internal */
type RoundedShape = Circle | Ellipse | RoundedRectangle;
/**
 * Builds a rectangle to draw
 *
 * Ignored from docs since it is not directly exposed.
 * @internal
 */
export declare const buildCircle: ShapeBuildCommand<RoundedShape>;
/** @internal */
export declare const buildEllipse: {
    extension: {
        name: string;
        type: ExtensionType | ExtensionType[];
        priority?: number;
    };
    build(shape: RoundedShape, points: number[]): boolean;
    triangulate(points: number[], vertices: number[], verticesStride: number, verticesOffset: number, indices: number[], indicesOffset: number): void;
};
/** @internal */
export declare const buildRoundedRectangle: {
    extension: {
        name: string;
        type: ExtensionType | ExtensionType[];
        priority?: number;
    };
    build(shape: RoundedShape, points: number[]): boolean;
    triangulate(points: number[], vertices: number[], verticesStride: number, verticesOffset: number, indices: number[], indicesOffset: number): void;
};
export {};
