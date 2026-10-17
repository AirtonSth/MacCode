# Context resolver integration checkpoint

This checkpoint proves the macOS contextual resolver's actual provider-start path reaches scoped runtime preparation, then refuses model launch and cleans up. It does not enable contextual provider execution. Public router and Bots window gates are unchanged; restricted mode and public contextual provider admission remain unavailable. There is no Mac fallback, and the resolver never returns a guest launch plan for a pinned thread.

## Actual path

`AppContext.coordinator.startRun` enters the real Distill ACP adapter's `openSession`, which invokes the wired Bot guest run resolver. For a pinned thread, that resolver invokes `BotContextGuestResources.prepare` with `secretStore: nil`, then provisions through the scoped guest service. This is runtime-only preparation: no gateway, keychain, provider credentials, or configuration/environment staging. After preparation, the resources are cancelled/stopped and the resolver throws the same model-unavailable error. Cancellation/revocation failure does not turn this into model admission.

Public routing and Bots window admission gates remain unchanged. A native public send after wipe still rejects and creates no runtime. Pinned threads do not fall through to the legacy Mac session path.

## Bounded verification

At exact macOS tree `7fb5689c72a95fb5ec9e31b7ee05218f64149961`, the combined isolated native run passed **43 tests, 0 skips, 0 failures, 43.591 seconds, exit 0**. It comprised 37 legacy resolver tests, 3 resource cases, 1 SDK A/B case, 1 revocation race, and 1 gateway probe. The run included the real Docker A/B test with the same Bot across two workspace file markers, distinct operational homes, and distinct networks. The provider executable marker remained absent; marker inspection ran as the configured guest user.

The real blocked-image-stage/native-RPC-revocation test observed pending cleanup journal while image preparation was blocked, then required an ended journal and stopped runtime. Late cancellation of an older preparation followed by a new owner was exercised against real Docker; the old completion did not stop the new owner's runtime. After the negative admission gate, the test resumed only through the scoped service for read-only marker inspection, never to start a model. Existing full-gateway and concurrent other-context cleanup regressions also passed. A separate earlier A/B run and pre-fix unit run are historical, not final proof.

Reviewer `01a14825-072a-7441-8eb2-7911a71605b3` closed the P1 revoke-before-create race and reported no new material finding. The fix serializes live publication and full resource preparation per operation; failure cancels/stops resources, and late cancellation uses atomic owner reclamation so it cannot stop a newer generation. Docker 29.4.0 aarch64 used pre-existing image `sha256:b3c068f7d076bbd8d87cac8a5e15955eda4730c5483c80b96f4a7987045299d2`, label 7; no pull was requested. Fixture cleanup and assertions covered runtime/network/root cleanup and absence of provider environment staging. The personal host, personal database, existing containers, and existing image were preserved.

## Limits

This is not proof of full provider-credential, network, or browser isolation; native public model execution; UI/accessibility; or completion of all S005/S006 requirements. Native package build succeeded from the same tested tree. The debug app passed code-signature verification with team `6SV3W8BFYJ`; executable SHA-256 is `54b91795ff4ea35618bda1d5133c95aa51d7f5e6669acf4091cf1bd5d470d9c3`. Docker image identity and recipe label remained unchanged after the tests and build. Existing UI and the 21 skill ledgers remain unchanged.

The combined log also contains Live Activity durable-acceptance I/O diagnostics during teardown of legacy `BotGuestRunResolverTests` fixtures. No such diagnostic was attributed to the new contextual cases. These diagnostics did not fail XCTest, but this run is not evidence of Live Activity durability or a clean end-to-end activity lifecycle. Those broader conditions remain pending.
