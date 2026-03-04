import { getServerConnectHints, getServerDiscoveryInfo, getServerId } from "../../shared/core/server-identity";
import { isValidToken } from "../../shared/auth/auth.service";
import type { DiscoveryInfoDTO } from "../../shared/core/server.types";
import type { ServerMetadataRepository } from "./server-metadata.repository";

export type DiscoveryMetadata = DiscoveryInfoDTO;

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
			...discovery,
			port: this.port,
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
		return {
			...this.metadata,
			connectHints: getServerConnectHints(this.metadata.port),
		};
	}
}

export const createServerMetadataService = (repository: ServerMetadataRepository, port: number) =>
	new ServerMetadataService(repository, port);
