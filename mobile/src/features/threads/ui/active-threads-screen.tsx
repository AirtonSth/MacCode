import { useMemo } from "react";
import { useIsFocused } from "@react-navigation/native";
import {
	ActivityIndicator,
	KeyboardAvoidingView,
	Platform,
	Pressable,
	ScrollView,
	StyleSheet,
	Text,
	View,
} from "react-native";
import { MaterialIcons } from "@expo/vector-icons";

import { useWorkspaceShell } from "../../chat/model/use-workspace-shell";
import { useFlowNavigator } from "../../../shared/navigation/use-flow-navigator";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";

const palette = {
	accent: "#63C8FF",
	background: "#0D0F14",
	border: "rgba(255,255,255,0.11)",
	muted: "#98A0AF",
	soft: "rgba(255,255,255,0.05)",
	text: "#F1F4FA",
};

export const ActiveThreadsScreen = () => {
	const { push, goBackOr } = useFlowNavigator();
	const isFocused = useIsFocused();
	const {
		activeThreads,
		isActiveThreadsLoading,
		selectChatById,
		selectProjectById,
	} = useWorkspaceShell({
		isActive: isFocused,
		scope: "threads",
	});

	const visibleThreads = useMemo(
		() =>
			[...activeThreads].sort(
				(left, right) => new Date(right.updatedAt).getTime() - new Date(left.updatedAt).getTime(),
			),
		[activeThreads],
	);

	return (
		<KeyboardAvoidingView
			behavior={Platform.OS === "ios" ? "padding" : undefined}
			style={styles.root}
			testID="screen-active-threads"
		>
			<IosStackHeader
				left={<MaterialIcons color={palette.text} name="arrow-back-ios-new" size={18} />}
				onBack={() => {
					goBackOr("/threads");
				}}
				subtitle="Threads currently running"
				title="Active threads"
			/>

			<ScrollView
				contentContainerStyle={styles.content}
				contentInsetAdjustmentBehavior="automatic"
				showsVerticalScrollIndicator={false}
			>
				{isActiveThreadsLoading ? (
					<View style={styles.loading}>
						<ActivityIndicator color={palette.accent} />
					</View>
				) : null}

				{!isActiveThreadsLoading && visibleThreads.length === 0 ? (
					<Text style={styles.emptyState} testID="active-threads-empty-state">
						No active thread right now.
					</Text>
				) : null}

				{visibleThreads.map((thread, index) => (
					<Pressable
						key={thread.id}
						onPress={() => {
							selectProjectById(thread.projectId);
							selectChatById({
								chatId: thread.id,
								projectId: thread.projectId,
							});
							push("/chat");
						}}
						style={({ pressed }) => [styles.item, pressed ? styles.itemPressed : null]}
						testID={`active-thread-item-${String(index)}`}
					>
						<View style={styles.itemHeader}>
							<Text numberOfLines={1} style={styles.itemTitle}>
								{thread.title}
							</Text>
							<View style={styles.activeBadge} testID={`active-thread-item-status-${String(index)}`}>
								<ActivityIndicator color="#9FDBFF" size={10} />
								<Text style={styles.activeBadgeLabel}>Active</Text>
							</View>
						</View>
						<Text numberOfLines={1} style={styles.itemMeta}>
							{thread.projectName}
						</Text>
					</Pressable>
				))}
			</ScrollView>
		</KeyboardAvoidingView>
	);
};

const styles = StyleSheet.create({
	root: {
		backgroundColor: palette.background,
		flex: 1,
	},
	content: {
		gap: 10,
		paddingBottom: 28,
		paddingHorizontal: 16,
		paddingTop: 14,
	},
	loading: {
		alignItems: "center",
		paddingVertical: 24,
	},
	emptyState: {
		color: palette.muted,
		fontSize: 13,
		paddingTop: 12,
		textAlign: "center",
	},
	item: {
		backgroundColor: palette.soft,
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		gap: 6,
		paddingHorizontal: 12,
		paddingVertical: 12,
	},
	itemPressed: {
		opacity: 0.84,
	},
	itemHeader: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
		justifyContent: "space-between",
	},
	itemTitle: {
		color: palette.text,
		flex: 1,
		fontSize: 15,
		fontWeight: "700",
	},
	itemMeta: {
		color: palette.muted,
		fontSize: 12,
	},
	activeBadge: {
		alignItems: "center",
		backgroundColor: "rgba(99,200,255,0.12)",
		borderColor: "rgba(99,200,255,0.5)",
		borderRadius: 999,
		borderWidth: 1,
		flexDirection: "row",
		gap: 4,
		paddingHorizontal: 8,
		paddingVertical: 2,
	},
	activeBadgeLabel: {
		color: "#9FDBFF",
		fontSize: 10,
		fontWeight: "700",
		textTransform: "uppercase",
	},
});
