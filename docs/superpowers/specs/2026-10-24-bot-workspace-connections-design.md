# MacCode: teams, workspace links, connections and a clean chat

Status: concrete proposal for review; no product implementation yet.
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

**Proposed default (builder's call): association is not exclusive ownership.**
For the requested setup, associate existing Tech Lead, QA and Engineer with the
existing airtours workspace using canonical context grants. Skip already-active
unchanged grants; do not increment policy revisions unnecessarily. Existing
conversation pins, bot IDs, histories, skills, schedules and destinations stay
unchanged. Show the scope/access explicitly in the manager.

For the existing general VM airtours, add a durable workspace association
separate from immutable VM ownership, retaining UUID, Docker storage namespace,
files, applications and browser sessions. General shared machines remain marked
Shared; linking them must not imply that data is isolated from previous users.
Do not weaken BotVirtualMachine.allows or reinterpret an ownership field just
to display a sidebar row. Existing exclusive workspace VMs retain their access
rules; incompatible links are refused with an explanation.

Use one canonical host/store operation per association with revision/conflict
checks, events and readback. Unlinking removes that association rather than the
resource. Context revocation follows the existing cancellation/revocation path;
a running task is not silently moved or given another runtime. Changing bot or
VM exclusive ownership is a distinct future operation, not implicit in linking.
The association catalog itself does not mount another directory, start a VM,
change a bot's execution destination or grant a connection to a bot.

Apply the named airtours associations only after the new behavior is tested,
resolving exact IDs and checking current associations first. No name-only writes.

Existing constraints: BotDefinition.workspaceID is exclusive legacy ownership;
context grants are different. saveVirtualMachine currently rejects ownership
changes. A dedicated additive association store avoids corrupting these rules.

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

This request asks to find an approach: first deliver the validated integration
design and catalog/gateway plan; do not purchase a service, create external apps,
or claim a live Composio connection before credentials and real calls are tested.
Generic MCP and the Composio adapter can then be implemented as separate slices.

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

## Explicit unresolved decisions

The owner may prefer exclusive ownership rather than non-exclusive association;
that changes migration and runtime-safety work materially. The proposal above
chooses association to avoid silently restricting current workflows. Composio
live setup needs an owner project key and each service's consent; neither is
assumed present. No external credential has been requested or read in this design.
