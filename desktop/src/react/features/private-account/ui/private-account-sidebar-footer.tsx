import type { PrivateAccountStateDto } from "@remotecode/contracts";
import QRCode from "qrcode";
import { useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";

import {
	createPrivateAccountApiClient,
	type PrivateAccountApiClient,
	PrivateAccountApiError,
} from "../api/private-account-api";

export const serializePrivateAccountQrPayload = (state: PrivateAccountStateDto): string | null => {
	if (!state.qrPayload) {
		return null;
	}

	return JSON.stringify(state.qrPayload);
};

export const getPrivateAccountStatusLabel = (state: PrivateAccountStateDto | null): string => {
	if (!state?.authenticated) {
		return "Sign in";
	}

	switch (state.connectorRelayState) {
		case "connected":
			return "Relay online";
		case "connecting":
			return "Relay connecting";
		case "error":
			return "Relay error";
		case "disconnected":
			return "Relay offline";
		default:
			return "Account ready";
	}
};

export const loadPrivateAccountState = async (
	client: PrivateAccountApiClient,
): Promise<PrivateAccountStateDto> => await client.getState();

export const runPrivateAccountAuthAction = async (input: {
	client: PrivateAccountApiClient;
	email: string;
	mode: "login" | "register";
	password: string;
}): Promise<PrivateAccountStateDto> =>
	input.mode === "login"
		? await input.client.login({
			email: input.email,
			password: input.password,
		})
		: await input.client.register({
			email: input.email,
			password: input.password,
		});

export const buildPrivateAccountQrDataUrl = async (input: {
	createQrDataUrl: (value: string) => Promise<string>;
	state: PrivateAccountStateDto;
}): Promise<string | null> => {
	const payload = serializePrivateAccountQrPayload(input.state);
	if (!payload) {
		return null;
	}

	return await input.createQrDataUrl(payload);
};

const defaultState: PrivateAccountStateDto = {
	authenticated: false,
	connector: null,
	connectorRelayState: "idle",
	errorMessage: null,
	qrPayload: null,
	user: null,
};

export const PrivateAccountSidebarFooter = ({
	client = createPrivateAccountApiClient(),
	createQrDataUrl = async (value: string) => await QRCode.toDataURL(value, { margin: 1, width: 256 }),
}: {
	client?: PrivateAccountApiClient;
	createQrDataUrl?: (value: string) => Promise<string>;
}) => {
	const [state, setState] = useState<PrivateAccountStateDto>(defaultState);
	const [email, setEmail] = useState("");
	const [errorMessage, setErrorMessage] = useState<string | null>(null);
	const [isLoading, setIsLoading] = useState(true);
	const [isModalOpen, setIsModalOpen] = useState(false);
	const [isSubmitting, setIsSubmitting] = useState(false);
	const [mode, setMode] = useState<"login" | "register">("login");
	const [password, setPassword] = useState("");
	const [qrDataUrl, setQrDataUrl] = useState<string | null>(null);

	useEffect(() => {
		let cancelled = false;
		void (async () => {
			try {
				const nextState = await loadPrivateAccountState(client);
				if (!cancelled) {
					setState(nextState);
					setErrorMessage(nextState.errorMessage);
				}
			} catch (error) {
				if (!cancelled) {
					setErrorMessage(error instanceof Error ? error.message : "Unable to load private account.");
				}
			} finally {
				if (!cancelled) {
					setIsLoading(false);
				}
			}
		})();

		return () => {
			cancelled = true;
		};
	}, [client]);

	useEffect(() => {
		const payload = serializePrivateAccountQrPayload(state);
		if (!payload) {
			setQrDataUrl(null);
			return;
		}

		let cancelled = false;
		void (async () => {
			try {
				const nextQrDataUrl = await buildPrivateAccountQrDataUrl({
					createQrDataUrl,
					state,
				});
				if (!cancelled) {
					setQrDataUrl(nextQrDataUrl);
				}
			} catch {
				if (!cancelled) {
					setQrDataUrl(null);
				}
			}
		})();

		return () => {
			cancelled = true;
		};
	}, [createQrDataUrl, state]);

	const statusLabel = useMemo(() => getPrivateAccountStatusLabel(state), [state]);

	const submit = async () => {
		setIsSubmitting(true);
		setErrorMessage(null);

		try {
			const nextState = await runPrivateAccountAuthAction({
				client,
				email,
				mode,
				password,
			});
			setState(nextState);
			setErrorMessage(nextState.errorMessage);
			setIsModalOpen(false);
			setPassword("");
		} catch (error) {
			setErrorMessage(
				error instanceof PrivateAccountApiError || error instanceof Error
					? error.message
					: "Unable to authenticate private account.",
			);
		} finally {
			setIsSubmitting(false);
		}
	};

	const logout = async () => {
		setIsSubmitting(true);
		setErrorMessage(null);
		try {
			const nextState = await client.logout();
			setState(nextState);
			setErrorMessage(nextState.errorMessage);
			setIsModalOpen(false);
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to sign out.");
		} finally {
			setIsSubmitting(false);
		}
	};

	return (
		<div className="mt-3 border-t border-white/10 pt-3" data-testid="private-account-sidebar-footer">
			{state.authenticated ? (
				<div className="mb-3 rounded-2xl border border-white/10 bg-black/20 p-3 text-slate-100" data-testid="private-account-connector-card">
					<div className="flex items-start justify-between gap-3">
						<div className="min-w-0">
							<p className="text-[11px] uppercase tracking-[0.14em] text-slate-400">Private Connector</p>
							<p className="truncate text-sm font-semibold text-slate-100">
								{state.connector?.name ?? state.qrPayload?.connectorName ?? "Desktop Connector"}
							</p>
							<p className="text-xs text-slate-300">{statusLabel}</p>
						</div>
						{qrDataUrl ? (
							<img
								alt="Private connect QR"
								className="h-20 w-20 rounded-lg border border-white/10 bg-white p-1"
								src={qrDataUrl}
							/>
						) : (
							<div className="flex h-20 w-20 items-center justify-center rounded-lg border border-dashed border-white/15 text-[11px] text-slate-400">
								QR
							</div>
						)}
					</div>
				</div>
			) : null}

			<button
				className="flex w-full items-center justify-between rounded-2xl border border-white/10 bg-white/[0.04] px-3 py-3 text-left transition hover:bg-white/[0.08]"
				onClick={() => {
					setIsModalOpen(true);
				}}
				type="button"
			>
				<span>
					<span className="block text-[11px] uppercase tracking-[0.14em] text-slate-400">Account</span>
					<span className="block text-sm font-semibold text-slate-100">
						{state.user?.email ?? "Log in or register"}
					</span>
				</span>
				<span className="text-xs text-slate-300">{isLoading ? "Loading..." : statusLabel}</span>
			</button>

			{errorMessage ? (
				<p className="mt-2 text-xs text-rose-200" data-testid="private-account-error">
					{errorMessage}
				</p>
			) : null}

			{isModalOpen && typeof document !== "undefined"
				? createPortal(
					<div
						aria-label="Private account modal"
						aria-modal="true"
						className="fixed inset-0 z-40 flex items-end justify-center bg-black/55 p-4"
						role="dialog"
					>
						<div className="w-full max-w-md rounded-3xl border border-white/10 bg-[#141824] p-4 shadow-[0_20px_60px_rgba(0,0,0,0.45)]">
						<div className="mb-4 flex items-center justify-between gap-3">
							<div>
								<p className="text-[11px] uppercase tracking-[0.16em] text-slate-400">Private Account</p>
								<h3 className="text-lg font-semibold text-slate-100">
									{state.authenticated ? "Account connected" : mode === "login" ? "Log in" : "Register"}
								</h3>
							</div>
							<button
								className="rounded-full border border-white/10 px-3 py-1.5 text-xs text-slate-300 transition hover:bg-white/[0.06]"
								onClick={() => {
									setIsModalOpen(false);
								}}
								type="button"
							>
								Close
							</button>
						</div>

						{state.authenticated ? (
							<div className="space-y-3">
								<div className="rounded-2xl border border-white/10 bg-white/[0.03] p-3">
									<p className="text-xs text-slate-400">Signed in as</p>
									<p className="text-sm font-semibold text-slate-100">{state.user?.email}</p>
									<p className="mt-1 text-xs text-slate-300">{statusLabel}</p>
								</div>
								<button
									className="w-full rounded-2xl bg-rose-400 px-3 py-2.5 text-sm font-semibold text-[#24080f] transition hover:bg-rose-300 disabled:opacity-60"
									disabled={isSubmitting}
									onClick={() => {
										void logout();
									}}
									type="button"
								>
									{isSubmitting ? "Signing out..." : "Log out"}
								</button>
							</div>
						) : (
							<div className="space-y-3">
								<div className="flex gap-2 rounded-2xl border border-white/10 bg-white/[0.03] p-1">
									<button
										className={`flex-1 rounded-xl px-3 py-2 text-sm font-medium transition ${
											mode === "login" ? "bg-sky-300 text-slate-950" : "text-slate-300 hover:bg-white/[0.06]"
										}`}
										onClick={() => {
											setMode("login");
										}}
										type="button"
									>
										Log in
									</button>
									<button
										className={`flex-1 rounded-xl px-3 py-2 text-sm font-medium transition ${
											mode === "register" ? "bg-sky-300 text-slate-950" : "text-slate-300 hover:bg-white/[0.06]"
										}`}
										onClick={() => {
											setMode("register");
										}}
										type="button"
									>
										Register
									</button>
								</div>
								<label className="block text-xs text-slate-300">
									Email
									<input
										className="mt-1.5 w-full rounded-2xl border border-white/10 bg-white/[0.03] px-3 py-2.5 text-sm text-slate-100 outline-none"
										onChange={(event) => {
											setEmail(event.currentTarget.value);
										}}
										placeholder="dev@example.com"
										type="email"
										value={email}
									/>
								</label>
								<label className="block text-xs text-slate-300">
									Password
									<input
										className="mt-1.5 w-full rounded-2xl border border-white/10 bg-white/[0.03] px-3 py-2.5 text-sm text-slate-100 outline-none"
										onChange={(event) => {
											setPassword(event.currentTarget.value);
										}}
										placeholder="••••••••"
										type="password"
										value={password}
									/>
								</label>
								<button
									className="w-full rounded-2xl bg-sky-300 px-3 py-2.5 text-sm font-semibold text-slate-950 transition hover:bg-sky-200 disabled:opacity-60"
									disabled={isSubmitting || email.trim().length === 0 || password.trim().length === 0}
									onClick={() => {
										void submit();
									}}
									type="button"
								>
									{isSubmitting ? "Working..." : mode === "login" ? "Log in" : "Register"}
								</button>
							</div>
						)}
						</div>
					</div>,
					document.body,
				)
				: null}
		</div>
	);
};
