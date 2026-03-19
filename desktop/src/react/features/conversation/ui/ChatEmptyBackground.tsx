import { Canvas } from "@react-three/fiber";
import { useEffect, useRef, useState } from "react";
import { RemoteFlowScene } from "./remote-flow-scene";

export interface Pointer {
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

export const createPointerRef = () => ({ current: { horizontal: 0, vertical: 0 } as Pointer });

export const ChatEmptyBackground = ({ reducedMotion }: { reducedMotion: boolean }) => {
	const [ready, setReady] = useState(false);
	const pointerRef = useRef<Pointer>({ horizontal: 0, vertical: 0 });

	useEffect(() => {
		setReady(canUseWebgl());

		const onPointerMove = (e: MouseEvent) => {
			pointerRef.current.horizontal = (e.clientX / window.innerWidth - 0.5) * 2;
			pointerRef.current.vertical = (e.clientY / window.innerHeight - 0.5) * -2;
		};

		window.addEventListener("pointermove", onPointerMove, { passive: true });
		return () => window.removeEventListener("pointermove", onPointerMove);
	}, []);

	if (!ready) return null;

	return (
		<div className="pointer-events-none absolute inset-0 overflow-hidden rounded-2xl" style={{ backgroundColor: "#05070c" }}>
			{/* @ts-expect-error mixed @types/react versions in workspace affect Canvas JSX typing */}
			<Canvas
				camera={{ far: 18, fov: 34, near: 0.1, position: [0, 0.1, 8.4] }}
				dpr={[1, 1.5]}
				gl={{ alpha: false, antialias: true, powerPreference: "high-performance" }}
				style={{ position: "absolute", inset: 0 }}
			>
				<RemoteFlowScene pointerRef={pointerRef} reducedMotion={reducedMotion} />
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
