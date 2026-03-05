import { ActivityIndicator, Modal, Pressable, StyleSheet, Text, TextInput, View } from "react-native";

const palette = {
	accent: "#63C8FF",
	background: "#0D0F14",
	border: "rgba(255,255,255,0.12)",
	overlay: "rgba(0,0,0,0.5)",
	text: "#F1F4FA",
	textSecondary: "#98A0AF",
};

interface WorkspaceRenameModalProps {
	isSubmitting: boolean;
	isVisible: boolean;
	name: string;
	onCancel: () => void;
	onChangeName: (value: string) => void;
	onSubmit: () => void;
}

export const WorkspaceRenameModal = ({
	isSubmitting,
	isVisible,
	name,
	onCancel,
	onChangeName,
	onSubmit,
}: WorkspaceRenameModalProps) => {
	const isSaveDisabled = isSubmitting || name.trim().length === 0;

	return (
		<Modal
			animationType="fade"
			onRequestClose={onCancel}
			presentationStyle="overFullScreen"
			transparent
			visible={isVisible}
		>
			<View style={styles.root}>
				<Pressable onPress={onCancel} style={StyleSheet.absoluteFill} />
				<View style={styles.panel}>
					<Text style={styles.title}>Rename workspace</Text>
					<Text style={styles.subtitle}>Choose a new workspace name.</Text>
					<TextInput
						autoCapitalize="words"
						autoCorrect={false}
						autoFocus
						onChangeText={onChangeName}
						onSubmitEditing={() => {
							if (isSaveDisabled) {
								return;
							}

							onSubmit();
						}}
						placeholder="Workspace name"
						placeholderTextColor={palette.textSecondary}
						returnKeyType="done"
						style={styles.input}
						testID="workspace-rename-input"
						value={name}
					/>
					<View style={styles.actions}>
						<Pressable
							accessibilityRole="button"
							disabled={isSubmitting}
							onPress={onCancel}
							style={({ pressed }) => [
								styles.cancelButton,
								pressed ? styles.buttonPressed : null,
								isSubmitting ? styles.buttonDisabled : null,
							]}
							testID="workspace-rename-cancel"
						>
							<Text style={styles.cancelButtonText}>Cancel</Text>
						</Pressable>
						<Pressable
							accessibilityRole="button"
							disabled={isSaveDisabled}
							onPress={onSubmit}
							style={({ pressed }) => [
								styles.saveButton,
								pressed ? styles.buttonPressed : null,
								isSaveDisabled ? styles.buttonDisabled : null,
							]}
							testID="workspace-rename-submit"
						>
							{isSubmitting ? (
								<ActivityIndicator color="#0A1D2B" size="small" />
							) : (
								<Text style={styles.saveButtonText}>Save</Text>
							)}
						</Pressable>
					</View>
				</View>
			</View>
		</Modal>
	);
};

const styles = StyleSheet.create({
	actions: {
		flexDirection: "row",
		gap: 10,
		justifyContent: "flex-end",
		marginTop: 14,
	},
	buttonDisabled: {
		opacity: 0.45,
	},
	buttonPressed: {
		opacity: 0.86,
	},
	cancelButton: {
		alignItems: "center",
		backgroundColor: "rgba(255,255,255,0.08)",
		borderColor: palette.border,
		borderRadius: 10,
		borderWidth: 1,
		height: 40,
		justifyContent: "center",
		minWidth: 90,
		paddingHorizontal: 14,
	},
	cancelButtonText: {
		color: palette.text,
		fontSize: 13,
		fontWeight: "600",
	},
	input: {
		backgroundColor: "rgba(255,255,255,0.05)",
		borderColor: palette.border,
		borderRadius: 10,
		borderWidth: 1,
		color: palette.text,
		fontSize: 15,
		marginTop: 12,
		minHeight: 44,
		paddingHorizontal: 12,
		paddingVertical: 8,
	},
	panel: {
		backgroundColor: palette.background,
		borderColor: palette.border,
		borderRadius: 14,
		borderWidth: 1,
		padding: 14,
		width: "100%",
	},
	root: {
		alignItems: "center",
		backgroundColor: palette.overlay,
		flex: 1,
		justifyContent: "center",
		paddingHorizontal: 18,
	},
	saveButton: {
		alignItems: "center",
		backgroundColor: palette.accent,
		borderRadius: 10,
		height: 40,
		justifyContent: "center",
		minWidth: 90,
		paddingHorizontal: 14,
	},
	saveButtonText: {
		color: "#0A1D2B",
		fontSize: 13,
		fontWeight: "700",
	},
	subtitle: {
		color: palette.textSecondary,
		fontSize: 12,
	},
	title: {
		color: palette.text,
		fontSize: 16,
		fontWeight: "700",
	},
});
