import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

import type { Browser, Page, Target } from "puppeteer-core";
import { connect as connectPuppeteer } from "puppeteer-core";
import { PNG } from "pngjs";

interface CdpVersionPayload {
	webSocketDebuggerUrl?: string;
}

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const desktopRoot = path.resolve(scriptDir, "..");
const artifactsDir = path.join(desktopRoot, "playwright-e2e", "artifacts");

const readNumberEnv = (name: string, fallback: number): number => {
	const rawValue = process.env[name];
	if (!rawValue) {
		return fallback;
	}

	const parsedValue = Number(rawValue);
	if (!Number.isFinite(parsedValue) || parsedValue <= 0) {
		return fallback;
	}

	return parsedValue;
};

const cdpPort = readNumberEnv("ELECTROBUN_CDP_PORT", 9333);
const windowWidth = readNumberEnv("ELECTROBUN_WINDOW_WIDTH", 1200);
const windowHeight = readNumberEnv("ELECTROBUN_WINDOW_HEIGHT", 700);
const startupTimeoutMs = readNumberEnv("ELECTROBUN_CDP_TIMEOUT_MS", 120000);
const pageTargetTimeoutMs = readNumberEnv("ELECTROBUN_PAGE_TIMEOUT_MS", 60000);
const captureRetries = readNumberEnv("ELECTROBUN_CAPTURE_RETRIES", 6);
const captureRetryDelayMs = readNumberEnv("ELECTROBUN_CAPTURE_RETRY_DELAY_MS", 1200);
const checkIntervalMs = 500;
const validateNonWhiteFrame = process.env.ELECTROBUN_SKIP_WHITE_CHECK !== "1";

const outputPath = path.join(artifactsDir, "electrobun-cdp-screenshot.png");
const tempOutputPath = path.join(artifactsDir, "electrobun-cdp-screenshot.tmp.png");
const versionEndpointUrl = `http://127.0.0.1:${cdpPort}/json/version`;

if (!fs.existsSync(artifactsDir)) {
	fs.mkdirSync(artifactsDir, { recursive: true });
}

const isWindows = process.platform === "win32";
const supportsDetachedGroupKill = !isWindows;
const bunCommand = isWindows ? "bun.cmd" : "bun";

let appProcess: ReturnType<typeof spawn> | null = null;
let spawnedApp = false;

const maybeKillProcess = (pid: number, signal: NodeJS.Signals): void => {
	try {
		process.kill(pid, signal);
	} catch {
		// Process may already be gone.
	}
};

const startElectrobunForCapture = (): void => {
	appProcess = spawn(bunCommand, ["run", "dev"], {
		cwd: desktopRoot,
		env: {
			...process.env,
			ELECTROBUN_CDP: "1",
			ELECTROBUN_CDP_PORT: String(cdpPort),
		},
		stdio: "pipe",
		detached: supportsDetachedGroupKill,
	});

	appProcess.stderr?.on("data", (chunk) => {
		console.error(`[electrobun] ${chunk.toString().trim()}`);
	});

	if (supportsDetachedGroupKill) {
		appProcess.unref();
	}

	spawnedApp = true;
};

const cleanup = async (): Promise<void> => {
	if (!spawnedApp || !appProcess || typeof appProcess.pid !== "number") {
		return;
	}

	const killTargetPid = supportsDetachedGroupKill ? -appProcess.pid : appProcess.pid;
	maybeKillProcess(killTargetPid, "SIGINT");
	await delay(700);
	maybeKillProcess(killTargetPid, "SIGKILL");

	appProcess.stdout?.destroy();
	appProcess.stderr?.destroy();
};

const fetchCdpVersion = async (): Promise<CdpVersionPayload | null> => {
	try {
		const response = await fetch(versionEndpointUrl);
		if (!response.ok) {
			return null;
		}
		return (await response.json()) as CdpVersionPayload;
	} catch {
		return null;
	}
};

const waitForCdpEndpoint = async (): Promise<string> => {
	const start = Date.now();

	while (Date.now() - start < startupTimeoutMs) {
		const payload = await fetchCdpVersion();
		if (payload?.webSocketDebuggerUrl) {
			return payload.webSocketDebuggerUrl;
		}
		await delay(checkIntervalMs);
	}

	throw new Error("Timed out waiting for Electrobun CDP endpoint.");
};

