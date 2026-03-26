'use strict';

Object.defineProperty(exports, '__esModule', { value: true });

const WORKER_CODE = "(function () {\n    'use strict';\n\n    async function loadImageBitmap(url, alphaMode) {\n      const response = await fetch(url);\n      if (!response.ok) {\n        throw new Error(`[WorkerManager.loadImageBitmap] Failed to fetch ${url}: ${response.status} ${response.statusText}`);\n      }\n      const imageBlob = await response.blob();\n      return alphaMode === \"premultiplied-alpha\" ? createImageBitmap(imageBlob, { premultiplyAlpha: \"none\" }) : createImageBitmap(imageBlob);\n    }\n    self.onmessage = async (event) => {\n      try {\n        const imageBitmap = await loadImageBitmap(event.data.data[0], event.data.data[1]);\n        self.postMessage({\n          data: imageBitmap,\n          uuid: event.data.uuid,\n          id: event.data.id\n        }, [imageBitmap]);\n      } catch (e) {\n        self.postMessage({\n          error: e,\n          uuid: event.data.uuid,\n          id: event.data.id\n        });\n      }\n    };\n\n})();\n";
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
//# sourceMappingURL=loadImageBitmap.worker.js.map
