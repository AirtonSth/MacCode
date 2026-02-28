import react from "@vitejs/plugin-react";
import { createServer } from "vite";

async function main() {
	const host = process.env.HMR_HOST || "127.0.0.1";
	const port = Number(process.env.HMR_PORT || 5173);

	const server = await createServer({
		root: "src/react",
		plugins: [react()],
		server: {
			host,
			port,
			strictPort: true,
		},
		build: {
			emptyOutDir: true,
			outDir: "../../dist",
		},
	});

	await server.listen();

	if (typeof server.printUrls === "function") {
		server.printUrls();
	} else {
		const resolved = server.config.server;
		console.log(`vite server running on http://${resolved.host || "localhost"}:${resolved.port}`);
	}
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
