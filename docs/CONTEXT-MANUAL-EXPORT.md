# Manual contextual excerpt export

## Delivered boundary

`bot.conversation.export.preview` and `bot.conversation.export` provide an explicit, text-only export to the authenticated human client's response. They export selected user/assistant excerpts, with role labels, rather than generating an AI summary or copying the conversation's entire history. The response identifies the source and intended destination context for the same stable Bot on the same host.

This checkpoint does not import into the destination, create its conversation/session, enqueue or run anything, or copy operational memory, provider state, cookies, files or attachments. Continuing in another context still requires a separate canonical conversation and explicit human action. Public contextual execution remains blocked by the outstanding runtime probes. No view, layout or automatic export workflow is added.

## Request and review

Both methods require `host_id`, `bot_id`, `context_key`, `context_version`, `policy_revision`, `conversation_id`, `target_context_key`, `target_policy_revision` and `message_ids`. The common context contract version applies to both versioned context keys. The paired host replaces a caller-declared host identity. Missing or unknown fields cannot infer a grant or selected conversation.

Preview returns only the selected messages' IDs, roles and text, a plain-text `summary`, source/destination metadata and `selection_sha256`. It is authorized disclosure to the human client for review, not delivery to another context's runtime. Source `read` and `export` grants must both be current; the intended destination must independently have a current `send` grant. The exact source conversation pin, locked Bot thread, host, context and policy revision must match.

Confirmation adds the strict Boolean `approved: true` and the preview's `selection_sha256`. The hash binds the selected IDs, actual current text and roles, host/Bot/conversation and both contexts/revisions. A changed selection, edited message, destination or stale policy invalidates approval. The digest is a freshness check, not a capability: every request rechecks current authority and data in the same SQLite transaction.

Selections contain 1–32 distinct message IDs and at most 65,536 UTF-8 text bytes. Membership in the exact source thread is checked before text is loaded. System messages, guessed IDs, foreign-context IDs, duplicate UUID aliases, attachments and unselected messages cannot be included. Limits reject rather than silently truncate content.

## Authentication, freshness and privacy

These are fresh reads, not replayable mutations. They require an authenticated paired principal with the `read` device capability; `write` alone is insufficient. The existing trusted-local HTTP fallback and the provider/Unix entry are refused. The methods remain outside the read-only batch allowlist, so approval cannot be folded into an automatic batch.

Exported content never enters the host mutation ledger, Bot receipt/claim sidecars or the iOS mutation ledger. Reusing the same JSON-RPC ID after revocation cannot replay an earlier private response. RPC HTTP responses carry `Cache-Control: no-store`. Revocation prevents subsequent responses; it cannot erase a copy already intentionally disclosed to an authorized client.

The iOS client registers the methods in its finite read-only catalog and forwards the review parameters through the existing session. Human approval is an explicit protocol input, not a claim that a human usability trial or a new native confirmation screen was delivered.

## Scope of proof

The host tests call the actual `AppContext`, application router, authority and SQLite repositories; the positive preview/confirmation and authentication/capability cases use a real loopback HTTP listener. The fixture bearer resolver is synthetic and does not use personal credentials or establish production pairing, LAN/TLS or physical-device proof. Other cases call the shipped dispatcher directly to isolate guessed-resource, stale-review and grant checks.

The iOS tests use the actual session and an empty mutation ledger with a recording transport. They establish forwarding and absence of mutation replay records, not a live iOS-to-host connection. Existing UI design guidance is unchanged because no view implementation is touched. Destination import, full contextual execution/delegation, OAuth, capacity, complete accessibility/usability and rollout remain open in the eight-stage matrix.

## Recorded checks

At exact macOS Sources/Tests tree `8385d3d66a7079f80e049923e3e8af60c6c86f7a`, 144 selected native tests passed with zero failures/skips in 34.302 seconds (exit 0). This includes real HTTP preview/confirmation, missing/invalid bearer and read/write device capability separation, source/target revocation, regrant, guessed resources, wrong-thread and system selections, edited content, strict approval, unchanged row counts, no mutation receipts, exact 32/33-message and 65,536/65,537-byte boundaries, and existing HTTP/queue/receipt regressions.

```sh
RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1 RC_CONTEXT_PROBE_ROOT=<caller-owned> scripts/isolated-sandbox.sh test --build-system native --filter 'BotContextExportTests|BotContextPublicQueueTests|BotContextAuthorityTests|BotConversationContextTests|BotContextDispatcherTests|HTTPServerTests|HybridHTTPWebSocketContractTests|Phase4MutationReceiptContractTests'
```

At exact iOS App/Tests tree `ab1a8b7ed9659fddc4c05ed4fcb945001c131abe`, 21 `ConnectionPhaseFourCatalogTests` passed with zero failures in 9.301 seconds (exit 0), using `xcodebuild test -project RemoteCode2App.xcodeproj -scheme RemoteCode2App -destination 'platform=iOS Simulator,id=CC8AB099-51D6-4AD7-95A2-EB006C80705C' -derivedDataPath .build-dd -parallel-testing-enabled NO -only-testing:RemoteCode2AppTests/ConnectionPhaseFourCatalogTests`. The existing simulator was retained. The client forwards the caller's host field unchanged; authenticated host replacement is proven by the actual macOS listener, not the recording transport.

Independent source review `01a14a16-bef1-74d0-bfae-3981b7bb2446` found a read/write device-capability classification mismatch. Explicit read classification without batch admission and real read-only/write-only bearer cases resolved it before publication. Follow-up review `01a14a1d-b4f6-7642-b504-98eb0cea35b0` closed that finding with no remaining concrete objection. Both reviews were source-only, not independent test executions. Initial missing-try, fixture permission and client-host-expectation failures are not counted as passing evidence.

Native signed macOS packaging passed from the tested source with `RC2_SWIFT_BUILD_SYSTEM=native scripts/isolated-sandbox.sh build` (exit 0); codesign reported the bundle valid. Executable SHA-256: `6b8ee26c16a3a2411d1777284e59205d6c88ebe8399e13616392f882f1ec63f8`. AppContext fixture logs can contain Live Activity warnings; this run does not prove Live Activity durability. No production host, personal database or credentials were used for export fixtures.

This checkpoint does not add a durable per-export audit receipt. The plan's general decision/cleanup auditing requirement, destination import and native export/review controls remain open; private response bodies deliberately stay out of mutation replay storage.
