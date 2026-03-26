import { ExtensionType } from '../../../extensions/Extensions';
/**
 * A parser that will resolve a json urls resolution for spritesheets
 * e.g. `assets/spritesheet@1x.json`
 * @category assets
 * @internal
 */
export declare const resolveJsonUrl: {
    extension: {
        type: ExtensionType.ResolveParser;
        priority: number;
        name: string;
    };
    test: (value: string) => boolean;
    parse: (value: string) => {
        resolution: number;
        format: string;
        src: string;
    };
};
