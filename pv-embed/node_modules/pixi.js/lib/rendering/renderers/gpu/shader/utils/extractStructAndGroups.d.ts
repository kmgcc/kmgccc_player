/**
 * Defines the structure of the extracted WGSL structs and groups.
 * @category rendering
 * @advanced
 */
export interface StructsAndGroups {
    groups: {
        group: number;
        binding: number;
        name: string;
        isUniform: boolean;
        type: string;
    }[];
    structs: {
        name: string;
        members: Record<string, string>;
    }[];
}
/**
 * @param wgsl
 * @internal
 */
export declare function extractStructAndGroups(wgsl: string): StructsAndGroups;
