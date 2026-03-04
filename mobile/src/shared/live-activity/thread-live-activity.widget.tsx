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
	timerForeground: string;
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

		return trimmed.length > 120 ? `${trimmed.slice(0, 120)}...` : trimmed;
	};

	const globalValues = globalThis as Record<string, unknown>;
	const textView = globalValues.Text as ((props: Record<string, unknown>) => ReactNode) | undefined;
	const hStackView = globalValues.HStack as ((props: Record<string, unknown>) => ReactNode) | undefined;
	const vStackView = globalValues.VStack as ((props: Record<string, unknown>) => ReactNode) | undefined;

	const background = globalValues.background as ((...args: unknown[]) => unknown) | undefined;
	const cornerRadius = globalValues.cornerRadius as ((...args: unknown[]) => unknown) | undefined;
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
			badgeBackground: "#E2E8F0",
			badgeForeground: "#334155",
			timerForeground: "#334155",
			defaultStatus: "Running in background",
			defaultPreview: "The response keeps running while the app is not active.",
		},
		completed: {
			icon: "OK",
			label: "Completed",
			badgeBackground: "#DCFCE7",
			badgeForeground: "#166534",
			timerForeground: "#166534",
			defaultStatus: "Response is ready",
			defaultPreview: "Tap to open the thread and review the full answer.",
		},
		error: {
			icon: "ERR",
			label: "Error",
			badgeBackground: "#FEE2E2",
			badgeForeground: "#991B1B",
			timerForeground: "#991B1B",
			defaultStatus: "Thread ended with an error",
			defaultPreview: "Open the thread to see the error details.",
		},
		failed: {
			icon: "FAIL",
			label: "Failed",
			badgeBackground: "#FEE2E2",
			badgeForeground: "#991B1B",
			timerForeground: "#991B1B",
			defaultStatus: "Thread failed",
			defaultPreview: "Open the thread to retry the request.",
		},
		finalizing: {
			icon: "...",
			label: "Finalizing",
			badgeBackground: "#DBEAFE",
			badgeForeground: "#1D4ED8",
			timerForeground: "#1D4ED8",
			defaultStatus: "Finalizing response",
			defaultPreview: "Wrapping up the final answer.",
		},
		running: {
			icon: "RUN",
			label: "Running",
			badgeBackground: "#CCFBF1",
			badgeForeground: "#0F766E",
			timerForeground: "#0F766E",
			defaultStatus: "Generating response",
			defaultPreview: "Working on your latest request.",
		},
	};

	const visual = phaseState[data.phase] ?? phaseState.running;
	const title = toTrimmed(data.chatTitle, "Thread");
	const statusLine = toTrimmed(data.statusLine, visual.defaultStatus);
	const preview = toPreview(toTrimmed(data.preview, visual.defaultPreview));
	const elapsed = toElapsed(data.elapsedSeconds);
	const leadingGlyph = data.phase === "running" || data.phase === "finalizing" ? "RC" : visual.label.slice(0, 2).toUpperCase();

	const headerText = textView({
		children: title,
		modifiers: [
			font({ size: 14, weight: "bold", design: "rounded" }),
			foregroundStyle({ type: "hierarchical", style: "primary" }),
			lineLimit(1),
		],
	});
	const phaseBadge = textView({
		children: visual.label,
		modifiers: [
			padding({ horizontal: 8, vertical: 3 }),
			background ? background(visual.badgeBackground) : null,
			cornerRadius ? cornerRadius(999) : null,
			font({ size: 11, weight: "semibold", design: "rounded" }),
			foregroundStyle(visual.badgeForeground),
			lineLimit(1),
		].filter(Boolean),
	});
	const statusText = textView({
		children: statusLine,
		modifiers: [
			font({ size: 12, weight: "medium" }),
			foregroundStyle({ type: "hierarchical", style: "secondary" }),
			lineLimit(1),
		],
	});
	const previewText = textView({
		children: preview,
		modifiers: [
			font({ size: 12, weight: "regular" }),
			foregroundStyle({ type: "hierarchical", style: "secondary" }),
			lineLimit(2),
		],
	});
	const elapsedText = textView({
		children: elapsed,
		modifiers: [
			font({ size: 12, weight: "semibold", design: "monospaced" }),
			monospacedDigit ? monospacedDigit() : null,
			foregroundStyle(visual.timerForeground),
		].filter(Boolean),
	});
	const iconText = textView({
		children: visual.icon,
		modifiers: [
			font({ size: 11, weight: "semibold" }),
			foregroundStyle(visual.timerForeground),
			lineLimit(1),
		],
	});
	const compactLeading = textView({
		children: leadingGlyph,
		modifiers: [
			font({ size: 11, weight: "bold", design: "rounded" }),
			foregroundStyle({ type: "hierarchical", style: "primary" }),
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
		children: visual.label.slice(0, 1),
		modifiers: [
			font({ size: 10, weight: "bold", design: "rounded" }),
			foregroundStyle(visual.timerForeground),
			lineLimit(1),
		],
	});

	return {
		banner: vStackView({
			alignment: "leading",
			spacing: 8,
			modifiers: [
				padding({ all: 12 }),
				background ? background("#F8FAFC") : null,
				cornerRadius ? cornerRadius(16) : null,
			].filter(Boolean),
			children: [
				hStackView({
					spacing: 8,
					children: [headerText, phaseBadge],
				}),
				hStackView({
					spacing: 8,
					children: [iconText, statusText, elapsedText],
				}),
				previewText,
			],
		}),
		compactLeading,
		compactTrailing,
		minimal,
		expandedCenter: vStackView({
			alignment: "leading",
			spacing: 4,
			children: [
				headerText,
				hStackView({
					spacing: 8,
					children: [iconText, statusText],
				}),
				previewText,
			],
		}),
		expandedLeading: phaseBadge,
		expandedTrailing: elapsedText,
		expandedBottom: previewText,
	};
};

export const threadLiveActivityFactory = createLiveActivity<ThreadLiveActivityProps>(
	"ThreadLiveActivity",
	toLayout,
);
