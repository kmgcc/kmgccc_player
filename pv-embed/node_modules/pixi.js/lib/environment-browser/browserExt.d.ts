import { ExtensionType } from '../extensions/Extensions';
/**
 * Extension for the browser environment.
 * @category environment
 * @internal
 */
export declare const browserExt: {
    extension: {
        type: ExtensionType;
        name: string;
        priority: number;
    };
    test: () => boolean;
    load: () => Promise<void>;
};
