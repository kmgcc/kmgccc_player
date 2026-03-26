interface MessageData {
    data: any[];
    uuid: number;
    id: string;
}
declare function loadImageBitmap(url: string, alphaMode?: string): Promise<ImageBitmap>;
