import { useEffect, useRef } from "react";
import { ActivityIndicator, Animated, Pressable, StyleSheet, Text, View } from "react-native";

const palette = {
	accent: "#63C8FF",
	background: "#0D0F14",
	text: "#F1F4FA",
};
const footerCtaHeight = 58;
const FADE_DURATION = 200;

interface ActiveThreadsFooterCtaProps {
	count: number;
	isLoading?: boolean;
	onPress: () => void;
	testID: string;
}

export const ActiveThreadsFooterCta = ({
	count,
	isLoading = false,
	onPress,
	testID,
}: ActiveThreadsFooterCtaProps) => {
	const fadeAnim = useRef(new Animated.Value(0)).current;
	const isVisible = count > 0 || isLoading;

	useEffect(() => {
		Animated.timing(fadeAnim, {
			toValue: isVisible ? 1 : 0,
			duration: FADE_DURATION,
			useNativeDriver: true,
		}).start();
	}, [isVisible, fadeAnim]);

	const label = isLoading ? "Loading active threads..." : `${String(count)} active threads`;

	return (
		<Animated.View
			pointerEvents={isVisible ? "auto" : "none"}
			style={[styles.container, { opacity: fadeAnim }]}
		>
			<Pressable
				accessibilityRole="button"
				onPress={onPress}
				style={({ pressed }) => [styles.button, pressed ? styles.buttonPressed : null]}
				testID={testID}
			>
				{isLoading ? (
					<ActivityIndicator color={palette.background} size="small" />
				) : (
					<>
						<View style={styles.badge}>
							<ActivityIndicator color={palette.accent} size={10} />
						</View>
						<Text style={styles.label}>{label}</Text>
					</>
				)}
			</Pressable>
		</Animated.View>
	);
};

const styles = StyleSheet.create({
	container: {
		bottom: 22,
		left: 16,
		position: "absolute",
		right: 92,
		zIndex: 20,
	},
	button: {
		alignItems: "center",
		backgroundColor: "rgba(99,200,255,0.18)",
		borderColor: "rgba(99,200,255,0.74)",
		borderRadius: footerCtaHeight / 2,
		borderWidth: 1,
		flexDirection: "row",
		gap: 10,
		height: footerCtaHeight,
		justifyContent: "center",
		paddingHorizontal: 16,
	},
	buttonPressed: {
		opacity: 0.88,
	},
	badge: {
		alignItems: "center",
		backgroundColor: "rgba(13,15,20,0.75)",
		borderRadius: 999,
		height: 18,
		justifyContent: "center",
		width: 18,
	},
	label: {
		color: palette.text,
		fontSize: 13,
		fontWeight: "700",
	},
});
