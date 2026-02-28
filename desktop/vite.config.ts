import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const config = defineConfig({
	build: {
		emptyOutDir: true,
		outDir: "../../dist",
	},

	plugins: [react()],
	root: "src/react",

	server: {
		port: 5173,
		strictPort: true,
	},
});

export default config;
