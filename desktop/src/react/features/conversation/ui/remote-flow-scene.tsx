import { useFrame } from "@react-three/fiber";
import { useEffect, useMemo, useRef, type RefObject } from "react";
import {
	AdditiveBlending,
	BufferGeometry,
	CatmullRomCurve3,
	Group,
	Line,
	LineBasicMaterial,
	MathUtils,
	Mesh,
	MeshBasicMaterial,
	Vector3,
} from "three";

interface FlowPathDefinition {
	color: string;
	curve: CatmullRomCurve3;
	id: string;
	opacity: number;
	points: Vector3[];
}

interface PulseDefinition {
	color: string;
	id: string;
	offset: number;
	pathIndex: number;
	scale: number;
	speed: number;
}

interface StatusNodeDefinition {
	color: string;
	id: string;
	pathIndex: number;
	phase: number;
	scale: number;
	tension: number;
	progress: number;
}

const palette = {
	backGlow: "#15203a",
	indigo: "#7d8fff",
	pulse: "#dbe6ff",
	violet: "#8c72ff",
	white: "#f7fbff",
} as const;

const createNoise = (seed: number) => {
	const value = Math.sin(seed * 127.1) * 43758.5453123;
	return value - Math.floor(value);
};

const resolvePulseColor = (index: number) => {
	if (index % 3 === 0) return palette.white;
	if (index % 2 === 0) return palette.violet;
	return palette.pulse;
};

const resolveNodeColor = (index: number) => {
	if (index % 4 === 0) return palette.pulse;
	if (index % 2 === 0) return palette.indigo;
	return palette.violet;
};

const createFlowPaths = (reducedMotion: boolean): FlowPathDefinition[] => {
	const pathCount = 16;
	const desktopPole = new Vector3(-3.35, -1.45, -0.25);
	const mobilePole = new Vector3(3.15, 1.55, 0.35);
	const paths: FlowPathDefinition[] = [];
	const spread = 0.56;
	const arch = 1.05;

	for (let index = 0; index < pathCount; index += 1) {
		const seed = index + 1;
		const start = desktopPole.clone().add(
			new Vector3(
				(createNoise(seed * 1.7) - 0.5) * spread,
				(createNoise(seed * 2.3) - 0.5) * (spread * 1.2),
				(createNoise(seed * 3.1) - 0.5) * 0.28,
			),
		);
		const end = mobilePole.clone().add(
			new Vector3(
				(createNoise(seed * 4.7) - 0.5) * (spread * 0.9),
				(createNoise(seed * 5.9) - 0.5) * spread,
				(createNoise(seed * 6.4) - 0.5) * 0.24,
			),
		);
		const direction = index % 2 === 0 ? 1 : -1;
		const widthBias = (index / Math.max(1, pathCount - 1)) * 1.8 - 0.9;
		const controlA = new Vector3(
			-1.5 + widthBias * 0.4,
			direction * arch + (createNoise(seed * 7.2) - 0.5) * 0.9,
			-0.18,
		);
		const controlB = new Vector3(
			1.4 - widthBias * 0.32,
			direction * arch * 0.72 + (createNoise(seed * 8.1) - 0.5) * 0.78,
			0.16,
		);
		const curve = new CatmullRomCurve3([start, controlA, controlB, end], false, "catmullrom", 0.55);

		paths.push({
			color: index % 5 === 0 ? palette.violet : palette.indigo,
			curve,
			id: `path-${index}`,
			opacity: reducedMotion ? 0.16 : 0.12 + createNoise(seed * 9.4) * 0.16,
			points: curve.getPoints(52),
		});
	}

	return paths;
};

const createPulses = (paths: FlowPathDefinition[], reducedMotion: boolean): PulseDefinition[] => {
	const pulseCount = 11;
	return Array.from({ length: pulseCount }, (_, index) => {
		const seed = index + 11;
		return {
			color: resolvePulseColor(index),
			id: `pulse-${index}`,
			offset: createNoise(seed * 1.37),
			pathIndex: Math.floor(createNoise(seed * 2.1) * paths.length) % paths.length,
			scale: 0.028 + createNoise(seed * 2.9) * 0.03,
			speed: (reducedMotion ? 0.022 : 0.032) + createNoise(seed * 3.8) * (reducedMotion ? 0.02 : 0.055),
		};
	});
};

