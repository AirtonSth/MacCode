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
		rpc?: unknown;
	}

	export class BrowserWindow {
		constructor(options?: BrowserWindowConfig);
		webview: WebView;
	}

	export interface BrowserViewConfig {
		id?: string;
	}

	export class BrowserView {
		constructor(options?: BrowserViewConfig);
		id: string;
		rpc: unknown;
	}

	export const BrowserView: {
		defineRPC: <T>(config: {
			handlers: {
				requests: Record<string, (...args: never[]) => unknown>;
				messages: Record<string, (...args: never[]) => void>;
			};
			maxRequestTime?: number;
		}) => T;
		getById: (id: string) => BrowserView;
		getAll: () => BrowserView[];
	};

	export interface UpdaterLocalInfo {
		channel(): Promise<string | undefined>;
	}

	export interface UpdaterNamespace {
		localInfo: UpdaterLocalInfo;
	}

	export const Updater: UpdaterNamespace;

	export interface UtilsNamespace {
		paths: {
			home: string;
		};
		openFileDialog: (options: {
			allowedFileTypes?: string;
			allowsMultipleSelection?: boolean;
			canChooseDirectory?: boolean;
			canChooseFiles?: boolean;
			startingFolder?: string;
		}) => Promise<string[]>;
	}

	export const Utils: UtilsNamespace;
}
