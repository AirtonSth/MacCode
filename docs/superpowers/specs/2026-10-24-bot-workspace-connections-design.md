# MacCode: teams, workspace links, connections and a clean chat

Status: approved 2026-10-24; user explicitly chose exclusive airtours ownership and authorized implementation, testing, review and push for all four points.
Base: AirtonSth/MacCode commit 285ab2c9. Reference: OpenMausBot UI inspected
on the user's Mac on 2026-10-24 and the user's MacCode screenshot.

## Intent

Make MacCode comfortable as the daily home for existing bots and project work.
The four requested outcomes are: visible team conversations, easy association of
existing bots/VMs with workspaces, app-owned service connections independent of
LLM, and a clean chat when opening a bot. Preserve identities, history, files,
current destinations and existing access unless the owner explicitly changes it.

## 1. Left navigation and teams

Add a first-class Group chats section to the main sidebar. List non-hidden group
conversations, pinned first then most recently active. Show group title, up to
three participant avatars, unread/attention state and active work. Opening a row
uses the existing group room and orchestrator, not a new transcript or execution
system. Selection and collapsed sections survive reopening the app.

Expose New group and Manage teams in that section. Teams show their existing
members and allow adding/removing existing bots. A team and a group conversation
remain distinct: changing membership does not silently rewrite a group's
participants or historical messages. Existing policies (mentions, lead, all and
bounded automatic hops) remain available in group details. Surface Stop and
failures honestly; do not claim a collective job succeeded until the run does.

Bot conversation history belongs under expandable bot rows in the left
navigation, rather than requiring a permanent second wide history column.
Workspace-linked bots can appear under their workspace; the same bot ID and
conversation selection must be retained across navigation entry points.

Existing seams: SidebarView.swift, BotsTeamsGroups.swift,
BotTeamsGroupsController, BotTeamGroupService and BotStore+Groups.swift.

## 2. Associate existing resources with workspaces

In a workspace menu, add Manage bots and VMs with lists of existing resources,
search, current associations and an Add existing action. Offer the same action
from each resource's context menu. Do not clone a bot, create a VM or rebuild a
container merely to organize it.

**Approved policy: exclusive workspace ownership.** The owner selected “Tornar exclusivos do airtours”. Add explicit transactional ownership-transfer operations for existing bots and VMs. Preserve IDs, histories, skills, schedules, VM UUID/storage/files and existing immutable conversation pins. Use compare-and-set revision/source-scope checks; do not silently rewrite thread or schedule destinations. Grant the destination context through the canonical authority path only when needed. Reject a transfer that would invalidate other bots, historical thread destinations or schedule overrides, explaining affected records. Coordinate with VM resource maintenance claims so starts/running/queued/user-controlled work cannot race a scope move. Do not silently stop or redirect unrelated work. Existing additional grants require explicit coherent policy handling; exclusivity is not merely sidebar grouping.

Add workspace “Attach existing bots…” and “Attach existing VM…” actions and resource “Move to workspace…” controls. These are existing-only selections, not resource duplication or rebuild. After isolated verification, resolve exact IDs and attach the named Tech Lead/QA/Engineer and airtours VM to airtours using the canonical operations. Remove the earlier non-exclusive association proposal; no cosmetic association table is needed for this approved delivery.

## 3. Connections owned by MacCode

Provide a separate Connections destination; Accounts & Auto remains LLM login
and routing. Desired model: connect a service once to MacCode, then choose which
bots/workspaces/tasks can use it, independently of Claude/Codex/Grok/Distill.

Use an app-owned ConnectionStore, an app-scoped Keychain secret store and a
ConnectionBroker. Connection types are remote MCP, local stdio MCP and Composio.
Display service/account/status/access and actions to connect, reconnect, test or
disconnect. Do not show secrets, export a global key into agent environments or
reuse the bot-secret environment injector for this purpose.

