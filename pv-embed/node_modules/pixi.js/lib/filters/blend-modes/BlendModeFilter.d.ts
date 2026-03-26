import { Filter } from '../Filter';
/** @internal */
export interface BlendModeFilterOptions {
    source?: string;
    gpu?: {
        functions?: string;
        main?: string;
    };
    gl?: {
        functions?: string;
        main?: string;
    };
}
/** @internal */
export declare class BlendModeFilter extends Filter {
    constructor(options: BlendModeFilterOptions);
}
