import {
	Flex,
	Callout,
	Text,
	TextField,
	Switch,
	Button,
} from "@radix-ui/themes";
import { useAtom } from "jotai";
import { useState } from "react";
import { toast } from "react-toastify";
import { invoke } from "@tauri-apps/api/core";
import {
	resizeWindowAtom,
	targetWidthAtom,
	targetHeightAtom,
	recoverWindowSizeAtom,
} from "./states.ts";

const LosslessScreenshotTab = () => {
	const [resizeWindow, setResizeWindow] = useAtom(resizeWindowAtom);
	const [targetWidth, setTargetWidth] = useAtom(targetWidthAtom);
	const [targetHeight, setTargetHeight] = useAtom(targetHeightAtom);
	const [recoverWindowSize, setRecoverWindowSize] = useAtom(
		recoverWindowSizeAtom,
	);
	const [screenshotData, setScreenshotData] = useState<string | undefined>(
		undefined,
	);

	return (
		<Flex direction="column" pt="2" gap="2" height="100%" overflow="hidden">
			<Callout.Root color="orange">
				本功能仅支持 Windows (WebView2) 且高度实验性
			</Callout.Root>
			<Text as="p">
				本功能将会尝试通过 DevTools API
				截取播放器窗口的画面内容，截图时请勿操作播放器，以免影响截图效果。
			</Text>
			<Text as="label">
				<Flex align="center" justify="between" gap="2">
					<Text as="span">修改窗口大小</Text>
					<Switch checked={resizeWindow} onCheckedChange={setResizeWindow} />
				</Flex>
			</Text>
			<Text as="label">
				<Flex align="center" justify="between" gap="2">
					<Text as="span">截图宽度</Text>
					<TextField.Root
						disabled={!resizeWindow}
						type="number"
						value={targetWidth}
						onChange={(v) => setTargetWidth(v.target.valueAsNumber)}
						min={0}
						max={65536}
						step={1}
					>
						<TextField.Slot />
						<TextField.Slot>像素</TextField.Slot>
					</TextField.Root>
				</Flex>
			</Text>
			<Text as="label">
				<Flex align="center" justify="between" gap="2">
					<Text as="span">截图高度</Text>
					<TextField.Root
						disabled={!resizeWindow}
						type="number"
						value={targetHeight}
						onChange={(v) => setTargetHeight(v.target.valueAsNumber)}
						min={0}
						max={65536}
						step={1}
					>
						<TextField.Slot />
						<TextField.Slot>像素</TextField.Slot>
					</TextField.Root>
				</Flex>
			</Text>
			<Text as="label">
				<Flex align="center" justify="between" gap="2">
					<Text as="span">截图后恢复窗口大小</Text>
					<Switch
						disabled={!resizeWindow}
						checked={recoverWindowSize}
						onCheckedChange={setRecoverWindowSize}
					/>
				</Flex>
			</Text>
			<Flex gap="2" justify="center">
				<Button
					onClick={async () => {
						const p = toast.loading("正在截图，请稍候...");
						const data = (await invoke("take_screenshot", {
							targetWidth,
							targetHeight,
							recoverSize: recoverWindowSize,
							resizeWindow,
						})) as string;
						const uri = `data:image/png;base64,${data}`;
						const img = new Image();
						img.src = uri;
						img.onload = () => {
							setTargetWidth(img.width);
							setTargetHeight(img.height);
							setScreenshotData(uri);

							toast.update(p, {
								render: "截图成功！",
								type: "success",
								isLoading: false,
								autoClose: 2000,
								pauseOnFocusLoss: false,
								pauseOnHover: false,
							});
						};
					}}
				>
					截图
				</Button>
			</Flex>
			<Flex gap="2" justify="center">
				<Button
					onClick={async () => {
						if (!screenshotData) {
							toast.error("无法找到截图元素，请确保已成功截图。");
							return;
						}
						const data = atob(screenshotData.slice(22));
						const byteArray = new Uint8Array(data.length);
						for (let i = 0; i < data.length; i++) {
							byteArray[i] = data.charCodeAt(i);
						}
						const blob = new Blob([byteArray], { type: "image/png" });
						navigator.clipboard
							.write([
								new ClipboardItem({
									"image/png": blob,
								}),
							])
							.then(() => {
								toast.success("图片已复制到剪贴板！", {
									autoClose: 2000,
									pauseOnFocusLoss: false,
									pauseOnHover: false,
								});
							})
							.catch((err) => {
								toast.error(`复制图片失败: ${err.message}`);
							});
					}}
				>
					复制图片
				</Button>
				<Button
					onClick={async () => {
						const svgEl = document.getElementById(
							"output",
						) as SVGSVGElement | null;
						if (!svgEl) {
							toast.error("无法找到截图元素，请确保已成功录制。");
							return;
						}
						const canvas = document.createElement("canvas");
						canvas.width = targetWidth + 200;
						canvas.height = targetHeight + 200;
						const ctx = canvas.getContext("2d");
						if (!ctx) {
							toast.error("无法获取画布上下文，请稍后再试。");
							return;
						}
						const img = new Image();
						img.onload = () => {
							ctx.drawImage(img, 0, 0);
							canvas.toBlob((blob) => {
								navigator.clipboard
									.write([
										new ClipboardItem({
											"image/png": blob as Blob,
										}),
									])
									.then(() => {
										toast.success("图片已复制到剪贴板！", {
											autoClose: 2000,
											pauseOnFocusLoss: false,
											pauseOnHover: false,
										});
									})
									.catch((err) => {
										toast.error(`复制图片失败: ${err.message}`);
									});
							});
						};
						img.onerror = (err) => {
							toast.error(`加载图片失败: ${err}`);
						};
						const svgData = new XMLSerializer().serializeToString(svgEl);
						img.src = `data:image/svg+xml;base64,${btoa(svgData)}`;
					}}
				>
					复制图片（带阴影）
				</Button>
			</Flex>
			<Flex align="center" justify="center" flexGrow="1" overflow="hidden">
				<svg
					id="output"
					viewBox={`0 0 ${targetWidth + 200} ${targetHeight + 200}`}
					xmlns="http://www.w3.org/2000/svg"
					style={{
						height: "100%",
					}}
				>
					<title>screenshot result</title>
					<defs>
						<filter id="macos-shadow">
							<feDropShadow
								dx="0"
								dy="0"
								stdDeviation="20"
								floodColor="rgba(0,0,0,0.15)"
							/>
						</filter>
						<filter id="macos-shadow2">
							<feDropShadow
								dx="0"
								dy="25"
								stdDeviation="30"
								floodColor="rgba(0,0,0,0.25)"
							/>
						</filter>
						<rect
							id="window-rect"
							x={100}
							y={80}
							width={targetWidth}
							height={targetHeight}
							rx="10"
						/>
						<clipPath id="window-rect-clip">
							<use href="#window-rect" />
						</clipPath>
					</defs>
					<use
						href="#window-rect"
						strokeWidth="1"
						style={{
							filter: "url(#macos-shadow)",
						}}
					/>
					<use
						href="#window-rect"
						strokeWidth="1"
						style={{
							filter: "url(#macos-shadow2)",
						}}
					/>
					<image
						href={screenshotData}
						x={100}
						y={80}
						width={targetWidth}
						height={targetHeight}
						clipPath="url(#window-rect-clip)"
					/>
					<use
						href="#window-rect"
						strokeWidth="1"
						stroke="#FFF4"
						fill="transparent"
						style={{
							mixBlendMode: "plus-lighter",
						}}
					/>
				</svg>
			</Flex>
		</Flex>
	);
};

export default LosslessScreenshotTab;
