import { ExtensionType } from '../../../../extensions/Extensions.mjs';
import { VideoSource } from '../../../../rendering/renderers/shared/texture/sources/VideoSource.mjs';
import { detectVideoAlphaMode } from '../../../../utils/browser/detectVideoAlphaMode.mjs';
import { getResolutionOfUrl } from '../../../../utils/network/getResolutionOfUrl.mjs';
import { testVideoFormat } from '../../../detections/utils/testVideoFormat.mjs';
import { checkDataUrl } from '../../../utils/checkDataUrl.mjs';
import { checkExtension } from '../../../utils/checkExtension.mjs';
import { createTexture } from './utils/createTexture.mjs';

"use strict";
const potentialVideoExtensions = [".mp4", ".m4v", ".webm", ".ogg", ".ogv", ".h264", ".avi", ".mov"];
let validVideoExtensions;
let validVideoMIMEs;
function crossOrigin(element, url, crossorigin) {
  if (crossorigin === void 0 && !url.startsWith("data:")) {
    element.crossOrigin = determineCrossOrigin(url);
  } else if (crossorigin !== false) {
    element.crossOrigin = typeof crossorigin === "string" ? crossorigin : "anonymous";
  }
}
function preloadVideo(element) {
  return new Promise((resolve, reject) => {
    element.addEventListener("canplaythrough", loaded);
    element.addEventListener("error", error);
    element.load();
    function loaded() {
      cleanup();
      resolve();
    }
    function error(err) {
      cleanup();
      reject(err);
    }
    function cleanup() {
      element.removeEventListener("canplaythrough", loaded);
      element.removeEventListener("error", error);
    }
  });
}
function determineCrossOrigin(url, loc = globalThis.location) {
  if (url.startsWith("data:")) {
    return "";
  }
  loc || (loc = globalThis.location);
  const parsedUrl = new URL(url, document.baseURI);
  if (parsedUrl.hostname !== loc.hostname || parsedUrl.port !== loc.port || parsedUrl.protocol !== loc.protocol) {
    return "anonymous";
  }
  return "";
}
function getBrowserSupportedVideoExtensions() {
  const supportedExtensions = [];
  const supportedMimes = [];
  for (const ext of potentialVideoExtensions) {
    const mimeType = VideoSource.MIME_TYPES[ext.substring(1)] || `video/${ext.substring(1)}`;
    if (testVideoFormat(mimeType)) {
      supportedExtensions.push(ext);
      if (!supportedMimes.includes(mimeType)) {
        supportedMimes.push(mimeType);
      }
    }
  }
  return {
    validVideoExtensions: supportedExtensions,
    validVideoMime: supportedMimes
  };
}
const loadVideoTextures = {
  /** used for deprecation purposes */
  name: "loadVideo",
  id: "video",
  extension: {
    type: ExtensionType.LoadParser,
    name: "loadVideo"
  },
  test(url) {
    if (!validVideoExtensions || !validVideoMIMEs) {
      const { validVideoExtensions: ve, validVideoMime: vm } = getBrowserSupportedVideoExtensions();
      validVideoExtensions = ve;
      validVideoMIMEs = vm;
    }
    const isValidDataUrl = checkDataUrl(url, validVideoMIMEs);
    const isValidExtension = checkExtension(url, validVideoExtensions);
    return isValidDataUrl || isValidExtension;
  },
  async load(url, asset, loader) {
    const options = {
      ...VideoSource.defaultOptions,
      resolution: asset.data?.resolution || getResolutionOfUrl(url),
      alphaMode: asset.data?.alphaMode || await detectVideoAlphaMode(),
      ...asset.data
    };
    const videoElement = document.createElement("video");
    const attributeMap = {
      preload: options.autoLoad !== false ? "auto" : void 0,
      "webkit-playsinline": options.playsinline !== false ? "" : void 0,
      playsinline: options.playsinline !== false ? "" : void 0,
      muted: options.muted === true ? "" : void 0,
      loop: options.loop === true ? "" : void 0,
      autoplay: options.autoPlay !== false ? "" : void 0
    };
    Object.keys(attributeMap).forEach((key) => {
      const value = attributeMap[key];
      if (value !== void 0) videoElement.setAttribute(key, value);
    });
    if (options.muted === true) {
      videoElement.muted = true;
    }
    crossOrigin(videoElement, url, options.crossorigin);
    const sourceElement = document.createElement("source");
    let mime;
    if (options.mime) {
      mime = options.mime;
    } else if (url.startsWith("data:")) {
      mime = url.slice(5, url.indexOf(";"));
    } else if (!url.startsWith("blob:")) {
      const ext = url.split("?")[0].slice(url.lastIndexOf(".") + 1).toLowerCase();
      mime = VideoSource.MIME_TYPES[ext] || `video/${ext}`;
    }
    sourceElement.src = url;
    if (mime) {
      sourceElement.type = mime;
    }
    return new Promise((resolve, reject) => {
      if (options.preload && !options.autoPlay) {
        videoElement.load();
      }
      videoElement.addEventListener("canplay", onCanPlay);
      videoElement.addEventListener("error", onError);
      sourceElement.addEventListener("error", onError);
      videoElement.appendChild(sourceElement);
      async function onCanPlay() {
        const base = new VideoSource({ ...options, resource: videoElement });
        cleanup();
        if (asset.data.preload) {
          await preloadVideo(videoElement);
        }
        resolve(createTexture(base, loader, url));
      }
      function onError(event) {
        cleanup();
        reject(event);
      }
      function cleanup() {
        videoElement.removeEventListener("canplay", onCanPlay);
        videoElement.removeEventListener("error", onError);
        sourceElement.removeEventListener("error", onError);
      }
    });
  },
  unload(texture) {
    texture.destroy(true);
  }
};

export { crossOrigin, determineCrossOrigin, loadVideoTextures, preloadVideo };
//# sourceMappingURL=loadVideoTextures.mjs.map
