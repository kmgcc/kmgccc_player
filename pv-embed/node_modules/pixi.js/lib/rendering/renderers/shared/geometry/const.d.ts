/**
 * The different topology types supported by the renderer used to describe how the geometry should be renderer
 * @category rendering
 * @advanced
 */
export type Topology = 'point-list' | 'line-list' | 'line-strip' | 'triangle-list' | 'triangle-strip';
/**
 * @deprecated since 8.0.0
 * @category rendering
 * @advanced
 */
export declare const DRAW_MODES: {
    POINTS: string;
    LINES: string;
    LINE_STRIP: string;
    TRIANGLES: string;
    TRIANGLE_STRIP: string;
};
/**
 * The different types of vertex formats supported by the renderer
 * @category rendering
 * @advanced
 */
export type VertexFormat = 'uint8x2' | 'uint8x4' | 'sint8x2' | 'sint8x4' | 'unorm8x2' | 'unorm8x4' | 'snorm8x2' | 'snorm8x4' | 'uint16x2' | 'uint16x4' | 'sint16x2' | 'sint16x4' | 'unorm16x2' | 'unorm16x4' | 'snorm16x2' | 'snorm16x4' | 'float16x2' | 'float16x4' | 'float32' | 'float32x2' | 'float32x3' | 'float32x4' | 'uint32' | 'uint32x2' | 'uint32x3' | 'uint32x4' | 'sint32' | 'sint32x2' | 'sint32x3' | 'sint32x4';
