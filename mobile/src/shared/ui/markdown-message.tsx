import { memo } from "react";
import { Linking, Platform, StyleSheet } from "react-native";
import MarkdownDisplay from "react-native-markdown-display";

interface MessageMarkdownProps {
	content: string;
	textColor: string;
	linkColor: string;
}

const markdownFontFamily = Platform.select({ android: "monospace", ios: "Menlo", default: "monospace" });

const buildStyles = (textColor: string, linkColor: string) => {
	return StyleSheet.create({
		body: {
			color: textColor,
		},
		"code_block": {
			backgroundColor: "rgba(0,0,0,0.35)",
			borderColor: "rgba(255,255,255,0.18)",
			borderRadius: 10,
			borderWidth: 1,
			color: "#F8FAFF",
			fontFamily: markdownFontFamily,
			fontSize: 13,
			lineHeight: 19,
			padding: 10,
		},
		"code_inline": {
			backgroundColor: "rgba(255,255,255,0.12)",
			borderRadius: 6,
			color: "#F8FAFF",
			fontFamily: markdownFontFamily,
			fontSize: 13,
			paddingHorizontal: 6,
			paddingVertical: 2,
		},
		fence: {
			backgroundColor: "rgba(0,0,0,0.35)",
			borderColor: "rgba(255,255,255,0.18)",
			borderRadius: 10,
			borderWidth: 1,
			color: "#F8FAFF",
			fontFamily: markdownFontFamily,
			fontSize: 13,
			lineHeight: 19,
			padding: 10,
		},
		h1: {
			fontSize: 24,
			fontWeight: "700",
			marginTop: 10,
		},
		h2: {
			fontSize: 20,
			fontWeight: "700",
			marginTop: 8,
		},
		h3: {
			fontSize: 18,
			fontWeight: "700",
			marginTop: 8,
		},
		h4: {
			color: textColor,
			fontSize: 16,
			fontWeight: "700",
			marginTop: 8,
		},
		h5: {
			color: textColor,
			fontSize: 15,
			fontWeight: "700",
			marginTop: 8,
		},
		h6: {
			color: textColor,
			fontSize: 15,
			fontWeight: "600",
			marginTop: 8,
		},
		link: {
			color: linkColor,
			textDecorationLine: "underline",
		},
		li: {
			color: textColor,
		},
		paragraph: {
			color: textColor,
			lineHeight: 21,
			marginBottom: 8,
		},
		strong: {
			fontWeight: "700",
		},
		text: {
			color: textColor,
			fontSize: 14,
		},
	});
};

export const MessageMarkdown = memo(({ content, linkColor, textColor }: MessageMarkdownProps): JSX.Element => {
	const styles = buildStyles(textColor, linkColor);

	return (
		<MarkdownDisplay
			onLinkPress={(url: string) => {
				void Linking.openURL(url);
				return false;
			}}
			style={styles}
		>
			{content}
		</MarkdownDisplay>
	);
});
