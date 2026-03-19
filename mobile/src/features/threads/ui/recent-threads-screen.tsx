import { useMemo, useState } from "react";
import { useIsFocused } from "@react-navigation/native";
import {
	ActivityIndicator,
	KeyboardAvoidingView,
	Platform,
	Pressable,
	ScrollView,
	StyleSheet,
	Text,
	TextInput,
	View,
} from "react-native";
import { MaterialIcons } from "@expo/vector-icons";

import { useWorkspaceShell } from "../../chat/model/use-workspace-shell";
import { useRecentThreadsQuery } from "../api/use-recent-threads-query";
import { useFlowNavigator } from "../../../shared/navigation/use-flow-navigator";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";
import { formatRelativeTime } from "../../../shared/lib/time";

const palette = {
	accent: "#63C8FF",
	background: "#0D0F14",
	border: "rgba(255,255,255,0.11)",
	muted: "#98A0AF",
	soft: "rgba(255,255,255,0.05)",
	text: "#F1F4FA",
};

export const RecentThreadsScreen = () => {
	const { push, goBackOr } = useFlowNavigator();
	const isFocused = useIsFocused();
	const { selectChatById } = useWorkspaceShell({
		isActive: isFocused,
		scope: "threads",
	});
	const recentThreadsQuery = useRecentThreadsQuery(isFocused);
	const [searchValue, setSearchValue] = useState("");

	const isLoading = recentThreadsQuery.isPending;

	const visibleThreads = useMemo(() => {
		const threads = recentThreadsQuery.data ?? [];
		const query = searchValue.trim().toLowerCase();
		if (!query) {
			return threads;
		}

		return threads.filter(
			(thread) =>
				thread.title.toLowerCase().includes(query) ||
				thread.projectName.toLowerCase().includes(query),
		);
	}, [recentThreadsQuery.data, searchValue]);

	const renderThreadStatusBadge = (thread: {
		hasUnreadFinished: boolean;
		isActive: boolean;
	}) => {
		if (thread.isActive) {
			return (
				<View style={styles.activeBadge}>
					<ActivityIndicator color="#9FDBFF" size={10} />
					<Text style={styles.activeBadgeLabel}>Active</Text>
				</View>
			);
		}

		if (thread.hasUnreadFinished) {
			return (
				<View style={styles.finishedBadge}>
					<View style={styles.finishedDot} />
					<Text style={styles.finishedBadgeLabel}>Finished</Text>
				</View>
			);
		}

		return null;
	};

	return (
		<KeyboardAvoidingView
			behavior={Platform.OS === "ios" ? "padding" : undefined}
			style={styles.root}
			testID="screen-recent-threads"
		>
			<IosStackHeader
				left={<MaterialIcons color={palette.text} name="arrow-back-ios-new" size={18} />}
				onBack={() => {
					goBackOr("/workspaces");
				}}
				subtitle="All threads by last update"
				title="Recent"
			/>

			<ScrollView
				contentContainerStyle={styles.content}
				contentInsetAdjustmentBehavior="automatic"
				keyboardShouldPersistTaps="handled"
				showsVerticalScrollIndicator={false}
			>
				<TextInput
					autoCapitalize="none"
					onChangeText={setSearchValue}
					placeholder="Search threads"
					placeholderTextColor={palette.muted}
					style={styles.input}
					testID="recent-threads-search-input"
					value={searchValue}
				/>

				{isLoading ? (
					<View style={styles.loading}>
						<ActivityIndicator color={palette.accent} />
					</View>
				) : null}

				{!isLoading && visibleThreads.length === 0 ? (
					<Text style={styles.emptyState} testID="recent-threads-empty-state">
						No threads found.
					</Text>
				) : null}

				{visibleThreads.map((thread, index) => (
					<Pressable
						key={thread.id}
						onPress={() => {
							selectChatById({
								chatId: thread.id,
								projectId: thread.projectId,
							});
							push({
								pathname: "/chat",
								params: { source: "thread-list" },
							});
						}}
						style={({ pressed }) => [styles.item, pressed ? styles.itemPressed : null]}
						testID={`recent-thread-item-${String(index)}`}
					>
						<View style={styles.itemHeader}>
							<Text numberOfLines={1} style={styles.itemTitle}>
								{thread.title}
							</Text>
							<View style={styles.itemRight}>
								{renderThreadStatusBadge(thread)}
								<Text style={styles.itemTime}>
									{formatRelativeTime(thread.updatedAt)}
								</Text>
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
	content: {
		gap: 10,
		paddingBottom: 28,
		paddingHorizontal: 16,
		paddingTop: 14,
	},
	emptyState: {
		color: palette.muted,
		fontSize: 13,
		paddingTop: 12,
		textAlign: "center",
	},
	finishedBadge: {
		alignItems: "center",
		backgroundColor: "rgba(52,211,153,0.12)",
		borderColor: "rgba(52,211,153,0.35)",
		borderRadius: 999,
		borderWidth: 1,
		flexDirection: "row",
		gap: 4,
		paddingHorizontal: 6,
		paddingVertical: 2,
	},
	finishedBadgeLabel: {
		color: "#A7F3D0",
		fontSize: 10,
		fontWeight: "700",
		textTransform: "uppercase",
	},
	finishedDot: {
		backgroundColor: "#A7F3D0",
		borderRadius: 999,
		height: 6,
		width: 6,
	},
	input: {
		backgroundColor: palette.soft,
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		color: palette.text,
		fontSize: 15,
		minHeight: 42,
		paddingHorizontal: 12,
		paddingVertical: 8,
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
	itemHeader: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
		justifyContent: "space-between",
	},
	itemMeta: {
		color: palette.muted,
		fontSize: 12,
	},
	itemPressed: {
		opacity: 0.84,
	},
	itemRight: {
		alignItems: "center",
		flexDirection: "row",
		gap: 6,
	},
	itemTime: {
		color: palette.muted,
		fontSize: 12,
	},
	itemTitle: {
		color: palette.text,
		flex: 1,
		fontSize: 15,
		fontWeight: "700",
	},
	loading: {
		alignItems: "center",
		paddingVertical: 24,
	},
	root: {
		backgroundColor: palette.background,
		flex: 1,
	},
});
