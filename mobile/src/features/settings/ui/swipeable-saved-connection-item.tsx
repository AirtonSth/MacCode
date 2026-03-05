import type { ReactNode } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { MaterialIcons } from "@expo/vector-icons";

interface SwipeableSavedConnectionItemProps {
	children: ReactNode;
	deleteTestID: string;
	index: number;
	isActive: boolean;
	onClose: () => void;
	onDelete: () => void;
}

export const SwipeableSavedConnectionItem = ({
	children,
	deleteTestID,
	index,
	isActive,
	onClose,
	onDelete,
}: SwipeableSavedConnectionItemProps) => {
	return (
		<View style={styles.rowRoot}>
			{children}

			{isActive ? (
				<View style={styles.optionsTooltip} testID={`saved-connection-options-${String(index)}`}>
					<View style={styles.optionsCaret} />
					<Pressable
						accessibilityLabel={`saved-connection-delete-${String(index)}`}
						accessibilityRole="button"
						onPress={() => {
							onClose();
							onDelete();
						}}
						style={({ pressed }) => [styles.optionButton, pressed ? styles.optionButtonPressed : null]}
						testID={deleteTestID}
					>
						<MaterialIcons color="#FF9BA2" name="delete-outline" size={16} />
						<Text style={styles.optionDeleteLabel}>Delete</Text>
					</Pressable>
				</View>
			) : null}
		</View>
	);
};

const styles = StyleSheet.create({
	optionButton: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
		paddingHorizontal: 11,
		paddingVertical: 9,
	},
	optionButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.06)",
	},
	optionDeleteLabel: {
		color: "#FF9BA2",
		fontSize: 13,
		fontWeight: "600",
	},
	optionsCaret: {
		backgroundColor: "#101521",
		borderColor: "rgba(255,255,255,0.16)",
		borderLeftWidth: 1,
		borderTopWidth: 1,
		height: 10,
		position: "absolute",
		right: 16,
		top: -5,
		transform: [{ rotate: "45deg" }],
		width: 10,
	},
	optionsTooltip: {
		backgroundColor: "#101521",
		borderColor: "rgba(255,255,255,0.16)",
		borderRadius: 10,
		borderWidth: 1,
		minWidth: 122,
		overflow: "hidden",
		position: "absolute",
		right: 10,
		shadowColor: "#000",
		shadowOffset: { height: 8, width: 0 },
		shadowOpacity: 0.34,
		shadowRadius: 12,
		top: 12,
		zIndex: 40,
		elevation: 9,
	},
	rowRoot: {
		position: "relative",
	},
});
