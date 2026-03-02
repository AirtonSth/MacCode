import { getServerDiscoveryInfo, getServerId } from "../../shared/core/server-identity";
import { isValidToken } from "../../shared/auth/auth.service";
import type { ServerMetadataRepository } from "./server-metadata.repository";

export interface DiscoveryMetadata {
	serverId: string;
	hostname: string;
	port: number;
	version: string;
	authMode: string;
	capabilitiesVersion: string;
}

export interface ServerMetadataServiceContract {
	getDiscoveryMetadata: () => DiscoveryMetadata;
	getServerId: () => string;
	verifyToken: (token: string | null | undefined) => boolean;
}

export class ServerMetadataService implements ServerMetadataServiceContract {
	private readonly metadata: DiscoveryMetadata;

	constructor(
		private readonly repository: ServerMetadataRepository,
		private readonly port: number,
		) {
			this.repository.setValue("serverId", getServerId());
			const discovery = getServerDiscoveryInfo();
			this.metadata = {
				authMode: discovery.authMode,
				capabilitiesVersion: discovery.capabilitiesVersion,
				hostname: discovery.hostname,
				port: this.port,
				serverId: discovery.serverId,
				version: discovery.version,
			};
		this.repository.setValue("lastPort", String(this.metadata.port));
		this.repository.setValue("version", this.metadata.version);
		this.repository.setValue("capabilitiesVersion", this.metadata.capabilitiesVersion);
	}

	getServerId(): string {
		return getServerId();
	}

	verifyToken(token: string | null | undefined): boolean {
		return isValidToken(token);
	}

	getDiscoveryMetadata(): DiscoveryMetadata {
		return this.metadata;
	}
}

export const createServerMetadataService = (repository: ServerMetadataRepository, port: number) =>
	new ServerMetadataService(repository, port);
