'use strict';

Object.defineProperty(exports, '__esModule', { value: true });

const WORKER_CODE = "(function () {\n    'use strict';\n\n    const WHITE_PNG = \"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=\";\n    async function checkImageBitmap() {\n      try {\n        if (typeof createImageBitmap !== \"function\") return false;\n        const response = await fetch(WHITE_PNG);\n        const imageBlob = await response.blob();\n        const imageBitmap = await createImageBitmap(imageBlob);\n        return imageBitmap.width === 1 && imageBitmap.height === 1;\n      } catch (_e) {\n        return false;\n      }\n    }\n    void checkImageBitmap().then((result) => {\n      self.postMessage(result);\n    });\n\n})();\n";
let WORKER_URL = null;
class WorkerInstance
{
    constructor()
    {
        if (!WORKER_URL)
        {
            WORKER_URL = URL.createObjectURL(new Blob([WORKER_CODE], { type: 'application/javascript' }));
        }
        this.worker = new Worker(WORKER_URL);
    }
}
WorkerInstance.revokeObjectURL = function revokeObjectURL()
{
    if (WORKER_URL)
    {
        URL.revokeObjectURL(WORKER_URL);
        WORKER_URL = null;
    }
};

exports.default = WorkerInstance;
//# sourceMappingURL=checkImageBitmap.worker.js.map
