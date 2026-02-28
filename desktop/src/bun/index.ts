import { BrowserWindow, Updater } from "electrobun/bun";

const DEV_SERVER_PORT = 5173;
const DEV_SERVER_URL = `http://localhost:${DEV_SERVER_PORT}`;

async function getMainViewUrl() {
	const channel = await Updater.localInfo.channel();

	if (channel === "dev") {
		try {
			await fetch(DEV_SERVER_URL, { method: "HEAD" });
			console.log(`HMR ativo: usando Vite em ${DEV_SERVER_URL}`);

			return DEV_SERVER_URL;
		} catch {
			console.log(
				"Servidor Vite não encontrado. Rode 'bun run dev:hmr' para HMR.",
			);
		}
	}

	return "views://react/index.html";
}

const url = await getMainViewUrl();

const mainWindow = new BrowserWindow({
	frame: {
		height: 700,
		width: 900,
		x: 200,
		y: 200,
	},

	title: "Remotecode + Electrobun",
	url,
});

void mainWindow;
console.log("Electrobun app started with React + Vite");
