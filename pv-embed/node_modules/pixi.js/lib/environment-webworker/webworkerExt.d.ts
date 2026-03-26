import { ExtensionType } from '../extensions/Extensions';
/**
 * Extension for the webworker environment.
 * @category environment
 * @internal
 */
export declare const webworkerExt: {
    extension: {
        type: ExtensionType;
        name: string;
        priority: number;
    };
    test: () => boolean;
    load: () => Promise<void>;
};
