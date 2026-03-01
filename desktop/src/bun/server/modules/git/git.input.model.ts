export interface GitCheckoutRequest {
	branch: string;
}

export interface GitCreateBranchRequest {
	name: string;
}

export interface GitCommitRequest {
	message: string;
	includeUnstaged?: boolean;
	push?: boolean;
}
