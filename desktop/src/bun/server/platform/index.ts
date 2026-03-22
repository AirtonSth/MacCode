import type { KillIntent, PlatformModule, Subprocess } from "./types";

import * as darwin from "./darwin";
import * as linux from "./linux";
import * as win32 from "./win32";

const platforms: Record<string, PlatformModule> = { darwin, linux, win32 };
const current: PlatformModule = platforms[process.platform] ?? linux;

export const resolveShell: PlatformModule["resolveShell"] = () => current.resolveShell();

export const buildShellArgs: PlatformModule["buildShellArgs"] = (shell, command) =>
	current.buildShellArgs(shell, command);

export const killProcess: PlatformModule["killProcess"] = (subprocess: Subprocess, intent: KillIntent) =>
	current.killProcess(subprocess, intent);

export const commandExtensions: PlatformModule["commandExtensions"] = () => current.commandExtensions();

export { collectResolvedPath, mergePathEntries, resolveCommand, resolveCommandInPath } from "./command";
export type { KillIntent, PlatformModule, Subprocess } from "./types";