const createStatusNodes = (paths: FlowPathDefinition[], _reducedMotion: boolean): StatusNodeDefinition[] => {
	const nodeCount = 10;
	return Array.from({ length: nodeCount }, (_, index) => {
		const seed = index + 41;
		return {
			color: resolveNodeColor(index),
			id: `node-${index}`,
			pathIndex: Math.floor(createNoise(seed * 1.4) * paths.length) % paths.length,
			phase: createNoise(seed * 2.9) * Math.PI * 2,
			progress: 0.18 + createNoise(seed * 5.1) * 0.64,
			scale: 0.024 + createNoise(seed * 4.3) * 0.024,
			tension: 0.45 + createNoise(seed * 6.8) * 0.55,
		};
	});
};

const AmbientGlowField = ({
	color,
	intensity,
	position,
	reducedMotion,
	scale,
}: {
	color: string;
	intensity: number;
	position: [number, number, number];
	reducedMotion: boolean;
	scale: [number, number, number];
}) => {
	const meshRef = useRef<Mesh>(null);

	useFrame(({ clock }) => {
		if (!meshRef.current) return;
		const pulse = reducedMotion ? 1 : 1 + Math.sin(clock.elapsedTime * 0.12 + position[0]) * 0.05;
		meshRef.current.scale.set(scale[0] * pulse, scale[1] * pulse, scale[2]);
	});

	return (
		<mesh position={position} ref={meshRef}>
			<circleGeometry args={[1, 64]} />
			<meshBasicMaterial blending={AdditiveBlending} color={color} depthWrite={false} opacity={intensity} transparent />
		</mesh>
	);
};

const FlowPathLine = ({ intensity, path }: { intensity: number; path: FlowPathDefinition }) => {
	const line = useMemo(() => {
		const geometry = new BufferGeometry().setFromPoints(path.points);
		const material = new LineBasicMaterial({
			color: path.color,
			opacity: path.opacity * intensity,
			toneMapped: false,
			transparent: true,
		});
		return new Line(geometry, material);
	}, [intensity, path.color, path.opacity, path.points]);

	useEffect(
		() => () => {
			line.geometry.dispose();
			line.material.dispose();
		},
		[line],
	);

	return <primitive object={line} />;
};

const FlowPaths = ({ intensity, paths }: { intensity: number; paths: FlowPathDefinition[] }) => (
	<group>
		{paths.map((path) => (
			<FlowPathLine intensity={intensity} key={path.id} path={path} />
		))}
	</group>
);

const TravelingPulse = ({
	definition,
	intensity,
	path,
	reducedMotion,
}: {
	definition: PulseDefinition;
	intensity: number;
	path: FlowPathDefinition;
	reducedMotion: boolean;
}) => {
	const meshRef = useRef<Mesh>(null);
	const materialRef = useRef<MeshBasicMaterial>(null);

	useFrame(({ clock }) => {
		if (!meshRef.current || !materialRef.current) return;
		const elapsed = clock.elapsedTime * definition.speed;
		const progress = (definition.offset + elapsed) % 1;
		const position = path.curve.getPointAt(progress);
		meshRef.current.position.copy(position);
		const shimmer = reducedMotion
			? 0.9
			: 0.65 + Math.sin(clock.elapsedTime * 0.75 + definition.offset * Math.PI * 2) * 0.25;
		const scale = definition.scale * (1 + shimmer * 0.45);
		meshRef.current.scale.setScalar(scale);
		materialRef.current.opacity = Math.min(0.92, (0.28 + shimmer * 0.48) * intensity);
	});

	return (
		<mesh ref={meshRef}>
			<sphereGeometry args={[1, 16, 16]} />
			<meshBasicMaterial
				blending={AdditiveBlending}
				color={definition.color}
				depthWrite={false}
				opacity={0.72}
				ref={materialRef}
				toneMapped={false}
				transparent
			/>
		</mesh>
	);
};

const TravelingPulses = ({
	intensity,
	paths,
	pulses,
	reducedMotion,
}: {
	intensity: number;
	paths: FlowPathDefinition[];
	pulses: PulseDefinition[];
	reducedMotion: boolean;
}) => (
	<group>
		{pulses.map((pulse) => {
			const path = paths[pulse.pathIndex];
			if (!path) return null;
			return (
				<TravelingPulse
					definition={pulse}
					intensity={intensity}
					key={pulse.id}
					path={path}
					reducedMotion={reducedMotion}
				/>
			);
		})}
	</group>
);

