import { Canvas } from "@react-three/fiber";
import { useEffect, useState } from "react";
import { RemoteFlowScene } from "./remote-flow-scene";

interface Pointer {
	horizontal: number;
	vertical: number;
}

const canUseWebgl = (): boolean => {
	try {
		const canvas = document.createElement("canvas");
		return Boolean(
			window.WebGLRenderingContext && (canvas.getContext("webgl") || canvas.getContext("experimental-webgl")),
		);
	} catch {
		return false;
	}
};

export const ChatEmptyBackground = ({ reducedMotion }: { reducedMotion: boolean }) => {
	const [ready, setReady] = useState(false);
	const [pointer, setPointer] = useState<Pointer>({ horizontal: 0, vertical: 0 });

	useEffect(() => {
		setReady(canUseWebgl());

		const onPointerMove = (e: MouseEvent) => {
			const h = (e.clientX / window.innerWidth - 0.5) * 2;
			const v = (e.clientY / window.innerHeight - 0.5) * -2;
			setPointer({ horizontal: h, vertical: v });
		};

		window.addEventListener("pointermove", onPointerMove, { passive: true });
		return () => window.removeEventListener("pointermove", onPointerMove);
	}, []);

	if (!ready) return null;

	return (
		<div className="pointer-events-none absolute inset-0 overflow-hidden rounded-2xl">
			{/* @ts-expect-error R3F v8 types vs @types/react v19 mismatch */}
			<Canvas
				camera={{ far: 18, fov: 34, near: 0.1, position: [0, 0.1, 8.4] }}
				dpr={[1, 1.5]}
				gl={{ alpha: true, antialias: true, powerPreference: "high-performance" }}
				style={{ position: "absolute", inset: 0 }}
			>
				<RemoteFlowScene pointer={pointer} reducedMotion={reducedMotion} />
			</Canvas>
			<div
				className="absolute inset-0"
				style={{
					background:
						"radial-gradient(ellipse at center, transparent 40%, rgba(5,7,12,0.7) 80%, rgba(5,7,12,0.95) 100%)",
				}}
			/>
		</div>
	);
};
