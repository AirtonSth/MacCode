import { hostname } from "node:os";

interface MdnsOptions {
	port: number;
	serverId: string;
	version: string;
	capabilitiesVersion: string;
}

interface PublishHandle {
	stop?: () => void;
}

interface BonjourHandle {
	publish: (config: {
		host?: string;
		name: string;
		port: number;
		protocol: "tcp" | "udp";
		type: string;
		txt?: Record<string, string>;
	}) => PublishHandle;
	destroy?: () => void;
}

export const startMdnsBroadcast = async (options: MdnsOptions): Promise<() => void> => {
	try {
		const module = await import("bonjour-service");
		const Bonjour = (module as { Bonjour: new () => BonjourHandle }).Bonjour;
		const bonjour = new Bonjour();
		const serviceName = `remotecode-${options.serverId.slice(0, 8)}`;
		const publication = bonjour.publish({
			host: hostname(),
			name: serviceName,
			port: options.port,
			protocol: "tcp",
			type: "remotecode",
			txt: {
				authMode: "token_lan",
				capabilitiesVersion: options.capabilitiesVersion,
				serverId: options.serverId,
				version: options.version,
			},
		});

		return () => {
			try {
				publication.stop?.();
			} catch {
				// no-op
			}

			try {
				bonjour.destroy?.();
			} catch {
				// no-op
			}
		};
	} catch (error) {
		console.warn("mDNS broadcast unavailable", error);
		return () => {
			// no-op
		};
	}
};
