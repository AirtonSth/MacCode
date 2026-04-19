import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const config = defineConfig({
	build: {
		emptyOutDir: true,
		outDir: "../../dist",
		rollupOptions: {
			output: {
				manualChunks: (id) => {
					if (!id.includes("node_modules")) {
						return undefined;
					}
					if (id.includes("@xterm")) {
						return "xterm";
					}
					if (id.includes("framer-motion")) {
						return "framer";
					}
					if (id.includes("@tanstack/react-query") || id.includes("@tanstack/react-virtual")) {
						return "tanstack";
					}
					if (id.includes("@radix-ui")) {
						return "radix";
					}
					if (id.includes("react-markdown") || id.includes("remark-") || id.includes("micromark") || id.includes("mdast")) {
						return "markdown";
					}
					if (id.includes("lucide-react")) {
						return "icons";
					}
					if (id.includes("cmdk")) {
						return "cmdk";
					}
					if (id.includes("react-dom")) {
						return "react-dom";
					}
					if (id.includes("/react/") && (id.includes("node_modules/react/") || id.includes("node_modules/scheduler/"))) {
						return "react";
					}
					return undefined;
				},
			},
		},
	},

	plugins: [react()],
	root: "src/react",

	server: {
		port: 5173,
		strictPort: true,
	},
});

export default config;