const StatusNode = ({
	definition,
	intensity,
	path,
	reducedMotion,
}: {
	definition: StatusNodeDefinition;
	intensity: number;
	path: FlowPathDefinition;
	reducedMotion: boolean;
}) => {
	const meshRef = useRef<Mesh>(null);
	const materialRef = useRef<MeshBasicMaterial>(null);
	const basePosition = useMemo(() => path.curve.getPointAt(definition.progress), [definition.progress, path.curve]);

	useFrame(({ clock }) => {
		if (!meshRef.current || !materialRef.current) return;
		const wave = reducedMotion
			? 0.72
			: 0.58 + Math.sin(clock.elapsedTime * definition.tension + definition.phase) * 0.16;
		const activation = reducedMotion
			? 0.14
			: Math.max(0, Math.sin(clock.elapsedTime * 0.19 + definition.phase) - 0.82) * 0.85;
		meshRef.current.position.copy(basePosition);
		meshRef.current.scale.setScalar(definition.scale * (1 + wave));
		materialRef.current.opacity = Math.min(0.75, (0.18 + wave * 0.24 + activation) * intensity);
	});

	return (
		<mesh position={basePosition} ref={meshRef}>
			<sphereGeometry args={[1, 12, 12]} />
			<meshBasicMaterial
				blending={AdditiveBlending}
				color={definition.color}
				depthWrite={false}
				opacity={0.26}
				ref={materialRef}
				toneMapped={false}
				transparent
			/>
		</mesh>
	);
};

const StatusNodes = ({
	intensity,
	nodes,
	paths,
	reducedMotion,
}: {
	intensity: number;
	nodes: StatusNodeDefinition[];
	paths: FlowPathDefinition[];
	reducedMotion: boolean;
}) => (
	<group>
		{nodes.map((node) => {
			const path = paths[node.pathIndex];
			if (!path) return null;
			return (
				<StatusNode definition={node} intensity={intensity} key={node.id} path={path} reducedMotion={reducedMotion} />
			);
		})}
	</group>
);

const ParallaxController = ({
	groupRef,
	pointer,
	reducedMotion,
}: {
	groupRef: RefObject<Group | null>;
	pointer: { horizontal: number; vertical: number };
	reducedMotion: boolean;
}) => {
	useFrame((_, delta) => {
		if (!groupRef.current) return;
		const targetX = reducedMotion ? 0 : pointer.horizontal * 0.18;
		const targetY = reducedMotion ? 0 : pointer.vertical * 0.12;
		const targetRotY = reducedMotion ? 0 : pointer.horizontal * 0.05;
		const targetRotX = reducedMotion ? 0 : pointer.vertical * 0.03;

		groupRef.current.position.x = MathUtils.lerp(groupRef.current.position.x, targetX, 1 - Math.exp(-delta * 3.2));
		groupRef.current.position.y = MathUtils.lerp(groupRef.current.position.y, targetY, 1 - Math.exp(-delta * 2.7));
		groupRef.current.rotation.y = MathUtils.lerp(
			groupRef.current.rotation.y,
			targetRotY,
			1 - Math.exp(-delta * 2.4),
		);
		groupRef.current.rotation.x = MathUtils.lerp(
			groupRef.current.rotation.x,
			targetRotX,
			1 - Math.exp(-delta * 2.4),
		);
	});

	return null;
};

export const RemoteFlowScene = ({
	pointer,
	reducedMotion,
}: {
	pointer: { horizontal: number; vertical: number };
	reducedMotion: boolean;
}) => {
	const groupRef = useRef<Group>(null);
	const paths = useMemo(() => createFlowPaths(reducedMotion), [reducedMotion]);
	const pulses = useMemo(() => createPulses(paths, reducedMotion), [paths, reducedMotion]);
	const nodes = useMemo(() => createStatusNodes(paths, reducedMotion), [paths, reducedMotion]);
	const intensity = reducedMotion ? 0.82 : 0.9;

	return (
		<>
			<color args={["#05070c"]} attach="background" />
			<fog args={["#05070c", 8.8, 15.5]} attach="fog" />
			<group ref={groupRef}>
				<AmbientGlowField
					color={palette.backGlow}
					intensity={0.13 * intensity}
					position={[-3.45, -1.55, -1.8]}
					reducedMotion={reducedMotion}
					scale={[3.8, 3.2, 1]}
				/>
				<AmbientGlowField
					color={palette.indigo}
					intensity={0.095 * intensity}
					position={[3.3, 1.6, -1.3]}
					reducedMotion={reducedMotion}
					scale={[2.7, 2.3, 1]}
				/>
				<FlowPaths intensity={intensity} paths={paths} />
				<TravelingPulses intensity={intensity} paths={paths} pulses={pulses} reducedMotion={reducedMotion} />
				<StatusNodes intensity={intensity} nodes={nodes} paths={paths} reducedMotion={reducedMotion} />
			</group>
			<ParallaxController groupRef={groupRef} pointer={pointer} reducedMotion={reducedMotion} />
		</>
	);
};
