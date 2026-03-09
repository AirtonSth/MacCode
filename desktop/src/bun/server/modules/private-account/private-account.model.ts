import type {
	DesktopMobileConnectQrPayloadDto,
	PrivateAccountStateDto,
	PrivateAuthUserDto,
	PrivateConnectorDto,
	PrivateSessionDto,
} from "@remotecode/contracts";

export interface PersistedPrivateConnector {
	backendUrl: string;
	connectorId: string;
	connectorName: string;
	connectorToken: string;
}

export interface PersistedPrivateState {
	connector: PersistedPrivateConnector | null;
	session: PrivateSessionDto | null;
}

export interface PrivateAccountStateSnapshot {
	connector: PrivateConnectorDto | null;
	connectorRelayState: PrivateAccountStateDto["connectorRelayState"];
	errorMessage: string | null;
	qrPayload: DesktopMobileConnectQrPayloadDto | null;
	user: PrivateAuthUserDto | null;
}

export interface PrivateAccountAuthInput {
	email: string;
	password: string;
}

