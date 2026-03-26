/** @internal */
export declare const scaleModeToGlFilter: {
    linear: number;
    nearest: number;
};
/** @internal */
export declare const mipmapScaleModeToGlFilter: {
    linear: {
        linear: number;
        nearest: number;
    };
    nearest: {
        linear: number;
        nearest: number;
    };
};
/** @internal */
export declare const wrapModeToGlAddress: {
    'clamp-to-edge': number;
    repeat: number;
    'mirror-repeat': number;
};
/** @internal */
export declare const compareModeToGlCompare: {
    never: number;
    less: number;
    equal: number;
    'less-equal': number;
    greater: number;
    'not-equal': number;
    'greater-equal': number;
    always: number;
};
