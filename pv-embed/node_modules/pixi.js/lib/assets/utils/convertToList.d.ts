/**
 * @param input
 * @param transform
 * @param forceTransform
 * @internal
 */
export declare const convertToList: <T>(input: string | T | (string | T)[], transform?: (input: string) => T, forceTransform?: boolean) => T[];
