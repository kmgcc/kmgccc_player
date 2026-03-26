import type { StructsAndGroups } from './extractStructAndGroups';
/**
 * @param vertexStructsAndGroups
 * @param fragmentStructsAndGroups
 * @internal
 */
export declare function removeStructAndGroupDuplicates(vertexStructsAndGroups: StructsAndGroups, fragmentStructsAndGroups: StructsAndGroups): {
    structs: {
        name: string;
        members: Record<string, string>;
    }[];
    groups: {
        group: number;
        binding: number;
        name: string;
        isUniform: boolean;
        type: string;
    }[];
};
