declare module "electrobun/bun" {
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
	}

	export interface UpdaterLocalInfo {
		channel(): Promise<string | undefined>;
	}

	export interface UpdaterNamespace {
		localInfo: UpdaterLocalInfo;
	}

	export const Updater: UpdaterNamespace;
}
