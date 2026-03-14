import type { PrivateAccountStateDto } from "@remotecode/contracts";
import { useCallback, useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";

import {
	createPrivateAccountApiClient,
	type PrivateAccountApiClient,
	PrivateAccountApiError,
} from "../api/private-account-api";

export const isPrivateAccountSubscribed = (state: PrivateAccountStateDto | null): boolean =>
	Boolean(state?.user?.subscribed);

export const getPrivateAccountStatusLabel = (state: PrivateAccountStateDto | null): string => {
	if (!state?.authenticated) {
		return "Sign in";
	}

	if (!isPrivateAccountSubscribed(state)) {
		return "Subscription required";
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

export const runPrivateAccountLoginAction = async (input: {
	client: PrivateAccountApiClient;
	email: string;
	password: string;
}): Promise<PrivateAccountStateDto> =>
	await input.client.login({
		email: input.email,
		password: input.password,
	});

const defaultState: PrivateAccountStateDto = {
	authenticated: false,
	connector: null,
	connectorRelayState: "idle",
	errorMessage: null,
	user: null,
};

const defaultClient = createPrivateAccountApiClient();

export const PrivateAccountSidebarFooter = ({
	client = defaultClient,
	openExternalUrl = async (url: string): Promise<void> => {
		globalThis.open(url, "_blank", "noopener,noreferrer");
	},
}: {
	client?: PrivateAccountApiClient;
	openExternalUrl?: (url: string) => Promise<void>;
}) => {
	const [state, setState] = useState<PrivateAccountStateDto>(defaultState);
	const [email, setEmail] = useState("");
	const [errorMessage, setErrorMessage] = useState<string | null>(null);
	const [isModalOpen, setIsModalOpen] = useState(false);
	const [isSubmitting, setIsSubmitting] = useState(false);
	const [password, setPassword] = useState("");
	const [toastMessage, setToastMessage] = useState<string | null>(null);

	const refreshState = useCallback(async (): Promise<void> => {
		const nextState = await loadPrivateAccountState(client);
		setState(nextState);
		setErrorMessage(nextState.errorMessage);
	}, [client]);

	useEffect(() => {
		let cancelled = false;
		void refreshState().catch((error) => {
			if (!cancelled) {
				setErrorMessage(error instanceof Error ? error.message : "Unable to load private account.");
			}
		});

		return () => {
			cancelled = true;
		};
	}, [refreshState]);

	useEffect(() => {
		if (!state.authenticated) {
			return;
		}

		const refreshIntervalMs = isModalOpen ? 5_000 : 60_000;
		const interval = globalThis.setInterval(() => {
			void refreshState().catch(() => undefined);
		}, refreshIntervalMs);

		return () => {
			globalThis.clearInterval(interval);
		};
	}, [isModalOpen, refreshState, state.authenticated]);

	useEffect(() => {
		if (!errorMessage) {
			setToastMessage(null);
			return;
		}

		setToastMessage(errorMessage);
		const timeout = globalThis.setTimeout(() => {
			setToastMessage((current) => (current === errorMessage ? null : current));
		}, 4500);

		return () => {
			globalThis.clearTimeout(timeout);
		};
	}, [errorMessage]);

	const statusLabel = useMemo(() => getPrivateAccountStatusLabel(state), [state]);
	const isSubscribed = useMemo(() => isPrivateAccountSubscribed(state), [state]);
	const daysRemaining = state.user?.daysRemaining ?? state.user?.daysRemaing ?? 0;

	const openModal = useCallback(() => {
		setIsModalOpen(true);
		void refreshState().catch(() => undefined);
	}, [refreshState]);

	const openBrowserRegister = useCallback(async (): Promise<void> => {
		setIsSubmitting(true);
		setErrorMessage(null);
		try {
			const response = await client.browserRegister({
				...(email.trim() ? { email: email.trim() } : {}),
			});
			await openExternalUrl(response.url);
			setIsModalOpen(false);
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to open registration.");
		} finally {
			setIsSubmitting(false);
		}
	}, [client, email, openExternalUrl]);

	const openBrowserForgotPassword = useCallback(async (): Promise<void> => {
		setIsSubmitting(true);
		setErrorMessage(null);
		try {
			const response = await client.browserForgotPassword({
				...(email.trim() ? { email: email.trim() } : {}),
			});
			await openExternalUrl(response.url);
			setIsModalOpen(false);
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to open password recovery.");
		} finally {
			setIsSubmitting(false);
		}
	}, [client, email, openExternalUrl]);

	const openBrowserManageSubscription = useCallback(async (): Promise<void> => {
		setIsSubmitting(true);
		setErrorMessage(null);
		try {
			const response = await client.browserManageSubscription();
			await openExternalUrl(response.url);
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to open subscription management.");
		} finally {
			setIsSubmitting(false);
		}
	}, [client, openExternalUrl]);

	const submit = async () => {
		setIsSubmitting(true);
		setErrorMessage(null);

		try {
			const nextState = await runPrivateAccountLoginAction({
				client,
				email,
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
				isSubscribed ? (
					<button
						className="mb-3 block w-full rounded-2xl border border-white/10 bg-black/20 p-3 text-left text-slate-100 transition hover:border-white/20 hover:bg-black/30"
						data-testid="private-account-connector-card"
						onClick={openModal}
						type="button"
					>
						<div className="flex items-start justify-between gap-3">
				<div className="min-w-0">
						<p className="text-[11px] uppercase tracking-[0.14em] text-slate-400">Private Connector</p>
						<p className="truncate text-sm font-semibold text-slate-100">
							{state.connector?.name ?? "Desktop Connector"}
						</p>
						<p className="text-xs text-slate-300">{statusLabel}</p>
					</div>
					</div>
				</button>
				) : (
					<div
						className="mb-3 rounded-2xl border border-amber-300/20 bg-[linear-gradient(135deg,rgba(250,204,21,0.15),rgba(249,115,22,0.08))] p-3 text-slate-100"
						data-testid="private-account-subscribe-card"
					>
						<p className="text-[11px] uppercase tracking-[0.14em] text-amber-200/80">Private Access</p>
						<p className="mt-1 text-sm font-semibold text-amber-50">Unlock mobile pairing and connector sync</p>
						<p className="mt-1 text-xs text-amber-100/80">
							Your account is signed in but does not have an active subscription.
						</p>
						<a
							className="mt-3 inline-flex rounded-full bg-amber-200 px-3 py-1.5 text-xs font-semibold text-[#2b1906] transition hover:bg-amber-100"
							data-testid="private-account-subscribe-link"
							href="#manage-subscription"
							onClick={(event) => {
								event.preventDefault();
								void openBrowserManageSubscription();
							}}
							rel="noreferrer"
							target="_blank"
						>
							Manage subscription
						</a>
					</div>
				)
			) : null}

			<button
				className="flex w-full items-center justify-between rounded-2xl border border-white/10 bg-white/[0.04] px-3 py-3 text-left transition hover:bg-white/[0.08]"
				onClick={openModal}
				type="button"
			>
				<span>
					<span className="block text-[11px] uppercase tracking-[0.14em] text-slate-400">Account</span>
					<span className="block text-sm font-semibold text-slate-100">
						{state.user?.email ?? "Log in"}
					</span>
				</span>
			</button>

			{errorMessage ? (
				<p
					aria-live="polite"
					className="mt-2 text-xs text-rose-200"
					data-testid="private-account-error"
					role="alert"
				>
					{errorMessage}
				</p>
			) : null}

			{toastMessage && typeof document !== "undefined"
				? createPortal(
					<div
						aria-live="assertive"
						className="fixed bottom-4 right-4 z-50 max-w-sm rounded-2xl border border-rose-300/30 bg-[#30131a] px-4 py-3 text-sm text-rose-100 shadow-[0_18px_50px_rgba(0,0,0,0.35)]"
						data-testid="private-account-toast"
						role="alert"
					>
						<div className="flex items-start gap-3">
							<div className="min-w-0 flex-1">
								<p className="font-semibold text-rose-50">Private account</p>
								<p className="mt-1 text-rose-100/90">{toastMessage}</p>
							</div>
							<button
								className="rounded-full border border-rose-200/20 px-2 py-0.5 text-xs text-rose-100/80 transition hover:bg-white/10"
								onClick={() => {
									setToastMessage(null);
								}}
								type="button"
							>
								Close
							</button>
						</div>
					</div>,
					document.body,
				)
				: null}

			{isModalOpen && typeof document !== "undefined"
				? createPortal(
					<div
						aria-label="Private account modal"
						aria-modal="true"
						className="fixed inset-0 z-40 flex items-end justify-center bg-black/55 p-4"
						role="dialog"
					>
						<div className="w-full max-w-lg rounded-3xl border border-white/10 bg-[#141824] p-4 shadow-[0_20px_60px_rgba(0,0,0,0.45)]">
						<div className="mb-4 flex items-center justify-between gap-3">
							<div>
								<p className="text-[11px] uppercase tracking-[0.16em] text-slate-400">Private Account</p>
								<h3 className="text-lg font-semibold text-slate-100">
									{state.authenticated ? "Account connected" : "Log in"}
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
									<div className="mt-3 flex flex-wrap items-center gap-2">
										<span
											className={`rounded-full px-2.5 py-1 text-[11px] font-semibold ${
												isSubscribed
													? "bg-emerald-400/15 text-emerald-200"
													: "bg-amber-300/15 text-amber-200"
											}`}
										>
											{isSubscribed ? "Subscribed" : "Subscription inactive"}
										</span>
										<span className="text-[11px] text-slate-400">
											{daysRemaining} days remaining
										</span>
									</div>
								</div>
					{isSubscribed ? (
						<div className="rounded-2xl border border-white/10 bg-[linear-gradient(180deg,rgba(255,255,255,0.05),rgba(255,255,255,0.02))] p-4">
							<div className="mb-3 flex items-center justify-between gap-3">
								<div>
									<p className="text-[11px] uppercase tracking-[0.16em] text-slate-400">Private Connector</p>
									<p className="text-sm text-slate-200">Relay is connected to your desktop account.</p>
								</div>
							</div>
							<p className="text-sm text-slate-200">
								Relay remains available while the desktop stays signed in.
							</p>
						</div>
					) : (
						<div className="rounded-2xl border border-amber-300/20 bg-[linear-gradient(135deg,rgba(250,204,21,0.15),rgba(249,115,22,0.08))] p-4">
							<p className="text-[11px] uppercase tracking-[0.16em] text-amber-200/80">Subscription</p>
							<h4 className="mt-1 text-base font-semibold text-amber-50">Activate private access</h4>
							<p className="mt-2 text-sm leading-6 text-amber-100/80">
								Subscribe to unlock mobile sync and relay management.
							</p>
										<a
											className="mt-4 inline-flex rounded-full bg-amber-200 px-3 py-2 text-sm font-semibold text-[#2b1906] transition hover:bg-amber-100"
											href="#manage-subscription"
											onClick={(event) => {
												event.preventDefault();
												void openBrowserManageSubscription();
											}}
											rel="noreferrer"
											target="_blank"
										>
											Manage subscription
										</a>
									</div>
								)}
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
									{isSubmitting ? "Working..." : "Log in"}
								</button>
								<div className="flex flex-wrap items-center justify-between gap-3 text-xs text-slate-300">
									<button
										className="rounded-full border border-white/10 px-3 py-1.5 transition hover:bg-white/[0.06]"
										disabled={isSubmitting}
										onClick={() => {
											void openBrowserForgotPassword();
										}}
										type="button"
									>
										Forgot password
									</button>
									<button
										className="rounded-full border border-white/10 px-3 py-1.5 transition hover:bg-white/[0.06]"
										disabled={isSubmitting}
										onClick={() => {
											void openBrowserRegister();
										}}
										type="button"
									>
										Register in browser
									</button>
								</div>
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
