import { MaterialIcons } from "@expo/vector-icons";
import * as Haptics from "expo-haptics";
import { useEffect, useRef, type ComponentProps } from "react";
import { Modal, Platform, Pressable, StyleSheet, Text, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

type ActionTone = "default" | "destructive";

export interface IosActionSheetAction {
	disabled?: boolean;
	icon?: ComponentProps<typeof MaterialIcons>["name"];
	key: string;
	label: string;
	onPress: () => void;
	testID?: string;
	tone?: ActionTone;
}

interface IosActionSheetProps {
	actions: IosActionSheetAction[];
	cancelLabel?: string;
	message?: string;
	onClose: () => void;
	testID?: string;
	title?: string;
	isVisible: boolean;
}

const palette = {
	background: "#0D0F14",
	border: "rgba(255,255,255,0.11)",
	muted: "#98A0AF",
	text: "#F1F4FA",
};

export const IosActionSheet = ({
	actions,
	cancelLabel = "Cancel",
	message = undefined,
	onClose,
	testID = undefined,
	title = undefined,
	isVisible,
}: IosActionSheetProps) => {
	const insets = useSafeAreaInsets();
	const wasVisibleRef = useRef<boolean>(isVisible);

	useEffect(() => {
		if (isVisible && !wasVisibleRef.current && Platform.OS === "ios") {
			const triggerHaptic = async () => {
				try {
					await Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
				} catch {
					// no-op
				}
			};
			void triggerHaptic();
		}
		wasVisibleRef.current = isVisible;
	}, [isVisible]);

	return (
		<Modal animationType="fade" onRequestClose={onClose} transparent visible={isVisible}>
			<Pressable
				onPress={onClose}
				style={styles.backdrop}
				testID={testID ? `${testID}-backdrop` : undefined}
			>
				<Pressable
					onPress={() => {
						// no-op
					}}
					style={[styles.sheetRoot, { paddingBottom: Math.max(8, insets.bottom) }]}
					testID={testID}
				>
					<View style={styles.sheetPanel}>
						{title ? <Text style={styles.title}>{title}</Text> : null}
						{message ? <Text style={styles.message}>{message}</Text> : null}

						<View style={styles.actionGroup}>
							{actions.map((action, index) => {
								const tone = action.tone ?? "default";
								return (
									<Pressable
										disabled={action.disabled}
										key={action.key}
										onPress={() => {
											action.onPress();
											onClose();
										}}
										style={({ pressed }) => [
											styles.actionButton,
											index > 0 ? styles.actionButtonBorder : null,
											pressed ? styles.actionButtonPressed : null,
											action.disabled ? styles.actionButtonDisabled : null,
										]}
										testID={action.testID}
									>
										{action.icon ? (
											<MaterialIcons
												color={tone === "destructive" ? "#FF8F98" : palette.text}
												name={action.icon}
												size={20}
											/>
										) : null}
										<Text
											style={[
												styles.actionLabel,
												tone === "destructive" ? styles.actionLabelDestructive : null,
											]}
										>
											{action.label}
										</Text>
									</Pressable>
								);
							})}
						</View>
					</View>

					<Pressable
						onPress={onClose}
						style={({ pressed }) => [
							styles.cancelButton,
							pressed ? styles.actionButtonPressed : null,
						]}
						testID={testID ? `${testID}-cancel` : undefined}
					>
						<Text style={styles.cancelLabel}>{cancelLabel}</Text>
					</Pressable>
				</Pressable>
			</Pressable>
		</Modal>
	);
};

const styles = StyleSheet.create({
	actionButton: {
		alignItems: "center",
		flexDirection: "row",
		gap: 10,
		justifyContent: "center",
		minHeight: 54,
		paddingHorizontal: 14,
		paddingVertical: 12,
	},
	actionButtonBorder: {
		borderTopColor: "rgba(255,255,255,0.1)",
		borderTopWidth: 1,
	},
	actionButtonDisabled: {
		opacity: 0.45,
	},
	actionButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.06)",
	},
	actionGroup: {
		overflow: "hidden",
	},
	actionLabel: {
		color: palette.text,
		fontSize: 18,
		fontWeight: "500",
	},
	actionLabelDestructive: {
		color: "#FF8F98",
	},
	backdrop: {
		backgroundColor: "rgba(2,5,10,0.62)",
		flex: 1,
		justifyContent: "flex-end",
	},
	cancelButton: {
		alignItems: "center",
		backgroundColor: "#141B27",
		borderColor: palette.border,
		borderRadius: 14,
		borderWidth: 1,
		justifyContent: "center",
		minHeight: 54,
		paddingHorizontal: 14,
		paddingVertical: 12,
	},
	cancelLabel: {
		color: palette.text,
		fontSize: 18,
		fontWeight: "700",
	},
	message: {
		color: palette.muted,
		fontSize: 13,
		lineHeight: 18,
		paddingBottom: 10,
		paddingHorizontal: 16,
		textAlign: "center",
	},
	sheetPanel: {
		backgroundColor: palette.background,
		borderColor: palette.border,
		borderRadius: 14,
		borderWidth: 1,
		marginBottom: 8,
		overflow: "hidden",
	},
	sheetRoot: {
		paddingHorizontal: 8,
	},
	title: {
		color: palette.muted,
		fontSize: 13,
		fontWeight: "600",
		paddingBottom: 8,
		paddingHorizontal: 16,
		paddingTop: 12,
		textAlign: "center",
	},
});
