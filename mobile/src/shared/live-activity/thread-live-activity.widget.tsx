import { createLiveActivity, type LiveActivityLayout } from "expo-widgets";
import type { ReactNode } from "react";

export type ThreadLiveActivityPhase =
	| "running"
	| "finalizing"
	| "background"
	| "completed"
	| "failed"
	| "error";

export interface ThreadLiveActivityProps {
	chatId: string;
	chatTitle: string;
	elapsedSeconds: number;
	phase: ThreadLiveActivityPhase;
	preview: string;
	statusLine: string;
}

interface PhaseVisualState {
	icon: string;
	label: string;
	badgeBackground: string;
	badgeForeground: string;
	timerBackground: string;
	timerForeground: string;
	titleForeground: string;
	statusForeground: string;
	previewForeground: string;
	cardBackground: string;
	containerBackground: string;
	brandBackground: string;
	brandForeground: string;
	defaultStatus: string;
	defaultPreview: string;
}

const FALLBACK_LAYOUT: LiveActivityLayout = {
	banner: null,
	compactLeading: null,
	compactTrailing: null,
	minimal: null,
	expandedCenter: null,
	expandedLeading: null,
	expandedTrailing: null,
	expandedBottom: null,
};

const toLayout = (props?: ThreadLiveActivityProps): LiveActivityLayout => {
	"widget";

	// eslint-disable-next-line unicorn/consistent-function-scoping -- Widget helpers must stay inside this function for runtime serialization.
	const toTrimmed = (value: string | undefined, fallback: string): string => {
		const trimmed = value?.trim();
		return trimmed && trimmed.length > 0 ? trimmed : fallback;
	};

	// eslint-disable-next-line unicorn/consistent-function-scoping -- Widget helpers must stay inside this function for runtime serialization.
	const toElapsed = (elapsedSeconds: number): string => {
		const bounded = Number.isFinite(elapsedSeconds) && elapsedSeconds > 0 ? Math.floor(elapsedSeconds) : 0;
		const minutes = Math.floor(bounded / 60);
		const seconds = bounded % 60;
		return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
	};

	// eslint-disable-next-line unicorn/consistent-function-scoping -- Widget helpers must stay inside this function for runtime serialization.
	const toPreview = (value: string): string => {
		const trimmed = value.trim();
		if (trimmed.length === 0) {
			return "Waiting for updates...";
		}

		return trimmed.length > 140 ? `${trimmed.slice(0, 140)}...` : trimmed;
	};

	const globalValues = globalThis as Record<string, unknown>;
	const textView = globalValues.Text as ((props: Record<string, unknown>) => ReactNode) | undefined;
	const imageView = globalValues.Image as ((props: Record<string, unknown>) => ReactNode) | undefined;
	const hStackView = globalValues.HStack as ((props: Record<string, unknown>) => ReactNode) | undefined;
	const spacerView = globalValues.Spacer as ((props?: Record<string, unknown>) => ReactNode) | undefined;
	const vStackView = globalValues.VStack as ((props: Record<string, unknown>) => ReactNode) | undefined;

	const background = globalValues.background as ((...args: unknown[]) => unknown) | undefined;
	const cornerRadius = globalValues.cornerRadius as ((...args: unknown[]) => unknown) | undefined;
	const frame = globalValues.frame as ((...args: unknown[]) => unknown) | undefined;
	const font = globalValues.font as ((...args: unknown[]) => unknown) | undefined;
	const foregroundStyle = globalValues.foregroundStyle as ((...args: unknown[]) => unknown) | undefined;
	const lineLimit = globalValues.lineLimit as ((...args: unknown[]) => unknown) | undefined;
	const monospacedDigit = globalValues.monospacedDigit as ((...args: unknown[]) => unknown) | undefined;
	const padding = globalValues.padding as ((...args: unknown[]) => unknown) | undefined;

	if (!textView || !hStackView || !vStackView || !font || !foregroundStyle || !lineLimit || !padding) {
		return FALLBACK_LAYOUT;
	}

	const data = props ?? {
		chatId: "unknown",
		chatTitle: "Thread",
		elapsedSeconds: 0,
		phase: "running" as ThreadLiveActivityPhase,
		preview: "Waiting for updates...",
		statusLine: "Starting...",
	};

	const phaseState: Record<ThreadLiveActivityPhase, PhaseVisualState> = {
		background: {
			icon: "BG",
			label: "Background",
			badgeBackground: "#DBEAFE",
			badgeForeground: "#1E3A8A",
			timerBackground: "#1E3A8A",
			timerForeground: "#DBEAFE",
			titleForeground: "#E2E8F0",
			statusForeground: "#BFDBFE",
			previewForeground: "#CBD5E1",
			cardBackground: "#0A2340",
			containerBackground: "#020617",
			brandBackground: "#0C2647",
			brandForeground: "#93C5FD",
			defaultStatus: "Running in background",
			defaultPreview: "The response keeps running while the app is not active.",
		},
		completed: {
			icon: "OK",
			label: "Completed",
			badgeBackground: "#DCFCE7",
			badgeForeground: "#166534",
			timerBackground: "#14532D",
			timerForeground: "#DCFCE7",
			titleForeground: "#E2E8F0",
			statusForeground: "#86EFAC",
			previewForeground: "#D1FAE5",
			cardBackground: "#052E1D",
			containerBackground: "#03170F",
			brandBackground: "#064E3B",
			brandForeground: "#6EE7B7",
			defaultStatus: "Response is ready",
			defaultPreview: "Tap to open the thread and review the full answer.",
		},
		error: {
			icon: "ERR",
			label: "Error",
			badgeBackground: "#FEE2E2",
			badgeForeground: "#991B1B",
			timerBackground: "#7F1D1D",
			timerForeground: "#FEE2E2",
			titleForeground: "#FEE2E2",
			statusForeground: "#FCA5A5",
			previewForeground: "#FECACA",
			cardBackground: "#3F1115",
			containerBackground: "#22070B",
			brandBackground: "#52131A",
			brandForeground: "#FCA5A5",
			defaultStatus: "Thread ended with an error",
			defaultPreview: "Open the thread to see the error details.",
		},
		failed: {
			icon: "FAIL",
			label: "Failed",
			badgeBackground: "#FEE2E2",
			badgeForeground: "#991B1B",
			timerBackground: "#7F1D1D",
			timerForeground: "#FEE2E2",
			titleForeground: "#FEE2E2",
			statusForeground: "#FCA5A5",
			previewForeground: "#FECACA",
			cardBackground: "#3F1115",
			containerBackground: "#22070B",
			brandBackground: "#52131A",
			brandForeground: "#FCA5A5",
			defaultStatus: "Thread failed",
			defaultPreview: "Open the thread to retry the request.",
		},
		finalizing: {
			icon: "...",
			label: "Finalizing",
			badgeBackground: "#E0EAFF",
			badgeForeground: "#1D4ED8",
			timerBackground: "#1D4ED8",
			timerForeground: "#E0EAFF",
			titleForeground: "#E2E8F0",
			statusForeground: "#BFDBFE",
			previewForeground: "#DBEAFE",
			cardBackground: "#102A56",
			containerBackground: "#020617",
			brandBackground: "#163569",
			brandForeground: "#93C5FD",
			defaultStatus: "Finalizing response",
			defaultPreview: "Wrapping up the final answer.",
		},
		running: {
			icon: "RUN",
			label: "Running",
			badgeBackground: "#CCFBF1",
			badgeForeground: "#0F766E",
			timerBackground: "#155E75",
			timerForeground: "#CCFBF1",
			titleForeground: "#E2E8F0",
			statusForeground: "#67E8F9",
			previewForeground: "#CFFAFE",
			cardBackground: "#082F49",
			containerBackground: "#020617",
			brandBackground: "#0A2A40",
			brandForeground: "#67E8F9",
			defaultStatus: "Generating response",
			defaultPreview: "Working on your latest request.",
		},
	};

	const visual = phaseState[data.phase] ?? phaseState.running;
	const title = toTrimmed(data.chatTitle, "Thread");
	const statusLine = toTrimmed(data.statusLine, visual.defaultStatus);
	const preview = toPreview(toTrimmed(data.preview, visual.defaultPreview));
	const elapsed = toElapsed(data.elapsedSeconds);
	const compactGlyph = data.phase === "running" || data.phase === "finalizing"
		? "RC"
		: visual.label.slice(0, 1).toUpperCase();

	const logoIcon = imageView
		? imageView({
			color: visual.brandForeground,
			size: 12,
			systemName: "arrow.up.right.circle.fill",
		})
		: null;
	const logoFallback = textView({
		children: "RC",
		modifiers: [
			font({ size: 11, weight: "bold", design: "rounded" }),
			foregroundStyle(visual.brandForeground),
			lineLimit(1),
		],
	});
	const logoWordmark = textView({
		children: "RemoteCode",
		modifiers: [
			font({ size: 10, weight: "semibold", design: "rounded" }),
			foregroundStyle(visual.brandForeground),
			lineLimit(1),
		],
	});
	const brandChip = hStackView({
		spacing: 4,
		modifiers: [
			padding({ horizontal: 8, vertical: 4 }),
			background ? background(visual.brandBackground) : null,
			cornerRadius ? cornerRadius(999) : null,
		].filter(Boolean),
		children: [logoIcon ?? logoFallback, logoWordmark],
	});

	const phaseBadge = textView({
		children: visual.label,
		modifiers: [
			padding({ horizontal: 8, vertical: 3 }),
			background ? background(visual.badgeBackground) : null,
			cornerRadius ? cornerRadius(999) : null,
			font({ size: 10, weight: "bold", design: "rounded" }),
			foregroundStyle(visual.badgeForeground),
			lineLimit(1),
		].filter(Boolean),
	});
	const elapsedPill = textView({
		children: elapsed,
		modifiers: [
			padding({ horizontal: 8, vertical: 3 }),
			background ? background(visual.timerBackground) : null,
			cornerRadius ? cornerRadius(999) : null,
			font({ size: 10, weight: "semibold", design: "monospaced" }),
			monospacedDigit ? monospacedDigit() : null,
			foregroundStyle(visual.timerForeground),
			lineLimit(1),
		].filter(Boolean),
	});
	const titleText = textView({
		children: title,
		modifiers: [
			font({ size: 14, weight: "bold", design: "rounded" }),
			foregroundStyle(visual.titleForeground),
			lineLimit(1),
		],
	});
	const statusText = textView({
		children: `${visual.icon} ${statusLine}`,
		modifiers: [
			font({ size: 12, weight: "medium", design: "rounded" }),
			foregroundStyle(visual.statusForeground),
			lineLimit(1),
		],
	});
	const previewText = textView({
		children: preview,
		modifiers: [
			font({ size: 12, weight: "regular" }),
			foregroundStyle(visual.previewForeground),
			lineLimit(2),
		],
	});

	const compactLeading = textView({
		children: compactGlyph,
		modifiers: [
			font({ size: 11, weight: "bold", design: "rounded" }),
			foregroundStyle(visual.brandForeground),
			lineLimit(1),
		],
	});
	const compactTrailing = textView({
		children: elapsed,
		modifiers: [
			font({ size: 11, weight: "semibold", design: "monospaced" }),
			monospacedDigit ? monospacedDigit() : null,
			foregroundStyle(visual.timerForeground),
		].filter(Boolean),
	});
	const minimal = textView({
		children: compactGlyph.slice(0, 1),
		modifiers: [
			font({ size: 10, weight: "bold", design: "rounded" }),
			foregroundStyle(visual.brandForeground),
			lineLimit(1),
		],
	});

	const previewCard = vStackView({
		alignment: "leading",
		spacing: 4,
		modifiers: [
			padding({ horizontal: 10, vertical: 8 }),
			background ? background(visual.cardBackground) : null,
			cornerRadius ? cornerRadius(10) : null,
		].filter(Boolean),
		children: [statusText, previewText],
	});
	const bannerContent = vStackView({
		alignment: "leading",
		spacing: 10,
		modifiers: [
			padding({ all: 12 }),
		],
		children: [
			hStackView({
				spacing: 6,
				children: [brandChip, phaseBadge, elapsedPill],
			}),
			titleText,
			previewCard,
		],
	});
	const bannerChildren = spacerView
		? [bannerContent, spacerView({ minLength: 0 })]
		: [bannerContent];
	const bannerSmallChildren = spacerView
		? [phaseBadge, elapsedPill, spacerView({ minLength: 0 })]
		: [phaseBadge, elapsedPill];

	return {
		banner: hStackView({
			alignment: "top",
			spacing: 0,
			modifiers: [
				frame ? frame({ alignment: "leading", maxWidth: 9_999 }) : null,
				background ? background(visual.containerBackground) : null,
				cornerRadius ? cornerRadius(16) : null,
			].filter(Boolean),
			children: bannerChildren,
		}),
		bannerSmall: hStackView({
			spacing: 6,
			modifiers: [
				frame ? frame({ alignment: "leading", maxWidth: 9_999 }) : null,
				padding({ horizontal: 8, vertical: 6 }),
				background ? background(visual.containerBackground) : null,
				cornerRadius ? cornerRadius(10) : null,
			].filter(Boolean),
			children: bannerSmallChildren,
		}),
		compactLeading,
		compactTrailing,
		minimal,
		expandedCenter: vStackView({
			alignment: "leading",
			spacing: 4,
			children: [titleText, statusText, previewText],
		}),
		expandedLeading: brandChip,
		expandedTrailing: elapsedPill,
		expandedBottom: previewCard,
	};
};

export const threadLiveActivityFactory = createLiveActivity<ThreadLiveActivityProps>(
	"ThreadLiveActivity",
	toLayout,
);
