import { Link, Stack } from "expo-router";
import { StyleSheet, Text, View } from "react-native";

import { theme } from "@/shared/theme/tokens";

export default function NotFoundScreen() {
	return (
		<>
			<Stack.Screen options={{ title: "Not Found" }} />
			<View style={styles.container}>
				<Text style={styles.title}>This screen does not exist.</Text>
				<Link href="/" style={styles.link}>
					<Text style={styles.linkText}>Return to workspace</Text>
				</Link>
			</View>
		</>
	);
}

const styles = StyleSheet.create({
	container: {
		backgroundColor: theme.colors.background,
		flex: 1,
		padding: 24,
	},
	title: {
		color: theme.colors.textPrimary,
		fontSize: 20,
		fontWeight: "700",
		marginTop: 20,
	},
	link: {
		marginTop: 16,
		paddingVertical: 8,
	},
	linkText: {
		color: theme.colors.accent,
		fontSize: 14,
		fontWeight: "600",
	},
});
