/**
 * TS for extracting the system as a record based on a list of systems
 * @example
 *
 * type Systems = [
 *   { extension: { name: 'foo' }, defaultOptions: { foo: 1 } },
 *   { extension: { name: 'bar' }, defaultOptions: { bar: 2 } },
 *   { extension: { name: 'baz' }, defaultOptions: { baz: 3 } },
 * ];
 *
 * type SystemTypes = ExtractSystemTypes<Systems>;
 *
 * SystemTypes = {
 *     foo: { extension: { name: 'foo' }, defaultOptions: { foo: 1 } },
 *     bar: { extension: { name: 'bar' }, defaultOptions: { bar: 2 } },
 *     baz: { extension: { name: 'baz' }, defaultOptions: { baz: 3 } },
 * }
 */
interface System {
    extension: {
        name: string;
    };
    defaultOptions?: any;
    new (...args: any): any;
}
type SystemsWithExtensionList = System[];
type InstanceType<T extends new (...args: any) => any> = T extends new (...args: any) => infer R ? R : any;
type NameType<T extends SystemsWithExtensionList> = T[number]['extension']['name'];
/**
 * Create a mapped type where each property key is a 'name' value,
 * and each property value is an ElementType with a matching 'name'
 * @internal
 */
export type ExtractSystemTypes<T extends SystemsWithExtensionList> = {
    [K in NameType<T>]: InstanceType<Extract<T[number], {
        extension: {
            name: K;
        };
    }>>;
};
/**
 *   TS for extracting the init options based on a list of systems
 *   @example
 *
 *   const list = [
 *      { extension: { name: 'foo' }, defaultOptions: { foo: 1 } },
 *      { extension: { name: 'bar' }, defaultOptions: { bar: 2 } },
 *      { extension: { name: 'baz' }, defaultOptions: { baz: 3 } },
 *   ]
 *
 *   type Options = ExtractRendererOptions<typeof list> // { foo: 1 } & { bar: 2 } & { baz: 3 }
 */
type NotUnknown<T> = T extends unknown ? keyof T extends never ? never : T : T;
type KnownProperties<T> = {
    [K in keyof T as NotUnknown<T[K]> extends never ? never : K]: T[K];
};
type FlattenOptions<T> = T extends {
    [K: string]: infer U;
} ? U : never;
type OptionsUnion<T extends SystemsWithExtensionList> = FlattenOptions<SeparateOptions<T>>;
type DefaultOptionsTypes<T extends SystemsWithExtensionList> = {
    [K in NameType<T>]: Extract<T[number], {
        extension: {
            name: K;
        };
    }>['defaultOptions'];
};
type SeparateOptions<T extends SystemsWithExtensionList> = KnownProperties<DefaultOptionsTypes<T>>;
type UnionToIntersection<U> = (U extends any ? (k: U) => void : never) extends ((k: infer I) => void) ? I : never;
/** @internal */
export type ExtractRendererOptions<T extends SystemsWithExtensionList> = UnionToIntersection<OptionsUnion<T>>;
export {};
