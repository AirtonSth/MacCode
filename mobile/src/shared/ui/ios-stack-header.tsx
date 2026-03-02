import { useRouter } from "expo-router";
import type { ReactNode } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

const palette = {
	border: "rgba(255,255,255,0.1)",
	muted: "#A7AFBC",
	surface: "#0D0F14",
	text: "#F1F4FA",
};

interface IosStackHeaderProps {
	onBack?: () => void;
	backLabel?: string;
	left?: ReactNode;
	right?: ReactNode;
	subtitle?: string | null;
	title: string;
}

export const IosStackHeader = ({
	onBack = undefined,
	backLabel = "Back",
	left = null,
	right = null,
	subtitle = null,
	title,
}: IosStackHeaderProps) => {
	const insets = useSafeAreaInsets();
	const router = useRouter();
	const canGoBack = router.canGoBack();
	const canGo = canGoBack || Boolean(onBack);

	const handleBack = () => {
		if (onBack) {
			onBack();
			return;
		}

		if (canGoBack) {
			router.back();
		}
	};

	return (
		<View style={[styles.container, { paddingTop: insets.top + 6 }]}>
			<View style={styles.row}>
				<Pressable
					disabled={!canGo}
					hitSlop={10}
					onPress={handleBack}
					style={({ pressed }) => [
						styles.backButton,
						pressed ? styles.backButtonPressed : null,
						!canGo ? styles.backButtonDisabled : null,
					]}
					testID="nav-back"
				>
					{left || <Text style={styles.backLabel}>{backLabel}</Text>}
				</Pressable>

				<View style={styles.center}>
					<Text numberOfLines={1} style={styles.title}>
						{title}
					</Text>
					{subtitle ? (
						<Text numberOfLines={1} style={styles.subtitle}>
							{subtitle}
						</Text>
					) : null}
				</View>

				<View style={styles.right}>{right}</View>
			</View>
		</View>
	);
};

const styles = StyleSheet.create({
	backButton: {
		alignItems: "center",
		borderRadius: 10,
		height: 32,
		justifyContent: "center",
		minWidth: 58,
		paddingHorizontal: 10,
	},
	backButtonDisabled: {
		opacity: 0.35,
	},
	backButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	backLabel: {
		color: palette.text,
		fontSize: 14,
		fontWeight: "600",
	},
	center: {
		alignItems: "center",
		flex: 1,
		gap: 2,
		justifyContent: "center",
	},
	container: {
		backgroundColor: palette.surface,
		borderBottomColor: palette.border,
		borderBottomWidth: StyleSheet.hairlineWidth,
		paddingBottom: 8,
		paddingHorizontal: 12,
	},
	right: {
		alignItems: "flex-end",
		justifyContent: "center",
		minWidth: 58,
	},
	row: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
	},
	subtitle: {
		color: palette.muted,
		fontSize: 11,
	},
	title: {
		color: palette.text,
		fontSize: 16,
		fontWeight: "700",
	},
});