Expose admitted tools through a common MCP facade with per-run capabilities,
revocation, bounded concurrency and redacted diagnostics. Integrate Claude CLI,
Claude SDK, both Codex launch paths, Grok ACP, Distill host and Distill guest.
Resume and scheduled tasks use the same connection identity and current grants;
removing a grant must prevent subsequent tool calls. Unsupported provider/runtime
combinations show unavailable, never a false connected state. Read-only connection
metadata can be mirrored to iOS; secret reads and service execution stay host-side.

Composio is a candidate backend, not a replacement for generic MCP support.
For a personal local pilot, use the owner's Composio project key stored in the
app Keychain and hosted OAuth Connect Links for supported services. Real OAuth
consent or missing keys are explicit setup steps. A distributed app with a
shared developer key requires a backend; no shared key embedded in the app.
Persist stable user/account IDs and scoped sessions, handle expiration, and never
blindly retry a service write after an ambiguous response.

The owner now requires all four points implemented and tested. Deliver working generic MCP management and provider-independent admission in this change, with real fixture tools/list and tools/call verification. Support Composio as a hosted MCP connection without requiring it as the only backend. Do not purchase services, create external apps or claim third-party OAuth is connected without a real credential/consent test.

Official sources checked on 2026-10-24:
- https://docs.composio.dev/docs/sessions-via-mcp
- https://docs.composio.dev/docs/authentication
- https://docs.composio.dev/docs/authentication/custom-app-vs-managed-app
- https://docs.composio.dev/docs/production-readiness

## 4. Clean bot chat

Opening a bot presents one wide central conversation with a compact identity
header and composer. History is available in the left navigation. Desktop,
schedules, tools and technical details are behind labeled buttons/drawers.
Default drawers/history panels are closed for first-time clean-chat users; an
explicit per-user preference to reopen a panel is persisted. Existing drafts,
selected conversations, attachments, quoted replies and streaming must survive
layout/navigation changes. Do not show another bot's conversation during loads.

Use existing DS tokens and shared Agent App/Bot Desk/Schedule Tasks controls.
Collapse routine tool progress into expandable activity; errors and required
approvals stay visible. Replace persistent permission explanation banners with
an accessible compact status plus details, retaining actual Full Access state
and the switch to supervised mode. Errors may be compacted but never concealed.
Keep model/effort/account/execution choices discoverable in the composer without
making them dominate the conversation. No removal of capabilities to get a
cleaner screenshot. Responsive layout uses a single chat column at narrow widths
and a readable bounded text width on wide screens.

Existing seams: BotsWindow.swift, shared composer chrome and Agent App timeline,
MainWindowController layout and persistent pane visibility. Groups use the same
chat layout primitives, without forcing the bot's desktop into the group room.

## Delivery and verification

1. Implement sidebar/group navigation and clean-chat layout together.
2. Implement safe associations, then apply the requested airtours links.
3. Deliver the provider-independent connection design, then implement/test the
   generic gateway and optional Composio adapter in separately reviewable slices.

Each implementation slice includes meaningful regression tests and isolated
native UI checks. Validate narrow/wide layouts, persistence across relaunch,
rapid bot/group/workspace switches, errors, active runs and access revocation.
Use temporary fixtures in the debug profile before touching real associations.
All changes occur in the linked worktree; the installed app stays available.
Do not repeat the known-failing entire suite without a reason. Report targeted
results and unrelated failures separately. Build, review and push the approved
changes to the owner's fork; replace the daily installed app only after relevant
checks and native verification, with backup and the original updater disabled.

## Approved execution

Exclusive workspace ownership is approved. The user said to continue until all four points work, are tested and pushed to the fork. No further routine design/plan approval is needed. A missing external credential or human-only sign-in remains a genuine blocker only for that live integration; generic MCP can be implemented and tested with an owned fixture.

Implemented transport compatibility: stdio and Streamable HTTP using the legacy MCP initialize handshake, negotiating 2024-11-05, 2025-03-26, 2025-06-18 or 2025-11-25. Unsupported negotiated versions fail closed. The newer 2026 protocol is not supported by this client. Discovery accepts at most 64 pages and 10,000 tools; service actions are never retried automatically.
