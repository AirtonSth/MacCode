# Titio interaction map

Titio is the conversational control center for MacCode. A request can combine the
families below; follow-ups keep the verified workspace, Bot and conversation.
This is a map of supported interaction families, not a finite list of sentences.
External services require an available provider integration, skill or Bot.

The current operating contract is injected into every Titio run, including
scheduled runs and existing profiles with a custom soul. `rc_host_help` exposes
this map to the model. A topic supplies the host workflow and parameter guidance;
`query` searches the index and `method` returns the current admission requirements
and related workflows. Requirements are derived from host validation and are not
a complete schema of optional domain fields. The index lists admitted host
methods. Mutations use the existing host controls, permissions, persistence and
mirroring.

| Family | Examples the user can say | Execution and verification |
| --- | --- | --- |
| Activity | “O que está acontecendo agora?”, “O que precisa de mim no elephant?”, “Por que falhou?” | Read filtered canonical Activity, counts, summaries and errors. Request `include_context:true` for open decisions and the full inventory. Follow pagination for a complete list; read the source thread for details. |
| Workspaces and layout | “Abra o elephant”, “Crie um workspace para esta pasta”, “Abra o navegador ao lado do terminal” | Resolve exact workspace and surface IDs; create, select, rename, pin, split, move or close through host APIs; read back the layout. |
| Bots | “Crie um revisor”, “Mude as instruções do XPTO”, “Desative as notificações dele” | Inspect the Bot, update the requested identity/settings, and read back. Workspace grants use the current policy revision. |
| Delegation and queues | “Mande o Bot XPTO limpar o repositório do elephant”, “Continue naquela conversa”, “Cancele o próximo envio” | Find the Bot and authorized conversation; send to that exact conversation, then inspect its run. Ambiguous names fail without starting work. Queue acceptance is distinct from completion. |
| Routines and schedules | “No elephant faça a rotina de pegar a tarefa do Linear”, “Execute a próxima tarefa”, “Faça isso toda manhã”, “Pause a rotina noturna” | List workspace tasks **and** Bot routines. A named routine resolves by owner and title/prompt and runs by its exact ID. Inspect scheduling and run receipts; running once does not enable recurrence. |
| Notifications and decisions | “O que o Developer precisa?”, “Aprove essa solicitação”, “Responda staging”, “Entendi” | Read the stored notice and indexed options. Forward only the user's explicit choice or answer to the exact source. Acknowledgement closes the question without another message, model call, rerun or delegation. |
| Agent conversations | “Comece isso no elephant”, “Pare essa execução”, “Continue”, “Implemente o plano”, “Mostre o checkpoint” | Create/read/configure the actual thread; send, stop, continue, manage follow-ups and inspect plans/checkpoints through host controls. Preserve routing and require authorization before discarding work. |
| Files | “Leia este arquivo”, “Crie um README no elephant”, “Mostre o relatório”, “Renomeie este arquivo” | Resolve the workspace and path, inspect existing content, edit using provider tools or revision-aware host sessions, then read back. Bot file access keeps its handles and concurrency guards. |
| Git and delivery | “O que mudou?”, “Crie uma branch”, “Faça o commit”, “Abra um PR”, “Já foi publicado?” | Inspect status/diff before mutation. Use the host delivery flow or available integration; distinguish local tests, push, PR, CI and deployment evidence. |
| Browser | “Abra o localhost do elephant”, “O que aparece na página?”, “Tire um screenshot”, “Preencha este campo” | Resolve the browser surface; use current snapshots/refs and host navigation. Canonical URLs remain mirrored to iOS, including localhost and file URLs. Bot browsers remain separate. |
| Terminal and SSH | “Rode os testes”, “Inicie o servidor”, “O que está nesse terminal?”, “Conecte ao servidor salvo” | Prefer registered project scripts; otherwise target the exact terminal. Read output and health afterwards. Use existing SSH profiles and the app's privilege helper. |
| Models, accounts and settings | “Quais modelos estão disponíveis?”, “Quanto de quota resta?”, “Mude o modelo desta conversa”, “Mude o idioma do Titio” | Query current supported values, preserve other fields, change the requested setting and read back. Schedule settings change only when the user asks to change future runs. |
| Teams and groups | “Crie um time”, “Peça ao Developer e ao QA para discutir isso”, “Adicione o Writer”, “Pare a discussão” | Resolve participants, create/update the team or group with its current revision, send with a stable submission key, then inspect the group's progress. |
| Desktop automation and handoffs | “Use este aplicativo”, “Automatize este site”, “Terminei o login, continue” | Prefer direct service/host tools; use the available browser/computer tools for other apps. Observe the exact session, honor human takeover, and report missing authentication or OS permissions. |
| Memory, skills and integrations | “Lembre deste fluxo”, “Esqueça esta preferência”, “Ensine esta rotina ao XPTO”, “Pegue uma tarefa do Linear” | Use the relevant Bot's memory/skills and available service connections. Reuse a requested routine; otherwise perform the authorized work through the provider or an appropriate Bot. Report missing authentication or capability explicitly. |

## The three primary flows

1. **Named workspace routine:** resolve `elephant`, call `scheduled_task.list`,
   match the requested routine in `tasks` or `bot_tasks`, then use
   `scheduled_task.run` or `bot.routine.run` with its exact ID. “Pick a Linear
   task” is not a request to run whichever schedule happens next.
2. **Delegate repository work:** resolve XPTO and the workspace, inspect its
   context bindings/conversations, then call `rc_bot_delegate` or `rc_bot_send`
   with the exact `conversation_id`. The normal send path enforces the current
   grant. Read the returned thread/run before reporting the outcome.
