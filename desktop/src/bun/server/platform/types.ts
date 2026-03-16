export type KillIntent = "force" | "graceful";

export interface Subprocess {
	kill(signal?: number | string): void;
}

export interface PlatformModule {
	resolveShell(): string;
	buildShellArgs(shell: string, command: string): string[];
	killProcess(subprocess: Subprocess, intent: KillIntent): void;
	commandExtensions(): string[];
}
