# Codex-like Pre-Final Streaming UX TODO

## Scope
- [ ] Implement Codex-app-style UX for pre-final-message events only.
- [ ] Keep final assistant message rendering unchanged.

## Behavioral Parity Targets
- [ ] Use item-based streaming state instead of append-only text.
- [ ] Update status lines in-place (replace/substitute), not append-only.
- [ ] Support collapsible tool/event rows with running/completed transitions.
- [ ] Auto-expand running tool rows after 2000ms when appropriate.
- [ ] Collapse completed tool rows after preview window of 200ms.
- [ ] Add active thinking shimmer with stepped animation (steps(48, end)).
- [ ] Respect prefers-reduced-motion by disabling shimmer/extra motion.

## Backend Protocol
- [ ] Add `assistant_event` to WebSocket protocol with typed payloads.
- [ ] Implement event types: `turn_started`, `item_started`, `item_delta`, `item_state`, `item_completed`, `turn_completed`.
- [ ] Map provider stream into stable `turnId` + `itemId` lifecycle events.
- [ ] Keep legacy `assistant_delta` fallback while migration path exists.

## Frontend State
- [ ] Add `streamTurnsByChat` model to workspace store.
- [ ] Add reducers/actions for all `assistant_event` types.
- [ ] Ensure `item_delta` appends only to target fields.
- [ ] Ensure `item_state`/`item_completed` update existing rows in-place.
- [ ] Keep legacy fallback rendering when structured events are unavailable.

## Frontend UI
- [ ] Build `StreamingTimeline` component for pre-final events.
- [ ] Build row components for reasoning/tool/plan/assistant streaming items.
- [ ] Implement summary substitution in same row based on state changes.
- [ ] Implement expand/collapse interactions with manual override behavior.
- [ ] Keep row layout concise when collapsed and informative when expanded.

## Accessibility and Motion
- [ ] Implement shimmer class for active thinking/running labels.
- [ ] Add reduced-motion fallbacks for shimmer and collapse transitions.
- [ ] Verify keyboard accessibility for expand/collapse controls.

## Tests
- [ ] Backend unit tests for event mapping/order/deduplication.
- [ ] Frontend reducer tests for in-place updates vs append behavior.
- [ ] Timer tests for 2000ms expand and 200ms collapse logic.
- [ ] Integration test for full stream lifecycle until final assistant message.
- [ ] Visual/manual QA for parity with expected Codex behavior.

## Cleanup
- [ ] Remove dead append-only streaming branches after validation.
- [ ] Document the new stream event contract in internal docs.
- [ ] Capture screenshots/gifs for regression reference.
