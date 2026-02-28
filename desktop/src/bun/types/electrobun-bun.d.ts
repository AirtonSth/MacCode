declare module "electrobun/bun" {
	export interface WebView {
		openDevTools: () => void;
		on: (event: string, listener: (...args: unknown[]) => void) => void;
	}

	export interface BrowserWindowConfig {
		frame?: {
			height?: number;
			width?: number;
			x?: number;
			y?: number;
		};
		title?: string;
		url?: string;
	}

	export class BrowserWindow {
		constructor(options?: BrowserWindowConfig);
		webview: WebView;
	}

	export interface UpdaterLocalInfo {
		channel(): Promise<string | undefined>;
	}

	export interface UpdaterNamespace {
		localInfo: UpdaterLocalInfo;
	}

	export const Updater: UpdaterNamespace;
}
