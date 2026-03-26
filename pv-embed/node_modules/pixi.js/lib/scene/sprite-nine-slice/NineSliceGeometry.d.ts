import { type PointData } from '../../maths/point/PointData';
import { PlaneGeometry } from '../mesh-plane/PlaneGeometry';
/**
 * Options for the NineSliceGeometry.
 * @category scene
 * @advanced
 */
export interface NineSliceGeometryOptions {
    /** The width of the NineSlicePlane, setting this will actually modify the vertices and UV's of this plane. */
    width?: number;
    /** The height of the NineSlicePlane, setting this will actually modify the vertices and UV's of this plane. */
    height?: number;
    /** The original width of the texture */
    originalWidth?: number;
    /** The original height of the texture */
    originalHeight?: number;
    /** The width of the left column. */
    leftWidth?: number;
    /** The height of the top row. */
    topHeight?: number;
    /** The width of the right column. */
    rightWidth?: number;
    /** The height of the bottom row. */
    bottomHeight?: number;
    /** The anchor point of the NineSliceSprite. */
    anchor?: PointData;
    /**
     * The trim rectangle of the texture, describing the offset and size of the visible
     * pixel area within the original (unpadded) frame. When provided, UV coordinates are
     * clamped to the trimmed region so that transparent padding in the atlas does not
     * bleed into the rendered corners/edges.
     * @default null
     */
    trim?: {
        x: number;
        y: number;
        width: number;
        height: number;
    } | null;
}
/**
 * The NineSliceGeometry class allows you to create a NineSlicePlane object.
 * @category scene
 * @advanced
 */
export declare class NineSliceGeometry extends PlaneGeometry {
    /** The default options for the NineSliceGeometry. */
    static defaultOptions: NineSliceGeometryOptions;
    /** @internal */
    _leftWidth: number;
    /** @internal */
    _rightWidth: number;
    /** @internal */
    _topHeight: number;
    /** @internal */
    _bottomHeight: number;
    private _originalWidth;
    private _originalHeight;
    private _trimX;
    private _trimY;
    private _trimWidth;
    private _trimHeight;
    private _anchorX;
    private _anchorY;
    constructor(options?: NineSliceGeometryOptions);
    /**
     * Updates the NineSliceGeometry with the options.
     * @param options - The options of the NineSliceGeometry.
     */
    update(options: NineSliceGeometryOptions): void;
    /** Updates the positions of the vertices. */
    updatePositions(): void;
    /** Updates the UVs of the vertices. */
    updateUvs(): void;
}
