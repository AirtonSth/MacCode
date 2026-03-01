import { useRouter } from "expo-router";
import { useState } from "react";
import { Pressable, ScrollView, Text, TextInput, View } from "react-native";

import { useApiConfig } from "@/shared/api/api-config-provider";
import { theme } from "@/shared/theme/tokens";
import { GlassPanel } from "@/shared/ui/glass-panel";

export const SettingsScreen = () => {
	const { config, update } = useApiConfig();
	const router = useRouter();
	const [baseUrl, setBaseUrl] = useState<string>(config.baseUrl);
	const [token, setToken] = useState<string>(config.token);
	const [isSaving, setIsSaving] = useState<boolean>(false);
	const [saved, setSaved] = useState<boolean>(false);

	const save = async () => {
		setIsSaving(true);
		setSaved(false);
		await update({
			baseUrl,
			token,
		});
		setSaved(true);
		setIsSaving(false);
	};

	return (
		<ScrollView
			contentContainerStyle={{
				flexGrow: 1,
				gap: 14,
				padding: 16,
			}}
			contentInsetAdjustmentBehavior="automatic"
			style={{
				backgroundColor: theme.colors.background,
				flex: 1,
			}}
		>
			<GlassPanel>
				<Text
					style={{
						color: theme.colors.textPrimary,
						fontSize: 22,
						fontWeight: "700",
					}}
				>
					Connection
				</Text>
				<Text
					style={{
						color: theme.colors.textSecondary,
						fontSize: 13,
						marginTop: 6,
					}}
				>
					Configure the local server URL and auth token used by the mobile app.
				</Text>

				<View style={{ marginTop: 16 }}>
					<Text
						style={{
							color: theme.colors.textSecondary,
							fontSize: 12,
							marginBottom: 6,
							textTransform: "uppercase",
						}}
					>
						Server URL
					</Text>
					<TextInput
						autoCapitalize="none"
						onChangeText={setBaseUrl}
						placeholder="http://127.0.0.1:3001"
						placeholderTextColor={theme.colors.muted}
						style={{
							backgroundColor: "rgba(255,255,255,0.04)",
							borderColor: theme.colors.borderSoft,
							borderRadius: theme.borderRadius.chip,
							borderWidth: 1,
							color: theme.colors.textPrimary,
							fontSize: 14,
							paddingHorizontal: 12,
							paddingVertical: 10,
						}}
						value={baseUrl}
					/>
				</View>

				<View style={{ marginTop: 14 }}>
					<Text
						style={{
							color: theme.colors.textSecondary,
							fontSize: 12,
							marginBottom: 6,
							textTransform: "uppercase",
						}}
					>
						Token
					</Text>
					<TextInput
						autoCapitalize="none"
						onChangeText={setToken}
						placeholder="local-dev-token"
						placeholderTextColor={theme.colors.muted}
						style={{
							backgroundColor: "rgba(255,255,255,0.04)",
							borderColor: theme.colors.borderSoft,
							borderRadius: theme.borderRadius.chip,
							borderWidth: 1,
							color: theme.colors.textPrimary,
							fontSize: 14,
							paddingHorizontal: 12,
							paddingVertical: 10,
						}}
						value={token}
					/>
				</View>

				<View
					style={{
						flexDirection: "row",
						gap: 10,
						marginTop: 18,
					}}
				>
					<Pressable
						onPress={() => {
							void save();
						}}
						style={({ pressed }) => ({
							backgroundColor: pressed ? "rgba(99,200,255,0.3)" : "rgba(99,200,255,0.18)",
							borderColor: "rgba(99,200,255,0.35)",
							borderRadius: theme.borderRadius.chip,
							borderWidth: 1,
							paddingHorizontal: 16,
							paddingVertical: 10,
						})}
					>
						<Text
							style={{
								color: theme.colors.textPrimary,
								fontSize: 14,
								fontWeight: "700",
							}}
						>
							{isSaving ? "Saving..." : "Save"}
						</Text>
					</Pressable>

					<Pressable
						onPress={() => {
							router.back();
						}}
						style={({ pressed }) => ({
							backgroundColor: pressed ? "rgba(255,255,255,0.13)" : "rgba(255,255,255,0.06)",
							borderColor: theme.colors.borderSoft,
							borderRadius: theme.borderRadius.chip,
							borderWidth: 1,
							paddingHorizontal: 16,
							paddingVertical: 10,
						})}
					>
						<Text
							style={{
								color: theme.colors.textPrimary,
								fontSize: 14,
								fontWeight: "600",
							}}
						>
							Close
						</Text>
					</Pressable>
				</View>

				{saved ? (
					<Text
						style={{
							color: theme.colors.accent,
							fontSize: 12,
							marginTop: 10,
						}}
					>
						Saved. The app now reconnects using the new settings.
					</Text>
				) : null}
			</GlassPanel>
		</ScrollView>
	);
};
