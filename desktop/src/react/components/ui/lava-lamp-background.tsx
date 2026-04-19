import { memo, useEffect, useRef, useState } from "react";

interface BlobConfig {
	id: number;
	color: string;
	size: number;
	x: number;
	y: number;
	duration: number;
	delay: number;
	blur: number;
	opacity: number;
	variant: number;
}

export type LavaLampMode = "idle" | "active";

const idleBlobs: BlobConfig[] = [
	{ id: 0, color: "hsl(270, 100%, 70%)", size: 70, x: 30, y: 20, duration: 14, delay: 0, blur: 40, opacity: 0.13, variant: 0 },
	{ id: 1, color: "hsl(230, 100%, 65%)", size: 60, x: 60, y: 50, duration: 12, delay: -2, blur: 35, opacity: 0.12, variant: 1 },
	{ id: 2, color: "hsl(320, 100%, 60%)", size: 55, x: 40, y: 75, duration: 16, delay: -4, blur: 38, opacity: 0.11, variant: 2 },
	{ id: 3, color: "hsl(210, 100%, 60%)", size: 50, x: 70, y: 15, duration: 13, delay: -6, blur: 42, opacity: 0.10, variant: 3 },
	{ id: 4, color: "hsl(290, 100%, 65%)", size: 45, x: 50, y: 45, duration: 10, delay: -3, blur: 32, opacity: 0.12, variant: 4 },
];

const activeBlobs: BlobConfig[] = [
	{ id: 0, color: "hsl(270, 100%, 70%)", size: 70, x: 30, y: 20, duration: 6, delay: 0, blur: 40, opacity: 0.40, variant: 0 },
	{ id: 1, color: "hsl(230, 100%, 65%)", size: 60, x: 60, y: 50, duration: 5, delay: -1, blur: 35, opacity: 0.38, variant: 1 },
	{ id: 2, color: "hsl(320, 100%, 60%)", size: 55, x: 40, y: 75, duration: 7, delay: -2, blur: 38, opacity: 0.35, variant: 2 },
	{ id: 3, color: "hsl(210, 100%, 60%)", size: 50, x: 70, y: 15, duration: 8, delay: -3, blur: 42, opacity: 0.35, variant: 3 },
	{ id: 4, color: "hsl(290, 100%, 65%)", size: 45, x: 50, y: 45, duration: 6, delay: -1.5, blur: 32, opacity: 0.38, variant: 4 },
];

function LavaLampBackgroundInner({
	mode = "idle",
	paused = false,
}: {
	mode?: LavaLampMode;
	paused?: boolean;
}) {
	const [isLowFPS, setIsLowFPS] = useState(false);
	const [isVisible, setIsVisible] = useState(() =>
		typeof document === "undefined" ? true : document.visibilityState === "visible",
	);
	const timerRef = useRef<number | null>(null);

	useEffect(() => {
		const handleVisibility = () => {
			setIsVisible(document.visibilityState === "visible");
		};
		document.addEventListener("visibilitychange", handleVisibility);
		return () => document.removeEventListener("visibilitychange", handleVisibility);
	}, []);

	const shouldAnimate = isVisible && !paused;

	useEffect(() => {
		if (!shouldAnimate) return;

		let frameCount = 0;
		let lastTime = performance.now();
		let rafId: number;

		const measureFPS = (now: number) => {
			frameCount++;
			const delta = now - lastTime;

			if (delta >= 2000) {
				const fps = (frameCount / delta) * 1000;
				setIsLowFPS(fps < 30);
				frameCount = 0;
				lastTime = now;
			}

			rafId = requestAnimationFrame(measureFPS);
		};

		timerRef.current = window.setTimeout(() => {
			rafId = requestAnimationFrame(measureFPS);
		}, 3000);

		return () => {
			if (timerRef.current) clearTimeout(timerRef.current);
			cancelAnimationFrame(rafId);
		};
	}, [shouldAnimate]);

	const blobs = mode === "active" ? activeBlobs : idleBlobs;

	return (
		<div
			className="lava-lamp-container"
			data-low-fps={isLowFPS || undefined}
			data-mode={mode}
			data-paused={!shouldAnimate || undefined}
			style={{ animationPlayState: shouldAnimate ? "running" : "paused" } as React.CSSProperties}
			aria-hidden="true"
		>
			{blobs.map((blob) => (
				<div
					key={blob.id}
					className={`lava-blob lava-blob-v${blob.variant}`}
					style={{
						"--blob-x": `${blob.x}%`,
						"--blob-y": `${blob.y}%`,
						"--blob-size": `${blob.size}%`,
						"--blob-color": blob.color,
						"--blob-duration": `${blob.duration}s`,
						"--blob-delay": `${blob.delay}s`,
						"--blob-blur": `${blob.blur}px`,
						"--blob-opacity": blob.opacity,
						animationPlayState: shouldAnimate ? "running" : "paused",
					} as React.CSSProperties}
				/>
			))}
		</div>
	);
}

export const LavaLampBackground = memo(LavaLampBackgroundInner);
