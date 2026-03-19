import type { AppFlowTarget } from "../../../shared/navigation/use-flow-navigator";

interface ActiveThread {
	id: string;
	projectId: string;
}

export interface ActiveThreadPressAction {
	type: "selectChatById" | "push";
	payload: unknown;
}

/**
 * Builds the sequence of actions that should execute when the user
 * presses an active thread item to open it.
 *
 * selectChatById already sets both projectId and chatId atomically,
 * so calling selectProjectById first would cause a race condition:
 * it persists selectedChatId=null via an async mutation that can
 * complete after selectChatById's mutation, reverting the selection.
 */
export const buildActiveThreadPressActions = (
	thread: ActiveThread,
): ActiveThreadPressAction[] => {
	return [
		{
			type: "selectChatById",
			payload: { chatId: thread.id, projectId: thread.projectId },
		},
		{
			type: "push",
			payload: {
				pathname: "/chat",
				params: { source: "thread-list" },
			} satisfies AppFlowTarget,
		},
	];
};
