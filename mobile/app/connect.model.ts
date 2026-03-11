import type { DesktopMobileConnectQrPayloadDto } from "@remotecode/contracts";

import {
	completePrivateMobileConnect,
	parsePrivateConnectInput,
	toPrivateConnectErrorMessage,
	type PrivateMobileConnectLink,
} from "@/shared/api/private-mobile-connect";
import type { PersistedPrivateSessionRecord } from "@/shared/api/private-session-store";

export interface ConnectRouteFlowDependencies {
	activateConnector: (options: {
		backendUrl: string;
		connectorId: string;
		sessionRecordOverride?: PersistedPrivateSessionRecord;
	}) => Promise<void>;
	clearPendingQrPayload: () => Promise<void>;
	completeConnect?: (input: {
		activateConnector: ConnectRouteFlowDependencies["activateConnector"];
		clearPendingQrPayload: ConnectRouteFlowDependencies["clearPendingQrPayload"];
		link: PrivateMobileConnectLink;
		setSessionRecord: ConnectRouteFlowDependencies["setSessionRecord"];
	}) => Promise<{
		connector: {
			id: string;
			name: string;
		};
		sessionRecord: PersistedPrivateSessionRecord;
	}>;
	onStatusMessage?: (message: string) => void;
	parseInput?: typeof parsePrivateConnectInput;
	rawUrl: string;
	sessionRecord: PersistedPrivateSessionRecord | null;
	setPendingQrPayload: (payload: DesktopMobileConnectQrPayloadDto) => Promise<void>;
	setSessionRecord: (sessionRecord: PersistedPrivateSessionRecord) => Promise<void>;
}

export type ConnectRouteFlowResult =
	| {
			errorMessage?: undefined;
			pathname: "/settings";
			privateConnectError?: undefined;
			statusMessage?: undefined;
		}
	| {
			errorMessage?: undefined;
			pathname: "/workspaces";
			privateConnectError?: undefined;
			statusMessage: string;
		}
	| {
			errorMessage: string;
			pathname: "/settings";
			privateConnectError: string;
			statusMessage?: undefined;
		};

export const runConnectRouteFlow = async (
	input: ConnectRouteFlowDependencies,
): Promise<ConnectRouteFlowResult> => {
	try {
		const intent = (input.parseInput ?? parsePrivateConnectInput)(input.rawUrl);
		if (intent.kind === "legacy_qr") {
			await input.setPendingQrPayload(intent.payload);
			if (input.sessionRecord?.backendUrl !== intent.payload.backendUrl) {
				return {
					pathname: "/settings",
				};
			}

			const statusMessage = `Connecting to ${intent.payload.connectorName}.`;
			input.onStatusMessage?.(statusMessage);
			await input.activateConnector({
				backendUrl: intent.payload.backendUrl,
				connectorId: intent.payload.connectorId,
			});
			await input.clearPendingQrPayload();
			return {
				pathname: "/workspaces",
				statusMessage,
			};
		}

		input.onStatusMessage?.("Claiming private connection.");
		const result = await (input.completeConnect ?? completePrivateMobileConnect)({
			activateConnector: input.activateConnector,
			clearPendingQrPayload: input.clearPendingQrPayload,
			link: intent.claim,
			setSessionRecord: input.setSessionRecord,
		});
		const statusMessage = `Connected to ${result.connector.name}.`;
		input.onStatusMessage?.(statusMessage);
		return {
			pathname: "/workspaces",
			statusMessage,
		};
	} catch (error) {
		const message = toPrivateConnectErrorMessage(error);
		return {
			errorMessage: message,
			pathname: "/settings",
			privateConnectError: message,
		};
	}
};
