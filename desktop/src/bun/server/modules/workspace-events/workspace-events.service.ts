import type {
	WorkspaceEventEnvelope,
	WorkspaceEventPublishInput,
	WorkspaceEventRepositoryContract,
	WorkspaceEventServiceContract,
} from "./workspace-events.model";

export class WorkspaceEventsService implements WorkspaceEventServiceContract {
	private readonly listeners = new Set<(event: WorkspaceEventEnvelope) => void>();

	constructor(private readonly repository: WorkspaceEventRepositoryContract) {}

	listAfterSeq(seq: number, limit?: number): WorkspaceEventEnvelope[] {
		return this.repository.listAfterSeq(seq, limit);
	}

	append(input: WorkspaceEventPublishInput): WorkspaceEventEnvelope {
		return this.publish(input);
	}

	publish(input: WorkspaceEventPublishInput): WorkspaceEventEnvelope {
		const event = this.repository.append(input);

		for (const listener of this.listeners) {
			try {
				listener(event);
			} catch {
				// Keep listeners isolated and resilient
			}
		}

		return event;
	}

	subscribe(listener: (event: WorkspaceEventEnvelope) => void): () => void {
		this.listeners.add(listener);

		return () => {
			this.listeners.delete(listener);
		};
	}
}

export const createWorkspaceEventsService = (repository: WorkspaceEventRepositoryContract) =>
	new WorkspaceEventsService(repository);
