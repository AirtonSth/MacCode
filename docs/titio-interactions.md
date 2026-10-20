# Titio interaction map

Titio is the conversational control center for MacCode. A request can combine the
families below; follow-ups keep the verified workspace, Bot and conversation.
This is a map of supported interaction families, not a finite list of sentences.
External services require an available provider integration, skill or Bot.

The current operating contract is injected into every Titio run, including
scheduled runs and existing profiles with a custom soul. `rc_host_help` exposes
this map to the model. A topic supplies the host workflow and parameter guidance;
the index lists admitted host methods. Mutations use the existing host controls,
permissions, persistence and mirroring.

| Family | Examples the user can say | Execution and verification |
| --- | --- | --- |
| Activity | “O que está acontecendo agora?”, “O que precisa de mim no elephant?”, “Por que falhou?” | Read canonical Activity, counts, summaries, errors and open decisions. Follow pagination for a complete list; read the source thread for details. |
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
3. **Global overview:** call `rc_activity_list`, summarize canonical running,
   queued, needs-user and finished/failed activity by workspace and Bot, and use
   the returned summaries/errors and exact notice options. Follow the Activity
   cursor when the user requests all entries.

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
