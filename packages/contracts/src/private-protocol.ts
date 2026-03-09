/* eslint-disable @typescript-eslint/naming-convention */
export interface PrivateAuthUserDto {
	email: string;
	id: string;
}

export interface PrivateSessionDto {
	accessToken: string;
	refreshToken: string;
	user: PrivateAuthUserDto;
}

export interface PrivateConnectorDto {
	claimedAt: string | null;
	hostname: string | null;
	id: string;
	isOnline: boolean;
	lastSeenAt: string | null;
	name: string;
	relayCapabilitiesVersion: string | null;
	relayVersion: string | null;
	status: "pending" | "online" | "offline" | "expired" | "claimed";
}

export interface PrivateConnectorsResponseDto {
	connectors: PrivateConnectorDto[];
}

export interface PrivateBootstrapQrPayloadDto {
	backendUrl: string;
	pairingCode: string;
	pairingId: string;
	type: "remotecode_private_pairing";
	version: 1;
}

export interface PrivateBootstrapResponseDto {
	connector: {
		id: string;
		name: string;
	};
	expiresAt: string;
	pairing: {
		code: string;
		id: string;
		pollToken: string;
		qrPayload: PrivateBootstrapQrPayloadDto;
	};
}

export interface PrivateBootstrapStatusDto {
	connector: {
		accessToken?: string;
		id: string;
	};
	expiresAt: string;
	status: "pending" | "claimed" | "expired";
}

export interface PrivatePairingClaimResponseDto {
	claimedAt: string;
	connectorId: string;
	status: "claimed";
}

export interface PrivateMeResponseDto {
	user: PrivateAuthUserDto;
}

export interface PrivateLogoutRequestDto {
	refreshToken: string;
}

export interface PrivateRefreshRequestDto {
	refreshToken: string;
}

export interface PrivateRegisterRequestDto {
	email: string;
	password: string;
}

export interface PrivateLoginRequestDto {
	email: string;
	password: string;
}

export interface PrivatePairingClaimRequestDto {
	pairingCode: string;
}

export interface DesktopMobileConnectQrPayloadDto {
	backendUrl: string;
	connectorId: string;
	connectorName: string;
	type: "remotecode_private_mobile_connect";
	version: 1;
}

export interface PrivateAccountStateDto {
	authenticated: boolean;
	connector: PrivateConnectorDto | null;
	connectorRelayState: "idle" | "connecting" | "connected" | "disconnected" | "error";
	errorMessage: string | null;
	qrPayload: DesktopMobileConnectQrPayloadDto | null;
	user: PrivateAuthUserDto | null;
}

const isObject = (value: unknown): value is Record<string, unknown> =>
	typeof value === "object" && value !== null;

export const isDesktopMobileConnectQrPayload = (value: unknown): value is DesktopMobileConnectQrPayloadDto => {
	if (!isObject(value)) {
		return false;
	}

	return (
		value.type === "remotecode_private_mobile_connect"
		&& value.version === 1
		&& typeof value.backendUrl === "string"
		&& value.backendUrl.trim().length > 0
		&& typeof value.connectorId === "string"
		&& value.connectorId.trim().length > 0
		&& typeof value.connectorName === "string"
		&& value.connectorName.trim().length > 0
	);
};

export const parseDesktopMobileConnectQrPayload = (raw: string): DesktopMobileConnectQrPayloadDto => {
	const parsed = JSON.parse(raw) as unknown;

	if (!isDesktopMobileConnectQrPayload(parsed)) {
		throw new Error("invalid_private_mobile_qr_payload");
	}

	return {
		backendUrl: parsed.backendUrl.trim(),
		connectorId: parsed.connectorId.trim(),
		connectorName: parsed.connectorName.trim(),
		type: parsed.type,
		version: parsed.version,
	};
};
