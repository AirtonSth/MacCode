export interface CreateProjectInput {
	name?: string;
	path: string;
}

export interface CreateProjectOutput {
	name?: string;
	path?: string;
	projectId?: string;
}
