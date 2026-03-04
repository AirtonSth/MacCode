import { HStack, Text, VStack } from "@expo/ui/swift-ui";
import { createLiveActivity, type LiveActivityLayout } from "expo-widgets";

export type ThreadLiveActivityPhase =
	| "running"
	| "finalizing"
	| "background"
	| "completed"
	| "failed"
	| "error";

export interface ThreadLiveActivityProps {
	chatId: string;
	chatTitle: string;
	elapsedSeconds: number;
	phase: ThreadLiveActivityPhase;
	preview: string;
	statusLine: string;
}

const MAX_PREVIEW_LENGTH = 84;

const toTrimmedPreview = (value: string): string => {
	const trimmed = value.trim();
	if (trimmed.length === 0) {
		return "Waiting for updates...";
	}

	return trimmed.length > MAX_PREVIEW_LENGTH ? `${trimmed.slice(0, MAX_PREVIEW_LENGTH)}...` : trimmed;
};

const toPhaseLabel = (phase: ThreadLiveActivityPhase): string => {
	switch (phase) {
		case "background": {
			return "Running in background";
		}
		case "completed": {
			return "Completed";
		}
		case "error": {
			return "Error";
		}
		case "failed": {
			return "Failed";
		}
		case "finalizing": {
			return "Finalizing";
		}
		case "running": {
			return "Running";
		}
		default: {
			return "Running";
		}
	}
};

const toElapsed = (elapsedSeconds: number): string => {
	const bounded = Number.isFinite(elapsedSeconds) && elapsedSeconds > 0 ? Math.floor(elapsedSeconds) : 0;
	const minutes = Math.floor(bounded / 60);
	const seconds = bounded % 60;
	return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
};

const toLayout = (props?: ThreadLiveActivityProps): LiveActivityLayout => {
	"widget";

	const resolvedProps = props ?? {
		chatId: "unknown",
		chatTitle: "Thread",
		elapsedSeconds: 0,
		phase: "running",
		preview: "Waiting for updates...",
		statusLine: "Running",
	};
	const title = resolvedProps.chatTitle.trim().length > 0 ? resolvedProps.chatTitle.trim() : "Thread";
	const phaseLabel = toPhaseLabel(resolvedProps.phase);
	const preview = toTrimmedPreview(resolvedProps.preview);
	const elapsed = toElapsed(resolvedProps.elapsedSeconds);
	const statusLine = resolvedProps.statusLine.trim().length > 0 ? resolvedProps.statusLine.trim() : phaseLabel;

	return {
		banner: (
			<VStack spacing={6}>
				<HStack spacing={8}>
					<Text>{title}</Text>
					<Text>{phaseLabel}</Text>
				</HStack>
				<HStack spacing={8}>
					<Text>{statusLine}</Text>
					<Text>{elapsed}</Text>
				</HStack>
				<Text>{preview}</Text>
			</VStack>
		),
		compactLeading: <Text>RC</Text>,
		compactTrailing: <Text>{elapsed}</Text>,
		minimal: <Text>{elapsed}</Text>,
		expandedCenter: (
			<VStack spacing={6}>
				<Text>{title}</Text>
				<Text>{statusLine}</Text>
				<Text>{preview}</Text>
			</VStack>
		),
		expandedLeading: <Text>{phaseLabel}</Text>,
		expandedTrailing: <Text>{elapsed}</Text>,
		expandedBottom: <Text>{preview}</Text>,
	};
};

export const threadLiveActivityFactory = createLiveActivity<ThreadLiveActivityProps>(
	"ThreadLiveActivity",
	toLayout,
);
