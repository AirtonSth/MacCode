declare module "electrobun/view" {
	export type RPCFunction = (...args: unknown[]) => unknown;

export interface RPCConfig {
	rpc?: unknown;
	handlers?: {
		requests?: Record<string, RPCFunction>;
		messages?: Record<string, RPCFunction>;
	};
}

	export interface ElectroviewClient {
		rpc: {
			request: Record<string, (...args: unknown[]) => Promise<unknown>>;
			respond: Record<string, (...args: unknown[]) => Promise<unknown>>;
			message: Record<string, (...args: unknown[]) => void>;
		};
	}

	export class Electroview implements ElectroviewClient {
		rpc: {
			request: Record<string, (...args: unknown[]) => Promise<unknown>>;
			respond: Record<string, (...args: unknown[]) => Promise<unknown>>;
			message: Record<string, (...args: unknown[]) => void>;
		};
		constructor(config: RPCConfig);
	}

	export namespace Electroview {
		function defineRPC<T>(config: {
			maxRequestTime?: number;
			handlers: {
				requests: Record<string, (...args: unknown[]) => unknown>;
				messages: Record<string, (...args: unknown[]) => unknown>;
			};
		}): T;
	}
}
