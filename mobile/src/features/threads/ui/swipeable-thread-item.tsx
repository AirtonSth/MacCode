import { useRef } from "react";
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from "react-native";
import { MaterialIcons } from "@expo/vector-icons";

import { formatRelativeTime } from "../../../shared/lib/time";
import type { ChatDTO } from "../../../shared/api/types";

const palette = {
	accent: "#9FDBFF",
	text: "#F1F4FA",
};

interface SwipeableThreadItemProps {
	chat: ChatDTO;
	index: number;
	isWorking?: boolean;
	isSelected: boolean;
	isLoading?: boolean;
	onLongPress: () => void;
	onOpenChat: () => void;
	rowTestID: string;
}

export const SwipeableThreadItem = ({
	chat,
	index,
	isWorking = false,
	isSelected,
	isLoading = false,
	onLongPress,
	onOpenChat,
	rowTestID,
}: SwipeableThreadItemProps) => {
	const shouldIgnorePressRef = useRef(false);

	return (
		<Pressable
			accessibilityLabel={`thread-item-${String(index)}`}
			accessibilityRole="button"
			accessibilityState={{ disabled: isLoading }}
			delayLongPress={280}
			disabled={isLoading}
			onLongPress={() => {
				if (isLoading) {
					return;
				}

				shouldIgnorePressRef.current = true;
				onLongPress();
			}}
			onPress={() => {
				if (isLoading) {
					return;
				}

				if (shouldIgnorePressRef.current) {
					shouldIgnorePressRef.current = false;
					return;
				}

				onOpenChat();
			}}
			onPressOut={() => {
				if (!shouldIgnorePressRef.current) {
					return;
				}

				setTimeout(() => {
					shouldIgnorePressRef.current = false;
				}, 0);
			}}
			style={({ pressed }) => [
				styles.listRow,
				isSelected ? styles.listRowSelected : null,
				isWorking ? styles.listRowWorking : null,
				pressed ? styles.listRowPressed : null,
			]}
			testID={rowTestID}
		>
			<View style={styles.rowContent}>
				<View style={styles.rowMain}>
					{isWorking ? (
						<View style={styles.rowLeading} testID={`thread-item-status-${String(index)}`}>
							<ActivityIndicator color={palette.accent} size={11} />
						</View>
					) : null}
					<View style={styles.rowText}>
						<Text
							numberOfLines={1}
							style={styles.rowTitle}
							testID={`thread-item-title-${String(index)}`}
						>
							{chat.title}
						</Text>
						<View style={styles.metaRow}>
							<Text style={styles.rowMeta}>Updated {formatRelativeTime(chat.updatedAt)}</Text>
						</View>
					</View>
				</View>
				{isLoading ? (
					<ActivityIndicator color={palette.text} size="small" />
				) : (
					<MaterialIcons color={palette.text} name="chevron-right" size={20} />
				)}
			</View>
		</Pressable>
	);
};

const styles = StyleSheet.create({
	listRow: {
		backgroundColor: "#12161E",
		borderColor: "rgba(255,255,255,0.11)",
		borderRadius: 11,
		borderWidth: 1,
		gap: 4,
		padding: 12,
	},
	listRowPressed: {
		opacity: 0.8,
	},
	listRowSelected: {
		borderColor: "rgba(99,200,255,0.45)",
	},
	listRowWorking: {
		backgroundColor: "rgba(99,200,255,0.18)",
		borderColor: "rgba(99,200,255,0.74)",
	},
	metaRow: {
		alignItems: "center",
		flexDirection: "row",
		paddingTop: 3,
	},
	rowContent: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
		justifyContent: "space-between",
	},
	rowLeading: {
		alignItems: "center",
		justifyContent: "center",
		width: 12,
	},
	rowMain: {
		alignItems: "center",
		flex: 1,
		flexDirection: "row",
		gap: 8,
		minWidth: 0,
	},
	rowMeta: {
		color: "#98A0AF",
		fontSize: 12,
	},
	rowText: {
		flex: 1,
		minWidth: 0,
	},
	rowTitle: {
		color: "#F1F4FA",
		fontSize: 15,
		fontWeight: "600",
	},
});