const scoreTargetUrl = (url: string): number => {
	if (!url) {
		return 10;
	}
	if (url.includes("localhost") || url.includes("127.0.0.1")) {
		return 0;
	}
	if (url.startsWith("views://")) {
		return 1;
	}
	if (url.startsWith("file://")) {
		return 2;
	}
	if (url === "about:blank") {
		return 8;
	}
	if (url.startsWith("devtools://")) {
		return 9;
	}
	return 3;
};

const listPageTargets = (browser: Browser): Target[] => {
	return browser
		.targets()
		.filter((target) => target.type() === "page")
		.sort((left, right) => scoreTargetUrl(left.url()) - scoreTargetUrl(right.url()));
};

const waitForPageTargets = async (browser: Browser): Promise<Target[]> => {
	const start = Date.now();

	while (Date.now() - start < pageTargetTimeoutMs) {
		const targets = listPageTargets(browser);
		if (targets.length > 0) {
			return targets;
		}
		await delay(checkIntervalMs);
	}

	throw new Error("Timed out waiting for a page target in CDP.");
};

const imageContainsNonWhitePixels = (imagePath: string): boolean => {
	if (!validateNonWhiteFrame) {
		return true;
	}

	const imageBuffer = fs.readFileSync(imagePath);
	const png = PNG.sync.read(imageBuffer);
	const sampleStride = 7;

	for (let y = 0; y < png.height; y += sampleStride) {
		for (let x = 0; x < png.width; x += sampleStride) {
			const offset = (png.width * y + x) * 4;
			const red = png.data[offset];
			const green = png.data[offset + 1];
			const blue = png.data[offset + 2];
			if (red < 245 || green < 245 || blue < 245) {
				return true;
			}
		}
	}

	return false;
};

const preparePage = async (page: Page): Promise<void> => {
	await page.setViewport({
		width: windowWidth,
		height: windowHeight,
		deviceScaleFactor: 1,
	});

	try {
		await page.waitForFunction(
			() => document.readyState === "interactive" || document.readyState === "complete",
			{ timeout: 20000 },
		);
	} catch {
		// Continue and let capture retries handle slower loads.
	}

	try {
		await page.waitForFunction(
			() => {
				const body = document.body;
				if (!body) {
					return false;
				}
				return body.children.length > 0 || (body.textContent?.trim().length ?? 0) > 0;
			},
			{ timeout: 20000 },
		);
	} catch {
		// Some UIs render primarily via canvas.
	}
};

const capturePage = async (page: Page, pageLabel: string): Promise<boolean> => {
	for (let attempt = 1; attempt <= captureRetries; attempt += 1) {
		await preparePage(page);
		await page.screenshot({
			path: tempOutputPath,
			type: "png",
			fullPage: false,
			captureBeyondViewport: false,
		});

		if (imageContainsNonWhitePixels(tempOutputPath)) {
			fs.copyFileSync(tempOutputPath, outputPath);
			console.log(
				`Screenshot saved to: ${outputPath} (target=${pageLabel}, attempt=${attempt})`,
			);
			return true;
		}

		if (attempt < captureRetries) {
			await delay(captureRetryDelayMs);
		}
	}

	return false;
};

try {
	const existingEndpoint = await fetchCdpVersion();
	let browserWSEndpoint = existingEndpoint?.webSocketDebuggerUrl ?? null;

	if (!browserWSEndpoint) {
		startElectrobunForCapture();
		browserWSEndpoint = await waitForCdpEndpoint();
	} else {
		console.log(`Reusing existing CDP endpoint on port ${cdpPort}`);
	}

	const browser = await connectPuppeteer({ browserWSEndpoint });
	const targets = await waitForPageTargets(browser);
	let screenshotCaptured = false;

	for (const target of targets) {
		const targetPage = await target.page();
		if (!targetPage) {
			continue;
		}
		const pageLabel = target.url() || "<empty-url>";
		screenshotCaptured = await capturePage(targetPage, pageLabel);
		if (screenshotCaptured) {
			break;
		}
	}

	await browser.disconnect();

	if (!screenshotCaptured) {
		throw new Error("Captured only blank frames. No rendered page was detected.");
	}

	await cleanup();
} catch (error) {
	const reason = error instanceof Error ? error.message : String(error);
	console.error("CDP automation failed:", reason);
	await cleanup();
	process.exit(1);
}
