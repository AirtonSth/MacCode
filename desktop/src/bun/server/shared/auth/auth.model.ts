export interface AuthConfig {
	token: string;
}

export interface RestAuthContext {
	authorized: boolean;
	token?: string;
}
