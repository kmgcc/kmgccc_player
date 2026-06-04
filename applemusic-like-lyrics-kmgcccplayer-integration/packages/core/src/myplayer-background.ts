/// <reference path="./types.d.ts" />
import type { BaseRenderer } from "./bg-render/base.ts";
export { MeshGradientRenderer } from "./bg-render/mesh-renderer/index.ts";

export class BackgroundRender<Renderer extends BaseRenderer> {
	private element: HTMLCanvasElement;
	private renderer: Renderer;

	constructor(renderer: Renderer, canvas: HTMLCanvasElement) {
		this.renderer = renderer;
		this.element = canvas;
		canvas.style.pointerEvents = "none";
		canvas.style.contain = "strict";
	}

	static new<Renderer extends BaseRenderer>(type: {
		new (canvas: HTMLCanvasElement): Renderer;
	}): BackgroundRender<Renderer> {
		const canvas = document.createElement("canvas");
		return new BackgroundRender(new type(canvas), canvas);
	}

	setRenderScale(scale: number): void {
		this.renderer.setRenderScale(scale);
	}

	setFlowSpeed(speed: number): void {
		this.renderer.setFlowSpeed(speed);
	}

	setStaticMode(enable: boolean): void {
		this.renderer.setStaticMode(enable);
	}

	setFPS(fps: number): void {
		this.renderer.setFPS(fps);
	}

	pause(): void {
		this.renderer.pause();
	}

	resume(): void {
		this.renderer.resume();
	}

	setLowFreqVolume(volume: number): void {
		this.renderer.setLowFreqVolume(volume);
	}

	setHasLyric(hasLyric: boolean): void {
		this.renderer.setHasLyric(hasLyric);
	}

	setAlbum(
		albumSource: string | HTMLImageElement | HTMLVideoElement,
		isVideo?: boolean,
	): Promise<void> {
		return this.renderer.setAlbum(albumSource, isVideo);
	}

	getElement(): HTMLCanvasElement {
		return this.element;
	}

	dispose(): void {
		this.renderer.dispose();
		this.element.remove();
	}
}