3. **Global overview:** call `rc_activity_list` with the relevant filters and
   summarize canonical running, queued, needs-user and finished/failed activity
   by workspace and Bot. Use `include_context:true` for exact notice options.
   Follow the Activity cursor when the user requests all entries.

## Automation audit (2026-10-21)

The discoverable host surface contains **270 methods** across 18 namespaces:
192 mutations with host receipts, 74 reads, and four thread fork/side-question
commands. This counts callable controls, not every possible sentence or every
control in an external application. `rc_host_help` is the live inventory.

| Request or bottleneck | Finding and current behavior |
| --- | --- |
| “Continue todas as conversas interrompidas” | The RPC previously sent an empty prompt and recorded an empty user message. It now follows the saved-session recovery path, sends a provider-only continuation instruction and preserves the user transcript. Active or unrecoverable threads fail explicitly. |
| Several independent actions | `rc_host_batch` submits up to 20 calls in one model/tool round trip. Each has an independent `operation_id`, authorization check, receipt and result/error. A failed action does not hide or cancel the others; cancelled batches do not start remaining calls. |
| Finding only interrupted, failed or workspace-specific work | `rc_activity_list` accepts Activity's section, outcome, workspace, search, time and pagination filters. Its default response contains the canonical page; `include_context:true` opts into the larger inventory and notice decisions. |
| Discovering an unfamiliar command | Help can search method names and workflows, or return the chosen method's current validation requirements. Titio does not need to repeatedly fetch the whole index or guess required identifiers. |
| Inspecting state in supervised mode | Known read-only `rc_host_call` and batches work in supervised mode. Mutations still require the authenticated run's captured Full Access permission. Other Bots cannot use these cross-object tools. |
| Creating/editing a Bot in Schedule Tasks | The shared save route accepts a Bot owner as well as a workspace owner, and forwards the authenticated host and receipt identity to Bot scheduling. Replays do not create duplicate routines. |
| Waiting unnecessarily for another conversation on the same VM | The guide now matches the VM registry: independent conversations can run concurrently; exclusive rebuild/stop operations block them. Shared files/browser sessions still need coordination. |
| Manual actions, moving execution to the Mac, guest input | The guide exposes the existing handoff/resolve and guest controls, including required identities and fresh frame evidence. User decisions and human takeover remain authoritative. |
| Browser and run-setting mistakes | The guide distinguishes workspace browser actions from the Bot browser's navigation/login API, names the current Distill modes, and documents Bot routing fields that must be preserved. |

For the interruption example, Titio should:

1. Read `rc_activity_list` with `section:"needs_you"`, `outcome:"interrupted"`
   and `limit:500`, plus the user's workspace filter if provided.
2. Collect all pages before starting work, deduplicate `thread_id`, and exclude
   its own thread and work superseded by a newer active run.
3. Call `rc_host_batch` with independent `agent.run.continue` calls and a stable,
   distinct `operation_id` per thread. Repeat for additional groups of 20.
4. Read those exact threads/runs and report started work and individual failures.
   An accepted run is not a completed task. Missing saved context requires
   inspecting the original conversation before proposing a new message.

A batch contains independent, already resolved calls. Creation followed by use
of a returned ID stays sequential. The four `agent.thread.fork`,
`agent.thread.side`, `agent.thread.side.close` and `agent.thread.btw` commands do
not have the shared mutation-receipt contract and are excluded from batches;
inspect their outcome before retrying a lost response.

External desktop/web automation uses the provider's installed computer/browser
or service tools. Authentication, native OS permissions, missing integrations
and controls without a host API remain real capability limits; this change does
not promise every arbitrary action will work. Provider selection of tools from
natural language requires live-model verification separately from host tests.

## Questions behave as messages

Each notice card renders only under its original message. When that message is
collapsed into earlier history, its question collapses too; expanding history
shows unresolved questions in their original position. There is no duplicate
stack below the current turn. macOS and iOS follow the same rule.

“Entendi” selects only the stored acknowledgement action. The host removes that
question and acknowledges its source attention item; it creates no user or
assistant turn and invokes no writer/provider. Repeating the acknowledgement is
silent. Other pending questions remain stored and available through Activity
and the original messages.

Open decisions remain available to Titio after intervening user messages, with
the source IDs and exact indexed options. Titio can relay a decision the user
already made; it must never invent an approval or treat notification text as
authorization.

Titio's replies, notices, questions, labels and action results are generated in
the client's current language. A failed or incomplete generation never inserts
canned dialogue: notices remain pending for retry, with their original source
alerts retained. Generated redacted push text survives a restart.

New contextual conversations honor the Bot's Mac/Docker desktop selection.
Ordinary user sends repair older conversations incorrectly marked for a VM
when the Bot is local, retaining the context grant and transferring transcript
history through the existing Mac handoff. Explicit internal isolated admissions
keep their VM contract; revoked context grants still reject sends.

## Operational boundaries

- Real names, IDs, options and current state come from host reads. Duplicate
  names require disambiguation; a refused contextual send is not retried in a
  general conversation.
- `bot.conversation.enqueue` is a legacy paused-draft API. Its
  `execution_available:false` / `requires_user_send:true` response is not proof
  of execution. Actual delegation uses the normal host Bot send path.
- Accepted, queued, running, completed and failed are separate outcomes. A
  remote action still enforces its normal permissions and availability.
- External services are not new native integrations. Linear, Git hosting, CI,
  deployments and messaging depend on the connected provider tools/skills.
- Automated coverage exercises host handlers, persisted state, scheduling,
  prompt compilation and the message/card presentation. It does not prove that
  every natural-language variation will select the right tools on a live model,
  or that an external Linear task was executed.
