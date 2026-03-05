import { useRef } from "react";
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from "react-native";
import { MaterialIcons } from "@expo/vector-icons";

import type { ProjectDTO } from "../../../shared/api/types";

const palette = {
	text: "#F1F4FA",
};

const defaultRowBackgroundColor = "#12161E";
const defaultRowBorderColor = "rgba(255,255,255,0.11)";
const defaultSelectedRowBackgroundColor = defaultRowBackgroundColor;
const defaultSelectedRowBorderColor = "rgba(99,200,255,0.45)";

interface SwipeableWorkspaceItemProps {
	index: number;
	isSelected: boolean;
	isLoading?: boolean;
	onLongPress: () => void;
	onOpenWorkspace: () => void;
	project: ProjectDTO;
	rowTestID: string;
	rowBackgroundColor?: string;
	rowBorderColor?: string;
	selectedRowBackgroundColor?: string;
	selectedRowBorderColor?: string;
}

export const SwipeableWorkspaceItem = ({
	index,
	isSelected,
	onLongPress,
	onOpenWorkspace,
	project,
	rowTestID,
	rowBackgroundColor = defaultRowBackgroundColor,
	rowBorderColor = defaultRowBorderColor,
	selectedRowBackgroundColor = defaultSelectedRowBackgroundColor,
	selectedRowBorderColor = defaultSelectedRowBorderColor,
	isLoading = false,
}: SwipeableWorkspaceItemProps) => {
	const shouldIgnorePressRef = useRef(false);

	return (
		<Pressable
			accessibilityLabel={`workspace-item-${String(index)}`}
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

				onOpenWorkspace();
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
				isSelected ? styles.listRowActive : null,
				{
					backgroundColor: isSelected
						? selectedRowBackgroundColor
						: rowBackgroundColor,
					borderColor: isSelected
						? selectedRowBorderColor
						: rowBorderColor,
				},
				pressed ? styles.listRowPressed : null,
			]}
			testID={rowTestID}
		>
			<View style={styles.rowContent}>
				<View style={styles.rowText}>
					<Text numberOfLines={1} style={styles.rowTitle}>
						{project.name}
					</Text>
					<Text numberOfLines={1} style={styles.rowMeta}>
						{project.path}
					</Text>
				</View>
				{isLoading ? (
					<ActivityIndicator color={palette.text} size="small" />
				) : (
					<MaterialIcons color="#F1F4FA" name="chevron-right" size={20} />
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
		width: "100%",
	},
	listRowActive: {
		borderColor: "rgba(99,200,255,0.45)",
	},
	listRowPressed: {
		opacity: 0.8,
	},
	rowContent: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
		justifyContent: "space-between",
	},
	rowMeta: {
		color: "#98A0AF",
		fontSize: 12,
	},
	rowText: {
		flex: 1,
	},
	rowTitle: {
		color: "#F1F4FA",
		fontSize: 15,
		fontWeight: "600",
	},
});
