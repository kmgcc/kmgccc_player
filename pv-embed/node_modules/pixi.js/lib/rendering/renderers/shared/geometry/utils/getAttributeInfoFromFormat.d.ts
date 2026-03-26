import type { VertexFormat } from '../const';
/**
 * @param format
 * @internal
 */
export declare function getAttributeInfoFromFormat(format: VertexFormat): {
    size: number;
    stride: number;
    normalised: boolean;
};
