import { DOMAdapter } from '../../environment/adapter.mjs';

"use strict";
let promise;
async function detectVideoAlphaMode() {
  promise ?? (promise = (async () => {
    const canvas = DOMAdapter.get().createCanvas(1, 1);
    const gl = canvas.getContext("webgl");
    if (!gl) {
      return "premultiply-alpha-on-upload";
    }
    const video = await new Promise((resolve) => {
      const video2 = document.createElement("video");
      video2.onloadeddata = () => resolve(video2);
      video2.onerror = () => resolve(null);
      video2.autoplay = false;
      video2.crossOrigin = "anonymous";
      video2.preload = "auto";
      video2.src = "data:video/webm;base64,GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAHTEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHGTbuMU6uEElTDZ1OsggEXTbuMU6uEHFO7a1OsggG97AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmoCrXsYMPQkBNgIRMYXZmV0GETGF2ZkSJiEBEAAAAAAAAFlSua8yuAQAAAAAAAEPXgQFzxYgAAAAAAAAAAZyBACK1nIN1bmSIgQCGhVZfVlA5g4EBI+ODhAJiWgDglLCBArqBApqBAlPAgQFVsIRVuYEBElTDZ9Vzc9JjwItjxYgAAAAAAAAAAWfInEWjh0VOQ09ERVJEh49MYXZjIGxpYnZweC12cDlnyKJFo4hEVVJBVElPTkSHlDAwOjAwOjAwLjA0MDAwMDAwMAAAH0O2dcfngQCgwqGggQAAAIJJg0IAABAAFgA4JBwYSgAAICAAEb///4r+AAB1oZ2mm+6BAaWWgkmDQgAAEAAWADgkHBhKAAAgIABIQBxTu2uRu4+zgQC3iveBAfGCAXHwgQM=";
      video2.load();
    });
    if (!video) {
      return "premultiply-alpha-on-upload";
    }
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    const framebuffer = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
    gl.framebufferTexture2D(
      gl.FRAMEBUFFER,
      gl.COLOR_ATTACHMENT0,
      gl.TEXTURE_2D,
      texture,
      0
    );
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video);
    const pixel = new Uint8Array(4);
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
    gl.deleteFramebuffer(framebuffer);
    gl.deleteTexture(texture);
    gl.getExtension("WEBGL_lose_context")?.loseContext();
    return pixel[0] <= pixel[3] ? "premultiplied-alpha" : "premultiply-alpha-on-upload";
  })());
  return promise;
}

export { detectVideoAlphaMode };
//# sourceMappingURL=detectVideoAlphaMode.mjs.map
