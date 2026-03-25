/* eslint-disable @typescript-eslint/naming-convention */
export interface PrivateAuthUserDto {
	daysRemaing: number;
	daysRemaining: number;
	email: string;
	id: string;
	subscribed: boolean;
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

export interface PrivateSubscriptionSnapshotDto {
	daysRemaing: number;
	daysRemaining: number;
	email: string;
	endsAt: string | null;
	portalUrl: string | null;
	renewsAt: string | null;
	status: "inactive" | "trialing" | "active" | "past_due" | "canceled" | "expired";
	subscribed: boolean;
	trialEndsAt: string | null;
}

export interface PrivateRevenueCatSyncResponseDto {
	subscription: PrivateSubscriptionSnapshotDto;
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

export interface PrivateSignupIntentRequestDto {
	email: string;
	password: string;
	platform: "web" | "ios" | "android" | "macos" | "windows" | "linux";
	returnUrl?: string | null;
	target: "web" | "mobile" | "desktop";
}

export interface PrivateSignupIntentDto {
	email: string;
	id: string;
	platform: "web" | "ios" | "android" | "macos" | "windows" | "linux";
	returnUrl: string | null;
	status: "pending_checkout" | "checkout_created" | "billing_active" | "completed" | "expired" | "canceled";
	subscriptionStatus: "inactive" | "trialing" | "active" | "past_due" | "canceled" | "expired";
	target: "web" | "mobile" | "desktop";
	trialEndsAt: string | null;
}

export interface PrivateSignupIntentResponseDto {
	signupIntent: PrivateSignupIntentDto;
}

export interface PrivateSignupIntentCheckoutResponseDto {
	checkoutUrl: string;
}

export interface PrivateSignupIntentCompletionResponseDto {
	redirectUrl: string;
	session: PrivateSessionDto;
	signupIntent: PrivateSignupIntentDto;
}

export interface PrivateAuthCompletionExchangeRequestDto {
	completionToken: string;
}

export interface PrivateForgotPasswordRequestDto {
	email: string;
}

export interface PrivateForgotPasswordResponseDto {
	sent: true;
}

export interface PrivateResetPasswordRequestDto {
	password: string;
	token: string;
}

export interface PrivateResetPasswordResponseDto {
	reset: true;
}

export interface PrivateResetPasswordValidateResponseDto {
	valid: true;
}

export interface PrivatePairingClaimRequestDto {
	pairingCode: string;
}

export interface PrivateAccountStateDto {
	authenticated: boolean;
	connector: PrivateConnectorDto | null;
	connectorRelayState: "idle" | "connecting" | "connected" | "disconnected" | "error";
	errorMessage: string | null;
	user: PrivateAuthUserDto | null;
}
