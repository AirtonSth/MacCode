import type { PrivateSessionDto } from "@remotecode/contracts";

import type { ServerMetadataRepository } from "../server-metadata/server-metadata.repository";
import type { PersistedPrivateConnector } from "./private-account.model";

const SESSION_KEY = "privateAccount.session";
const CONNECTOR_KEY = "privateAccount.connector";

const parseJson = <T>(value: string | null): T | null => {
	if (!value) {
		return null;
	}

	try {
		return JSON.parse(value) as T;
	} catch {
		return null;
	}
};

export class PrivateAccountRepository {
	public constructor(private readonly repository: ServerMetadataRepository) {}

	public clearConnector(): void {
		this.repository.setValue(CONNECTOR_KEY, "");
	}

	public clearSession(): void {
		this.repository.setValue(SESSION_KEY, "");
	}

	public readConnector(): PersistedPrivateConnector | null {
		return parseJson<PersistedPrivateConnector>(this.repository.getValue(CONNECTOR_KEY));
	}

	public readSession(): PrivateSessionDto | null {
		return parseJson<PrivateSessionDto>(this.repository.getValue(SESSION_KEY));
	}

	public saveConnector(input: PersistedPrivateConnector): void {
		this.repository.setValue(CONNECTOR_KEY, JSON.stringify(input));
	}

	public saveSession(input: PrivateSessionDto): void {
		this.repository.setValue(SESSION_KEY, JSON.stringify(input));
	}
}

export const createPrivateAccountRepository = (repository: ServerMetadataRepository) =>
	new PrivateAccountRepository(repository);

