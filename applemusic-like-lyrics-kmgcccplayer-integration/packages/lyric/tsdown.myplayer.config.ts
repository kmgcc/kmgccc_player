import { defineConfig } from "tsdown";
import { baseConfig } from "../../tsdown.base.ts";

export default defineConfig({
	...baseConfig,
	entry: { "amll-lyric": "./src/myplayer-app.ts" },
	format: ["esm"],
	dts: false,
	outDir: "dist-myplayer",
	clean: true,
	deps: {
		alwaysBundle: [/./],
	},
});
