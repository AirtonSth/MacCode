import { logHeadlessServerError, runHeadlessServerCli } from "./headless-server";
import { serverLogger } from "../shared/core/server-logger";

const registerSignalHandlers = (stop: () => Promise<void>): void => {
	let shuttingDown = false;

	const handleSignal = (signal: NodeJS.Signals): void => {
		if (shuttingDown) {
			return;
		}

		shuttingDown = true;
		serverLogger.info("headless-server", "Shutdown signal received", {
			signal,
		});
		void stop()
			.then(() => {
				serverLogger.success("headless-server", "Headless server stopped");
				process.exit(0);
			})
			.catch((error) => {
				logHeadlessServerError(error);
				process.exit(1);
			});
	};

	process.on("SIGINT", () => {
		handleSignal("SIGINT");
	});
	process.on("SIGTERM", () => {
		handleSignal("SIGTERM");
	});
};

const main = async (): Promise<void> => {
	const runtime = await runHeadlessServerCli(process.argv.slice(2));
	registerSignalHandlers(runtime.stop);
	await new Promise<void>(() => undefined);
};

await main().catch((error) => {
	logHeadlessServerError(error);
	process.exit(1);
});
