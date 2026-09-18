# checklist.md — loop de melhoria contínua RemoteCode (branch `improve-sep-17`)

Worktree: `/Users/samuelfajreldines/dev/remote-code/macos-app/.worktrees/improve-sep-17`
Branch: `improve-sep-17` (a partir de `origin/production` @ `e7fb6371`)
Build/test: `scripts/isolated-sandbox.sh test [--filter …]` (bundle `io.remotecode.desktop.debug`, porta 18218, App Support próprio).
O RemoteCode do dono (`io.remotecode.desktop`) nunca é tocado: sem `pkill`, sem `run-app.sh`, sem bundle estável.

Regras de método já em vigor (AGENTS.md + TODO.md §Regras):

- Testes: `swift test` completo **não** é verde na base. Toda rodada precisa de baseline-diff, não de "passou".
- Toda medição de peso/DB é **read-only** (`sqlite3 "file:$DB?mode=ro"`); a amostra live desta iter foi feita assim.
- Um commit por item, mensagem no padrão do repo, MR atualizado com "Antes / Depois".

## Iteração 1 — 2026-09-17

### Escopo auditado

1. **Estado fixo do loop**: worktree + branch criados, MR aberto, checklist.
2. **Peso de disco / retenção do SQLite** (eixo novo, não coberto pelo TODO.md de 2026-09-14): auditoria tabela-a-tabela do banco vivo (read-only) + leitura dos caminhos de retenção (`LocalStorageBudget`, `agent_turn_checkpoints`).
3. **Varredura de code-smells** em `Sources/`: alocação de formatter por chamada, `performSync` no main, polling, force-unwraps/`fatalError` — sem achado novo relevante (formatters já são estáticos/cacheados; ver "Sem achado novo" abaixo).

### Evidência medida (banco vivo do dono, read-only, 2026-09-17)

`~/Library/Application Support/RemoteCode/remotecode.sqlite` — arquivo 1,4 GB; `dbstat` somando tabelas:

| Tabela | MB | Observação |
|---|---|---|
| `agent_turn_checkpoints` | **201** | maior tabela do banco; sem retenção por idade |
| `token_saver_recovery_objects` (+índices) | 188 + 15 | tem `retention_days` por lane |
| `agent_provider_event_logs` | 66 | 30 dias (runs terminais) |
| `agent_stream_events` | 50 | 30 dias (runs terminais) |
| `terminal_output_chunks` | 12 | |
| livre (`freelist_count` = 219.228 páginas) | ~898 | não é crescimento: páginas livres são reutilizadas |

Dentro de `agent_turn_checkpoints` (1.285 linhas, 2026-06-16 → 2026-09-17):

| Coluna | MB |
|---|---|
| `file_snapshots_json` | **176** |
| `diff_patch` | 8 |
| `file_diffs_json` | 11 |
| `files_json` | 1 |
| `files_summary_json` | 0 |

Distribuição do tamanho de `file_snapshots_json`: 958 linhas <10 KB (0 MB), 56 linhas 10-100 KB (3 MB), 205 linhas 100-500 KB (55 MB), **66 linhas >500 KB (117 MB — 66% de tudo)**; pior linha = 5,5 MB.

### Item corrigido (maior valor / menor escopo)

**CKPT-BUDGET · P1 · peso — o snapshot de checkpoint não tinha orçamento por turno.**

- Antes: `captureFileSnapshots` tinha só o cap **por arquivo** (`checkpointSnapshotByteCap` = 1 MiB). Um turno que mexesse em vários arquivos de texto grandes escrevia linhas de multi-MiB (pior caso medido: 5,5 MB numa linha; 66 linhas >500 KB = 117 MB).
- Depois: orçamento **por checkpoint** (`checkpointSnapshotTotalByteCap` = 1 MiB de bytes crus; o JSON base64 é ~4/3 disso). Arquivo que não cabe no que sobrou cai no mesmo marker nil-content que já existe para binário/grande — o restore continua, via HEAD — e o log passa a registrar `budget_remaining`. Arquivos menores depois de um grande ainda são snapshottados.
- Arquivos: `Sources/AgentRuntime/AgentRunCoordinator.swift` (constante + `checkpointSnapshotBudgetDecision` + fold no `captureFileSnapshots`), `Tests/AgentRuntimeTests/CheckpointSnapshotDecisionTests.swift` (7 testes novos).

**Antes / Depois (projeção sobre as 1.285 linhas reais, mesmo workload):**

| Métrica | Antes | Depois | Ganho |
|---|---|---|---|
| `file_snapshots_json` total | 176,3 MB | 120,7 MB | **−55,6 MB (−31,5%)** |
| Tabela `agent_turn_checkpoints` | 201 MB | ~145 MB | −28% |
| Pior linha single-turn | 5,5 MB | ≤1,4 MB | −75% |
| Linhas afetadas | — | 23/1.285 (1,8%) | perdem snapshot exato só além do 1º MiB |

Trade-off explícito: nos 1,8% de turnos gigantes, arquivos além do orçamento passam a restaurar de HEAD em vez de conteúdo exato — exatamente o comportamento que já existe hoje para arquivos >1 MiB e binários.

### Status por área (auditoria contínua)

| Área / fluxo | Arquivos-chave | Status |
|---|---|---|
| Retenção e peso do SQLite | `Persistence/LocalStorageBudget.swift`, `Schema.swift`, `Repositories.swift` | auditado; CKPT-BUDGET corrigido; 3 pendências abertas abaixo |
| Snapshot de checkpoint (captura/restore) | `AgentRuntime/AgentRunCoordinator.swift`, `CheckpointRevertUndo.swift` | auditado + corrigido nesta iter |
| Agent App (transcript por frame/delta) | `Surfaces/AgentAppSurface.swift` | auditado em TODO.md 2026-09-14; sem item novo aqui |
| Bots Desk | `AppShell/BotsWindow.swift`, `BotsDeskFollowThrough.swift` | auditado em TODO.md; itens P2 deferidos (falta amostra) |
| EventBus / fan-out | `SocketServer/EventBus.swift` | auditado em TODO.md; `publishAsync` deferido sem evidência |
| Formatters/alocação em hot path | `Sources/**` (39 sites `DateFormatter`, 81 `JSONDecoder`) | 47 sites são estáticos/cacheados ou benchmark DEBUG; sem regressão nova |
| `performSync`/polling na UI | `Surfaces/`, `AppShell/` | 3 usos em Surfaces; polling com intervalos ≥1 s documentados; sem achado novo |
| Plan notes por thread | `Surfaces/AgentAppSurface.swift` (`planNotes*`), `Persistence/PlanNotesStore.swift` | **BUG corrigido na iter 2** (vazamento entre threads) |
| Buffer de uso do Graphify (`graphifyItemBuffers`) | `AppShell/AppContext.swift` | **crescimento sem limite corrigido na iter 38** (entrada de run interrompido era eterna; ~16,4 KiB cada) |

### Skills (twostraws/Swift-Agent-Skills)

Lista curada conferida contra os diretórios de skills (`~/.claude/skills`, `~/.grok/skills`): SwiftUI Pro, SwiftData Pro, Swift Concurrency Pro, Swift Testing Pro, SwiftUI UI Patterns / View Refactor / Design Principles, SwiftData Expert, Swift Testing Expert, Swift Architecture, Swift API Design Guidelines, Swift Security, Swift Format Style, Focus Engine, Core Data, iOS Accessibility (+ auditores), ios-simulator, figma-to-swiftui, Widgets, App Intents, Background Execution, App Store (ASO + `asc-*`), appstore-review — todas instaladas.

**Instalado nesta iteração:** `observability` (`n0an/Observability-Agent-Skill`, a entrada mais nova da lista curada) em `~/.claude/skills/observability` e `~/.grok/skills/observability`.

### Pendências / backlog (próximas iterações)

1. ~~**Plan notes vazam entre threads**~~ — **corrigido na iteração 2** (ver abaixo).
2. **Captura de checkpoint em turno completo** — `AgentRuntimeTests.FakeRunnerTests.test_coordinatorCapturesCheckpointSummaryForCompletedTurn` falha no HEAD (idêntico antes/depois da mudança da iter 1): summary `missing` em vez de `ready` e "checkpoint rows must keep per-file diff patches". Investigar antes de mexer em snapshot de novo.
3. **`CheckpointRevertUndoToastTests` (2) e `ProviderSnapshotRuntimeTests` (1)** falham no HEAD — mesmo conjunto antes/depois da iter 1.
4. **`AgentThreadDeletionUndoTests.test_deleteAndUndoIncludesTerminalForkIntentWithoutRetainingDeletedTranscript`** falha no HEAD e no branch (confirmado por stash em 2026-09-17, iter 2): o undo restaura o fork intent mas `sourceMessages` volta `[]` em vez de `["private source transcript"]`. Perda de dados no undo de delete de um source com fork terminal — alto valor, escopo a medir (`AgentThreadRepository` / snapshot de delete).
5. **`AgentAppViewModelTests` derruba o processo de teste** (`Fatal error: Unexpectedly found nil` em `Tests/SurfacesTests/AgentAppViewModelTests.swift:8428`, force-unwrap de `vm.latestProposedPlan` após `selectThread`) no HEAD e no branch: o runner aborta com signal 5 e o resto da suíte não roda. Suspeita de regressão real (plano proposto não reidratado ao abrir thread) — alto valor, próxima iteração.
6. **`token_saver_attempt_events` / `token_saver_attempts` / `token_saver_input_components` sem retenção** (EV-28): nenhum `DELETE` no código; hoje 0 linhas no banco do dono (Token Saver inativo), cresce só com o recurso ligado.
7. **`agent_turn_checkpoints` sem retenção por idade**: 201 MB, 1.285 linhas de 3 meses. Decisão de produto (apagar checkpoint antigo remove rewind antigo) — **não** fazer sem o dono decidir.
8. **`agent_turn_checkpoints` fora do `LocalStorageBudget`**: a maior tabela do banco não aparece em `usage()`/snapshot de armazenamento — falta de visibilidade, não de correção.
9. Demais itens abertos do `TODO.md` (PL-05, AA-30, BT-29, EV-26, EV-27, EV-28, EV-30) — todos deferidos com motivo no próprio arquivo; dois deles (AA-30, EV-30) já estão parcialmente implementados no código atual e merecem re-checagem antes de virar trabalho.

### Baseline de testes (HEAD `e7fb6371`, antes de qualquer mudança)

`scripts/isolated-sandbox.sh test --filter PersistenceTests` → 919 testes, **8 falhas pré-existentes** (nenhuma introduzida por esta iter):

`PlanNotesPersistenceTests.test_planNotes_persistAndRestoreOnThreadSwitch`, `PlanNotesPersistenceTests.test_planNotes_twoThreadsIndependent`, `RetentionCapTests.test_heavySession_allRetentionCapsTogetherBoundTheDatabase`, `RoutingConfigPreservingThreadProbeTests.test_setRoutingConfiguration_fasterThanGetAndUpsert`, `SchemaMigrationMatrixTests.test_headOriginBaselineWas71AndV72Rejects…`, `SchemaMigrationMatrixTests.test_v81ToV82IndexesAuditLogActionIdForReceiptSignatureReads`, `StreamBatchAtomicPersistenceTests.test_stopCannotOvertakeTerminalWaitingForDurabilityBarrier` (+1 do mesmo filtro).

### Baseline-diff da mudança desta iteração (`--filter Checkpoint`, mesma máquina e mesmo workload)

| Rodada | Falhas |
|---|---|
| HEAD `e7fb6371` (arquivos revertidos no mesmo worktree, build quente) | 4 métodos: `FakeRunnerTests.test_coordinatorCapturesCheckpointSummaryForCompletedTurn`, `FakeRunnerTests.test_coordinatorRecordsMissingCheckpointWhenWorkspaceIsNotGit` (flaky), `ProviderSnapshotRuntimeTests.test_minimalCheckpointUpsertFailurePublishesOneNilIdentityAndNeedsAttention`, `CheckpointRevertUndoToastTests.test_revertSelectedCheckpoint_armsUndoToast`, `CheckpointRevertUndoToastTests.test_undoLastCheckpointRevert_restoresAndClearsToast` |
| branch `improve-sep-17` (`01edf71c`) | os mesmos, **menos** o flaky `test_coordinatorRecordsMissingCheckpointWhenWorkspaceIsNotGit` |

`CheckpointSnapshotDecisionTests`: 16 testes, 0 falhas (9 pré-existentes + 7 novos) nas duas rodadas — os 7 novos só existem no branch.

## Iteração 2 — 2026-09-17

### Escopo auditado

1. **Estado fixo do loop**: worktree/branch/MR `!382` já existiam da iter 1; skills confirmadas instaladas (nenhuma nova entrada na lista curada do twostraws nesta rodada).
2. **Plan notes por thread** (pendência 1 da iter 1, dois testes falhando no HEAD desde 2026-06-10): diagnóstico → correção.
3. **Regressão de espelho macOS↔iOS de plan notes** (`agent.plan.notes.updated`): contratos reconferidos na suíte do AppShell.

### Item corrigido: PLAN-NOTES-BLEED · P1 · correção de dados

Diagnóstico (falha real, reproduzida no sandbox antes da mudança):

- `selectThread` **nunca repontava** `planNotes` na troca de thread. O valor só mudava quando o *open bundle* assíncrono chegava (`applyThreadOpenBundle`), 1+ frame depois. Entre o clique e a hidratação o painel de plano do thread B mostrava as notas do thread A.
- Consequência de dados: o editor persiste a cada mudança (`.onChange(of: vm.planNotes) { vm.savePlanNotes() }`) e `savePlanNotes()` grava sob o `selectedThreadId` **atual**. Texto de A visível em B vira, no primeiro caractere digitado, conteúdo de B — a corrupção descrita pelo teste "saving beta notes must not overwrite alpha notes".
- Não havia cache: nada para publicar no turno do clique (regra de percepção: primeiro feedback ≤100 ms) e leitura síncrona de SQLite no clique é proibida (perf AA-02 já tinha movido essas leituras para o open bundle).

Correção (menor escopo — 1 arquivo de produção + testes):

- `planNotesByThread: [AgentThreadID: String]` no `AgentAppViewModel`: último valor conhecido por thread, escrito na hidratação bem-sucedida, no save local e no espelho do host (`applyMirroredPlanNotes` passa pelo mesmo publisher).
- `selectThread` (só o caminho de troca real, não o soft reselect) publica `planNotesByThread[id] ?? ""` no mesmo turno, usando o mecanismo `ignoredPlanNotesSave` que já existe para não ecoar o `onChange` como save/evento de espelho.
- Leitura que falha (`bundle.planNotesFailed`) continua publicando `""` + status, mas **não** entra no cache: valor desconhecido nunca vira "notas vazias" na próxima troca.
- Evicção: `planNotesByThread` entrou em `cachedThreadIDs()`/`evictThreadCaches` (F9), então deletar thread não deixa resíduo no tab.

### Antes / Depois

| Métrica | Antes | Depois |
|---|---|---|
| `--filter PlanNotes` (52 testes) | 2 falhas | **0 falhas** |
| Notas ao clicar em B com A aberto | notas de A até a hidratação (1+ frame) | notas de B (cache) ou `""` no mesmo turno |
| Gravar notas de A sob a chave de B | possível na janela clique→hidratação | eliminado — o editor já mostra o texto do thread correto |
| Cache miss (app relançado) | — | `""` até o open bundle; hidratação publica o valor durável do SQLite |
| Leituras de DB no turno do clique | 0 (mantido) | 0 (mantido) |
| Eventos de espelho extras por troca | 0 | 0 (`ignoredPlanNotesSave` suprime) |

### Testes

- 2 falhas históricas agora verdes: `PlanNotesPersistenceTests.test_planNotes_persistAndRestoreOnThreadSwitch`, `.test_planNotes_twoThreadsIndependent`.
- 2 novos: `test_planNotes_coldSurfaceHydratesDurableNotesAndWarmSwitchPublishesThem` (relançamento: `""` → hidratação → valor durável → troca quente publica do cache), `test_planNotes_deleteEvictsCachedNotesForThatThread` (delete não deixa resíduo de cache).
- Espelho realtime intacto: `--filter 'PlanNotesPersistenceTests|AgentSurfaceThreadBindingRouterTests'` → **41 testes, 0 falhas** (inclui os 3 contratos de plan notes do router: exatamente 1 evento por save local, sem eco do remoto).

### Baseline-diff do batch VM/rail (mesma máquina, mesmo workload)

`--filter 'AgentAppViewModelTests|AgentWorkspaceRailReloadCoordinatorTests|AgentAutoRoutingViewModelTests'`:

| Rodada | Resultado |
|---|---|
| HEAD (mudança em stash) | 10 falhas + crash do processo (`Fatal error` em `AgentAppViewModelTests.swift:8428`, signal 5) |
| branch `improve-sep-17` (iter 2) | **exatamente as mesmas 10 falhas + o mesmo crash** — nada introduzido |

Falhas pré-existentes do batch: `test_authErrorRetryWaitsForAuthenticatedSnapshotBeforeResending`, `test_defaultCommandMakesNextProviderRunUseDefaultInteractionMode`, `test_failedPendingCallbackResponsesBecomeStaleAndNonActionable`, `test_implementLatestPlanDoesNotPublishImplementedStateWhenPersistenceFails`, `test_implementLatestPlanStartsRunAndMarksPlanTraceability`, `test_queuedFollowupStaysOutOfTranscriptAndClearsActivePlan`, `test_queueLifecycleEvents_cacheOnlyLocalPreRailOwnershipAcrossReloadFailures`, `test_rejectLatestPlanStartsAPlanRevisionWithoutMarkingImplementation`, `test_reloadThreadsBackfillsPlaceholderTitleFromFirstUserMessage`, `test_runningStatusCallbackReflectsCoordinatorClearedUnreadIndicator`.

Outras rodadas desta iteração: `--filter PlanNotes` (52/0), `--filter 'PlanNotesPersistenceTests|AgentThreadDeletionUndoTests'` (22 testes, 1 falha pré-existente — ver backlog 4), `--filter 'PlanNotesPersistenceTests|AgentSurfaceThreadBindingRouterTests'` (41/0).

## Iteração 3 — 2026-09-17

Método: `/sam-goal` (precedência exclusiva no turno — sam-task/sam-orchestrate ficam como contexto). Nenhuma entrada nova na lista curada de skills nesta rodada.

### Escopo auditado

1. **Crash de processo em `AgentAppViewModelTests.swift:8428`** (pendência 5 da iter 1) — prioridade (a) do loop: o `xctest` abortava com signal 5 e todo filtro que nomeasse o arquivo perdia as suítes seguintes.
2. **Gap do ritual LFS** — `scripts/isolated-sandbox.sh ensure` não materializava os objetos LFS (obrigatório desta iteração).
3. **Follow-up durante o start do provider** — apareceu ao destravar o arquivo (item 3.3); contrato já escrito em teste.

### Item 3.1 — CRASH-FIX · P1 · force-unwrap matava o processo de teste

Diagnóstico (baseline medido antes da mudança):

- `--filter test_saveLatestProposedPlanWritesMarkdownFile` → `Tests/SurfacesTests/AgentAppViewModelTests.swift:8428: Fatal error: Unexpectedly found nil while unwrapping an Optional value` + `exited with unexpected signal code 5`, `EXIT=1`.
- Causa: o full-open (`selectThread` → `hydrateOpenedThread` → `gatherThreadOpenBundle` em `Task.detached`, perf AA-02/SEP-3) lê o plano durável **fora da main** e o aplica quando o bundle chega. O teste lia `vm.latestProposedPlan!` no mesmo turno do `selectThread` — nil por construção, e o force-unwrap derrubava o processo inteiro.
- Mesma causa em 3 specs irmãs: `implementLatestPlan`/`rejectLatestPlan` fazem `guard let plan = latestProposedPlan else { return }` (`AgentAppSurface.swift:8599`, `:8622`), então sem hidratação a ação virava no-op (`test_implementLatestPlanStartsRunAndMarksPlanTraceability`, `test_implementLatestPlanDoesNotPublishImplementedStateWhenPersistenceFails`, `test_rejectLatestPlanStartsAPlanRevisionWithoutMarkingImplementation`).

Correção (só teste; nenhum arquivo de produção tocado):

- `await vm.waitForSelectThreadHydrationForTesting()` — costura que os outros specs de thread-open já usavam (7718/7792/7806/7842) — nos 4 specs.
- `try XCTUnwrap(vm.latestProposedPlan)` no lugar do force-unwrap: uma regressão futura falha **um** teste em vez de matar o processo e esconder o resto do arquivo.

Antes / Depois:

| Rodada | Antes | Depois |
|---|---|---|
| `--filter test_saveLatestProposedPlanWritesMarkdownFile` | crash do processo, signal 5, EXIT=1 | passa (0.310 s) |
| `--filter <os 4 specs>` | 1 crash + 3 falhas | **4 testes, 0 falhas**, EXIT=0 |

### Item 3.2 — LFS-RITUAL · P1 · `ensure` devolvia worktree com ponteiros de 133 B

Causa raiz medida: o `.git/config` **local do repo** (compartilhado por todos os worktrees) instala LFS com `--skip-smudge` e vence o global `~/.gitconfig`:

```
filter.lfs.smudge   git-lfs smudge --skip -- %f        (local > global)
filter.lfs.process  git-lfs filter-process --skip
filter.lfs.required false
```

Como o escopo local vence o global, **todo** checkout — inclusive `git worktree add` — escreve o ponteiro de 133 B no lugar de `Vendor/*.xcframework/*.a`. Reproduzido: worktree novo → `Vendor/TailcatBridge/Artifacts/RCTailcat.xcframework/macos-arm64/libRCTailcat.a` = **133 B**.

Correção em `scripts/isolated-sandbox.sh` (33 linhas, 4 pontos de chamada):

- `lfs_pointer_paths()`: lista os arquivos rastreados por LFS e devolve só os que ainda são ponteiro (64 B de header por arquivo).
- `materialize_lfs()`: se há ponteiro → `git lfs fetch --all` + `git lfs checkout`; se ainda sobrar ponteiro, **morre** (`die`) em vez de compilar contra stub de 133 B.
- Chamado em `ensure` (caminho "já é worktree" **e** caminho de criação), `test` e `build`. Worktree já materializado paga ~0 (23 leituras de 64 B).
- `require_sandbox_tree` (recusa do checkout primário) **não** foi tocado.

Antes / Depois (mesma máquina):

| Verificação | Antes | Depois |
|---|---|---|
| `libRCTailcat.a` em worktree novo | 133 B (ponteiro) | **48.690.800 B** |
| `ensure` num worktree com ponteiro | devolvia o caminho em silêncio | `materializing 23 LFS pointer file(s)` → `LFS artifacts ready` |
| 2º `ensure` | — | no-op (sem linha de materialização) |
| `status` (bundle debug/18218) | ok | ok (inalterado) |
| checkout primário (`git status --porcelain`) | 3 modificações do dono | **as mesmas 3** — intocado |

Nota para o dono: a config `--skip-smudge` é do repo local e pode ser intencional (evita 1 GB de download automático em clones). O loop **não** a alterou; o ritual agora materializa explicitamente e falha alto se não conseguir.

### Item 3.3 — QUEUE-START · P1 · follow-up não entrava na fila durante o start

Contrato já escrito em teste (`test_send_runningThreadQueuesFollowupPrompt`: "follow-up prompts should queue only while a real provider run is active").

Diagnóstico: `beginSurfacePreparation` insere o thread em `preparingRunThreads` e o `defer` só remove quando `startProviderRun` retorna — mas o provider publica `.status(.running)` **dentro** de `startRun` (no `SlowStartRunner`, 100 ms antes de retornar; num CLI real, segundos). Nessa janela:

- a UI já mostra "Working…" (`selectedThreadIsPreparingRun` cede ao run rastreado — contrato travado por `test_loadingStatusCoversPrepareWindowThenYieldsToWorking`), mas
- `send()` testava o latch **cru** (`preparingRunThreads.contains(...) || coordinator.isPreparingProviderStart(...)`) e retornava antes de qualquer caminho de fila, com `statusMessage = "A run is already preparing. Stop it first, or wait."`.

Efeito no usuário: follow-up digitado logo após o start era recusado, não entrava na fila, não limpava o Active plan anterior e voltava só como draft restaurado.

Correção (menor escopo — 1 guard em `send()`): `followUpCanQueue = isThreadStartingOrRunning(sendThreadId) && queuedMessageRepo != nil` pula a recusa quando o thread **já tem run** e a superfície tem fila — isso não é start concorrente, é follow-up. Preparação **sem** run continua recusando (corrida do S5 inalterada).

Antes / Depois:

| Rodada | Antes | Depois |
|---|---|---|
| `test_send_runningThreadQueuesFollowupPrompt` | falha (`[]` vs `["follow up after current run"]`) | **passa** |
| `test_send_runningThreadHandlesLocalSlashCommandInsteadOfQueueing` | falha (`plan` vs `default`) | **passa** |
| `test_queuedFollowupStaysOutOfTranscriptAndClearsActivePlan` | 4 falhas | **passa** |
| `test_loadingStatusCoversPrepareWindowThenYieldsToWorking` (S5) | passa | **passa** |
| `test_sendKeepsExactPreNormalizationDraftWhenDurableDraftDeletionFailsAfterStart` | passa | **passa** |
| Rodada conjunta dos 5 | — | 5 testes, **0 falhas** |

### Item 3.4 — O crash escondia 11 falhas pré-existentes (evidência)

Mesmo filtro nas três rodadas (`AgentAppViewModelTests|AgentWorkspaceRailReloadCoordinatorTests|AgentAutoRoutingViewModelTests`):

| Rodada | Executados | Falhas | Crash |
|---|---|---|---|
| iter 2 (HEAD, mudança em stash) | interrompido no crash | 10 | sim |
| iter 3, após CRASH-FIX | 299 (8 skip) | 36 | **não** |
| iter 3, após QUEUE-START | 299 (8 skip) | **28** | **não** |

As 11 falhas que só apareceram depois do crash-fix foram medidas **com o arquivo de teste pré-mudança** (`git show HEAD~1:...`), em isolamento e no mesmo filtro: lista de asserções **idêntica** (só os UUIDs aleatórios diferem). São pré-existentes, não introduzidas; estavam invisíveis porque o `xctest` morria antes de alcançá-las (ordem alfabética: o crash era em `test_saveLatestProposedPlan…`).

Métodos ainda falhando (15, todos pré-existentes; nenhum novo):

`test_authErrorRetryWaitsForAuthenticatedSnapshotBeforeResending`, `test_defaultCommandMakesNextProviderRunUseDefaultInteractionMode`, `test_failedPendingCallbackResponsesBecomeStaleAndNonActionable`, `test_queueLifecycleEvents_cacheOnlyLocalPreRailOwnershipAcrossReloadFailures`, `test_reloadThreadsBackfillsPlaceholderTitleFromFirstUserMessage`, `test_runningStatusCallbackReflectsCoordinatorClearedUnreadIndicator`, `test_selectThread_marksItRead`, `test_selectThread_rejectsRepositoryMissingStaleRailRow`, `test_selectThreadRehydratesPersistedProposedPlansForMainTimeline`, `test_selectThreadRehydratesPersistedStaleCallbacksIntoTimeline`, `test_selectThreadReplaysPersistedContextTelemetryAfterRestart`, `test_selectThreadReplaysPersistedStreamHistoryWithoutDuplicatingFinalAnswer`, `test_staleCallbacksRehydratedAfterRelaunchAreNeverActionable`, `test_supervisedKeepsProposedPlanReviewable`, `test_terminalCodexAuthFailureSurfacesSignInAction`.

Mensagens (resumo, para o próximo fire): planos propostos `[]` vs `["plan-1"]`; callbacks stale `nil` vs `.stale`; telemetria de contexto `nil` vs `"Context 50% · 500 / 1000 tokens · auto-compacts · compacted"`; unread não limpo no store ao abrir thread; rail stale vence ausência no repo; timeout em `waitAsync` (linha 4743) para auth-retry/plan-mode/running-status.

### Commits da iteração

| Commit | Item |
|---|---|
| `aa7cdfd8` | `test(agent-app): await thread-open hydration in proposed-plan specs` (3.1) |
| `5f126e5f` | `fix(sandbox): materialize LFS artifacts in ensure/test/build` (3.2) |
| `7adb4830` | `fix(agent-app): queue follow-ups sent while the run is starting` (3.3) |

### Pendências / backlog (atualizado na iter 3)

1. **Família `test_selectThread*` (5 falhas)** — abertura de thread não aplica estado durável (planos, callbacks stale, telemetria de contexto, replay de stream, unread flag, rail stale vs repo). Suspeita de **uma** causa comum em `hydrateOpenedThread`/`applyThreadOpenBundle` — alto valor, próximo item.
2. **`test_supervisedKeepsProposedPlanReviewable`** — cartão de plano sob supervisão não fica revisável.
3. **`test_staleCallbacksRehydratedAfterRelaunchAreNeverActionable`** — callbacks stale não reidratam após relançar.
4. **`test_terminalCodexAuthFailureSurfacesSignInAction`** — marcador terminal de auth do Codex não chega ao timeline (CTA Sign in ausente).
5. **`test_authErrorRetryWaitsForAuthenticatedSnapshotBeforeResending` / `test_defaultCommandMakesNextProviderRunUseDefaultInteractionMode`** — timeout em `waitAsync` (linha 4743): o evento esperado não chega.
6. **`test_failedPendingCallbackResponsesBecomeStaleAndNonActionable`** — resposta de callback que falha não vira `.stale`.
7. **`test_queueLifecycleEvents_cacheOnlyLocalPreRailOwnershipAcrossReloadFailures`** — evento de fila de outro thread retém estado local.
8. **`test_reloadThreadsBackfillsPlaceholderTitleFromFirstUserMessage`** — título placeholder não é reparado a partir da primeira mensagem do usuário.
9. **`test_runningStatusCallbackReflectsCoordinatorClearedUnreadIndicator`** — rail não reflete o reset de unread do coordinator.
10. **`AgentThreadDeletionUndoTests.test_deleteAndUndoIncludesTerminalForkIntentWithoutRetainingDeletedTranscript`** (iter 2, pendência 4) — segue falhando: perda de dados no undo de delete.
11. **`agent_turn_checkpoints` sem retenção por idade** (201 MB) e **fora do `LocalStorageBudget`** — decisão de produto (itens 7 e 8 da iter 1).
12. **`token_saver_attempt_*` sem retenção** (EV-28) — só cresce com Token Saver ligado (item 6 da iter 1).
13. **Config LFS `--skip-smudge` do repo** — decidir se permanece (evidência no item 3.2).

## Iteração 4 — 2026-09-17

Método: `/sam-goal` (precedência exclusiva no turno). Item escolhido: a família `test_selectThread*` (5 falhas da iter 3) + os 5 specs vizinhos da mesma causa (estado durável aplicado fora do turno do clique).

### Causa raiz comum (medida)

Depois do AA-02/SEP-3, todo o estado durável de uma thread é aplicado pelo open bundle, que roda **depois** do turno do clique:

- `applyThreadOpenBundle` faz `timeline = bundle.replayedTimeline` → **substitui** o timeline inteiro (qualquer evento aplicado antes do bundle chegar é descartado).
- O probe de existência durável e o `repairPlaceholderThreadTitles` (Task + `Task.detached`) também rodam depois.

Dez specs ainda liam o estado **no mesmo turno** (ou esperavam a barreira errada, ex.: `waitForMessageHistoryLoad` em vez do open bundle). Falhavam por fixture, escondendo o contrato que codificam.

### Item 4.1 — PROD-REJECT · P1 · seleção ficava presa numa thread deletada (correção de produto)

`scheduleSelectThreadHydration` → probe de existência: quando `threadRepo.workspaceId(of:)` devolvia nil, o código só escrevia o status "The thread is no longer available." e retornava — a rail row stale (reload falho) continuava **vinculada**: seleção, painel e composer presos numa thread que o store não tem mais.

Correção (4 linhas): o ramo de ausência passa por `recoverDeletedSelectionIfNeeded([id])` — o caminho que o delete detectado por reload já usava: preserva draft não enviado, limpa caches da thread morta, zera a seleção, avisa o host com `nil`. O ramo "another workspace" mantém o comportamento atual (só status; sem teste de contrato para o probe — anotado no backlog).

Antes / Depois:

| Rodada | Antes | Depois |
|---|---|---|
| `test_selectThread_rejectsRepositoryMissingStaleRailRow` | `XCTAssertNil failed: "<uuid>"` | **passa** |
| `AgentAppPerfBundleTests` (71 testes, guarda do caminho de seleção) | 1 falha pré-existente | a mesma 1 (`test_stopStaleProjection_usesStatusProbeWithoutDurableGet`), **idêntica com o arquivo revertido** |

### Item 4.2 — TEST-BARRIER · P1 · 10 specs liam estado deferido um turno cedo

Correção: usar as costuras que o repo já expõe — `waitForSelectThreadHydrationForTesting()` depois de `selectThread`/`createThread`, `awaitTitleRepairForTesting()` depois de `reloadThreads`.

| Spec | Antes | Depois |
|---|---|---|
| `test_selectThreadRehydratesPersistedProposedPlansForMainTimeline` | `[]` vs `["plan-1"]` | **passa** |
| `test_selectThreadRehydratesPersistedStaleCallbacksIntoTimeline` | `nil` vs `.stale` | **passa** |
| `test_selectThread_marksItRead` | unread não limpo no store | **passa** |
| `test_supervisedKeepsProposedPlanReviewable` | `reviewableProposedPlan` nil | **passa** |
| `test_selectThreadReplaysPersistedContextTelemetryAfterRestart` | telemetria `nil` | **passa** |
| `test_selectThreadReplaysPersistedStreamHistoryWithoutDuplicatingFinalAnswer` | replay ausente | **passa** |
| `test_failedPendingCallbackResponsesBecomeStaleAndNonActionable` | timeline zerada pelo bundle | **passa** |
| `test_staleCallbacksRehydratedAfterRelaunchAreNeverActionable` | timeline zerada pelo bundle | **passa** |
| `test_reloadThreadsBackfillsPlaceholderTitleFromFirstUserMessage` | título `"Thread"` | **passa** |
| `test_selectThread_rejectsRepositoryMissingStaleRailRow` | ver item 4.1 (produto) | **passa** |

Rodadas conjuntas: `--filter <5 sync>` → 5 testes, 1 falha (a de produto, corrigida em 4.1) → depois 4/4; `--filter <4 restantes>` → 4 testes, **0 falhas**; `--filter <2 callbacks>` → 2 testes, **0 falhas**.

### Item 4.3 — Baseline-diff do batch (mesmo filtro da iter 2/3)

| Rodada | Executados | Falhas | Métodos | Crash |
|---|---|---|---|---|
| iter 2 (HEAD) | abortado no crash | 10 | — | sim |
| iter 3 início | 299 (8 skip) | 36 | 18 | não |
| iter 3 fim | 299 (8 skip) | 28 | 15 | não |
| **iter 4** | 299 (8 skip) | **8** | **5** | não |

Nenhuma falha nova introduzida; as 5 restantes já falhavam antes desta iteração.

### Commits da iteração

| Commit | Item |
|---|---|
| `227d922a` | `fix(agent-app): reject a rail-cached thread the store no longer has` (4.1) |
| `b6f78fb6` | `test(agent-app): await the deferred open/repair seams in stale-state specs` (4.2) |

### Pendências / backlog (atualizado na iter 4)

1. **`test_queueLifecycleEvents_cacheOnlyLocalPreRailOwnershipAcrossReloadFailures`** — estado de fila de **outro workspace** fica retido no VM (`threadCacheResidueForTesting.contains(foreign.id)`); o gate é `handleQueueLifecycleEvent` → `resolvedWorkspaceID(for:)` (repo-backed) e `cachedThreadIDs()` agrega `queueStatusByThread`/`runThreads`/etc. Precisa de diagnóstico focado (o gate parece correto; medir quem popula o cache).
2. **`test_authErrorRetryWaitsForAuthenticatedSnapshotBeforeResending`** — timeout em `waitAsync` "initial request completes" (linha 4743): o run inicial não completa.
3. **`test_defaultCommandMakesNextProviderRunUseDefaultInteractionMode`** — timeout "plan mode reaches runner and completes".
4. **`test_runningStatusCallbackReflectsCoordinatorClearedUnreadIndicator`** — timeout + rail não reflete o reset de unread do coordinator.
5. **`test_terminalCodexAuthFailureSurfacesSignInAction`** — timeout "terminal auth failure reaches timeline" (CTA Sign in ausente).
6. **`AgentThreadDeletionUndoTests.test_deleteAndUndoIncludesTerminalForkIntentWithoutRetainingDeletedTranscript`** (iter 2) — perda de dados no undo de delete.
7. **`test_stopStaleProjection_usesStatusProbeWithoutDurableGet`** (`AgentAppPerfBundleTests`) — falha pré-existente confirmada com o fonte revertido: "stale Stop must probe status once instead of a 26-column get" (2 vs 1).
8. **Ramo "another workspace" do probe de existência** — mesmo tratamento do 4.1 (limpar seleção) não tem teste de contrato; decidir com o dono.
9. **`agent_turn_checkpoints` sem retenção por idade** (201 MB) e **fora do `LocalStorageBudget`** — decisão de produto.
10. **`token_saver_attempt_*` sem retenção** (EV-28).
11. **Config LFS `--skip-smudge` do repo** — decidir se permanece.

## Iteração 5 — 2026-09-17

Método: `/sam-goal` (precedência exclusiva no turno). Item escolhido: o primeiro do backlog da iter 4 — evento de fila de **outro workspace** voltando a fixar a thread nos caches do surface (família (a) do loop, escopo de estado por workspace).

### Item 5.1 — QUEUE-FOREIGN-CACHE · P1 · regressão de escopo introduzida por refactor de perf

Evidência por commit (não por suspeita):

| Commit | Data | Comportamento do caminho de fila |
|---|---|---|
| `88faea2c` "fix(agent): scope pre-rail thread state" | 2026-08-05 | retém **só** membership local: `if eventWorkspaceID == workspaceID { threadWorkspaceCache[eventThreadId] = eventWorkspaceID }`; no miss usava `threadRepo.get` |
| `9df3c782` "perf(macos): skip leftover full-thread SQLite gets on hot paths" | 2026-08-27 | troca o probe inline pelo helper compartilhado `resolvedWorkspaceID(for:)`, que cacheia **todo** resultado — o foreign também |

Efeito medido: `threadWorkspaceCache[foreign]` passa a existir; `threadCacheResidueForTesting` (usado pelo contrato de evicção F9 / PERF-MAC_AGENT-013) o enxerga, então um reload cuja list falha pode classificar o ID de outro workspace como "podado localmente". O teste de contrato da iter anterior (`88faea2c`) falhava exatamente aí.

Correção (`Sources/Surfaces/AgentAppSurface.swift`, ~12 linhas, 1 arquivo): o helper ganha a política explícita `retainingForeignProbe` (default `true`, preservando os 3 call sites de status/finish); o caminho de fila passa `false`, ou seja: hit de cache continua sendo reusado (membership foreign **já aprendido** pelo status fan-out sobrevive — é o que mantém barato o filtro do broadcast multi-workspace), hit local continua sendo cacheado, e um probe foreign **novo** não entra nos caches.

Primeira tentativa (descartada, medida): evictar o membership foreign no ramo estrangeiro (`removeValue`) — corrigia um lado e quebrava o outro (`test_reloadThreads_preservesForeignWorkspaceCacheAndCoordinatorState`, 2 falhas novas). O batch pegou a troca; a política explícita no único ponto de probe é a forma que satisfaz os dois contratos.

Antes / Depois (mesmo filtro `AgentAppViewModelTests|AgentWorkspaceRailReloadCoordinatorTests|AgentAutoRoutingViewModelTests`, mesmo sandbox):

| Rodada | Executados | Falhas | Métodos | Crash |
|---|---|---|---|---|
| iter 4 (HEAD `50752db1`) | 299 (8 skip) | 8 | 5 | não |
| iter 5, fix ingênuo (evict) | 299 (8 skip) | 8 | 5 (troca: 1 sai, 1 entra) | não |
| **iter 5 (commit `8717c676`)** | 299 (8 skip) | **6** | **4** | não |

Filtro dirigido (6/6 passam no commit final): `test_queueLifecycleEvents_cacheOnlyLocalPreRailOwnershipAcrossReloadFailures` (antes: 2 falhas em `8989`/`8999`; agora passa), `test_reloadThreads_preservesForeignWorkspaceCacheAndCoordinatorState`, `test_reloadThreads_evictsLocalWorkspaceCacheLearnedBeforeRail`, `test_queueLifecycleEventsSurfaceTimeoutAndClearOnLateDrainForSelectedThread`, `test_lifecycleWorkspaceFilter_sourceUsesWorkspaceIdProbe`, `test_didChangeStatus_cacheMiss_usesWorkspaceIdProbeNotDurableGet`.

Custo: zero regressão de perf — o probe continua sendo `threadRepo.workspaceId(of:)` (uma coluna) e a varredura de fonte `test_lifecycleWorkspaceFilter_sourceUsesWorkspaceIdProbe` segue verde (o corpo do handler continua chamando `resolvedWorkspaceID(for:` e não usa `threadRepo.get(id:`).

### Item 5.2 — dois itens do backlog fechados como **não-bug** (auditoria com evidência)

1. **`implementLatestPlan`/`rejectLatestPlan` "retornam em silêncio"** — o card Approve/Reject renderiza de `reviewableProposedPlan`, que deriva de `latestProposedPlan` = `timeline.proposedPlans.last { markdown não vazio }`; a ação lê o **mesmo** valor no mesmo turno do clique. Não há janela em que o botão esteja visível e o guard falhe; o guard é falha-fechada (nunca implementa o plano de outra thread), não ação perdida.
2. **`AgentThreadDeletionUndoTests` "perde `sourceMessages` no undo"** — não é perda de dado. A cópia duplicada do transcript no intent é **liberada no commit do fork** por contrato (`6c27b31b`, 2026-08-05) e travada por `AgentForkAtomicityTests.test_recoverableTranscriptsRemainExactAndCausalTerminalRowsDoNotSurvive` (`source_messages_json` = `[]` = 2 bytes depois de `local_committed`). A asserção do teste de undo é anterior (`b73c7fc7`, 2026-07-15) — o undo restaura o grafo exato como estava no delete (thread + `agent_messages` + linha do intent), então nada do usuário se perde. Vira decisão do dono (ver backlog).

### Commits da iteração

| Commit | Item |
|---|---|
| `8717c676` | `fix(agent-app): keep a foreign queue event out of the surface caches` (5.1) |

### Pendências / backlog (atualizado na iter 5)

1. **`test_authErrorRetryWaitsForAuthenticatedSnapshotBeforeResending`** — timeout em `waitAsync` linha 4747 "initial request completes": o run inicial não completa.
2. **`test_defaultCommandMakesNextProviderRunUseDefaultInteractionMode`** — timeout "plan mode reaches runner and completes".
3. **`test_runningStatusCallbackReflectsCoordinatorClearedUnreadIndicator`** — timeout + rail não reflete o reset de unread do coordinator (linha 3760).
4. **`test_terminalCodexAuthFailureSurfacesSignInAction`** — timeout "terminal auth failure reaches timeline" + CTA Sign in ausente (linha 212).
5. **Decisão do dono — transcript do intent de fork no undo** (item 5.2.2): manter a liberação em `local_committed` e ajustar o spec de `AgentThreadDeletionUndoTests`, ou ressuscitar a cópia no undo (contradiz `AgentForkAtomicityTests`).
6. **`AgentThreadDeletionUndoTests.test_deleteAndUndoIncludesTerminalForkIntentWithoutRetainingDeletedTranscript`** — mesma decisão do item 5.
7. **`test_stopStaleProjection_usesStatusProbeWithoutDurableGet`** (`AgentAppPerfBundleTests`) — falha pré-existente confirmada com o fonte revertido: "stale Stop must probe status once instead of a 26-column get" (2 vs 1).
8. **Ramo "another workspace" do probe de existência** (item 4.1 da iter 4) — mesmo tratamento (limpar seleção) não tem teste de contrato; decidir com o dono.
9. **`agent_turn_checkpoints` sem retenção por idade** (201 MB) e **fora do `LocalStorageBudget`** — decisão de produto.
10. **`token_saver_attempt_*` sem retenção** (EV-28).
11. **Config LFS `--skip-smudge` do repo** — decidir se permanece.

## Iteração 6 — 2026-09-17

Método: `/sam-goal` (precedência exclusiva no turno). Itens escolhidos: os 4 specs restantes da família de timeouts do backlog da iter 5. Dois eram **bug de produto real** (corrigidos), dois são **spec obsoleto** (diagnóstico com evidência, não alterados).

### Item 6.1 — ERROR-DROP · P1 · erro de run vivo era apagado por um open em voo

Causa medida por instrumentação (prints temporários, já revertidos), não por suspeita:

```
[DBG didFinish] tid=2FA16CFC… threadWorkspace=Optional(7AB8…) surface=7AB8… selected=Optional(2FA1…) status=failed msg=Optional("[auth-required] Unauthorized")
[DBG didFinish] gate passed selectedMatch=true timelineError=nil provider=codex
[DBG openBundle] thread=2FA16CFC… paintedError=Optional("[auth-required] Unauthorized") replayError=nil
```

`applyThreadOpenBundle` fazia `timeline = bundle.replayedTimeline` (troca integral) e só protegia a **flag** `lastErrorRecoverable`; o **texto** do erro pintado depois do início do gather (mais novo que a leitura do replay) era descartado. Efeito de produto: run falha com marcador de auth → erro e CTA "Sign in" somem quando um open desse mesmo thread aplica → usuário vê run falho sem motivo e sem ação até o próximo reload.

Correção (`Sources/Surfaces/AgentAppSurface.swift`, 8 linhas, 1 arquivo): depois da troca, se o replay **não** traz erro, o erro pintado é reposto (`timeline.error = paintedErrorBeforeOpen`); replay com erro próprio continua vencendo. Semântica de thread preservada: no momento do apply o timeline pintado é sempre o do thread aberto (`selectThread` já pinta o cache do alvo ou vazio antes do bundle).

Cobertura: `test_terminalCodexAuthFailureSurfacesSignInAction` (falhava com o CTA nil; agora verde).

### Item 6.2 — RAIL-UNREAD · P1 · patch de status não espelhava o read state

Causa: `applyInMemoryThreadStatus` (X-02, `031f0538`) patcheava só `status`/`updatedAt`. O coordinator persiste status **e** read state juntos (`AgentRunCoordinator.hasUnread(for:)` → `pending`/`running`/`cancelled` = lido; `completed`/`failed`/`interrupted` = não lido). Como X-02 parou de re-listar a rail a cada status event, a linha ficava com o badge antigo até um list completo posterior.

Correção (`Sources/Surfaces/AgentAppSurface.swift`, 14 linhas, 1 arquivo): o patch passa a espelhar a mesma regra (`Self.railUnread(for:)`), sem nenhum list novo.

Cobertura: `test_runningStatusCallbackReflectsCoordinatorClearedUnreadIndicator` (verde) e o contrato de perf de X-02 `test_didChangeStatus_doesNotReloadThreadList` **mantido verde** (nenhum list).

### Item 6.3 — dois timeouts do backlog são **spec obsoleto**, não bug (diagnóstico medido)

Evidência instrumentada em `test_authErrorRetryWaitsForAuthenticatedSnapshotBeforeResending`:

```
[DBG auth] prompts=["resume only after auth"] status=failed msg= canRun=true reason=-
```

O prompt **chega** ao runner e o status fica `failed` porque `CapturingProviderRunner` emite só `.status(.completed)` + `.finished(.completed, finalMessage: nil)` — sem nenhum output de assistant. `ProviderStderrClassifier.resolveTerminal` (linhas 50-60) reclassifica por contrato um `.completed` **sem** output de assistant para `.failed` com a mensagem "run completed without producing an assistant response" (regra explícita no fonte: "a 'success' with no assistant output is not success"). Os dois specs (`test_authErrorRetryWaits…`, `test_defaultCommandMakesNextProviderRunUseDefaultInteractionMode`) esperam `vm.status == .completed` de um double que **não pode** produzir esse estado em produção → a asserção contradiz o contrato vigente, não o inverso. Nenhuma mudança de produto feita; decisão de fixture/owner (ver backlog).

### Baseline-diff (mesmo filtro, mesma máquina, mesmo workload)

`AgentAppViewModelTests|AgentWorkspaceRailReloadCoordinatorTests|AgentAutoRoutingViewModelTests`:

| Rodada | Executados | Skip | Falhas | Métodos |
|---|---|---|---|---|
| iter 5 (HEAD `9c151324`) | 299 | 8 | 6 | 4 |
| **iter 6 (HEAD `4fd93d72`)** | 299 | 8 | **2** | **2** |

Extra (famílias de open/perf/gating, fora do batch padrão): `AgentAppPerfBundleTests|AgentRunFinishWorkspaceGatingTests|AgentAppGhostRunLatchTests` → 79 executados, 2 falhas, **ambas pré-existentes**: `test_stopStaleProjection_usesStatusProbeWithoutDurableGet` (já no backlog) e `test_recoveredSessionEventForFinishedRunDoesNotRelatchWorking` (medido com o fonte em `git stash`: falha igual sem a mudança).

Filtro dirigido no commit final (4 verdes, exit 0): `test_terminalCodexAuthFailureSurfacesSignInAction`, `test_runningStatusCallbackReflectsCoordinatorClearedUnreadIndicator`, `test_didChangeStatus_doesNotReloadThreadList`, `test_paintedTimelineByThread_evictsLRUAndDeletedThreads`.

### Commits da iteração

| Commit | Item |
|---|---|
| `e837a708` | `fix(agent-app): keep a live run error across an in-flight thread open` (6.1) |
| `4fd93d72` | `fix(agent-app): mirror the coordinator read state on a status-only rail patch` (6.2) |

### Pendências / backlog (atualizado na iter 6)

1. **Decisão do dono — fixture vs contrato nos 2 specs de send** (item 6.3): `CapturingProviderRunner` não emite output de assistant, então nunca produz `.completed` (reclassificado para `.failed` pelo classifier). Opções: fazer o double emitir um turn de assistente (realista; toca ~20 specs que usam o runner) ou reescrever as asserções para o contrato atual (prompt chega ao runner + status terminal). Não é bug de produto.
2. **Decisão do dono — transcript do intent de fork no undo** (item 5.2.2): manter a liberação em `local_committed` e ajustar o spec de `AgentThreadDeletionUndoTests`, ou ressuscitar a cópia no undo (contradiz `AgentForkAtomicityTests`).
3. **`AgentThreadDeletionUndoTests.test_deleteAndUndoIncludesTerminalForkIntentWithoutRetainingDeletedTranscript`** — mesma decisão do item 2.
4. **`test_stopStaleProjection_usesStatusProbeWithoutDurableGet`** (`AgentAppPerfBundleTests`) — falha pré-existente confirmada com o fonte revertido: "stale Stop must probe status once instead of a 26-column get" (2 vs 1).
5. **`AgentAppGhostRunLatchTests.test_recoveredSessionEventForFinishedRunDoesNotRelatchWorking`** — falha pré-existente medida nesta iter (baseline por `git stash`): "replayed provider event still reaches the timeline" (linha 72).
6. **Ramo "another workspace" do probe de existência** (item 4.1 da iter 4) — mesmo tratamento (limpar seleção) não tem teste de contrato; decidir com o dono.
7. **`agent_turn_checkpoints` sem retenção por idade** (201 MB) e **fora do `LocalStorageBudget`** — decisão de produto.
8. **`token_saver_attempt_*` sem retenção** (EV-28).
9. **Config LFS `--skip-smudge` do repo** — decidir se permanece.
10. **Operacional — `origin/production` avançou 1 commit** (`322634f0`, toca `Sources/AgentRuntime/AgentSkillInstaller.swift` + testes + `goal/`); este branch está 18 commits à frente e 1 atrás. Fazer `git merge origin/production` no início da próxima iteração e **remedir o batch** antes de qualquer novo item (não medido nesta iter).

## Iteração 7 — 2026-09-17

Método: `/sam-goal` (precedência exclusiva no turno). Primeiro o merge de `origin/production` (item 10 do backlog da iter 6) e a remedição do batch **antes** de qualquer mudança; item escolhido: prioridade (b) do loop — linha fantasma na rail depois do probe de existência + o ramo "another workspace" do mesmo probe.

### Merge e baseline remedido

- `git merge origin/production` limpo (`b5bb3604`); o commit `322634f0` é só o pin do skill orchestrate v6→v7 nos 3 arquivos espelhados (`AgentSkillInstaller`, `RemoteCodeOrchestrateInstallTests`, `check-app-bundle.sh`) — nada a reconciliar. Branch 20 à frente, 0 atrás.
- Batch remedido no HEAD pós-merge (mesmo filtro das iters 2–6): 299 executados, 8 skip, **2 falhas** — exatamente as duas decisões do dono da iter 6.3 (`test_authErrorRetryWaitsForAuthenticatedSnapshotBeforeResending`, `test_defaultCommandMakesNextProviderRunUseDefaultInteractionMode`). Nenhuma falha nova trazida pelo merge.

### Item 7.1 — RAIL-PHANTOM · P1 · o probe de existência aposentava a seleção mas deixava a linha (e os caches)

O fix da iter 4 parou na metade: `recoverDeletedSelectionIfNeeded([id])` libera a seleção, mas nem remove a linha de `threads` nem chama `evictThreadCaches` — as duas coisas que **todos** os outros caminhos de "thread sumiu" fazem antes (`reloadThreads` e `applyAuthoritativeThreadDeletions`: `evictThreadCaches` → `threads.removeAll` → `recoverDeletedSelectionIfNeeded`).

Efeito de produto: a linha da rail continua clicável depois de o store dizer que a thread não existe mais; cada clique repete "The thread is no longer available" e volta ao composer, até um reload de rail conseguir rodar. Como o reload que criou a linha tinha falhado (`setReloadThreadListForTesting { throw }` é exatamente o cenário), não havia garantia de quando isso aconteceria. Os caches por thread (`queueStatusByThread`, `threadWorkspaceCache`, `composerDraftsByThread`, `paintedTimelineByThread`, plan notes, projeção de run) sobreviviam à thread morta — o resíduo que o contrato de evicção F9/PERF-MAC_AGENT-013 proíbe.

Mesma história no ramo **"another workspace"**: o probe só escrevia o status e retornava. A seleção ficava **presa na thread foreign** (o bind da rail acontece antes do probe): composer, chrome e host passavam a apontar para uma thread que este workspace não possui, e a linha continuava na rail.

Correção (menor escopo — 1 arquivo de produção, 2 ramos do probe + 1 helper):

- `retireUnbackedRailRow(_:)` — os mesmos três passos de um delete commitado: `evictThreadCaches` → `threads.removeAll` → `recoverDeletedSelectionIfNeeded` (que já publica `nil` ao host, preserva o draft não enviado e mantém o status mais relevante).
- Chamado nos **dois** ramos do probe (row ausente no store; row com dono durável em outro workspace). O ramo de erro de leitura continua intocado (falha de leitura ≠ ausência).

### Antes / Depois (mesmo sandbox, mesmos fixtures; asserções dos specs dirigidos)

| Asserção | Antes | Depois |
|---|---|---|
| Linha da rail some quando o store não tem a thread | ❌ permanecia clicável | ✅ removida |
| Caches por thread evictados (store ausente) | ❌ ficavam | ✅ evictados |
| Seleção liberada em row "outro workspace" | ❌ `selectedThreadId` presa na thread foreign | ✅ `nil` |
| Linha da rail some em row "outro workspace" | ❌ permanecia | ✅ removida |
| Caches por thread evictados (outro workspace) | ❌ ficavam | ✅ evictados |
| `statusMessage` ("no longer available" / "belongs to another workspace") | mantido | idêntico |
| Fallback não-rail de thread foreign (spec irmão) | passa | passa |
| Rodada dirigida (3 specs) | **3 testes, 5 falhas** | **3 testes, 0 falhas** |
| Batch `AgentAppViewModelTests\|AgentWorkspaceRailReloadCoordinatorTests\|AgentAutoRoutingViewModelTests` | 299 (8 skip), 2 falhas | **300 (8 skip), 2 falhas** (as mesmas decisões do dono; +1 spec novo) |

Baseline por revert real do fonte (patch salvo, `git checkout`, rodada, `git apply`), não por stash: os 5 failures acima são medidos com o `AgentAppSurface.swift` pré-mudança e os specs novos no lugar.

### Item 7.2 — `test_stopStaleProjection…` diagnosticado: spec super-especificado, sem bug de produto

Evidência medida (instrumentação temporária no ramo stale de `stop()`, já revertida):

```
[DBG stop] coordinatorProbes=1
[DBG stop] clearProbes=1
```

Os 2 probes são dois `SELECT status FROM agent_threads WHERE id=?` legítimos de **dois** componentes: `AgentRunCoordinator.stopRun(threadId:)` (guarda F19, contrato próprio `StopRunStatusProbeTests` = +1 probe) e `AgentAppSurface.clearStaleRunProjection` (repaint do status durável, contrato de fonte próprio). Nenhum `get` de 26 colunas acontece — os dois specs de fonte que travam isso (`test_stopStaleProjection_sourceUsesStatusProbe`, `test_stopRun_sourceUsesStatusProbe`) estão **verdes** na mesma rodada; só a asserção "exatamente 1 probe no total" falha. Nenhuma mudança de produto feita (deduplicar exigiria remover o `coordinator.stopRun(threadId:)` defensivo do ramo stale ou passar o status entre componentes) — decisão do dono, ver backlog.

### Commits da iteração

| Commit | Item |
|---|---|
| `d76772f7` | `fix(agent-app): retire a rail row the durable store no longer backs` (7.1) |

### Pendências / backlog (atualizado na iter 7)

1. **Decisão do dono — fixture vs contrato nos 2 specs de send** (item 6.3): `CapturingProviderRunner` não emite output de assistant, então nunca produz `.completed`. Opções: fazer o double emitir um turn de assistente (realista; toca ~20 specs) ou reescrever as asserções para o contrato atual. Não é bug de produto.
2. **Decisão do dono — transcript do intent de fork no undo** (item 5.2.2): manter a liberação em `local_committed` e ajustar o spec de `AgentThreadDeletionUndoTests`, ou ressuscitar a cópia no undo (contradiz `AgentForkAtomicityTests`).
3. **`AgentThreadDeletionUndoTests.test_deleteAndUndoIncludesTerminalForkIntentWithoutRetainingDeletedTranscript`** — mesma decisão do item 2.
4. **Decisão do dono — `test_stopStaleProjection_usesStatusProbeWithoutDurableGet`** (agora diagnosticado, item 7.2): a asserção "1 probe" é mais estreita que o contrato que o nome do teste declara ("instead of a 26-column get"), que está honrado. Opções: relaxar a asserção para o contrato real (nenhum `get`; ≤1 probe por componente) ou deduplicar de verdade removendo o `coordinator.stopRun(threadId:)` do ramo stale (perde a defesa contra corrida). Não é bug de produto.
5. **`AgentAppGhostRunLatchTests.test_recoveredSessionEventForFinishedRunDoesNotRelatchWorking`** — falha pré-existente (baseline por `git stash`, iter 6): "replayed provider event still reaches the timeline" (linha 72).
6. **`agent_turn_checkpoints` sem retenção por idade** (201 MB) e **fora do `LocalStorageBudget`** — decisão de produto.
7. **`token_saver_attempt_*` sem retenção** (EV-28).
8. **Config LFS `--skip-smudge` do repo** — decidir se permanece.

**Fechados nesta iteração:** linha fantasma na rail / ramo "another workspace" (7.1, com teste de contrato para os dois); merge de `origin/production` (item 10 da iter 6).

## Iteração 8 — 2026-09-17

Método: `/sam-goal` (precedência exclusiva no turno). Escopo: fechar a **prioridade (a)** do loop — os três specs que ainda falhavam. Nos três casos a causa é a mesma classe: a asserção exigia um estado que o fixture/fluxo do próprio teste **não pode** produzir. Nenhuma linha de produção foi alterada; os contratos de produto envolvidos seguem travados pelos testes que já os cobriam.

### Item 8.1 — SEND-SPEC-TERMINAL · 2 specs de send esperavam `.completed` de um double mudo

`CapturingProviderRunner` (`Tests/SurfacesTests/AgentAppViewModelTests.swift:10179`) captura requests e emite apenas `.status(.completed)` + `.finished(.completed, finalMessage: nil)` — sem nenhum output de assistente. `ProviderStderrClassifier.resolveTerminal` (`Sources/AgentRuntime/ProviderStderrClassifier.swift:50-62`) reclassifica esse `.completed` silencioso para `.failed` por contrato explícito no fonte ("a 'success' with no assistant output is not success"). O predicado dos dois specs era `vm.status == .completed` → **nunca** assentava.

**Decisão (fixture vs código): fixture.** Fazer o double emitir um turn de assistente mudaria o observado por 26 call sites e tiraria do caminho o `resolveTerminal` silencioso (contrato testado em `ClaudeStreamingCLIAdapterTests`/`ClaudeParserCLITests`); o errado era a asserção, não o contrato. O predicado passou a usar `AgentRunCoordinator.isTerminalThreadStatus(vm.status)` — autoridade única de "terminal" no repo. Asserções de intent (prompts, interaction modes, recovery action, `timeline.error`) intactas.

Antes / Depois (filtro dirigido, mesmo sandbox):

| Spec | Antes | Depois |
|---|---|---|
| `test_authErrorRetryWaitsForAuthenticatedSnapshotBeforeResending` | timeout em `waitAsync` | **passa** |
| `test_defaultCommandMakesNextProviderRunUseDefaultInteractionMode` | timeout em `waitAsync` | **passa** |

### Item 8.2 — GHOST-PAINT · evento da sessão recuperada era apagado pelo open em voo (spec, não produto)

`AgentAppGhostRunLatchTests.test_recoveredSessionEventForFinishedRunDoesNotRelatchWorking` falhava em "replayed provider event still reaches the timeline" (linha 72). Causa medida: o spec chama o observer **direto** (`runCoordinator(_:didReceive:)`), o que faz do evento um registro não-durável, e injetava enquanto o open do `selectThread` do harness ainda estava em voo. `applyThreadOpenBundle` troca o timeline inteiro (`timeline = bundle.replayedTimeline`, `Sources/Surfaces/AgentAppSurface.swift:2698`) — o replay apagava o evento. **Produção não alcança esse estado**: o coordinator grava o stream event antes do fan-out ("S3: never publish an undurable event", `Sources/AgentRuntime/AgentRunCoordinator.swift:7114-7138`), então o próximo replay já contém o evento.

Correção no spec: `await h.vm.waitForSelectThreadHydrationForTesting()` antes de injetar. O gate sob teste (pinta o evento; **não** re-latcha Working/`currentRunId`/`runStartedAt`) não mudou.

Antes / Depois (`--filter AgentAppGhostRunLatchTests`; o "antes" com o spec pré-mudança via `git stash`, mesma máquina):

| Rodada | Antes | Depois |
|---|---|---|
| Arquivo completo | 5 executados, **1 falha** (linha 72) | **5 executados, 0 falhas** |

### Item 8.3 — STOP-PROBE-BUDGET · asserção mais estreita que o contrato do próprio nome

`test_stopStaleProjection_usesStatusProbeWithoutDurableGet` pedia "exatamente +1 probe". Medição independente nesta iteração (contadores `statusProbeCountForTesting` / `durableGetCountForTesting` do repositório, sem instrumentar o fonte):

```
probesBefore=0 probesAfter=2 getsBefore=1 getsAfter=1
```

Os 2 probes são `SELECT status` de coluna única, um de cada componente com contrato próprio (guarda F19 de `AgentRunCoordinator.stopRun(threadId:)`; repaint de `clearStaleRunProjection`), e o **get de 26 colunas continua zero** — exatamente o que o nome do spec promete. O spec agora trava (i) `durableGetCountForTesting` inalterado e (ii) orçamento de probes ≤ 2. Um dedup futuro (decisão do dono, backlog 4) pode derrubar um probe sem editar o teste; um terceiro leitor falha.

Antes / Depois (mesmo filtro):

| Rodada | Antes | Depois |
|---|---|---|
| `test_stopStaleProjection_usesStatusProbeWithoutDurableGet` | 1 falha (2 ≠ 1) | **passa** |
| `test_stopStaleProjection_sourceUsesStatusProbe` + `StopRunStatusProbeTests.test_stopRun_sourceUsesStatusProbe` | passam | **passam** |

### Item 8.4 — TERMINAL-ONCE · terminal retido era publicado **duas vezes** (bug de produto pré-existente, prioridade (c))

Primeiro item da varredura (b)/(c) e o de maior valor que apareceu: `StreamBatchAtomicPersistenceTests.test_stopCannotOvertakeTerminalWaitingForDurabilityBarrier` falhava desde antes deste loop com `onRunFinished` recebendo `[.completed, .completed]` — contrato "exactly once" do terminal do provider quebrado.

**Diagnóstico por instrumentação temporária (7 prints, revertidos).** Sequência real medida:

```
[DBGFIN-enter] status=completed      ← provider terminal retido (DB travado)
[DBGFIN-claim] needs=true
[DBGFIN-retry-schedule] ... [DBGFIN-retry-take] hasPending=true   ×5 (retry loop)
[DBGFIN-publish-finish] status=completed
[DBGFIN-publish-finish] status=completed   ← DUAS execuções concorrentes publicam
```

Causa raiz: **duas retries de durabilidade podem estar vivas ao mesmo tempo**. `scheduleTerminalDurabilityRetry` libera seu marcador (`terminalRetryScheduled`) quando a task é *tomada* (`takePendingTerminalRetry`), não quando ela *retorna*, e a reentrada em `.finished` é permitida enquanto a tradução de resposta final está desligada (~`allowFinalResponseTranslation == false`). As duas execuções adotam a **mesma** entrada retida de `pendingTerminalEvents`, ambas committam (`persistTerminalGraph` + transições + cleanup) e ambas publicam. É exatamente a regra do AGENTS.md ("only the task that owns a handle clears it") violada no caminho de terminal.

Correção (menor escopo — 1 arquivo, 1 parâmetro default + 1 conjunto): **lease single-flight por run**, tomado e liberado **só por retries** (`isDurabilityRetry: true` só no `Task` de retry), liberado em todos os exits (falha de flush, falha de persist, cleanup do commit bem-sucedido). O lease é deliberadamente **separado** de `terminalCheckpointAttempts` e **não** é observado por chamadores síncronos. Duas variantes foram medidas e descartadas:

| Variante | Resultado medido |
|---|---|
| A. Reusar `terminalCheckpointAttempts` como lease (inserir no claim) | `test_stopCannotOvertake...` **passa**, mas `test_failedStopFlushDoesNotReuseSeq1ForLateProviderRuntimeAndAllowsNextStart` **quebra** com 503: a janela do lease passou a cobrir o flush e bloqueou o `releaseStaleInMemoryOwnershipIfDurableTerminal` |
| B. Lease novo, mas observado por **todo** `.finished` | Alvo passa, irmão **quebra igual**: `reconcilePendingTerminalBeforeStart` (síncrono, "must observe the durability result, not race the detached retry") era recusado pelo lease de uma retry viva → próximo turno levava 503 |
| **C. Lease só para retries (final)** | Alvo passa **e** irmão passa |

**Antes / Depois (mesma máquina, mesmo sandbox):**

| Rodada | Antes | Depois |
|---|---|---|
| `test_stopCannotOvertakeTerminalWaitingForDurabilityBarrier` | 1 falha (`[.completed, .completed]`) | **passa** |
| `test_failedStopFlushDoesNotReuseSeq1ForLateProviderRuntimeAndAllowsNextStart` (liveness do start gate) | passa | **passa** |
| `--filter StreamBatchAtomicPersistenceTests` | 12 testes, 1 falha | **12 testes, 0 falhas** |
| `--filter PersistenceTests` (família) | 921 (5 skip), 7 falhas | 921 (5 skip), 7 falhas **0 unexpected** — a falha do alvo sai e entra `PinSortOrderPreservingRoutingProbeTests` (micro-benchmark sensível a carga) |
| Batch A (VM\|Rail\|Routing) | 300 (8 skip), 0 | **300 (8 skip), 0** (uma flake em corrida: `testSubagentRefreshDemotesDeadExternalReceiptFromActive`; A/B isolado passa com e sem a mudança, rerun limpo) |
| Batch B (Perf\|Gating\|Ghost) | 79, 0 | **79, 0** |
| `test_minimalCheckpointUpsertFailurePublishesOneNilIdentityAndNeedsAttention` | 3 asserções (pré-existente, iter 1) | **as mesmas 3, idênticas** (A/B com a mudança em stash) |
| Família `AgentRuntimeTests` (2009 testes) | 136 falhas | 145 falhas — diferença dominada por micro-benchmarks de tempo real (±5%) e testes de provider real; os 2 specs não-benchmark que diferiram foram A/B: `AgentForkAtomicityTests.test_productionAdaptersDeclareForkUnsafeAndCoordinatorNeverLaunchesThem` falha **nos dois** lados (ambiente: adapter Claude real instalado) e `GrokACPAdapterTests.test_turnInactivityWatchdog...` passa **nos dois** (flake de carga) |

Ruído de micro-benchmark medido nesta iteração (mesmo código, rodadas diferentes): `SessionDiagnosticsUpdateTests` −27% / +2,9% / −23% / −31%; `SessionMarkStoppedTests` −41% / −7% / −8,5% / −9%; `PinSortOrder…` passa e falha alternando; `StartPendingStatusUpdateTests`/`StopCancelIfActiveTests` idem. Todos exigem ganho >5% de uma medição de tempo real — nenhum toca o coordinator.

### Baseline-diff da iteração (filtros idênticos aos das iters 2–7)

| Rodada (`AgentAppViewModelTests|AgentWorkspaceRailReloadCoordinatorTests|AgentAutoRoutingViewModelTests`) | Executados | Skip | Falhas |
|---|---|---|---|
| iter 7 (HEAD `36723f9e`) | 300 | 8 | 2 |
| **iter 8 (HEAD `1bee4ddb`)** | 300 | 8 | **0** |

| Rodada (`AgentAppPerfBundleTests|AgentRunFinishWorkspaceGatingTests|AgentAppGhostRunLatchTests`) | Executados | Falhas |
|---|---|---|---|
| iter 6 (HEAD `4fd93d72`) | 79 | 2 |
| iter 7 (HEAD `36723f9e`) | 79 | 1 |
| **iter 8 (HEAD `1bee4ddb`)** | 79 | **0** |

Filtro dirigido final: 2 send specs (2/0), ghost file (5/0), stop-probe + 2 irmãos de fonte (3/0).

### Commits da iteração

| Commit | Item |
|---|---|
| `b94ae3e7` | `test(agent-app): wait on the terminal contract in the capture-double send specs` (8.1) |
| `1ea0e30b` | `test(agent-app): settle the seed open before injecting a replayed run event` (8.2) |
| `1bee4ddb` | `test(agent-app): assert the stale-stop status-probe budget, not a single probe` (8.3) |
| `3ab88f0e` | `docs(checklist): iteration 8 — priority (a) closed, baseline re-measured` |
| `0f068af1` | `fix(agent): publish a retained terminal exactly once across durability retries` (8.4) |

### Cobertura acumulada (o que já foi varrido e com que evidência)

| Área / fluxo | Evidência | Status |
|---|---|---|
| Peso/retenção do SQLite (`LocalStorageBudget`, `Schema`, retenção) | iters 1, 7 | auditado; CKPT-BUDGET corrigido; 3 pendências (itens 1–3 do backlog abaixo) |
| Snapshot de checkpoint (captura/restore) | iter 1 | auditado + corrigido |
| Estado durável de thread no open (`AgentAppSurface` `hydrateOpenedThread`/`applyThreadOpenBundle`) | iters 2, 4, 6, 7 | auditado; PLAN-NOTES-BLEED, PROD-REJECT, ERROR-DROP, RAIL-PHANTOM, RAIL-UNREAD corrigidos |
| Fila de follow-up (`send`, `preparingRunThreads`, eventos de fila) | iters 3, 5 | auditado; QUEUE-START, QUEUE-FOREIGN-CACHE corrigidos |
| Stop/stale projection (ramo stale, força-stop, probe de status) | iters 6, 7, 8 | auditado; spec do probe alinhado ao contrato (8.3) |
| Terminal do provider / barreira de durabilidade (`pendingTerminalEvents`, retries, start gate) | iter 8 (8.4) | auditado; publicação duplicada corrigida (lease single-flight das retries); `releaseStaleInMemoryOwnershipIfDurableTerminal`, `reconcilePendingTerminalBeforeStart` e `recordTerminalTransition` lidos e cobertos por A/B |
| Ghost run latch (evento de sessão recuperada) | iters 6, 8 | auditado; spec alinhado ao fluxo durável (8.2) |
| Specs com doubles que não produzem o estado asserido (`CapturingProviderRunner`) | iter 8 | auditado: 2 specs corrigidos; os outros 24 call sites não esperam `.completed` |
| Plan notes por thread | iter 2 | auditado + corrigido |
| Ritual LFS / sandbox isolado | iter 3 | auditado + corrigido |
| Retenção `token_saver_*` (EV-28) | iter 1 (leitura do código + DB) | auditado; decisão do dono |
| Agent App transcript por frame/delta, EventBus/fan-out, Bots Desk, formatters/hot path, `performSync`/polling | TODO.md 2026-09-14 + iter 1 | auditados fora deste loop; sem item novo |
| **Áreas ainda não varridas** | — | `Sources/AppShell/` (fora `BotsWindow`/`BotsDeskFollowThrough`/`AgentApp*`), `Sources/SocketServer/` (fora `EventBus`), `Sources/Terminal*`, `Sources/Tailcat*`, `Sources/Computer*`/`Bot*`, `Sources/Access*`, `Sources/Insomnia*` — prioridade (c) |

### Pendências / backlog (atualizado na iter 8)

**Prioridade (a) do loop: fechada** — não há mais spec vermelho acionável nas famílias cobertas (batches A e B em 0 falhas). A prioridade (c) começou no item 8.4 (terminal duplicado, corrigido). Os itens abaixo são decisão do dono ou varredura remanescente.

1. **Decisão do dono — transcript do intent de fork no undo** (iter 5.2): manter a liberação em `local_committed` e ajustar o spec de `AgentThreadDeletionUndoTests`, ou ressuscitar a cópia no undo (contradiz `AgentForkAtomicityTests`). `test_deleteAndUndoIncludesTerminalForkIntentWithoutRetainingDeletedTranscript` segue vermelho por isso.
2. **Decisão do dono — dedup dos 2 probes do ramo stale de `stop()`** (iter 7.2 + 8.3): o spec agora permite 1 ou 2 probes; deduplicar exigiria remover a guarda defensiva `coordinator.stopRun(threadId:)` ou passar o status entre componentes.
3. **`agent_turn_checkpoints` sem retenção por idade** (201 MB medidos) — decisão de produto (apagar checkpoint antigo remove rewind antigo).
4. **`agent_turn_checkpoints` fora do `LocalStorageBudget`**: `LocalStorageClass` tem só 4 classes (`reversibleContent`, `attachmentBlobs`, `streamEvents`, `providerLogs`) e `usage()` não lê a tabela — a maior tabela do banco é invisível no snapshot de armazenamento. Único consumidor além de `snapshot()` são 2 testes que comparam com `allCases`; adicionar uma classe exige definir se ela tem retenção (item 3) — **candidato à prioridade (b) do próximo fire**.
5. **`token_saver_attempt_*` sem retenção** (EV-28) — 0 linhas hoje; cresce só com Token Saver ligado.
6. **Config LFS `--skip-smudge` do repo** — decidir se permanece (evidência na iter 3.2).
7. **Falhas pré-existentes fora das famílias Surfaces** — baseline remedido nesta iteração com o filtro da iter 1 (`--filter PersistenceTests`, mesmo sandbox): **921 executados, 5 skip, 7 falhas em 6 métodos** (a iter 1 media 8 falhas nesse filtro; os 2 de plan notes fecharam na iter 2 e `RoutingConfigPreservingThreadProbeTests` está verde hoje):
   - ~~`AgentRuntimeTests.StreamBatchAtomicPersistenceTests.test_stopCannotOvertakeTerminalWaitingForDurabilityBarrier` — `onRunFinished` publica `[.completed, .completed]`~~ — **corrigido no item 8.4** (lease single-flight das retries de durabilidade); arquivo 12/0 e irmão de liveness verde.
   - `PersistenceTests.RetentionCapTests.test_heavySession_allRetentionCapsTogetherBoundTheDatabase` — 2 asserções `100 is not greater than 100` (limite exato, não folga).
   - `PersistenceTests.SchemaMigrationMatrixTests` (2): a lista do head tem **83** passos onde o fixture espera até 82 ("v72 remains the first unpublished C10 step; … v82 indexes audit_log(action, id)") — drift do fixture contra um passo v83 no schema. **Próximo candidato**: decidir se o passo v83 existe de verdade no schema e o fixture está velho, ou o inverso.
   - Micro-benchmarks de tempo real (`SessionDiagnosticsUpdateTests`, `SessionMarkStoppedTests`, `PinSortOrderPreservingRoutingProbeTests`, `StartPendingStatusUpdateTests`, `StopCancelIfActiveTests` — todos `must beat get+upsert by ≥5%`): medidos entre −41% e +3,5% em rodadas diferentes do **mesmo código**. Não são regressão nem bug; a asserção de ganho é sensível a carga. Antes de qualquer conclusão: 5 amostras aquecidas na mesma janela, como manda o AGENTS.md.

**Fechados nesta iteração (8):** 2 specs de send que esperavam `.completed` de um double mudo (8.1); spec do ghost run alinhado ao fluxo durável (8.2); asserção do probe de status alinhada ao contrato (8.3); **publicação duplicada do terminal retido** (8.4, bug de produto pré-existente com evidência instrumentada). Baseline das famílias Persistence/AgentRuntime remedido e ruído de micro-benchmark documentado.

## Iteração 9 — 2026-09-17

Método: `/sam-goal` (precedência exclusiva no turno). Escopo: **prioridade (c)** — avançar a varredura das áreas ainda não auditadas — com três auditorias read-only em paralelo (AppShell infra, SocketServer fora do EventBus, superfícies de terminal/pane) e o fechamento do último fixture de persistência que ainda falhava. Cada achado de subagente foi reconferido no fonte pelo autor antes de virar item (nenhum foi aceito por relato).

### Item 9.1 — PERSIST-FIXTURE · 2 falhas de `SchemaMigrationMatrixTests` eram fixture velho, não bug

`Schema.currentVersion` é 83 desde `daace020` (índice `idx_agent_threads_workspace_updated`, X-02), mas duas asserções param no 82:

- `test_headOriginBaselineWas71AndV72RejectsCavemanOnWinnerAndArmWhileAcceptingRCS1Arm` (linha 604) exigia a lista de passos `[72…82]` — a lista real é `[72…83]`.
- `test_v81ToV82IndexesAuditLogActionIdForReceiptSignatureReads` (linha 1385) migrava **todos** os passos e então exigia `maxVersion == 82` — virava asserção de head, não do contrato v82.

Correção (só teste): lista do head ganha 83 com a descrição do índice; o contrato v81→v82 passa a migrar `Schema.steps.filter { $0.version <= 82 }`, então um head futuro não o quebra de novo. O passo v83 já tem contrato próprio e verde (`test_v82ToV83IndexesWorkspaceUpdatedAtForRailList`).

Antes / Depois (`--filter SchemaMigrationMatrixTests`, mesmo sandbox):

| Rodada | Resultado |
|---|---|
| Antes | 31 testes, **2 falhas** (`("83") is not equal to ("82")` nas duas) |
| Depois | 31 testes, **0 falhas** |

### Item 9.2 — OWNER-UNBIND · P1 · fd fechado continuava com o binding de owner (e um revoke podia derrubar outra conexão)

Achado da varredura do `Sources/SocketServer/` (reconferido linha a linha). O caminho `POST /v1/rpc` faz o hand-off do fd para uma `Task` (PERF-114, `HTTPServer.swift:3383`) que passa a ser dona do descritor. Quatro saídas dessa Task fecham o fd **sem** liberar o binding de owner:

```
3398/3415/3432/3436  → registry.close(fd)      // AcceptedSocketRegistry.close: close(2)
2086                 → activeHTTPOwnerConnections.unbind(fd)   // só no defer da sessão, que o hand-off pula
```

Consequências medidas no código:
- `ownerByDescriptor[fd]` sobrevive ao `close(2)`; `trackedOwnerFingerprints()` (2039) passa a reportar um owner fantasma.
- `POST /v1/devices/revoke` → `closeOwnerChannels` → `ActiveHTTPOwnerConnectionRegistry.close(ownedBy:)` faz `Darwin.shutdown(fd, SHUT_RDWR)` em **todo** descritor do owner. Descritores são reciclados (cap de 64 sockets aceitos, `AcceptedSocketRegistry.defaultMaximumDescriptors`), então o número morto costuma ser um socket vivo de outro peer/requisição — revogar o device A pode derrubar a conexão do device B.
- `closeOwnerChannels()` nunca consegue confirmar "sem canais" para aquele owner.

Correção (`HTTPServer.swift`, 5 sítios + captura de `ownerRegistry` no hand-off; seam de teste em `WebSocketOutboundQueue.swift`): as quatro saídas da Task liberam o binding antes de fechar, então o mapa volta a ser exatamente o conjunto de sockets vivos com owner. Nenhuma mudança de wire, de authz ou de keep-alive.

Antes / Depois (`--filter SocketServerTests`, mesmo sandbox, mesmo workload):

| Rodada | Executados | Falhas | Delta |
|---|---|---|---|
| Antes (5 `unbind` removidos, seam + teste no lugar) | 925 (3 skip) | 720 | — |
| Depois | 925 (3 skip) | **719** | só o teste novo sai da lista |

Teste dirigido `test_rpcConnectionClose_releasesHTTPOwnerBinding` (`Connection: close` → 200 → mapa de owner em 0): **falha** sem a correção (`("1") is not equal to ("0")`), **passa** com ela.

Falhas pré-existentes do target `SocketServerTests` (9 testes distintos, idênticos nas duas rodadas — ruído de ambiente/contrato já velho, nada tocado nesta iteração): `Phase4MutationReceiptContractTests.test_everyCanonicalMutationRunsPureSyntacticPreflightBeforeReceiptClaim` (691 asserções, `-32097` em vez de `-32602`) e `.test_liveMutationRequiresClientRequestIdAndBearerOwnerOnly`; `RemoteCodeHostCatalogDispatcherTests` (4 métodos); `HTTPServerTests.test_attachmentUploadEnvelopeCarriesExact25MBAndRejectsNextDecodedByte`, `.test_authenticatedCapabilities_acceptsValidBearer_envelopeAndNoStoreCaching`, `.test_authenticatedCapabilities_acceptsRepeatedAuthorizationSpaces_extractsExactToken`; `DeviceRevokeClosesChannelsTests.test_deviceRevoke_closesOwnerWebSocketBefore200_leavesOtherDevice_rejectsRevokedToken`.

### Varredura 9.3 — cobertura medida nesta iteração (e o que ficou registrado)

Três auditorias read-only completas (leitura integral dos arquivos + call sites + testes que travam o contrato), com achados reconferidos pelo autor:

| Área varrida | Evidência | Status |
|---|---|---|
| `Sources/SocketServer/` **menos `EventBus.swift`** (26 arquivos: HTTP, Dispatcher, Unix socket, uploads v2/v3, WorkspaceFileService, chunk transfers, WS queue/batcher/parser, contratos, métricas) | varredura 9.3 | auditado; **OWNER-UNBIND corrigido**; 3 achados abertos no backlog (itens 1–3) |
| `Sources/AppShell/` — infra de energia/processo/wake (TailcatRuntimeSupervisor, TailcatTransport, InsomniaPowerManager, DirectAccessLifecycleSupervisor, ComputerUsePermissionBroker, HostFileAccessPermissions, MaterialWake*, LiveActivity*, PowerSourceMonitor, LocalAuthAdapter, SystemNotifier, StartupPlan, ConnectionFeatureFlags, PaletteFrecency, CommandPaletteFilter, KeybindingConfig) | varredura 9.3 | auditado; 4 achados abertos (itens 4–7) |
| Superfícies de terminal/pane (`TerminalSurface`, `GhosttyTerminalView`, `TerminalScrollbackPolicy`, `SSHSurface`, `PaneTabsView`, `ClosedTabRingBuffer`, file-tree do `FilesSurface`) | varredura 9.3 | auditado; 4 achados abertos (itens 8–11) |
| Testes de persistência/schema | item 9.1 | auditado + corrigido |
| **Ainda não varridas** | — | `Sources/AppShell/` restante: `BotsWindow` (13.4k linhas), `AppCommandRouter` (9.1k), `AppContext` (6.3k), `SidebarView` (5.8k), `SettingsWindow`, `MainWindowController`, `AppDelegate`, `ScheduledTask*`, `TokenSaverDistillServiceController`, `PrivateAccountIntegration`, `Pet/*`; `Sources/Surfaces/` (AgentAppSurface/BrowserSurface já cobertos por iters 2–8, restam as demais); `Sources/Persistence/` (repos individuais); `Sources/AgentRuntime/` (providers já cobertos até a iter 8) |

### Backlog (atualizado na iter 9; itens 1–11 novos, ordenados por valor ÷ escopo)

1. **`FileEditSessionStore.open` sem cap nem TTL** (`Sources/SocketServer/WorkspaceFileService.swift:557-612`): cada `files.edit.open` cria uma sessão nova com o `draftText` inteiro (≤2 MiB, `WorkspaceFileLimits.editBytes`) e um evento `files.edit.opened` com o mesmo conteúdo; a única remoção é o `close` vindo do cliente. Um device pareado em loop cresce a memória residente do Mac sem limite. Não há teste que trave o comportamento atual; o comentário de `FileEditSessionStoreClockTests:68` planeja TTL de 1 h. **Decisão embutida**: cap/evicção pode descartar rascunho não salvo de um editor aberto → precisa de política (TTL + cap alto + talvez preservar o último por (surface, path)).
2. **`files.edit.*` faz I/O de disco e SHA-256 no main actor** (`WorkspaceFileService.swift:643-670`, `724-733`, `936-941`): `save` lê até 2 MiB, hasheia, escreve temp e faz `replaceItemAt` **segurando o `lock` global**, tudo dentro de `@MainActor` (`Dispatcher`/`AppCommandRouter`). Em workspace NFS (suportado pelo próprio arquivo) congela a UI. Fix no padrão `*OffMain` já existente; escopo médio.
3. **`Content-Length` duplicado no `204` do chunk v3** (`HTTPServer.swift:5098-5101` + writer em `5534-5541`): o caller manda `Content-Length: 0` e o writer já emite o seu. RFC 7230 §3.3.2 — header duplicado é framing malformado; clientes estritos podem tratar o 204 como resposta inválida. Fix de 1 linha (remover a chave do dicionário). Teste atual só confere o status 204 (`AttachmentUploadV3Tests.swift:1018`).
4. **`LiveActivityAcceptanceOutbox` trava para sempre com um blob indecifrável** (`Sources/AppShell/LiveActivityAcceptanceOutbox.swift:340-345`): `loadUnlocked` é o único leitor e **relança** o erro de decode; `pump` engole (`:906-913`) e `accept` propaga até o coordinator. Nada reescreve o valor ruim → toda operação falha para sempre (Live Activity congela em um card velho, sem erro visível). Fix mínimo: decodificar com `try?` e tratar como backlog vazio (auto-cura no próximo `enqueue`), mantendo a regra "nunca inventar ack". Mesmo padrão em `SilentWakeOutbox.swift:263-268` — decidir os dois juntos.
5. **Insomnia: falha diferida do caminho privilegiado derruba a sessão e não atualiza o estado** (`Sources/AppShell/InsomniaPowerManager.swift:84-98`): `activate()` retorna `true` e o `pmset` privilegiado roda em background; se falhar (usuário cancela o diálogo admin, helper ausente), `deactivate()` libera as assertions **sem** atualizar `insomniaEnabled`/persistência (a pill continua "Keeping Mac awake" e o flag volta ligado no relaunch), e sem guarda de geração uma falha antiga pode derrubar a sessão mais nova. Fix: bump de geração + ligar o caminho de falha ao `finishInsomniaSession()` que o caminho síncrono já usa.
6. **`StartupPlan` não é consumido por ninguém** (`Sources/AppShell/StartupPlan.swift`): só `StartupPlanPhaseTests` referencia o tipo; `AppDelegate.runDeferredStartup()` tem a ordem hard-coded. O teste de primeira-frame não pode falhar se alguém mover o sweep/PTY para antes do `showWindow`. Fix: derivar a ordem de `StartupPlan.steps(in: .deferred)`.
7. **Revoke de device engole falha de escrita** (`Sources/AppShell/LocalAuthAdapter.swift:356-373`): `try? repo.revoke(id:)` e depois audit + evento `device.revoke` + `200 {"revoked": id}`; com `SQLITE_BUSY`/IO error o token continua válido. Fix completo muda `revokeDevice` para devolver sucesso e o handler responder 500.
8. **Reabrir aba fechada (⌘⇧T) perde metadata do descriptor** (`AppCommandRouter.reopenClosedSurface` → `makeSurface`): o `ClosedTabEntry` guarda o descriptor completo, mas `makeSurface` só reaproveita `selected_thread` (agentApp) e `workspace_cwd`. Browser volta em branco (URL existia em `metadata["url"]`), Files volta sem `files_state`/`selected_path`. Contraria a regra de persistência de workflow do AGENTS.md; fix no router (1 parâmetro defaulted + reaproveitar `restoredBrowserURL`/`files_state`), sem teste hoje.
9. **SSHSurface: timer de sessão viva pode abortar um connect em voo** (`Sources/AppShell/SSHSurface.swift:977-996`, `470-486`, `515-602`): o timer da sessão A só é parado depois dos awaits de `performConnect`; se o filho antigo morrer nessa janela, `handleUnexpectedDisconnect()` chama `invalidateConnectionRequests()` e mata o connect novo do usuário sem erro. Fix de 1 linha (parar o timer em `enqueueConnection`).
10. **Rename inline de aba: cancelar ainda commita** (`Sources/AppShell/PaneTabsView.swift:1884-1901`, `2290-2306`): `onCancel` não desliga `onCommit`, e `resignFirstResponder` commita em qualquer resign — Escape pode renomear, e Return commita duas vezes. **Confiança**: o defeito de código (commit não idempotente, cancel não suprime) é certo; o elo "AppKit chama `resignFirstResponder` ao remover da hierarquia" não foi verificado sem rodar o app — verificação barata (teste de 6 linhas com o campo numa window).
11. **`extendDeferredUnhostedReplay` copia o buffer inteiro a cada chunk de PTY** (`Sources/Surfaces/TerminalSurface.swift:2107-2121`): `guard var deferred = deferredUnhostedGhosttyReplay` cria segunda referência e `deferred.append(data)` vira COW de até ~4 MiB por chunk → O(n²) no replay Live cap. Fix: mutar in-place (box/classe ou `inout`) sem mudar o cap.
12. ~~Fixture de `SchemaMigrationMatrixTests`~~ — **fechado no item 9.1**.

**Decisões do dono que seguem abertas** (não impedem a varredura): transcript do intent de fork no undo (iter 5.2); dedup dos 2 probes do stale-stop (iters 7.2/8.3); retenção por idade de `agent_turn_checkpoints` (201 MB) e sua visibilidade no `LocalStorageBudget`; retenção de `token_saver_attempt_*` (EV-28); config LFS `--skip-smudge`; política de cap/evicção das sessões de edição (item 1 acima).

### Commits da iteração

| Commit | Item |
|---|---|
| `dec0ebab` | `test(persistence): stop the schema matrix from asserting v82 at head` (9.1) |
| `8642f61e` | `fix(socket-server): release the HTTP owner binding when the RPC task closes the fd` (9.2) |

**Fechados nesta iteração (9):** fixture v83 do schema (9.1) e o binding de owner preso no fechamento do fd do RPC (9.2, com teste que falha sem a correção). A varredura das áreas não auditadas avançou: `SocketServer` inteiro (menos EventBus), infra de energia/wake do AppShell e superfícies de terminal/pane, todos com ledger de "sem achado" por arquivo e 11 itens novos registrados acima.

## Iteração 10 — 2026-09-17

Método: `/sam-goal` + `/sam-task`. Escopo: prioridade (b) — o dedup dos 2 probes single-column do ramo stale de Stop (item 4 do backlog da iter 9, listado como "decisão do dono"); prioridade (a) — varredura de duas áreas ainda não auditadas do `AppShell` (`ScheduledTaskRuntime.swift` e `AppDelegate.swift`), sem achado de produto.

### Item 10.1 — STOP-PROBE-SHARE · P2 · o ramo stale de `stop()` lia o status duas vezes

O ramo "não há nada para parar" de `AgentAppViewModel.stop()` (`Sources/Surfaces/AgentAppSurface.swift:8960`) faz:

```
coordinator.stopRun(threadId: tid)        // F19 lê o status (probe #1)
clearStaleRunProjection(threadId: tid)    // repinta com outro `status(of:)` (probe #2)
```

Os dois probes são o mesmo `SELECT status FROM agent_threads WHERE id = ? LIMIT 1`, ambos **síncronos no main actor** (`AgentThreadRepository.status(of:)` compila um statement novo por chamada), e a medição da iter 8 (instrumentação temporária, revertida) deu `probesBefore=0 probesAfter=2 getsBefore=1 getsAfter=1` — o spec da iter 8.3 travava esse orçamento em "≤ 2".

A iter 7.2 já tinha descrito as duas saídas: (a) remover o `coordinator.stopRun(threadId:)` defensivo do ramo stale, ou (b) **passar o status entre os componentes**. A opção (b) é a que preserva a defesa contra corrida do F19 (um segundo clique de Stop, ou um Stop para uma thread há muito terminada, não pode cair nos ramos de sessão/recover e re-broadcastar `.cancelled`/respwnar provider).

Correção (3 arquivos, nenhuma mudança de wire/comportamento visível):

- `AgentRunCoordinator.stopRun(threadId:)` passa a devolver o status que o guard F19 leu — `@discardableResult ... -> AgentRunStatus?`; `nil` em todo caminho que tocou estado (handle vivo, pending start, sessão de adapter). O guard retorna antes de escrever, então o valor continua sendo "o status durável agora".
- `AgentAppViewModel.clearStaleRunProjection(threadId:durableStatus:)` aceita esse valor (`nil` = re-probe aqui, como hoje; leitura que falha continua deixando o status pintado intacto).
- O ramo stale passa o retorno do coordinator para o repaint.

Ganho medido (não estimado): **1 probe por Stop stale em vez de 2** — uma leitura SQLite a menos, uma compilação de statement a menos, um round-trip de banco no main actor a menos por clique. O spec `test_stopStaleProjection_usesStatusProbeWithoutDurableGet` saiu de "≤ `probesBefore + 2`" para `XCTAssertEqual(..., probesBefore + 1)` (exatamente 1) e o spec de fonte `test_stopStaleProjection_sourceUsesStatusProbe` passou a ter needle agnóstico de assinatura + asserção do parâmetro compartilhado (`durableStatus: AgentRunStatus? = nil`), mantendo as duas asserções originais (usa `status(of:)`, nunca o `get` de 26 colunas). O guard F19 e o contrato de `StopRunStatusProbeTests` (probe = +1 no `stopRun` idle) ficaram intactos.

Antes / Depois (`--filter` idêntico nos dois lados: `AgentAppPerfBundleTests`, `AgentAppGhostRunLatchTests`, `StopRunStatusProbeTests`, `AgentRunCoordinatorStopLifecycleTests`, `StreamBatchAtomicPersistenceTests`, `BackgroundAwaitStatusProbeTests`, `AgentRunTerminalReasonTests`, `DurableActiveRunExistenceProbeTests`; mesmo sandbox isolado):

| Rodada | Executados | Falhas | Fonte |
|---|---|---|---|
| Antes (mudança em `git stash`, HEAD `52fb1a0b`) | 120 | 0 | rev. pré-mudança |
| Depois (HEAD `19a32a9f`) | 120 | 0 | rev. commitada |
| Recorte só `AgentAppPerfBundleTests` | 71 | 0 antes / 0 depois | — |

Regressão intermediária medida e corrigida dentro da iteração: a primeira rodada "depois" deu 1 falha — `test_stopStaleProjection_sourceUsesStatusProbe` falhava no `XCTUnwrap` do needle `private func clearStaleRunProjection(threadId: AgentThreadID)` (a assinatura ganhou um segundo parâmetro, então `AgentThreadID)` deixou de existir). Não era falha de produto: o needle virou `...(threadId:` (agnóstico) e o spec passou a pinar o parâmetro novo. Nenhuma outra ocorrência do needle antigo existe no repo (`DurableActiveRunExistenceProbeTests` já usava `...(`, e foi incluído no filtro final).

### Varredura 10.2 — cobertura medida nesta iteração

Leitura integral (arquivo + call sites + specs que travam o contrato), read-only:

| Área varrida | Evidência | Status |
|---|---|---|
| `Sources/AppShell/ScheduledTaskRuntime.swift` (1.150 linhas: catálogo de usuários do sistema, preflight/erros localizados, executor in-process, scheduler `tick`/`runNow`/`claim`/`stopOwned`, reclaim de órfãos no launch, skip de ocorrências perdidas, `observeRunning` + heartbeat, notificações cross-process, XPC listener/proxy/versão, delegate do LaunchAgent legado) | varredura 10.2 | auditado; **sem achado de produto** (3 notas abaixo) |
| `Sources/AppShell/AppDelegate.swift` (2.246 linhas: abertura de DB + quarentena, onboarding TCC, wiring do EventBus, socket/HTTP/auth retention GAP-5, pairing sheet não-bloqueante, timers de reaper/CCR/heartbeat/uso, orphan sweep com latch + detached, Bonjour com geração/retry, menu/validação, deep link de notificação, `applicationWillTerminate` completo) | varredura 10.2 | auditado; **sem achado de produto** (2 notas abaixo) |
| `Sources/AppShell/ScheduledTasksWindow.swift` (1.919 linhas) | varredura 10.2 | **parcial**: seams de runtime (`store.*`, `scheduler.runNow/tick`, `listRuns/listActiveRuns`, `observeStoreChanged`); UI não lida linha-a-linha |

Notas registradas (nenhuma delas é bug acionável):

- `ScheduledTaskScheduler.runNow` responde `.success` ao chamador assim que o claim manual committa, **antes** de `execute(claim)` rodar; uma falha posterior vira linha de run `.failed` + `SystemNotifier`. É a política de "ack imediato" do AGENTS.md, não uma falha silenciosa.
- `reclaimOrphanedActiveRuns` marca "did not survive app restart" como `.failed` **sem** postar `SystemNotifier` (só o ramo de falha do `observeRunning` posta). Assimetria cosmética no cold start; nenhum retry é perdido (missed fires são skipados por contrato).
- `AppDelegate.handleDeniedPost` liga o gate "uma vez por sessão" **antes** da projeção no Pet: se a projeção falhar, o aviso in-app ainda aparece (desenho declarado no próprio código).
- Os 4 timers do `AppDelegate` (reaper 30 s, CCR 24 h, heartbeat 60 s, uso de Token Saver 60 s) e os observers são todos invalidados/removidos em `applicationWillTerminate`; `runCCRRetention()` no launch roda na `backgroundWriterQueue` com `compact: false` (sem VACUUM no caminho de abertura).

Cobertura do `AppShell` depois desta iteração — **ainda não varridas** (inalterado do resto): `BotsWindow` (13.4k linhas), `AppCommandRouter` (9.1k), `AppContext` (6.3k), `SidebarView` (5.8k), `SettingsWindow` (1.9k), `MainWindowController`, `TokenSaverDistillServiceController`, `PrivateAccountIntegration`, `Pet/*`, `BotScheduleTasksWindow`; `Sources/Surfaces/` (restam as superfícies fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs); `Sources/Persistence/` (repos individuais); `Sources/AgentRuntime/` (restante fora dos providers e dos caminhos de stop/checkpoint já cobertos).

### Backlog (repriorizado na iter 10)

Ordem sugerida para a próxima iteração (valor ÷ escopo, com o que a varredura 10.2 confirmou):

1. **Item 4 (LiveActivity/SilentWake outbox com blob indecifrável)** — o usuário vê a Live Activity congelada para sempre, sem erro; fix de ~2 linhas por arquivo nos dois outboxes, com a regra "nunca inventar ack" preservada.
2. **Item 3 (`Content-Length` duplicado no 204 do chunk v3)** — framing malformado (RFC 7230 §3.3.2), fix de 1 linha + 1 asserção de header.
3. **Item 8 (⌘⇧T perde URL/estado da aba fechada)** — contraria a regra de persistência de workflow do AGENTS.md; hoje sem teste.
4. **Item 9 (timer do SSHSurface aborta connect em voo)** — fix de 1 linha.
5. Itens 1, 2, 5, 6, 7, 10, 11 seguem abertos com o escopo registrado na iter 9 (as decisões embutidas — cap/evicção das sessões de edição, geração do Insomnia, consumo do `StartupPlan` — continuam sendo do dono).

**Decisões do dono que seguem abertas** (não impedem a varredura): transcript do intent de fork no undo (iter 5.2); retenção por idade de `agent_turn_checkpoints` (201 MB) e sua visibilidade no `LocalStorageBudget`; retenção de `token_saver_attempt_*` (EV-28); config LFS `--skip-smudge`; política de cap/evicção das sessões de edição (item 1). O **dedup dos 2 probes do stale-stop saiu desta lista**: executado no item 10.1 pela opção "passar o status entre componentes", que preserva a defesa F19.

### Commits da iteração

| Commit | Item |
|---|---|
| `19a32a9f` | `fix(agent-app): share the F19 status probe with the stale-stop repaint` (10.1) |

**Fechados nesta iteração (10):** dedup dos 2 probes do ramo stale de Stop (2 → 1 leitura por clique, travado por asserção exata) e a varredura integral de `ScheduledTaskRuntime.swift` + `AppDelegate.swift` (sem achado de produto). Pendências acionáveis seguem nos itens 1–11 do backlog, agora com ordem sugerida.

## Iteração 11 — 2026-09-17

Método: `/sam-goal` + `/sam-task`. Escopo: prioridade (b) — os dois primeiros itens da ordem sugerida pela iter 10 (`Content-Length` duplicado no 204 do chunk v3 e o outbox travado por blob indecifrável), mais a varredura (a) de `Sources/Persistence/SQLite.swift` e do caminho de reabertura de aba (`ClosedTabRingBuffer` + `AppCommandRouter.reopenClosedSurface`).

Nota de método: nesta iteração o "antes" foi medido com `git checkout <base> -- <arquivos de produção>` (não com `git stash`), porque os dois itens já estavam commitados quando o baseline-diff foi rodado. Um `git stash push` sobre árvore limpa não guarda nada e o `pop` seguinte aplica um stash antigo de outro branch — aconteceu nesta iteração, foi revertido com `git reset` + `git checkout -- .` (árvore limpa, stashes alheios preservados) e não afetou nenhum commit.

### Item 11.1 — HTTP204-DUP · P2 · o 204 do chunk v3 carregava dois `Content-Length`

`case ("PUT", .chunk)` mandava `Content-Length: 0` em `additionalHeaders` e `send` já escreve o seu (`HTTPServer.swift:5555`). Resultado: `Content-Length` duplicado em toda resposta 204 do chunk protegido — framing malformado por RFC 7230 §3.3.2, que clientes estritos podem rejeitar (o `URLSession` do teste de contrato emparelhado normaliza o header, então o defeito nunca apareceu na suíte). Só existia **um** sítio com essa chave em todo o `Sources/SocketServer/` (grep `"Content-Length"`), e o 200 de status (`sendAttachmentUploadV3Status`) já não passava a chave.

Correção: removida a chave do dicionário do caller (1 linha + comentário de uma linha explicando que `send` emite o header). Nenhuma mudança no writer compartilhado — remover o header do 204 exigiria condicionar `send`/`sendFile` e não há cliente verificável neste repo (o iOS é outro repositório).

Teste: o spec de contrato HTTP v3 passou a fazer um upload novo por **socket cru** (prepare + PUT do chunk 0) e a contar os `Content-Length` do head; o replay do chunk já commitado não serve porque o upload de 1 chunk **aposenta o manifesto ao completar** (`AttachmentUploadV3.putProtectedChunk` → `removeManifest` quando a fase deixa de ser `.receiving`, por desenho).

Antes / Depois (filtro `AttachmentUploadV3Tests`, mesmo sandbox):

| Rodada | Resultado |
|---|---|
| Antes (produção em `9749b194`) | `XCTAssertEqual failed: ("2") is not equal to ("1")` com `Content-Length: 0` duas vezes no head |
| Depois (`a087ea2f`) | passa |

### Item 11.2 — OUTBOX-SELFHEAL · P1 · blob indecifrável travava os dois outboxes para sempre

`LiveActivityAcceptanceOutboxStore.loadUnlocked` e `SilentWakeOutboxStore.loadUnlocked` eram os **únicos** leitores do blob e relançavam o erro de decode. Consequências medidas no código: `accept` propaga o erro até o sink do `LiveActivitySyncCoordinator` (a Live Activity congela num card velho, sem erro para o usuário), `candidates()` falha em todo `pump` e `compactBacklog()` falha em todo `resumePending` — e **nada** reescrevia o valor ruim, então o estado era permanente.

Correção (2 arquivos, 1 `do/catch` + 1 `Logger` por store): snapshot indecifrável passa a ser tratado como backlog vazio. Nenhum ack é inventado — as linhas já não podiam ser entregues nem confirmadas — e a próxima escrita (`enqueue`/`compactBacklog`/`acknowledge`) persiste um snapshot legível, ou seja, o outbox se auto-cura. O descarte é registrado no `os.Logger` (`live-activity-acceptance` / `silent-wake-outbox`), não engolido.

Testes novos (1 por store): escrevem `{"schema":"from-a-newer-build"}` na chave do outbox e exigem (i) leitura como backlog vazio, (ii) `enqueue`/`accept` seguinte durável e legível. Os dois falham sem a correção com `DecodingError.typeMismatch: expected value of type Array<Any>` (o do SilentWake falha dentro do próprio `loadUnlocked`, `SilentWakeOutbox.swift:267`).

Antes / Depois (`--filter 'AttachmentUploadV3Tests|SilentWakeOutboxTests|LiveActivitySyncCoordinatorTests'`, produção pré/pós, mesmo sandbox):

| Rodada | Executados | Falhas (asserções) | Specs falhando |
|---|---|---|---|
| Antes (`9749b194` para os 3 arquivos de produção) | 75 | 6 (4 unexpected) | `test_httpContractMatchesIOSPrepareCapabilityPUTAndStatus`, `testUndecodableSnapshotIsDiscardedAndAcceptRewritesIt`, `testUndecodableSnapshotIsDiscardedAndRewrittenByNextEnqueue` |
| Depois (`c4aa4085`) | 75 | **0** | — |

Recorte por família no estado final: `SilentWakeOutboxTests` 12/0, `LiveActivitySyncCoordinatorTests` 51/0, `AttachmentUploadV3Tests` 12/0. Nenhuma falha pré-existente nessas três famílias (não houve delta além dos 3 specs novos).

### Varredura 11.3 — cobertura medida nesta iteração (leitura integral, read-only)

| Área varrida | Evidência | Status |
|---|---|---|
| `Sources/Persistence/SQLite.swift` (648 linhas: abertura/WAL/busy_timeout, cache de statements com `sqlite3_reset`+clear_bindings, retry de lock transitório com teto de 8 tentativas e 2 s, `transaction` BEGIN IMMEDIATE com restauração do contador de eventos no rollback, `readTransaction` BEGIN DEFERRED, `enableFullDurability`, `installOwnedMaintenance` single-owner, `deinit` finalizando o cache antes do `close`) | varredura 11.3 | auditado; **sem achado acionável** (2 notas abaixo) |
| `Sources/AppShell/ClosedTabRingBuffer.swift` (64 linhas) + `AppCommandRouter.reopenClosedSurface` (`:1764-1781`) | varredura 11.3 | auditado; confirma o item 8 do backlog (aba de browser/Files volta sem URL/estado) |
| `AppCommandRouter.reinstantiateRestoredSurfaces` (`:640-770`, caminho de restore do launch) | varredura 11.3 | auditado: é o caminho que **já** usa `restoredBrowserURL(from:)` e `files_state`/`selected_path` — o fix do item 8 é reaproveitar isso em `makeSurface` |
| `AttachmentUploadV3.putProtectedChunk` + `status` (via teste do item 11.1) | item 11.1 | auditado: manifesto é removido quando o upload deixa de estar `.receiving`; replay de chunk já commitado responde 404 `upload_not_found` **por desenho** |

Notas registradas (nenhuma é bug acionável hoje):

- `SQLiteStatement.columnBlob` devolve `nil` tanto para SQL NULL quanto para blob de 0 bytes, e `bind(_:Data?)` com `Data()` grava SQL NULL (ponteiro nulo + n=0), não `X''`. Conferido nos 6 leitores e 5 escritores de blob do repo: todos tratam `nil` como ausente/0 byte e o único round-trip que exige igualdade (`TokenSaverT003Persistence` read-back) **falha alto** (`durableReadBackFailed`) em vez de corromper. Fica registrado como assimetria de baixo valor (o dado "presente mas vazio" é indistinguível de ausente).
- `reasonPhrase(204)` cai no `default: "OK"` (`HTTPServer.swift:5702`) → o 204 sai como `HTTP/1.1 204 OK`. Cosmético (o reason-phrase é advisory), 1 linha, registrado no backlog abaixo; não entrou no commit do item 11.1 para não misturar escopo.

### Backlog (repriorizado na iter 11)

1. **Item 8 (⌘⇧T perde URL/estado da aba fechada)** — reconfirmado no fonte; hoje o **primeiro** da fila. Fix mapeado: `makeSurface(... restoringFrom: SurfaceDescriptor? = nil)` reaproveitando `restoredBrowserURL(from:)` e `metadata["files_state"]/["selected_path"]` como o caminho de restore do launch já faz.
2. **Item 9 (timer do SSHSurface aborta connect em voo)** — fix de 1 linha.
3. **Item 2 (`files.edit.*` faz I/O + SHA-256 no main actor segurando o lock)** — escopo médio, padrão `*OffMain` já existe.
4. **Item 1 (`FileEditSessionStore.open` sem cap/TTL)** — política é decisão do dono.
5. Itens 5, 6, 7, 10, 11 seguem abertos com o escopo da iter 9 (geração do Insomnia, consumo do `StartupPlan`, 500 no revoke, rename inline de aba, COW do replay unhosted).
6. **Novo — `reasonPhrase(204)` devolve "OK"** (cosmético, 1 linha, sem cliente afetado).

**Fechados nesta iteração (11):** item 3 (`Content-Length` duplicado no 204 do chunk v3) e item 4 (outbox travado por blob indecifrável, nos dois outboxes, com auto-cura registrada no log).

**Áreas ainda não varridas** (não mudou nesta iteração): `AppShell` — `BotsWindow` (13.4k), `AppCommandRouter` (9.1k, varredura parcial: reopen/restore/makeSurface), `AppContext` (6.3k), `SidebarView` (5.8k), `SettingsWindow`, `MainWindowController`, `ScheduledTasksWindow` (parcial), `TokenSaverDistillServiceController`, `PrivateAccountIntegration`, `Pet/*`, `BotScheduleTasksWindow`; `Sources/Surfaces/` (restam as superfícies fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs); `Sources/Persistence/` (restantes: `Repositories.swift` 10.9k, `BotRemoteControlAuthority`, `TokenSaverT003Persistence`, `BotStore`, `Schema`, …); `Sources/AgentRuntime/` (restante fora dos providers e dos caminhos de stop/checkpoint).

**Decisões do dono que seguem abertas** (não impedem a varredura): transcript do intent de fork no undo (iter 5.2); retenção por idade de `agent_turn_checkpoints` (201 MB) e sua visibilidade no `LocalStorageBudget`; retenção de `token_saver_attempt_*` (EV-28); config LFS `--skip-smudge`; política de cap/evicção das sessões de edição (item 1).

### Commits da iteração

| Commit | Item |
|---|---|
| `a087ea2f` | `fix(socket-server): emit one Content-Length on the v3 chunk 204` (11.1) |
| `c4aa4085` | `fix(app-shell): recover the wake/acceptance outboxes from an undecodable blob` (11.2) |

## Iteração 12 — 2026-09-18

Método: `/sam-goal` + `/sam-task`, com a varredura (a) delegada a dois workers read-only (`/sam-orchestrate`; nenhum dos dois escreveu em disco, build ou git). Escopo: prioridade (b) — item 1 do backlog (⌘⇧T reabrindo a aba sem URL/estado) — mais a varredura (a) das duas maiores áreas ainda não varridas: `Sources/AppShell/SettingsWindow.swift` (3.461 linhas) e `Sources/Persistence/Repositories.swift` (10.930 linhas), ambas lidas na íntegra.

Nota de método (A/B): o "antes" foi medido com `git checkout HEAD -- Sources/AppShell/AppCommandRouter.swift` (o fix ficou salvo em `/tmp/rc-iter12-AppCommandRouter.fixed.swift`, `md5 be6a0493…`), nunca com `git stash`.

### Item 12.1 — REOPEN-STATE · P1 · ⌘⇧T reabria a aba fechada sem o alvo/estado dela

`reopenClosedSurface` reconstruía a aba só com tipo/título/cwd: o `ClosedTabEntry` já guardava o descriptor inteiro, mas `makeSurface` não olhava para ele. Efeito medido por teste (baseline = produção, mesmo sandbox, filtro `ReopenClosedSurfaceStateTests`):

| Rodada | Executados | Falhas (asserções) |
|---|---|---|
| Antes (produção `90fac1f5`) | 4 | **10** |
| Depois (`6fa1633b`) | 4 | **0** |

O que o baseline mostrou, por tipo de aba:

- **browser**: o descriptor reaberto não ficava sem URL — ficava com `https://www.remotecode.io/from-app`, a **start page**. `BrowserSurface.init` navega para `initialURL ?? Self.defaultInitialURL` e `publishNavigationChange` → `persistBrowserNavigation` grava isso por cima do descriptor novo, ou seja ⌘⇧T **sobrescrevia** a URL que a aba tinha. O iOS recebia o mesmo alvo errado pelo snapshot de conexão.
- **browser de bot**: `bot_id` ausente no descriptor reaberto → a aba sairia do `WKWebsiteDataStore` do bot (cookies/sessão) e `persistBrowserNavigation` deixaria de gravar o alvo em `BotBrowserStore` (o fallback de restore do launch, `:677-683`, só existe no launch).
- **Files**: `files_state`, `selected_path` e a `revision` voltavam nil/0 → aba na raiz do workspace, sem seleção, e snapshot de conexão mandando revision 0 para o iOS (o estado do dispositivo pareado parece mais novo).
- **SSH conectado**: voltava como `SSHSurface` (picker de perfil), não como o terminal ssh vivo — a sessão que o usuário tinha fechado.
- **markdown / filePreview**: `path` vinha de `title`; o `metadata["path"]` do descriptor era ignorado.
- **agentApp / terminal**: já corretos (thread selecionada e cwd).

Correção (1 arquivo de produção, +45/−16, reaproveitando o que o restore do launch já sabia ler): `makeSurface(..., restoringFrom: SurfaceDescriptor? = nil)` passa a derivar `restoredBrowserURL(from:)`, `metadata["bot_id"]`, `metadata["files_state"]`/`["selected_path"]`, `metadata["path"]` e `sshProfile(from:)`; `reopenClosedSurface` passa `entry.descriptor`. Dois keys que as superfícies não conseguem re-derivar no `init` — a URL do browser (só escrita no primeiro callback de navegação; mesma razão do comentário em `makeBrowserSurface`) e o espelho `files_state_revision` — são carregados para o descriptor novo, para reabrir + reiniciar cair na mesma aba.

Testes novos (4, `Tests/AppShellTests/ReopenClosedSurfaceStateTests.swift`): URL do browser fechado, binding de bot, state + seleção + revision do Files, e ssh conectado reabrindo como terminal vivo. Cada um falha no fonte de produção com a asserção que descreve o defeito.

**Equivalência do caminho nil** (por que o fix não pode afetar `createSurface`/`splitPane`/`ensureGitSurface`): com `restoringFrom == nil` toda expressão nova é `nil ?? <literal antigo>` — `initialURL: nil`, `botID: nil` (default da assinatura), `initialState: nil`, `selectedPath: nil`, `restore?.metadata["path"] ?? title` = `title` — o ramo `else` do ssh é o corpo antigo e o merge final é pulado. Conferido no `diff` completo produção→fix.

**Famílias vizinhas** (`--filter ClosedTabRingBufferTests|PersistenceRestoreTests|SplitLayoutRuntimeTests|AppLifecycleTests|ConnectionSnapshotRouterPhase3Tests|FilesViewModelRoutingTests|SSHSurfaceForTestingHooksTests|PetWorkspaceSurfaceRoutingTests|AgentSurfaceThreadBindingRouterTests|ReopenClosedSurfaceStateTests`, mesmo sandbox):

| Rodada | Executados | Falhas | Quais |
|---|---|---|---|
| Antes (produção `90fac1f5`) | 102 | 10 | apenas os 10 dos meus testes novos |
| Depois (`6fa1633b`), rodada combinada | 102 | 1 | `SplitLayoutRuntimeTests.test_horizontalSplit_panesAreEqualWidthAtRuntime` ("RatioSplitView must exist") |
| Depois (`6fa1633b`), família isolada | 6 | 0 | — |

`SplitLayoutRuntimeTests` isolado passa 6/6 com o fix (11,3 s) e passou na rodada combinada do baseline; o spec é sensível a tempo (`drainMainQueue(0.05)` + `layoutSubtreeIfNeeded` na árvore de views). A rodada combinada "depois" rodou com a máquina sob carga de outros worktrees (`uptime` com load 20–30; `xctest` de `agent-app-memperf-20260911T151128Z` e `xcodebuild` do runner iOS em paralelo). A tentativa de replicar a rodada combinada ficou **36 min parada com ~0% de CPU** (processo dormindo) e foi encerrada sem resultado. Registro honesto: **spec flaky sob carga, não atribuído à mudança** — além do isolado verde, o caminho nil é comportamento idêntico ao de produção (diff acima) e `SplitLayoutRuntimeTests` não fecha nem reabre aba nenhuma. Nenhuma falha pré-existente nova apareceu nas famílias medidas (baseline combinado = 102/10, todas as 10 minhas).

### Varredura 12.2 — cobertura medida nesta iteração (delegada, leitura integral, read-only)

| Área varrida | Evidência | Status |
|---|---|---|
| `Sources/AppShell/SettingsWindow.swift` (3.461 linhas: VM, observers, pareamento, storage, Token Saver, tailcat, atualização) | varredura 12.2 | auditado; **sem P1**; 10 achados (6×P2, 4×P3) no backlog |
| `Sources/Persistence/Repositories.swift` (10.930 linhas, 15 blocos contíguos de ~800–1000) | varredura 12.2 | auditado; 4×P1 + 5×P2 + 2×P3 no backlog |
| `Sources/Persistence/SQLite.swift` + `Schema.swift` + `EventLog.swift` (conferência dos callees dos achados) | varredura 12.2 | auditado; sem achado próprio |
| `Sources/AppShell/ActiveThreadsWindow.swift` (leitor de `agent_runs` no main actor, `:10`/`:153`/`:155`) | varredura 12.2 | auditado; achado P1 registrado (índice + retenção) |

Verificado pelo loop (não só reportado pelo worker): `attachmentsJSON` devolve `"[]"` no `try?` do encode (`Repositories.swift:4562`); `deleteByPrefix` sem nenhum chamador no repo (`:10916`) enquanto `agent.history.partial.<threadID>` é gravado e nunca apagado (`:6302`); `listRecent` desempata por `id` UUID (`:3303`) enquanto `listPage` já documenta o mesmo defeito e corrige com `rowid` (`:3552-3558`).

### Backlog (repriorizado na iter 12)

1. **`attachmentsJSON` engole falha de encode e grava `"[]"`** (`Repositories.swift:4562-4564`) — perda silenciosa em `enqueue`/`upsert`/`update`; o caminho irmão em `:3680-3685` já lança `SQLiteError.execute`. Fix de 1 função (tornar `attachmentsJSON` throwing). **Menor escopo, próximo da fila.**
2. **`listRecent` desempata por UUID em vez de `rowid`** (`:3303`) — `created_at` é gravado com precisão de segundo, então empates são comuns; `listPage` corrigiu exatamente isso com `rowid` e comentário próprio. Fix de 1 linha.
3. **`settings` key `agent.history.partial.<threadID>` nunca apagada** (`:6299`/`:6309`; `deleteByPrefix` sem chamador) — 1 linha permanente por thread que já podou stream. Fix: chamar `deleteByPrefix` no delete da thread.
4. **`command_receipts` sem prune** (`:8601` insert; nenhum `DELETE FROM command_receipts` no repo, só `command_receipt_events` em `EventLog.swift:51`) — P1 de disco; mexer exige decidir a janela de idempotência → **decisão do dono**.
5. **`provider_pending_callbacks` nunca removido + leitura sem `LIMIT`** (`:9111` insert, `:9082-9098` list com `ORDER BY` e sem `LIMIT`; `resolve`/`markStale` só dão UPDATE).
6. **`agent_runs` sem retenção e sem índice em `finished_at`** (`:4841` insert, `:5132` leitura no main actor via `ActiveThreadsWindow`; `Schema.swift:184` só indexa `thread_id`) — índice exige bump de schema; retenção é política.
7. **SettingsWindow (varredura 12.2)**: escrita SQLite por tecla em 4 campos (`:835-856`, `:971-974` + `SettingsStore.update` faz get+encode+set); falha de enable do Token Saver engolida (`:817-824` usa só `outcome.isEnabled`); QR de pareamento expirado continua na tela (`:2479` sem checar `expiresAt`); "Dismiss" do banner de startup não gruda (`:1603` limpa só a cópia do VM); `SettingsViewModel` construído com `loadImmediately: true` no launch (`AppDelegate.swift:262`); 5 observers disparando `reload()` completo sem coalescing (`:535-566`).
8. **Itens antigos que seguem abertos**: 2 (timer do SSH abortando connect em voo), 3 (`files.edit.*` com I/O + SHA-256 no main actor), 4 (`FileEditSessionStore` sem cap/TTL — política é decisão do dono), Insomnia (geração, consumo do `StartupPlan`, 500 no revoke), rename inline de aba, COW do replay unhosted, `reasonPhrase(204)` = "OK".

**Áreas ainda não varridas** (atualizado): AppShell — `BotsWindow` (13.4k), `AppCommandRouter` (9.1k, varredura parcial: reopen/restore/makeSurface/files state/browser/ssh), `AppContext` (6.3k), `SidebarView` (5.8k), `MainWindowController`, `ScheduledTasksWindow` (parcial), `TokenSaverDistillServiceController`, `PrivateAccountIntegration`, `Pet/*`, `BotScheduleTasksWindow`; `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs); `Sources/Persistence/` (restantes: `BotStore`, `Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority`, `SettingsStore` além dos setters citados); `Sources/AgentRuntime/` (fora dos providers e dos caminhos de stop/checkpoint).

**Decisões do dono que seguem abertas** (não impedem a varredura): transcript do intent de fork no undo; retenção por idade de `agent_turn_checkpoints` (201 MB) e sua visibilidade no `LocalStorageBudget`; retenção de `token_saver_attempt_*` (EV-28); janela de retenção de `command_receipts`; config LFS `--skip-smudge`; política de cap/evicção das sessões de edição (item 4).

### Commits da iteração

| Commit | Item |
|---|---|
| `6fa1633b` | `fix(app-shell): reopen a closed tab with its URL, files state and ssh target` (12.1) |

## Iteração 13 — 2026-09-18

Método: `/sam-goal` + `/sam-task`, varredura (a) delegada a dois workers read-only (`/sam-orchestrate`). Começou pelo **merge de `origin/production`** (2 commits novos: Token Saver comprimindo tool results do Grok via `PostToolUse`, `2c2d01b3`/`781987e2`) e pela **remedição do baseline** exigida depois de merge: filtro do neighborhood (`AgentSurfaceThreadBindingRouterTests|ClosedTabRingBufferTests|PersistenceRestoreTests|SplitLayoutRuntimeTests|ReopenClosedSurfaceStateTests`) → **61 executados, 0 falhas** (o fix da iter 12 sobreviveu ao merge; `SplitLayoutRuntimeTests` passou 6/6, consistente com o diagnóstico de flaky da iter 12).

### Item 13.1 — LISTRECENT-ORDER · P2 · a janela mais recente desempatava por UUID

`listRecent` (`Repositories.swift:3303`) ordenava por `created_at DESC, id DESC`. `created_at` é gravado com precisão de segundo, então mensagens do mesmo turno empatam o tempo todo e o desempate caía no UUID — exatamente o defeito que `list()` e `listPage()` já documentam e corrigem com `rowid` (PERSISTENCE-DATA-004, `:3552-3558`). Efeito: o par volta invertido e a UI pinta a resposta acima do prompt.

Correção: 1 linha (`ORDER BY created_at DESC, rowid DESC`) + comentário apontando a regra e o teste. Teste novo em `MessageOrderingTieBreakerTests` (o arquivo que já guarda a família).

Antes / Depois (mesmo filtro, mesmo sandbox; o "antes" rodou com o fonte de produção e o teste novo):

| Rodada | Executados | Falhas | Qual |
|---|---|---|---|
| Antes | 58 | **1** | `test_sameSecond_listRecent_returnsInsertionOrder` → `("[\"a-second\", \"z-first\"]") is not equal to ("[\"z-first\", \"a-second\"]")` |
| Depois | 65 | **0** | — |

(o "depois" tem 65 porque o filtro ganhou `SettingsFirstFrameTests` e o teste novo do item 13.2.)

### Item 13.2 — PAIRING-QR-EXPIRY · P3 · o QR do pareamento continuava na tela depois de expirar

O bloco do QR ficava **fora** do `TimelineView` do countdown (`SettingsWindow.swift:2475-2482`), então renderizava sempre que havia payload: o botão de copiar desabilitava e o rótulo dizia "Expired", mas o QR seguia escaneável para um alvo que o servidor já rejeita — e o comentário logo acima afirmava o contrário ("hidden once expired"). `pairingQRPayload` só é limpo quando uma nova geração **falha** (`:1246`).

Correção: o gate virou `livePairingQRPayload(_:)` na costura pura que o arquivo já usa para isso (`PairingCodeCountdownPresentation`, o mesmo padrão que `PairingCountdownTests` testa) e o bloco foi movido para dentro do timeline, de modo que o mesmo tick de 1 s que acinzenta o código remove o QR.

**Nota de honestidade do A/B:** este item **não tem baseline vermelho por teste** — a costura não existia, então o teste novo não compila contra o fonte antigo (`value of type 'PairingCodeCountdownPresentation' has no member 'livePairingQRPayload'`, medido). O "antes" aqui é prova de código (bloco fora do timeline, sem estado de expiração no escopo) + o erro de compilação, não uma asserção falhando. O "depois" é verde com a família vizinha de pareamento/Settings.

### Varredura 13.3 — cobertura medida nesta iteração (delegada, leitura integral, read-only)

| Área varrida | Evidência | Status |
|---|---|---|
| `Sources/AppShell/BotsWindow.swift` (13.414 linhas, lidas por inteiro) | varredura 13.3 | auditado; **1×P1**, 9×P2, 3×P3 no backlog |
| `Sources/AppShell/AppContext.swift` (6.298 linhas, lidas por inteiro) | varredura 13.3 | auditado; **sem P1**; 6×P2, 3×P3 no backlog |
| Callees conferidos: `BotStore.list(includeHidden:)`, `AgentSkillInstaller` (`:1360-1543`, `:1878-1885`), `TokenSaverUsageStore.recordAccountUsage`, `SidebarView:565-586/750-805` | varredura 13.3 | auditado; sem achado próprio |

**Achado P1 verificado pelo loop (não só reportado):** esconder um bot apaga — de forma diferida — os rascunhos salvos e as filas de follow-up dele. `reloadFleet` monta o roster já filtrado (`BotsWindow.swift:6802` `botStore.list(includeHidden: showHidden)`), e `pruneQueuedFollowUpsToFleet`/`pruneStudioDraftsToFleet` (`:7454-7459`, `:7576-7583`) podam contra esse conjunto: `persistQueuedFollowUps` roda `botStore.deleteQueuedFollowUps(botID:)` para todo bot fora do mapa (`:7496-7497`) e o `draftPersistenceAuthority.retainStudioDrafts(for: live)` apaga os rascunhos. `BotStore.list` **não** apaga o bot oculto (o filtro é só de query: `hidden = 0` / `deleted_at IS NULL`), então o dado existia e é destruído. O toggle em si (`applyShowHiddenLocally`/`applyHiddenLocally`, `:5531-5552`) só remove o bot da lista em memória; a destruição acontece no próximo `reloadFleet()` enquanto ele está oculto. Fix de menor escopo: podar contra `try? botStore.list(includeHidden: true)`.

### Backlog (repriorizado na iter 13)

1. **P1 — esconder bot apaga rascunhos/fila (BotsWindow)** — fix mapeado acima (podar contra o roster com ocultos). **Próximo da fila.**
2. **BotsWindow P2**: `send()` limpa composer/anexos/rascunho antes da escrita que pode falhar (`:6041-6073`); chip provider·model do rail de threads fica permanentemente velho (cache só limpo no caminho frio, `:7321-7323` vs `:9495`); watch de 2 s faz SQLite no main por tick (`:9100-9105`); `refreshActiveBotCount()` no main e 2× por run terminado (`:3684`, `:10594`/`:10608`); até 3 reloads completos por delta de handoff (`:6930-6932`, `:10479-10486`); 2 `stat` de filesystem por avaliação do composer (`:7788-7790` vs TTL em `:7795-7800`); `searchText` grava UserDefaults por tecla (`:3068-3070`); toda mutação de fila reescreve a tabela inteira com `createdAt: Date()` (`:7494-7512`); deletar bot deixa caches residentes (`:5576-5588`).
3. **AppContext P2**: installers de Token Saver rodam por turno, no main, relendo PATH + 4 MCP configs (`:2128`, `:2134-2165`, `:2285-2333`); `graphifyItemBuffers` sem cap e com saída que vaza entrada (`:792`, `:6050-6053`); heal de 7 dias da economia sincrônico no boot (`:5607-5615`); `usage.json` read-modify-write no main por evento (`:3122`, `:3193`, `:3276`); retry eterno de 0,75 s em falha de escrita de usage (`:5349-5353`); leitura de fila que falha é tratada como fila vazia e derruba o drain (`:1877-1878`).
4. **Item 3 da iter 12 segue aberto**: `agent.history.partial.<threadID>` nunca apagado; `deleteByPrefix` sem chamador. Ficou maior do que parecia: há **3 caminhos de delete de thread** (`Repositories.swift:1581` single, `:1673-1683` vítima do cap, `:2355-2366` bulk), então a limpeza precisa cobrir os três.
5. **Reclassificado (não é bug) — `attachmentsJSON` devolvendo `"[]"`** (`Repositories.swift:4563`): o guard é **inalcançável** hoje (`AgentAttachment` só tem `String?`/`Int?`/enum — todo campo é primitivo JSON), então trocá-lo por `throw` seria endurecer cenário impossível e nenhum teste conseguiria falhar antes. Fica registrado como assimetria; a variante alcançável é a leitura (`decodeAttachments` devolve `[]` em linha corrompida) e essa precisa de decisão do dono porque surfacing muda UI.
6. **Antigos que seguem abertos**: timer do SSH, `files.edit.*` no main actor, `FileEditSessionStore` sem cap/TTL (decisão do dono), Insomnia (geração/`StartupPlan`/500 no revoke), rename inline de aba, COW do replay unhosted, `reasonPhrase(204)`, `command_receipts` sem prune (decisão do dono), `provider_pending_callbacks`, índice/retenção de `agent_runs`, itens de `SettingsWindow` da iter 12.

**Áreas ainda não varridas** (atualizado): AppShell — `AppCommandRouter` (9.1k, parcial), `SidebarView` (5.8k), `MainWindowController`, `ScheduledTasksWindow` (parcial), `TokenSaverDistillServiceController`, `PrivateAccountIntegration`, `Pet/*`, `BotScheduleTasksWindow`; `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs); `Sources/Persistence/` (`BotStore`, `Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority`, `SettingsStore` além dos setters); `Sources/AgentRuntime/` (fora dos providers e dos caminhos de stop/checkpoint).

### Commits da iteração

| Commit | Item |
|---|---|
| `658bd55b` | merge de `origin/production` (Token Saver/Grok PostToolUse) |
| `f2aa9d1e` | `fix(persistence): tie-break listRecent on rowid like list() and listPage()` (13.1) |
| `e3318838` | `fix(agent-app): drop the pairing QR the moment its code expires` (13.2) |

## Iteração 14 — 2026-09-18

Método: `/sam-goal` + `/sam-task`. Conserto do **P1 herdado da iter 13** (fila e rascunhos destruídos ao esconder um bot) e varredura (c) de uma área não auditada, delegada a um worker read-only (`/sam-orchestrate`).

### Item 14.1 — HIDE-PRUNES-USER-WORK · P1 · esconder um bot apagava a fila de follow-up e os rascunhos dele

Confirmado no fonte **antes** de corrigir: `reloadFleet` pedia o roster já filtrado (`botStore.list(includeHidden: showHidden)`, `BotsWindow.swift:6802`) e os cinco pruners derivavam dele o conjunto "vivo" (`let live = Set(bots.map(\.id))`). Com o bot oculto, o próximo `reloadFleet()` rodava `retain*Drafts(for: live)` e, pior, `persistQueuedFollowUps()`, que chama `botStore.deleteQueuedFollowUps(botID:)` para todo bot fora do mapa (`:7500-7504`): a fila era **apagada do SQLite**, não só escondida. `BotStore.setHidden` só escreve `hidden = 1` (`BotStore.swift:402-412`) — a linha continua em `bots` —, então o dado existia e era destruído; reexibir não trazia nada de volta.

Correção (menor escopo): o roster passa a vir de `list(includeHidden: true)` **uma vez** e a lista de exibição é derivada em memória (`bots = showHidden ? roster : roster.filter { !$0.hidden }`, equivalente ao filtro SQL `hidden = 0` — a coluna é `INTEGER NOT NULL DEFAULT 0`, `Schema.swift:1200`). Os cinco pruners passaram a receber o conjunto vivo por parâmetro (`pruneQueuedFollowUpsToFleet(live:)`, `pruneComposerDraftsToFleet(live:)`, `pruneInspectorDraftsToFleet(live:)`, `pruneStudioDraftsToFleet(live:)`, `pruneUnpublishedNewBotIDs(live:)`), montado de `roster`: só apaga o que o store realmente não tem (bot deletado — comportamento que o teste `test_deletedBotDropsItsQueuedFollowUp` trava). Nenhuma query extra: continua **1** `list()` por reload.

Antes / Depois (mesmo filtro, mesmo sandbox; o "antes" rodou com `git checkout HEAD~1 -- Sources/AppShell/BotsWindow.swift` e os testes novos já commitados — o teste compila contra o fonte antigo, usa só API pública):

| Rodada | Executados | Falhas | Qual |
|---|---|---|---|
| Antes | 2 | **4** | `test_hidingATeammateKeepsTheQueuedFollowUp…`: `XCTAssertTrue` sobre `listAllQueuedFollowUps()` + 2× `("[]") is not equal to ("["keep while hidden"]")`; `test_hidingATeammateKeepsTheComposerDraft…`: `("") is not equal to ("unsent on Piper")` |
| Depois | 2 | **0** | — |

Família vizinha (hide/show + rascunhos + fila), **mesmo filtro antes/depois** — sem falha pré-existente na família e sem regressão:

| Rodada | Executados | Falhas |
|---|---|---|
| Antes | 14 | **4** (todas nos 2 testes novos deste item) |
| Depois | 14 | **0** |

Filtro da família: `BotsWindowTests/test_(hiddenBotsAreExcludedFromDefaultFleet|queuedFollowUp|composerDraft|deletedBotDropsItsQueuedFollowUp|hidingATeammateKeeps|showHiddenSurvivesRelaunch|showHiddenDoesNotReloadFleet|setHiddenDoesNotReloadFleet|rosterHiddenShowsOnTheRow|deskSendAdmitsAndClearsAttachments)`. `git status` conferido limpo depois de cada restore.

### Varredura 14.2 — `Sources/AppShell/SidebarView.swift` (5.834 linhas) — **sem P1**

Lida na íntegra por worker read-only (nenhum arquivo tocado) e com os callees conferidos (`AppCommandRouter.listWorkspaces/isWorkspaceBusy`, `AppContext.activeAgentThreadTitles`, `PowerSourceMonitor`, `TokenSaverUsageStore.load/record`, `TokenSaverModelInstaller.distillDirectory`). **Zero P1, zero cache sem cap** (`busyStateCache`, `busyTooltipCache`, `busySurfaceTitlesCache`, `filteredWorkspacesCache`, `tokenSaverInstalledModelSizeCache` são todos limpos ou de entrada única; `removedWorkspaceStack` capado em 10; 6 observers removidos no `deinit`).

Verificados por mim no fonte (linha citada conferida, consequência descrita):

| # | Linhas | Defeito | Consequência |
|---|---|---|---|
| 1 | `:1153-1177` | o observer one-shot de conclusão escuta `.rc2TokenSaverUsageChanged` com `object: nil`, mas essa notificação também é postada por caminhos **locais** (ex.: `:1286`, logo após `beginTokenSaverModelDownload`) | um evento local resolve a espera do probe de CLI e carimba `tokenSaverAccountUsageLastUpdated = Date()`: o popover afirma "atualizado agora" para uma consulta de conta que não terminou |
| 2 | `:3364-3365` | `try? FileManager.default.removeItem(...)` seguido de `recordInstalledTokenSaverModelBytes(0, …)` | falha ao apagar (permissão/arquivo em uso) é reportada como sucesso: o cache fica com 0 bytes, a linha "Delete model (N GB)" desaparece e os arquivos continuam no disco |
| 3 | `:1627-1638` + `:1294-1308` | `volumeFreeDiskBytes()` devolve `0` quando a leitura falha; `downloadConfirmDecision` compara `0 < modelBytes + margin` → `.insufficientDisk` → alerta "Not enough disk space" sem segundo botão e `guard confirmed else { return }` | volume ilegível vira "disco cheio": o modelo local fica **indownloadável pela UI**, com afirmação falsa sobre espaço e sem override |
| 4 | `:1845-1858` (+ call sites `:1833`, `:1942`) | `catch { return false }` sem surfacing, e o retorno é descartado por `newWorkspace()` e pelo drop do Finder | usuário escolhe/arrasta uma pasta, o painel fecha e **nada acontece** — sem linha, sem erro |
| 5 | `:5510-5514` | `dropUpdated` reatribui `dragScrollEdge` (@Published, `:421`) a cada movimento do ponteiro, sem comparar antes (os vizinhos `dropExited`/`dropEntered` comparam, `:5477`, `:5500`) | body inteiro do `SidebarRootView` reavaliado a 60-120 Hz durante o drag, para um valor que é `0` no meio da lista |
| 6 | `:2986-3000` | o timer de auto-scroll do drag só é invalidado dentro do próprio `onChange`; `onDisappear` **não existe no arquivo** (grep) | se o ramo da lista sai de cena com `dragScrollEdge != 0`, o `Timer` de 16 Hz continua rodando com o proxy capturado |

Reportados pelo worker, **não reverificados** por mim (linhas conferidas por amostragem; entram no backlog como "a confirmar"): `:833-871` popover de Token Saver faz N+1 de SQLite no main **incluindo write** (`ensureDefaults` por projeto); `:1431-1443`/`:3193` walk síncrono da árvore Distill dentro do `body` no toggle; `:584`/`:779-782` heal de 7 dias da economia no caminho de boot do main actor; `:3578-3579` "Today" segue mostrando o total de ontem depois da meia-noite (o clock de virada só mexe em `tokenSaverNow`); `:1766`, `:2122`, `:2126`, `:2257`, `:2309` `try?` engolindo mutações do router (seleção selecionada localmente "volta" no próximo reload; reorder/cor/`pin` descartados sem feedback).

### Backlog (repriorizado na iter 14)

1. **SidebarView P2 (novos, 6 verificados)** — os de maior valor são o frescor fabricado do account usage (#1), o "Delete model" que mente (#2) e o disco ilegível que bloqueia o download (#3).
2. **BotsWindow P2** (seguem): `send()` limpa composer/anexos/rascunho antes da escrita que pode falhar (`:6041-6073`); chip provider·model do rail de threads permanentemente velho (`:7321-7323` vs `:9495`); watch de 2 s faz SQLite no main por tick (`:9100-9105`); `refreshActiveBotCount()` no main e 2× por run terminado (`:3684`, `:10594`/`:10608`); até 3 reloads completos por delta de handoff (`:6930-6932`, `:10479-10486`); 2 `stat` de filesystem por avaliação do composer (`:7788-7790` vs TTL `:7795-7800`); `searchText` grava UserDefaults por tecla (`:3068-3070`); toda mutação de fila reescreve a tabela inteira com `createdAt: Date()` (`:7494-7512`); deletar bot deixa caches residentes (`:5576-5588`).
3. **AppContext P2** (seguem): installers de Token Saver por turno no main relendo PATH + 4 MCP configs (`:2128`, `:2134-2165`, `:2285-2333`); `graphifyItemBuffers` sem cap e saída que vaza entrada (`:792`, `:6050-6053`); heal de 7 dias no boot (`:5607-5615`); `usage.json` read-modify-write no main por evento (`:3122`, `:3193`, `:3276`); retry eterno de 0,75 s em falha de escrita de usage (`:5349-5353`); leitura de fila que falha tratada como fila vazia (`:1877-1878`).
4. **Item 3 da iter 12 segue aberto**: `agent.history.partial.<threadID>` nunca apagado; `deleteByPrefix` sem chamador; 3 caminhos de delete de thread (`Repositories.swift:1581`, `:1673-1683`, `:2355-2366`).
5. **Antigos que seguem abertos**: timer do SSH, `files.edit.*` no main actor, `FileEditSessionStore` sem cap/TTL (decisão do dono), Insomnia (geração/`StartupPlan`/500 no revoke), rename inline de aba, COW do replay unhosted, `reasonPhrase(204)`, `command_receipts` sem prune (decisão do dono), `provider_pending_callbacks`, índice/retenção de `agent_runs`, itens de `SettingsWindow` da iter 12, `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono), EV-28 (`token_saver_attempt_*`).

**Áreas ainda não varridas** (atualizado): AppShell — `AppCommandRouter` (9.1k, parcial), `MainWindowController`, `ScheduledTasksWindow` (parcial), `TokenSaverDistillServiceController`, `PrivateAccountIntegration`, `Pet/*`, `BotScheduleTasksWindow`; `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs); `Sources/Persistence/` (`BotStore`, `Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority`, `SettingsStore` além dos setters); `Sources/AgentRuntime/` (fora dos providers e dos caminhos de stop/checkpoint). ~~`SidebarView`~~ (feito na 14.2).

### Commits da iteração

| Commit | Item |
|---|---|
| `51e32151` | `fix(bots): keep a hidden teammate's drafts and queued follow-ups on reload` (14.1) |

## Iteração 15 — 2026-09-18

Método: `/sam-goal` + `/sam-task`. Correção do P2 de maior valor em `SidebarView` (frescor fabricado do account usage) e **veredito dos 5 achados "a confirmar" da iter 14** (prioridade (b) do loop).

### Item 15.1 — USAGE-FRESHNESS-FABRICADO · P2 · "Account usage updated just now" era carimbado por evento **local**

Confirmado no fonte antes de corrigir. `refreshTokenSaverAccountUsageForDetails()` (`Sources/AppShell/SidebarView.swift:1146-1184`) esperava a conclusão da consulta de conta observando `.rc2TokenSaverUsageChanged` com `object: nil`. Essa notificação **não é exclusiva** da consulta de conta:

| Origem do post | Linha | Consulta provider? |
|---|---|---|
| Toggle de Token Saver (enable/disable) | `SidebarView.swift:1250`, `:1262`, `:1271`, `:1286` | **não** — é só a preferência local |
| `savings_recorded` do sidecar Distill | `TokenSaverDistillServiceController.swift:1108` | **não** — ledger local; dispara durante qualquer run |

Qualquer um deles resolvia a espera com `done = true` e o probe carimbava `tokenSaverAccountUsageLastUpdated = Date()`. O popover pintava então "Account usage updated just now" (`SidebarRootView.accountUsageLastUpdatedLabel`, renderizado em `:3864-3878`) ao lado do spinner, para uma consulta ainda em andamento — o job real só termina em `AppContext.publishTokenSaverAccountUsageRefresh(state: "finished", …)`. Com Token Saver ligado durante uma run, o `savings_recorded` torna isso o caso comum, não uma corrida rara.

Correção (menor escopo — 1 linha de lógica em cada arquivo):

| Arquivo | Mudança |
|---|---|
| `Sources/AppShell/AppContext.swift:3227` | posta `.rc2TokenSaverAccountUsageSettled` **só** no estado terminal do refresh de conta |
| `Sources/AppShell/SidebarView.swift:18` | declara a notificação dedicada |
| `Sources/AppShell/SidebarView.swift:1161` | o probe passa a observar essa notificação |

Os skips `signed_out`/`busy` seguem apoiados no timeout de 90 s — é o comportamento documentado no próprio código para essas corridas (`:1153-1158`); nada mais mudou. Nenhum outro consumidor da notificação genérica foi alterado.

Antes / Depois (mesmo filtro, mesmo sandbox, **mesmo arquivo de teste**; o "antes" rodou com `git checkout 22d51adc -- Sources/AppShell/AppContext.swift Sources/AppShell/SidebarView.swift`):

| Rodada | Executados | Falhas | Qual |
|---|---|---|---|
| Antes | 99 | **3** | 2 pré-existentes + `test_detailsProbe_ignoresLocalUsageNotificationWhileProbeIsInFlight` (`:129`): `XCTAssertNil failed: "2026-09-18 04:31:55 +0000"` |
| Depois | 99 | **2** | só as 2 pré-existentes, **idênticas** |

O teste prova o mecanismo, não a costura: segura o probe com um refresher gated (`GatedAccountUsageRefresher`), **espera a chamada ao provider começar** (`await refresher.hasStarted()`) para garantir que o observer one-shot já está registrado, posta `.rc2TokenSaverUsageChanged` e exige que o timestamp continue nil; só depois de liberar o refresh real ele pode ser carimbado. A primeira versão do teste era **vazia** (postava antes do registro do observer e passava nos dois fontes) — corrigida no commit `6d808f5c`.

Falhas pré-existentes da família, idênticas nas duas rodadas (mesmo `arquivo:linha`, mesma asserção; só o UUID aleatório muda): `TokenSaverAppContextTests.swift:364` `test_itemHostMetadataPublishesDistillAppliedAsAdditiveWireEvent` (casing do `uuidString`: minúsculo no valor real vs maiúsculo no esperado) e `TokenSaverAppContextTests.swift:2938` `test_rolloverProtectedCapacityFailsBeforeGraphWritesAndPublishesNothing`. Baseline registrado; nenhuma relação com esta mudança.

Filtro: `--filter TokenSaverLocalUsageSignalTests --filter TokenSaverAppContextTests`. `git status` limpo e `git diff 47a09a3c --stat -- Sources/` vazio depois do restore.

### Varredura 15.2 — veredito dos 5 achados "a confirmar" da iter 14 (prioridade (b))

Os números de linha da iter 14 são referentes ao fonte **antes** desta iteração; os abaixo são do estado atual (−4).

| # | Achado (iter 14) | Veredito | Evidência |
|---|---|---|---|
| 1 | Popover faz N+1 de SQLite no main **incluindo write** | **CONFIRMADO (P2)** | `reloadTokenSaverGovernance()` (`:838-878`) roda `projects.compactMap` e, por projeto em escopo, chama `ensureDefaults(projectID:)` (**write**, `:856`), `tokenSaverRolloverAdmission` (`:861`) e `list(projectID:)` (`:867`). Chamado por `toggleTokenSaverDetails` (`:3346`): 1× por abertura do popover, com N = projetos do workspace. **Não** é por render — os outros 5 call sites (`:890`, `:905`, `:921`, `:936`, `:959`) são ações explícitas do usuário. Entra no backlog como P2. |
| 2 | Walk síncrono da árvore Distill dentro do `body` | **DESCARTADO como P2** | `installedTokenSaverModelBytes()` (`:1435-1446`) é chamado do `body` (`:3199`), mas é **cacheado** (`tokenSaverInstalledModelSizeCache`) e invalidado só em disable/download/delete (`:1243`, `:1425`, `:1547`). Custo = 1 walk por mudança de estado, não por avaliação de body. Rebaixado a P3. |
| 3 | `try?` engolindo mutações do router | **CONFIRMADO (P3)** | `:1770` `selectWorkspace` (falha = clique não abre nada, sem erro nem reload), `:2126` `setWorkspaceColor`, `:2130` `setWorkspacePinned`, `:2261` `reorderWorkspace`, `:2313` pin em lote. Nos quatro últimos o `reload()` seguinte mostra a verdade (o item "volta"), mas sem explicar por quê. A costura `operationErrorPresenter` já existe e é usada em `:877`. Só manifesta em falha de escrita SQLite. |
| 4 | "Today" mostrando o total de ontem depois da meia-noite | **CONFIRMADO com janela limitada (P3, menor que o reportado)** | O relógio de virada (`tokenSaverDailyRolloverClock`, `:3036-3049`) só atualiza `tokenSaverNow`; `tokenSaverPersistedOrLiveCredible(.currentSession)` (`:3581-3585`) devolve `vm.tokenSaverDailyEconomyToday`, linha chaveada pelo `dayStartMs` do dia anterior. Mas o loop de 60 s (`AppDelegate.tokenSaverAccountUsageRefreshInterval`) dispara um refresh que termina em reload do sidebar e recomputa a linha do dia novo ⇒ a inconsistência (manchete de ontem × medido 0) dura **≲1 min**. Só persiste se o refresh voltar vazio (aí não há notificação e o sidebar não recarrega). |
| 5 | heal de 7 dias no boot | **JÁ COBERTO POR TESTE** | `test_economyWindow_loadsSharedSettingsAndUsageOnce` (1 load compartilhado por chamada) e `test_usageChangedNotification_doesNotRehealSevenDayWindow` ("boot must heal the week once") travam o contrato. Fecha como coberto. |

### Backlog (repriorizado na iter 15)

1. **`reloadTokenSaverGovernance` N+1 com write por projeto** (15.2 #1, P2 confirmado) — `ensureDefaults` por projeto a cada abertura do popover.
2. **SidebarView P2 — 2 dos 6 verificados na iter 14 seguem abertos**: "Delete model" que mente e envenena o cache (`:3368-3369`); disco ilegível → "Not enough disk space" e modelo indownloadável pela UI (`:1632-1643` + `:1298-1312`). Mais os 2 achados do worker não tratados nesta iteração: `dragScrollEdge` reatribuído a 60-120 Hz no drag (`:5514-5518`, vizinhos comparam em `:5486`/`:5495`); timer de auto-scroll de 16 Hz sem `onDisappear` (`:2987-3004`); pasta não adicionada em silêncio (`createWorkspace(fromFolder:)` `:1846-1865`, retorno descartado com `_ =` em `:1840`).
3. **BotsWindow P2** (inalterado desde a iter 14): `send()` limpa composer/anexos/rascunho antes da escrita que pode falhar (`:6041-6073`); chip provider·model do rail de threads permanentemente velho (`:7321-7323` vs `:9495`); watch de 2 s faz SQLite no main por tick (`:9100-9105`); `refreshActiveBotCount()` no main e 2× por run terminado (`:3684`, `:10594`/`:10608`); até 3 reloads completos por delta de handoff (`:6930-6932`, `:10479-10486`); 2 `stat` de filesystem por avaliação do composer (`:7788-7790` vs TTL `:7795-7800`); `searchText` grava UserDefaults por tecla (`:3068-3070`); toda mutação de fila reescreve a tabela inteira com `createdAt: Date()` (`:7494-7512`); deletar bot deixa caches residentes (`:5576-5588`).
4. **AppContext P2** (inalterado desde a iter 14): installers de Token Saver por turno no main relendo PATH + 4 MCP configs (`:2128`, `:2134-2165`, `:2285-2333`); `graphifyItemBuffers` sem cap e saída que vaza entrada (`:792`, `:6050-6053`); `usage.json` read-modify-write no main por evento (`:3122`, `:3193`, `:3276`); retry eterno de 0,75 s em falha de escrita de usage (`:5349-5353`); leitura de fila que falha tratada como fila vazia (`:1877-1878`). ~~heal de 7 dias no boot~~ (coberto por teste, ver 15.2 #5).
5. **Item 3 da iter 12 segue aberto**: `agent.history.partial.<threadID>` nunca apagado; `deleteByPrefix` sem chamador; 3 caminhos de delete de thread (`Repositories.swift:1581`, `:1673-1683`, `:2355-2366`).
6. **Antigos que seguem abertos**: timer do SSH, `files.edit.*` no main actor, `FileEditSessionStore` sem cap/TTL (decisão do dono), Insomnia (geração/`StartupPlan`/500 no revoke), rename inline de aba, COW do replay unhosted, `reasonPhrase(204)`, `command_receipts` sem prune (decisão do dono), `provider_pending_callbacks`, índice/retenção de `agent_runs`, itens de `SettingsWindow` da iter 12, `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono), EV-28 (`token_saver_attempt_*`).

**Áreas ainda não varridas** (inalterado): AppShell — `AppCommandRouter` (9.1k, parcial), `MainWindowController`, `ScheduledTasksWindow` (parcial), `TokenSaverDistillServiceController`, `PrivateAccountIntegration`, `Pet/*`, `BotScheduleTasksWindow`; `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs); `Sources/Persistence/` (`BotStore`, `Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority`, `SettingsStore` além dos setters); `Sources/AgentRuntime/` (fora dos providers e dos caminhos de stop/checkpoint).

### Commits da iteração

| Commit | Item |
|---|---|
| `47a09a3c` | `fix(sidebar): settle the Token Saver details probe on the real refresh` (15.1) |
| `6d808f5c` | `test(sidebar): gate the details probe before posting the local usage event` (15.1, correção do teste vazio) |

## Iteração 16 — 2026-09-18

Método: `/sam-goal` + `/sam-task` + `/sam-orchestrate` (varredura read-only em paralelo). Prioridade (b) **esgotada**: não há mais nenhum achado marcado "a confirmar" no checklist (os 5 da iter 14 fecharam em 15.2). Item escolhido da prioridade (a).

### Item 16.1 — ADD-FOLDER-SILENCIOSO · P2 · pasta que não pode ser adicionada não dizia nada

Confirmado no fonte antes de corrigir. `createWorkspace(fromFolder:)` (`Sources/AppShell/SidebarView.swift:1845-1871`) engolia a falha:

```swift
} catch {
    return false        // :1861-1863 (antes)
}
```

O caminho é compartilhado por três gestos do usuário — `newWorkspace()` (NSOpenPanel, `:1840`), o drop do Finder (`createWorkspaces(fromDroppedProviders:)`, `:1967`) e File ▸ Open Recent — e `AppCommandRouter.createWorkspace(fromFolder:)` (`Sources/AppShell/AppCommandRouter.swift:1194-1203`) **lança** `LayoutError.workspaceNotFound` exatamente no caso real: uma entrada velha de Open Recent, ou uma pasta movida/renomeada/apagada entre o painel e o drop. Resultado: o painel fechava, nenhuma linha aparecia, nenhum erro, nenhuma explicação — gesto morto.

Correção (menor escopo — 1 chamada no `catch` + 1 helper puro):

| Arquivo:linha | Mudança |
|---|---|
| `SidebarView.swift:1861-1870` | o `catch` passa a reportar via a costura **já existente** `operationErrorPresenter` |
| `SidebarView.swift:1879-1884` | novo `addWorkspaceFailureDetail(for:)` traduz o caso stale-folder |

Por que o helper existe: `LayoutError` (`Sources/CoreModel/Reducer.swift:32-37`) é um `enum: Error` **sem conformidade `LocalizedError`**, então `error.localizedDescription` produziria apenas *"The operation couldn't be completed. (CoreModel.LayoutError error 0.)"*. O helper traduz **só** `workspaceNotFound` ("That folder no longer exists. It may have been moved, renamed or deleted.") e deixa qualquer outro erro com a própria descrição — reportar uma falha de disco/DB como "pasta não existe" seria trocar um silêncio por uma mentira.

Trade-off registrado: um drop/`NSOpenPanel` com **várias** pastas inválidas de uma vez apresenta uma folha por pasta (`defaultOperationErrorPresenter` usa sheet não bloqueante, `:2344-2355`). Preferi isso a manter o silêncio; agregação por gesto fica como follow-up (ver backlog 8). O `guard let router else { return false }` (`:1846`) **não** foi tocado de propósito: `router` é `weak` e pode estar desalocado durante o teardown da janela, onde uma folha de erro seria ruído.

Antes / Depois (mesmo filtro, mesmo sandbox, **mesmo arquivo de teste**; o "antes" rodou com `git checkout 12fed219 -- Sources/AppShell/SidebarView.swift`):

| Rodada | Executados | Falhas | Qual |
|---|---|---|---|
| Antes | 9 | **3** | `test_staleFolderAdd_surfacesTheFailureInsteadOfDoingNothing` (`Tests/AppShellTests/WorkspaceCwdDeduplicationTests.swift:146`, `:148`, `:149`): `("0") is not equal to ("1")` + `("nil") is not equal to ("Could not add RC2Stale-…")` + `("nil") is not equal to ("That folder no longer exists…")` |
| Depois | 9 | **0** | — |

Sem falhas pré-existentes nesta família. Filtro: `--filter WorkspaceCwdDeduplicationIntegrationTests --filter FindExistingWorkspaceByCwdTests`.

**Armadilha encontrada e registrada:** a primeira rodada do "antes" usou `--filter WorkspaceCwdDeduplicationTests` (o nome do *arquivo*) e saiu **exit=0 com "Executed 0 tests"** — um verde falso: as classes do arquivo são `FindExistingWorkspaceByCwdTests` e `WorkspaceCwdDeduplicationIntegrationTests`. O leg foi refeito com os nomes reais. Regra prática para as próximas iterações: **conferir sempre `Executed N tests` com N > 0** antes de aceitar qualquer rodada como evidência.

O segundo spec (`test_addWorkspaceFailureDetail_keepsUnderlyingMessageForOtherErrors`, `:161`) referencia o símbolo novo, então **não compila contra o fonte pré-correção** e não tem "antes" próprio — declarado como tal no comentário do teste; ele trava a direção oposta (falha real não pode ser reportada como pasta ausente). Rodada final com os dois specs: 10 testes, 0 falhas.

### Varredura 16.2 — `MainWindowController.swift` (2.635 linhas) e `Pet/*` (~5k linhas)

Delegada a dois workers read-only em paralelo (`/sam-orchestrate`). Nenhum arquivo foi tocado. Abaixo, a distinção explícita entre o que **eu reverifiquei no fonte** e o que é **report do worker** (entra como "a confirmar").

#### `MainWindowController.swift`

| # | Linhas | Severidade | Defeito | Consequência | Reverifiquei? |
|---|---|---|---|---|---|
| 1 | `:956-968`, `:972-992`, `:995-1005` | **P1** | `closeFocusedSurface` / `splitFocusedPane` / `resizeFocusedPane` resolvem o alvo só por `selectedWorkspaceID` + `detachedWorkspaceIDs`, **sem checar `shellContentMode`** nem qual janela tem o foco; `?? paneControllers.first` garante alvo sempre | Com Bots/Schedule Tasks/Active Threads ocupando o conteúdo, ⌘W/⌘D agem sobre a aba do workspace **oculto**: surface desregistrada (terminal/agent morto) sem nenhum feedback visível. Com uma janela destacada em foco, ⌘W fecha aba da janela principal | **SIM** — li as três funções; `shellContentMode` existe (`:322`, vira `.bots` em `:1214`, `.scheduledTasks` em `:1185`, `.activeThreads` em `:1201`); `paneControllers.removeAll()` só existe em `:1463` (rebuild do main) e `:2109` (janela destacada), então os controllers do workspace oculto seguem vivos; `AppDelegate.swift:1907` roteia ⌘W para `closeFocusedSurface()` e só cai no `performClose` quando ela devolve `false`, e `:1859-1865` roteiam ⌘D para `splitFocusedPane` |
| 2 | `:2100-2118` (chamado de `:868`) | P2 | `WorkspaceWindowController.refreshFromState` sem assinatura/early-return/coalescing (ao contrário da principal, `:1432`): a cada refresh da principal faz `removeAll` de subviews + `paneControllers.removeAll()` + `buildLayoutView` completo | Com qualquer workspace destacado, todo refresh da principal reergue os painéis da janela destacada mesmo sem mudança: hitch O(painéis) no main, scroll do tab strip volta e um divider em drag é morto | worker |
| 3 | `:812-818` (linha `:817`) | **P2** | `newWorkspace` (botão "+" do header) faz `_ = try? router?.createWorkspace(fromFolder: url)`, **não** passa por `SidebarView.createWorkspace(fromFolder:)` — o caminho onde vive o DEDUP-P2 e o `noteNewRecentDocumentURL` | (a) escolher uma pasta que já é workspace **cria workspace duplicado** (dois registros/terminais para o mesmo cwd; o reducer não deduplica); (b) se lançar, o painel fecha e nada acontece — a mesma classe de silêncio que a 16.1 corrigiu no caminho irmão; (c) a pasta não entra em File ▸ Open Recent | **SIM** — li `:812-818`; é exatamente `_ = try? router?.createWorkspace(fromFolder: url)`, e `AppCommandRouter.swift:1194-1203` não deduplica |
| 4 | `:469-475` (linha `:473`), `:479-481` | P3 | `sidebarDragUpdated` grava em `sidebarWidth` o valor **já clampado** pela janela (o arquivo documenta em `:276-279` que `sidebarWidth` é a preferência e a constraint guarda o clamp); `sidebarDragEnded` persiste esse valor rebaixado | Arrastar a costura com a janela estreita descarta permanentemente a largura maior escolhida (não volta ao alargar, e o valor menor persiste no relaunch) | worker |
| 5 | `:1956-1991` (call único `:1958`) | P3 | Lista do popup "Attach Workspace..." montada uma única vez e nunca revalidada (`rebuildPopupItems` sem outro chamador) | Workspaces criados depois que a janela extra abriu não aparecem no menu; se abriu sem workspaces, mostra "No workspaces available" para sempre | worker |
| 6 | `:449`, `:479-481`, `:1786-1794` | P3 | Preferências de layout/shell persistidas com `try?` / `Task` fire-and-forget sem tratamento | Falha de escrita = estado volta no relaunch sem nenhuma mensagem | worker |

**Verificado limpo pelo worker** (categorias checadas sem defeito): coalescing de refresh (`:837-854`, sem flush perdido); tasks/cancelamento com generation (`:1375-1398`, `:1786-1794`, `deinit` `:413-417`); observers/timers/retain cycles (um único observer removido no `deinit`, nenhum `Timer`/`asyncAfter`/`.sink` no arquivo, `[weak self]` em todos os closures); coleções/retensão (`workspaceWindows`, `botWindows`/`botGuestWindows`, `extraWindows` podados ao fechar; `dividerLayers` trimado); remoção concorrente (`Array(workspaceWindows)` em `:861-869`); main-actor offloading (nenhum SQLite/walk/JSON/regex; `listWorkspaces()` é in-memory); índices/CGFloat bounds-checked; título/header cobrindo os 4 destinos.

#### `Pet/*`

| # | Linhas | Severidade | Defeito | Consequência | Reverifiquei? |
|---|---|---|---|---|---|
| 1 | `PetWindowController.swift:665` (+`PetSystemActivityMonitor.swift:59`, `PetController.swift:445`, `:937`, `PetDockFrameProvider.swift:39-64`, `:192-232`) | P2 | `screensDidChange()` invalida o cache do Dock e re-resolve o frame no main actor, ligado a `onDockContentsMayHaveChanged` = `didBecomeActive` + cada launch/quit de app do sistema; o miss roda `CGWindowListCopyWindowInfo` + varredura de borda com `sampleStep = 8` (~190-320 round-trips ao WindowServer) **sem** condicionar a mudança de geometria | Hitch na main thread em todo cmd-tab de volta ao RemoteCode e em qualquer launch/quit, justo quando o AppKit processa ativação. É a sonda que a nota PL-04 do próprio repo (`PetWindowController.swift:972-976`) mediu em ~130 ms/tick; o timer foi removido, mas o caminho de notificação continua pagando. Pet é ligado por padrão (`AppSettings.petEnabled = true`) | worker |
| 2 | `PetPlacementStore.swift:37` (também `:41`, `:29-31`) | P3 | `save`/`reset`/`load` engolem todo erro do repositório com `try?` (`SettingsRepository.set` lança de verdade, `Repositories.swift:10867`) | Arrastar o pet e a escrita falhar = ele volta à posição antiga no relaunch; "Reset position" pode não fazer nada; `get` falho é indistinguível de "sem posição salva" | worker |
| 3 | `PetController.swift:842` (idem `:897`) | P3 | Toda mudança de estado de animação reatribui `model.routeError = projectionErrorMessage` (em geral `nil`), apagando a mensagem de falha escrita por `open()`/`openActive()`/`markAllViewed()`; `apply()` roda a cada mudança de estado (sub-segundo durante run) | O usuário clica numa linha cujo roteamento falha, o erro aparece no popover e é apagado pelo próximo pose antes de dar para ler — é a classe "erro vivo apagado" que o loop já tratou antes | worker |
| 4 | `Core/PetEventReducer.swift:432-437` (`mutateState` `.agentRunFinished`) | P3 | `activeItems` só é limpo quando `activeRunIDs` fica **vazio**; terminar a run A com a B viva mantém os poses de A (chave `threadA:itemID`), e `derivedState` (`:629-632`) mistura todos os poses de item enquanto qualquer run estiver viva, sem filtro por thread | Se o último item de A nunca emitiu `item.completed`, o pet anima o trabalho de uma thread **terminada** (ex.: `.terminal` 620 vence `.thinking` 400 da B) enquanto B roda | worker |

**Verificado limpo pelo worker**: timers/tasks (`transientTask`, `companionTask`, `idleTask`, `attentionRefreshTask` cancel-before-arm; um único timer no `PetAnimationController` invalidado em `deinit`/`stop` e parado em hide/lock/pause/reduced-motion); observers/handles (monitores de evento removidos, `NSCursor.push/pop` balanceado, EventBus desinscrito no `stop()`); retain cycles (`[weak self]` em todos os closures); stale async (generation + cancel em `fetchActiveThreadChromeOffMain`, `liveActivitySummaryTask`, `LiveActivitySummaryStore` por fingerprint); crescimento limitado (`terminalRunIDs/Order` 256, `LiveActivitySummaryStore` 32, caches do atlas, máscara alpha única); persistência/fail-loud de atenção (rotas verificadas antes de mutar, `routeError` persistente, watermark que não avança); trabalho por frame (`animationFrameDidChange()` early-return, `isOpaque` O(1) com máscara cacheada); round-trip de placement idempotente.

**Não confirmado pelo worker** (registrado como suspeita, sem prova): `agent.item.delta` inalcançável por estar em `alwaysPrefilteredNoiseKinds` (`PetController.swift:331-335` vs `:602-604`); `stop()` não cancela `liveActivitySummaryTask`/`linkedBotResolveTask` (único chamador é o término do app); `fetchLinkedBotsOffMain` (`:1253-1282`) e o early-return de `linkedBotResolveTask`; `PetAttentionStore.refresh()` com 6 queries síncronas no main (`PetAttentionStore.swift:49-71`, limitado pelo debounce de 10 ms).

### Backlog (repriorizado na iter 16)

1. **`MainWindowController` P1 — ⌘W/⌘D agem sobre o workspace oculto** (16.2 #1, verificado por mim). Correção mínima proposta: `guard shellContentMode == .workspace` nas **três** funções (`closeFocusedSurface` `:956`, `splitFocusedPane` `:972`, `resizeFocusedPane` `:995`); devolver `false` faz o `AppDelegate` cair no comportamento padrão (⌘W fecha a janela). Não é testável por unit test hoje (AppKit/NSWindow, `shellContentMode` só muda via `presentBotsInMainContent`), então a verificação tem de ser por sessão de UI no sandbox — declarar isso em vez de inventar um "antes". O segundo braço (janela destacada em foco) exige roteamento por janela-chave: escopo maior, fica como item separado.
2. **`MainWindowController.newWorkspace` (`:812-818`)** (16.2 #3, verificado por mim): `_ = try?` — duplica workspace e falha em silêncio. Mesma classe da 16.1, no caminho irmão; passar pelo `SidebarView.createWorkspace(fromFolder:)` (ou extrair dedup+report) resolve os três sintomas de uma vez.
3. **Varredura (c) restante**: `ScheduledTasksWindow`/`ScheduledTaskRuntime`, `TokenSaverDistillServiceController`, `PrivateAccountIntegration`, `BotScheduleTasksWindow`, `AppCommandRouter` (9,1k, parcial), resto de `Surfaces/`/`Persistence/`/`AgentRuntime/`. `MainWindowController` e `Pet/*` **cobertos** na 16.2.
2. **`reloadTokenSaverGovernance` N+1 com write por projeto** (15.2 #1, P2 confirmado) — `ensureDefaults` por projeto a cada abertura do popover.
3. **SidebarView P2 — 2 dos 6 verificados na iter 14 seguem abertos**: "Delete model" que mente e envenena o cache (`:3368-3369`); disco ilegível → "Not enough disk space" e modelo indownloadável pela UI (`:1632-1643` + `:1298-1312`). Mais os 2 de performance: `dragScrollEdge` reatribuído a 60-120 Hz no drag (`:5514-5518`, vizinhos comparam em `:5486`/`:5495`); timer de auto-scroll de 16 Hz sem `onDisappear` (`:2987-3004`).
4. **BotsWindow P2** (inalterado desde a iter 14): `send()` limpa composer/anexos/rascunho antes da escrita que pode falhar (`:6041-6073`); chip provider·model do rail de threads permanentemente velho (`:7321-7323` vs `:9495`); watch de 2 s faz SQLite no main por tick (`:9100-9105`); `refreshActiveBotCount()` no main e 2× por run terminado (`:3684`, `:10594`/`:10608`); até 3 reloads completos por delta de handoff (`:6930-6932`, `:10479-10486`); 2 `stat` de filesystem por avaliação do composer (`:7788-7790` vs TTL `:7795-7800`); `searchText` grava UserDefaults por tecla (`:3068-3070`); toda mutação de fila reescreve a tabela inteira com `createdAt: Date()` (`:7494-7512`); deletar bot deixa caches residentes (`:5576-5588`).
5. **AppContext P2** (inalterado desde a iter 14): installers de Token Saver por turno no main relendo PATH + 4 MCP configs (`:2128`, `:2134-2165`, `:2285-2333`); `graphifyItemBuffers` sem cap e saída que vaza entrada (`:792`, `:6050-6053`); `usage.json` read-modify-write no main por evento (`:3122`, `:3193`, `:3276`); retry eterno de 0,75 s em falha de escrita de usage (`:5349-5353`); leitura de fila que falha tratada como fila vazia (`:1877-1878`).
6. **Item 3 da iter 12 segue aberto**: `agent.history.partial.<threadID>` nunca apagado; `deleteByPrefix` sem chamador; 3 caminhos de delete de thread (`Repositories.swift:1581`, `:1673-1683`, `:2355-2366`).
7. **Antigos que seguem abertos**: timer do SSH, `files.edit.*` no main actor, `FileEditSessionStore` sem cap/TTL (decisão do dono), Insomnia (geração/`StartupPlan`/500 no revoke), rename inline de aba, COW do replay unhosted, `reasonPhrase(204)`, `command_receipts` sem prune (decisão do dono), `provider_pending_callbacks`, índice/retenção de `agent_runs`, itens de `SettingsWindow` da iter 12, `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono), EV-28 (`token_saver_attempt_*`).
8. **Novo (16.1)**: agregar em uma única folha as falhas de um gesto com várias pastas (`createWorkspaces(fromFolders:)` `:1940`, `newWorkspace()` `:1840`, drop `:1967`) — hoje é 1 folha por pasta inválida.

**Áreas ainda não varridas** (atualizado): AppShell — `AppCommandRouter` (9,1k, parcial), `ScheduledTasksWindow` (parcial) e `ScheduledTaskRuntime` (1,1k), `TokenSaverDistillServiceController` (1,2k), `PrivateAccountIntegration` (1,8k), `BotScheduleTasksWindow`; `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs); `Sources/Persistence/` (`BotStore`, `Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority`, `SettingsStore` além dos setters); `Sources/AgentRuntime/` (fora dos providers e dos caminhos de stop/checkpoint). ~~`MainWindowController`~~ e ~~`Pet/*`~~ (feitos na 16.2); ~~`SidebarView`~~ (feito na 14.2).

### Commits da iteração

| Commit | Item |
|---|---|
| `b8e1f094` | `fix(sidebar): report a folder that could not be added instead of doing nothing` (16.1) |
| `92b6f93e` | `test(sidebar): lock the fall-through message for non-stale add failures` (16.1) |
| `ada01298` | `docs(checklist): iteration 16 — silent add-folder failure, sweep of MainWindowController/Pet started` (16.1) |

## Iteração 17 — 2026-09-18

### Item 17.1 — P1 de 16.2 #1: ⌘W/⌘D agiam sobre o workspace **oculto** (CORRIGIDO)

O destino principal do shell (`Bots`, `Schedule Tasks`, `Active Threads`) monta no lugar dos painéis do workspace e **esconde** a árvore: `rebuildWorkspaceContainer()` (`Sources/AppShell/MainWindowController.swift:1400-1430`) devolve cedo enquanto `shellContentMode != .workspace`, então `paneControllers` **continua vivo e apontando para o workspace fora da tela**. As três entradas de teclado resolviam o alvo só por `ctx.state.window.selectedWorkspaceID` (`:954-970`, `:975-995`, `:1001-1011` pré-correção), com `?? paneControllers.first` garantindo alvo sempre — ou seja, ⌘W/⌘D/⌘⌥setas agiam sobre o que o usuário **não vê**.

O braço do ⌘W é destrutivo, não cosmético: `PaneTabsView.closeSelectedSurface()` → `AppCommandRouter.closeSurfaces` → `permanentlyCloseRuntimeSurface`, que roda `terminal.closeAndDeletePersistedHistory()` e `SurfaceRegistry.shared.unregister(surfaceID)` (`AppCommandRouter.swift:1749-1769`). O scrollback morre e nada na tela explica por quê; o layout só "aparece" sem a aba quando o usuário volta ao workspace.

**Correção (mudança mínima):** um `guard shellContentMode == .workspace else { return false }` em cada uma das três entradas — `closeFocusedSurface()` `:963`, `splitFocusedPane(_:)` `:982`, `resizeFocusedPane(_:)` `:1005`. Devolver `false` é o fall-through **documentado** dessas funções: `AppDelegate.swift:1907` cai no `performClose` (⌘W fecha a janela) e `:1859-1865` toca o beep (⌘D sem alvo visível). Sem tocar em nenhum outro caminho: em `.workspace` os três guards são sempre verdadeiros, então o comportamento normal é idêntico.

**Antes / Depois** (mesmo filtro, mesmo sandbox, **mesmo arquivo de teste**; o "antes" rodou com `git checkout b3e01c85 -- Sources/AppShell/MainWindowController.swift`):

| Spec (`ShellDestinationKeyboardTargetTests`) | Antes | Depois |
|---|---|---|
| `test_closeFocusedSurface_isRefusedWhileBotsOwnsTheShell_…` | **falha** — `XCTAssertFalse` (devolvia `true`), surfaces `1 → 0`, surface desregistrada | passa |
| `test_splitFocusedPane_isRefusedWhileScheduledTasksOwnsTheShell` | **falha** — `XCTAssertFalse` (devolvia `true`), `paneIDs` `1 → 2` | passa |
| `test_resizeFocusedPane_isRefusedWhileActiveThreadsOwnsTheShell` | **falha** — `XCTAssertFalse`, ratios `[0.5, 0.5] → [0.45, 0.55]` | passa |
| Total | 3 executados, **7 falhas** | 3 executados, **0 falhas** |

Os specs não são vazios: cada um chama o destino real (`presentBotsInMainContent` / `presentScheduledTasksInMainContent` / `presentActiveThreadsInMainContent`) e exige **precondition** de painel montado (botão `pane.overflowMenu` na hierarquia). Armadilha registrada: a primeira versão da precondition procurava `PaneTabsView` nas subviews e falhava — `PaneTabsView` é `NSObject`, não `NSView` (`PaneTabsView.swift:25`), quem entra na árvore é `PaneTabsView.view`. Sem essa checagem o "antes" poderia passar por lista de controllers vazia; com ela, as 7 falhas são todas de comportamento.

O 3º spec também mede a direção oposta de propósito: exige `splitFocusedPane(.right) == true` **antes** de trocar o destino, provando que a resolução de alvo estava viva e que o `false` posterior é recusa, não ausência de alvo.

**Regressão nas famílias vizinhas** (mesmo filtro nas duas rodadas): `NavigationFirstFrameTests|MainWindowControllerRebuildCountTests|MainWindowControllerSidebarWidthTests|MainWindowAppearanceAndFocusTests|AppMenuOpenRecentTests|AppMenuUpdateItemTests|SplitLayoutRuntimeTests` → **38 executados, 1 falha**. A falha é `MainWindowControllerRebuildCountTests.test_focusSurfaceUpdatesVisibleContentWithoutFullRebuild` (`:265`, "the previously selected tab's surface must be removed from the content area") e é **pré-existente**: rodada com o fonte revertido (`git checkout b3e01c85 -- Sources/AppShell/MainWindowController.swift`), `--filter MainWindowControllerRebuildCountTests` → 10 executados, **a mesma 1 falha, mesma asserção, mesma linha**. Nada atribuído a ruído.

### Achado novo — a asserção pré-existente contradiz o contrato PF-11 (lead para a próxima iteração)

`MainWindowControllerRebuildCountTests.swift:265` exige que a view da aba anterior **saia** da `contentArea`; o contrato PF-11 documenta o oposto — *"keep each tab's surface view mounted and toggle `isHidden` instead of removeFromSuperview/addSubview on every click"* (`PaneTabsView.swift:60-62`, e o próprio seam `isMountedContentHiddenForTesting` `:279-282` existe para isso). Hoje o spec está vermelho, então **uma** das duas pontas está errada:

- se `installSelectedContent` (`:284-363`) realmente marca a view anterior como `isHidden = true`, o spec está **obsoleto** em relação ao PF-11 e a asserção correta é `isMountedContentHiddenForTesting(first) == true` + `== false` para a segunda;
- se a view anterior continua **visível e montada**, é bug de produto (duas superfícies pintadas ao mesmo tempo).

Não foi tocado nesta iteração (fora do escopo do P1 e o loop proíbe "consertar" vermelho pré-existente de carona). Próxima iteração: medir o seam primeiro e só então decidir qual ponta muda — com vermelho antes/depois se for produto.

### Estado do LFS e do sandbox

`Vendor/TailcatBridge/Artifacts/RCTailcat.xcframework/{macos-arm64,ios-arm64,ios-arm64-simulator}/libRCTailcat.a` materializados em disco (47-49 MB cada, não são os pointers de 133 B) — `scripts/isolated-sandbox.sh ensure` fez o trabalho; nenhuma ação necessária. Todos os builds/testes desta iteração rodaram por `scripts/isolated-sandbox.sh test` no worktree de debug; nenhum `pkill`, nenhum `run-app.sh`, bundle estável intacta.

### Varredura

Nenhuma área nova varrida nesta iteração — o tempo foi para o P1 (16.2 #1) e para a evidência A/B. A lista de áreas não varridas segue a de 16.2: `ScheduledTasksWindow`/`ScheduledTaskRuntime` (parcial), `TokenSaverDistillServiceController`, `PrivateAccountIntegration`, `BotScheduleTasksWindow`, `AppCommandRouter` (parcial), resto de `Sources/Surfaces/`, `Sources/Persistence/`, `Sources/AgentRuntime/`.

### Backlog (repriorizado na iter 17)

1. ~~`MainWindowController` P1 — ⌘W/⌘D agem sobre o workspace oculto~~ **fechado (17.1)**.
2. **Segundo braço do P1 de 16.2 #1 (aberto)**: com uma **janela destacada em foco**, ⌘W/⌘D continuam resolvendo o alvo pela janela principal — exige roteamento por janela-chave (`AppDelegate.swift:1900-1908` usa `keyWindowProviderForTests`/`NSApp.keyWindow` só para o fallback). Escopo maior, nada medido ainda.
3. **`MainWindowController.newWorkspace` (`:812-818`, 16.2 #3, verificado)**: `_ = try? router?.createWorkspace(fromFolder: url)` — duplica workspace já existente e falha em silêncio (mesma classe da 16.1, no caminho irmão). Caminho testável sem AppKit se a correção passar por `SidebarView.findExistingWorkspace(byCwd:in:)` + `addWorkspaceFailureDetail(for:)`.
4. **Veredito pendente do achado PF-11 acima** (item 17.1 do achado novo) — decidir spec obsoleto vs bug de produto.
5. **`reloadTokenSaverGovernance` N+1 com write por projeto** (15.2 #1, P2 confirmado) — `ensureDefaults` por projeto a cada abertura do popover.
6. **SidebarView P2 — 2 dos 6 verificados na iter 14 seguem abertos**: "Delete model" que mente e envenena o cache (`:3368-3369`); disco ilegível → "Not enough disk space" e modelo indownloadável pela UI (`:1632-1643` + `:1298-1312`). Mais os 2 de performance: `dragScrollEdge` reatribuído a 60-120 Hz no drag (`:5514-5518`); timer de auto-scroll de 16 Hz sem `onDisappear` (`:2987-3004`).
7. **BotsWindow P2** e **AppContext P2** (inalterados desde a iter 14; listas completas na 14) — inclui `send()` que limpa composer/anexos antes da escrita que pode falhar (`BotsWindow:6041-6073`), watch de 2 s com SQLite no main (`:9100-9105`) e installers de Token Saver por turno no main (`AppContext:2128`, `:2134-2165`, `:2285-2333`).
8. **Demais itens antigos** (nada mudou nesta iteração): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28 (`token_saver_attempt_*`); agregar falhas de um gesto multi-pasta numa única folha (16.1); janela destacada sem coalescing (`WorkspaceWindowController.refreshFromState`, 16.2 #2).

### Commits da iteração

| Commit | Item |
|---|---|
| `8f707a36` | `fix(shell): refuse ⌘W/⌘D while another destination owns the shell` (17.1) |
| `4e9a4a48` | `test(shell): lock the hidden-workspace keyboard target rule` (17.1) |

## Iteração 18 — 2026-09-18

Método: `/sam-goal` + `/sam-task` + `/sam-orchestrate`. O tempo desta iteração foi para A/B dirigido dos itens (a), (b) e (c) — **nenhuma área nova varrida** (a lista de áreas pendentes segue a de 17). Regra de método aprendida e registrada no fim desta seção.

### Item 18.1 — P1 2º braço: com uma janela destacada em foco, ⌘W/⌘D agiam na janela principal (CORRIGIDO)

O 1º braço (17.1) parou o ⌘W/⌘D quando um destino do shell cobre os painéis. Faltava o outro lado do mesmo defeito: `AppDelegate` monta os itens de menu com `target = self` (`AppDelegate.swift:1335`, `:1412-1417`) e entregava o comando direto ao **controller da janela principal**; `closeFocusedSurface`/`splitFocusedPane` resolviam o alvo por `ctx.state.window.selectedWorkspaceID`. Com o workspace A selecionado na janela principal e W destacado em outra janela, ⌘W sobre W fechava uma aba de **A** (caminho destrutivo: `permanentlyCloseRuntimeSurface` → `closeAndDeletePersistedHistory()` + `unregister`) e ⌘D dividia o painel de A fora da tela.

**Correção (mudança mínima — as duas entradas de menu passam a receber a janela que tem o teclado):**

| Arquivo:linha | Mudança |
|---|---|
| `AppDelegate.swift:1859-1870` | `splitFocusedPaneRight/Down` passam `keyWindowProviderForTests?() ?? NSApp.keyWindow` |
| `AppDelegate.swift:1913` | `closeActiveTabOrWindow` passa a mesma `keyWindow` (já a calculava para o caso do Settings) |
| `MainWindowController.swift:1002-1052` | `closeFocusedSurface(in:)` e `splitFocusedPane(_:in:)` ganham `in window: NSWindow? = nil`; com `nil` o comportamento é idêntico ao de antes |
| `MainWindowController.swift:1010`/`:1036` | `detachedWindowController(owning:)` (`:1123-1130`) mapeia a janela-chave para o `WorkspaceWindowController` dono |
| `MainWindowController.swift:20-66` | helpers de resolução compartilhados (`keyboardTargetPane`, `closeKeyboardTargetSurface`, `splitKeyboardTargetPane`, `resizeKeyboardTargetPane`) — o `WorkspaceWindowController` tinha a **mesma** resolução duplicada no `resizeFocusedPane` |
| `MainWindowController.swift:2255-2272` | `WorkspaceWindowController.closeFocusedSurface()` e `.splitFocusedPane(_:)` novos, usando os helpers |

**Terceiro braço verificado limpo (sem mudança):** ⌘⌥setas **não** passam pelo `AppDelegate` — `InteractiveTitlebarWindow.sendEvent` (`:36-46`) despacha para o `delegate` da própria janela, e o delegate da janela destacada é o `WorkspaceWindowController` (que já conforma `PaneKeyboardResizeHandling`). Só ⌘W/⌘D eram menu key equivalents.

**Antes / Depois** (mesmo filtro, mesmo sandbox, **mesmo arquivo de teste**; o "antes" rodou com `git checkout 26aa0f2a -- Sources/AppShell/MainWindowController.swift Sources/AppShell/AppDelegate.swift`):

| Spec (`DetachedWorkspaceKeyboardTargetTests`, novo) | Antes | Depois |
|---|---|---|
| `test_closeShortcut_closesTheTabOfTheKeyDetachedWindow_notTheMainWorkspace` | **falha** — `⌘W over the detached window must not close a tab of the main window's workspace` (main 2 → 1 surfaces) e `⌘W must close the focused tab of the window the user is looking at` (detached seguia com 2) | passa |
| `test_splitShortcut_splitsTheKeyDetachedWindow_notTheMainWorkspace` | **falha** — `paneIDs` do main 1 → 2 e o destacado seguia com 1 | passa |
| Total | 2 executados, **4 falhas** | 2 executados, **0 falhas** |

Os specs são dirigidos pelo caminho real do menu: `NSApp.sendAction(NSSelectorFromString("closeActiveTabOrWindow"/"splitFocusedPaneRight"), to: delegate, from: nil)` com a costura **já existente** `AppDelegate.keyWindowProviderForTests` (mesmo padrão de `SettingsWindowCloseRoutingTests`). Precondições não-vacuosas: os painéis das **duas** janelas montados (`pane.overflowMenu` na hierarquia), 2 abas em cada workspace, e `main.workspaceWindow(for:)` devolvendo uma janela diferente da principal.

**Família vizinha (mesmo filtro nas duas rodadas):** 105 executados, 4 falhas em ambas — mas o **conjunto** diferiu, então re-me­di por spec com `--filter` dirigido: `PaneActionTests:1498` vermelho nas duas pernas, `test_sidebarToggle…(_:1300)` verde nas duas, `test_terminalBusyRuntimeRefresh…(_:77/:574)` vermelho nas duas → **delta zero** atribuível a esta correção. `:1300` (spec de ~20 s) é flaky sob carga; `:77/:574` é vermelho pré-existente.

### Item 18.2 — Veredito PF-11: **spec obsoleto**, não bug de produto (DECIDIDO e corrigido)

Medido antes de decidir. O produto (`PaneTabsView.installSelectedContent`) remove do `contentArea` **só** as views cujo surface saiu do pane e alterna `isHidden` nas demais; o contrato PF-11 está documentado no próprio arquivo (`PaneTabsView.swift:60-62`) e já era travado em verde por `PaneActionTests.test_switchingTabsKeepsPreviousViewHiddenInHierarchy` (`:722-768`). Contra esse contrato havia **dois** specs afirmando remoção, um deles no mesmo arquivo do lock:

| Spec | Asserção antiga | Medido (produto inalterado) | Decisão |
|---|---|---|---|
| `MainWindowControllerRebuildCountTests.swift:265` | `XCTAssertFalse(liveSubviews.contains { $0 === firstView })` | a view anterior continua **montada** e com `isHidden == true`; a nova fica `isHidden == false` | spec obsoleto |
| `PaneActionTests.swift:1498` | `XCTAssertFalse(secondSurfaceView.isDescendant(of: content))` | a view anterior continua descendente do `contentView` da janela destacada e `isHidden == true` | spec obsoleto |

Ambos foram reescritos para o contrato montado+oculto (com o WHY citando PF-11 e o lock irmão). **Evidência de que só o spec mudou:** as asserções novas passam com o **fonte de produto inalterado** — `--filter MainWindowControllerRebuildCountTests --filter test_focusSurfaceReconcilesDetachedWorkspaceWindowTabs` → **11 executados, 0 falhas** — e as antigas estavam vermelhas nas duas pernas do A/B dirigido (18.1). Nenhuma linha de produto foi tocada neste item.

### Item 18.3 — `newWorkspace` do header "+" ignorava o DEDUP e falhava em silêncio (CORRIGIDO)

`MainWindowController.newWorkspace()` (`:858-866`) fazia `_ = try? router?.createWorkspace(fromFolder: url)` — o caminho que a iter 16.1 corrigiu no irmão do `SidebarView` continuava vivo no botão "+" do header e no botão "New Workspace" do estado vazio (`:618`, `:1643`, ambos com a mesma action). Consequências medidas no fonte: pasta que já é workspace → **workspace duplicado** (dois registros/terminais para o mesmo cwd, sem passar pelo `findExistingWorkspace(byCwd:in:)`); pasta velha/renomeada → painel fecha e nada acontece (o `try?` engole o `LayoutError.workspaceNotFound`); e a pasta nunca entra em File ▸ Open Recent.

| Arquivo:linha | Mudança |
|---|---|
| `MainWindowController.swift:862-867` | o resultado do painel passa a ir para o caminho canônico do sidebar (`sidebar.createWorkspace(fromFolder: url)`) |
| `SidebarView.swift:5794-5801` | `SidebarView.createWorkspace(fromFolder:)` — passthrough para o `SidebarViewModel`, que é o dono do DEDUP-P2, do `noteNewRecentDocumentURL` e da folha de falha (mesmo padrão de delegação já usado por `disableInsomniaForAppClose()`) |

**Antes / Depois** (mesmo filtro, mesmo sandbox, **mesmo arquivo de teste**; "antes" com as duas fontes revertidas para `26aa0f2a`):

| Spec (`MainWindowControllerAddWorkspacePathTests`, novo) | Antes | Depois |
|---|---|---|
| `test_headerNewWorkspaceTakesTheSidebarAddPath` | **falha** — 2 falhas: `the panel result must go through SidebarView.createWorkspace(fromFolder:)` e `creating the workspace straight from the router skips DEDUP-P2` | passa |
| Total | 1 executado, **2 falhas** | 1 executado, **0 falhas** |

O spec é de **contrato de fonte** (lê `Sources/AppShell/MainWindowController.swift` e isola o corpo de `newWorkspace()`), a convenção que o repo já usa para wiring de AppKit sem teste possível (`AppMenuOpenRecentTests`, `NavigationFirstFrameTests`) — o `NSOpenPanel` é modal e não é dirigível por unit test. A cobertura **comportamental** do caminho segue em `WorkspaceCwdDeduplicationIntegrationTests` (4 specs, verdes nesta rodada: dedup por cwd, cwd distinto, pasta velha reportada, mensagem de erro preservada). Sem este spec a regressão volta em silêncio, porque o comportamento testado é o do sidebar, não o do botão.

### Regressão / baseline da iteração

| Rodada (mesmo filtro de família) | Executados | Falhas | Specs |
|---|---|---|---|
| Antes (fontes em `26aa0f2a`) | 105 | 4 | `MainWindowControllerRebuildCountTests:265`, `PaneActionTests:1498` (ambos PF-11 obsoleto), `PaneActionTests:1300` (flaky sob carga), `test_terminalBusyRuntimeRefresh…:77/:574` |
| Depois (18.1+18.2) | 112 | 5 | só sobraram pré-existentes/flaky: `:77/:574`, `:1300` (flaky) e `test_wideLayoutSixPanesFortyTabs_rebuildsWithinBudget:409` **sob carga** |

- Os dois specs PF-11 saíram do vermelho **sem tocar no produto** (18.2) e os 7 specs novos entraram verdes.
- `MainWindowControllerRebuildCountTests.test_wideLayoutSixPanesFortyTabs_rebuildsWithinBudget` ficou vermelho **apenas na rodada de família** (`1431,5 ms > 750 ms`) e passa isolado com folga nas duas pernas: pós-correção `135 ms` (2 rodadas) e pré-correção `145 ms` → **carga da máquina**, não regressão. Registrado como flaky sob carga.
- `PaneActionTests:1300` e `:77/:574` são vermelhos/flaky **nas duas pernas** (A/B dirigido idêntico) → pré-existentes, fora do escopo desta correção.
- Nenhuma rodada desta iteração teve `Executed 0 tests`.

### Achados novos verificados (não corrigidos — entram no backlog)

1. **⌘W/⌘D com uma janela de bot em foco (P2, verificado no fonte, sem spec):** `closeActiveTabOrWindow` (`AppDelegate.swift:1900-1914`) só trata Settings e janelas destacadas de workspace. Com uma janela de bot (`BotDeskWindowController`) em foco e um workspace selecionado na principal, `closeFocusedSurface(in: botWindow)` cai no caminho da principal e fecha uma aba que o usuário não está vendo; se o shell estiver em `.bots`, devolve `false` e o fall-through fecha a janela-chave. É a mesma classe do P1 de 18.1, num terceiro tipo de janela.
2. **Navegação de abas por teclado no mesmo defeito (P2, verificado no fonte):** `focusedPaneContext()` (`AppDelegate.swift:1871-1883`) resolve `⌘⇧[`/`⌘⇧]`/`⌘1..9` por `context?.state.window.selectedWorkspaceID` — com a janela destacada em foco, a troca de aba acontece no workspace da janela principal.

### Backlog (repriorizado na iter 18)

1. ~~Segundo braço do P1 de 16.2 #1 (janela destacada)~~ **fechado (18.1)**; ~~`MainWindowController.newWorkspace` (`:812-818`)~~ **fechado (18.3)**; ~~veredito PF-11~~ **fechado (18.2)**.
2. **Janela de bot / agent em foco para ⌘W/⌘D** (18 §1, P2 verificado) — mesma correção de roteamento por janela-chave, agora para `botWindows`/`botGuestWindows`/`extraWindows`.
3. **Navegação de abas (⌘⇧[ / ⌘⇧] / ⌘1..9) por janela-chave** (18 §2, P2 verificado).
4. **`reloadTokenSaverGovernance` N+1 com write por projeto** (15.2 #1, P2 confirmado) — `ensureDefaults` por projeto a cada abertura do popover.
5. **SidebarView P2 abertos** (inalterado): "Delete model" que mente e envenena o cache (`:3368-3369`); disco ilegível → "Not enough disk space" (`:1632-1643` + `:1298-1312`); `dragScrollEdge` reatribuído a 60-120 Hz no drag (`:5514-5518`); timer de auto-scroll de 16 Hz sem `onDisappear` (`:2987-3004`).
6. **BotsWindow P2** e **AppContext P2** (inalterados desde a iter 14; listas completas na 14).
7. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28 (`token_saver_attempt_*`); agregar falhas de um gesto multi-pasta numa única folha (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (inalterado desde 17)

AppShell — `AppCommandRouter` (9,1k, parcial), `ScheduledTasksWindow` (parcial) e `ScheduledTaskRuntime` (1,1k), `TokenSaverDistillServiceController` (1,2k), `PrivateAccountIntegration` (1,8k), `BotScheduleTasksWindow`; `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs); `Sources/Persistence/` (`BotStore`, `Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority`, `SettingsStore` além dos setters); `Sources/AgentRuntime/` (fora dos providers e dos caminhos de stop/checkpoint). Feitos: ~~`MainWindowController`~~/~~`Pet/*`~~ (16.2), ~~`SidebarView`~~ (14.2).

### Armadilha de método desta iteração (vale para as próximas)

`git checkout HEAD -- <caminho>` restaura o **HEAD**, não o estado da árvore de trabalho. Na perna "antes" do item (c), o HEAD ainda era `43fdb686` (correção de 18.1 sem a de 18.3), então o restore apagou a edição **não commitada** do `MainWindowController` e o commit `70af654a` saiu só com o `SidebarView.swift` — o spec novo pegou isso na rodada de família (`MainWindowControllerAddWorkspacePathTests` vermelho com o "depois" aplicado). Corrigido em `74ba9609` e re-verificado. Regra: **commitar a correção antes de rodar a perna "antes"** (ou salvar o patch fora da árvore).

### Commits da iteração

| Commit | Item |
|---|---|
| `cf914f61` | `fix(shell): route ⌘W/⌘D to the key detached workspace window` (18.1) |
| `43fdb686` | `test(shell): lock the detached-window keyboard target rule` (18.1) |
| `ff542652` | `test(shell): assert the PF-11 mounted-and-hidden tab contract` (18.2) |
| `78fc023f` | `test(sidebar): lock the header \`+\` workspace add path` (18.3) |
| `c3acba2f` | `test(shell): keep the detached ⌘W spec on the routed behavior` (18.1) |
| `70af654a` | `fix(sidebar): add header-chosen folders through the dedup path` (18.3, só o passthrough do SidebarView) |
| `74ba9609` | `fix(shell): add header-chosen folders through the sidebar dedup path` (18.3, call site) |

## Iteração 19 — 2026-09-18

Método: `/sam-goal` + `/sam-task` + `/sam-orchestrate`. Escopo: os **dois leads verificados de teclado** abertos no fim da iter 18 (backlog #2 e #3) — a mesma classe do P1 de 18.1, agora num terceiro tipo de janela (bot Desk/Guest) e na navegação de abas. Nenhuma área nova varrida (a lista de áreas pendentes segue a de 17).

### Item 19.1 — ⌘W/⌘D com uma janela de bot em foco agiam na janela principal (CORRIGIDO)

`AppDelegate.closeActiveTabOrWindow` (`:1900-1914`) só tratava Settings e janelas destacadas de workspace; `MainWindowController.detachedWindowController(owning:)` devolve `nil` para uma janela de bot Desk/Guest, e aí `closeFocusedSurface(in:)`/`splitFocusedPane(_:in:)` caíam no alvo da **janela principal** (`state.window.selectedWorkspaceID` + `shellContentMode == .workspace`). Com um bot Desk destacado em foco e o shell na workspace, medido por spec:

- ⌘W fechava uma aba do workspace **atrás da janela** (caminho destrutivo: `permanentlyCloseRuntimeSurface` → `closeAndDeletePersistedHistory()` + `unregister`) e **não** fechava a janela do bot;
- ⌘D dividia o painel do workspace principal, fora da tela.

**Correção (mudança mínima — um predicado de janela + dois guards):**

| Arquivo:linha | Mudança |
|---|---|
| `MainWindowController.swift:1168-1173` | `detachedWorkspaceID(owning:)` — o mapa janela → workspace destacado, reutilizado pelo predicado e pela navegação de abas |
| `MainWindowController.swift:1179-1185` | `presentsWorkspacePanes(_:)` — `nil` e a janela principal apresentam painéis; a janela destacada de workspace também; janela de bot/Guest/additional **não**. Folhas (`sheetParent`) e janelas-filho (`parent`) mantêm o alvo antigo (⌘W não passa a fechar uma folha) |
| `MainWindowController.swift:1022` / `:1046` | `closeFocusedSurface(in:)` e `splitFocusedPane(_:in:)` devolvem `false` quando a janela-chave não apresenta painéis — o fall-through que já existia fecha a janela do bot, e ⌘D beepa |

**Antes / Depois** (mesmo filtro, mesmo sandbox, **mesmo arquivo de teste**; "antes" = `Sources/AppShell/MainWindowController.swift` restaurado de `ce09b2cf`, HEAD limpo depois):

| Spec (`BotWindowKeyboardTargetTests`, novo) | Antes | Depois |
|---|---|---|
| `test_closeShortcut_withABotWindowFocused_closesTheBotWindow_notTheMainWorkspaceTab` | **falha** — 2 asserções: o workspace principal perdeu uma aba (2 → 1) e a janela do bot continuou visível | passa |
| `test_splitShortcut_withABotWindowFocused_leavesTheMainWorkspacePanesAlone` | **falha** — o workspace principal foi de 1 para 2 painéis | passa |
| Total | 2 executados, **3 falhas** | 2 executados, **0 falhas** |

### Item 19.2 — Navegação de abas (⌘⇧[ / ⌘⇧] / ⌘1..9) pela janela-chave (CORRIGIDO)

`AppDelegate.focusedPaneContext()` (`:1877-1890`) resolvia por `context?.state.window.selectedWorkspaceID` — o estado da **janela principal**. Com uma janela destacada de workspace em foco, ⌘⇧] trocava a aba do workspace de trás; com uma janela de bot em foco, ⌘2 selecionava a aba de um workspace invisível e, com um destino do shell (Bots) cobrindo a workspace, ⌘⇧] mudava uma aba fora da tela — a mesma regra que `ShellDestinationKeyboardTargetTests` já travava para ⌘W/⌘D desde 16.2.

**Correção:**

| Arquivo:linha | Mudança |
|---|---|
| `MainWindowController.swift:1192-1197` | `tabNavigationWorkspace(in:)` — a janela-chave escolhe o workspace; `nil` = sem alvo (bot/additional) e o destino do shell que cobre a workspace também é recusado, pela mesma razão de ⌘W/⌘D |
| `AppDelegate.swift:1880-1881` | `focusedPaneContext()` passa a usar `tabNavigationWorkspace(in: keyWindow)` (mesma costura `keyWindowProviderForTests` que 18.1 já usa) |

**Antes / Depois** (mesmo filtro de 5 classes, mesmo sandbox, mesmos arquivos de teste; "antes" = fontes de produto em `a7e32191`, que já contém 19.1):

| Spec | Antes | Depois |
|---|---|---|
| `DetachedWorkspaceKeyboardTargetTests.test_tabShortcut_stepsTheTabsOfTheKeyDetachedWindow_notTheMainWorkspace` (novo) | **falha** — 2 asserções: a aba do workspace principal mudou e a do destacado não | passa |
| `BotWindowKeyboardTargetTests.test_tabNumberShortcut_withABotWindowFocused_leavesTheMainWorkspaceTabAlone` (novo) | **falha** — ⌘2 moveu a seleção do workspace principal | passa |
| `ShellDestinationKeyboardTargetTests.test_tabShortcut_isRefusedWhileBotsOwnsTheShell_becauseTheTabsAreOffScreen` (novo) | **falha** — ⌘⇧] mudou a aba coberta pelo destino | passa |

Armadilha de método desta iteração: o primeiro spec de ⌘2 saiu **verde na perna "antes"** porque o fixture criava a 2ª aba já selecionada — o teste era inócuo. Corrigido para começar determinístico (`focusSurface` na aba #1, precondição explícita de que a #2 existe) e re-medido vermelho antes de seguir. Regra: spec de roteamento precisa de precondição que torne a mudança **observável**.

### Regressão / baseline da iteração

Filtro de família (5 classes: `BotWindowKeyboardTargetTests`, `DetachedWorkspaceKeyboardTargetTests`, `ShellDestinationKeyboardTargetTests`, `SettingsWindowCloseRoutingTests`, `BotWindow`), mesmo sandbox:

| Rodada | Fontes de produto | Executados | Falhas |
|---|---|---|---|
| Antes de 19.1 | `ce09b2cf` (sem os dois guards) | 9 | **3** — todas no spec novo de 19.1 |
| Antes de 19.2 | `a7e32191` (com 19.1) | 12 | **4** — 1 do ⌘2 + 2 do destacado + 1 do destino do shell |
| Depois | HEAD (`da35e6e1`) | 12 | **0** |

- Nenhum vermelho pré-existente apareceu nas três rodadas (as classes vizinhas `SettingsWindowCloseRoutingTests` e `BotWindow…` seguem verdes em todas as pernas) → delta atribuível só às correções.
- Nenhuma rodada com `Executed 0 tests`.
- Varredura larga de `--filter AppShellTests` (alvo inteiro) rodada **depois** desta iteração como checagem de regressão fora das famílias: ver "Pendências" abaixo.

### Checagem larga desta iteração (fora das famílias)

- **`--filter AppShellTests` (alvo inteiro) foi iniciado e abortado após ~56 min**: 1.705 specs verdes e 16 vermelhos no momento do corte, **sem baseline da mesma rodada** — número não atribuível, e por isso não usado como evidência (nem como "passou"). Custo alto demais para o orçamento de um fire; a atribuição foi feita pelo A/B dirigido abaixo.
- **A/B dirigido de 158 specs** — as 9 classes que tocam os pontos alterados (`BotWindowKeyboardTargetTests`, `DetachedWorkspaceKeyboardTargetTests`, `ShellDestinationKeyboardTargetTests`, `SettingsWindowCloseRoutingTests`, `PetWindowAccessibilityTests`, `PetWindowAndLifecycleTests`, `ServerStartupFailureTests`, `MainWindowControllerRebuildCountTests`, `PaneActionTests`), mesmo sandbox, produto em `ce09b2cf` na perna "antes":

| Perna | Executados | Falhas | Composição |
|---|---|---|---|
| Antes (`ce09b2cf`) | 158 | **14** | 8 asserções dos 5 specs novos (vermelhos por desenho) + `PaneActionTests:77/:574` (pré-existente) + `PaneActionTests:1300` (flaky sob carga) + 2 specs de timing de `Pet*` sob carga + `ShellDestinationKeyboardTargetTests.test_closeFocusedSurface…` (flaky sob carga; verde em isolamento) |
| Depois (HEAD) | 158 | **4** | `PaneActionTests:77/:574` (2 asserções, pré-existente — segue vermelho isolado) + `PetWindowAndLifecycleTests:test_progressRepublish…` + `PaneActionTests:test_focusSurfaceReconcilesDetachedWorkspaceWindowTabs` (este verde em isolamento) |

Re-medidas dirigidas para atribuir as 4 falhas restantes (mesmo sandbox):

| Spec | Medida | Veredito |
|---|---|---|
| `PaneActionTests.test_terminalBusyRuntimeRefreshUpdatesTabSpinnerWithoutRebuildingPane` (`:77`/`:574`) | vermelho **isolado** | pré-existente (já registrado na iter 18) |
| `PaneActionTests.test_focusSurfaceReconcilesDetachedWorkspaceWindowTabs` | **verde** isolado | flaky sob carga |
| `ShellDestinationKeyboardTargetTests.test_closeFocusedSurface_isRefusedWhileBotsOwnsTheShell…` | **verde** isolado (vermelho só na perna "antes" do A/B) | flaky sob carga, não é da correção |
| `PetWindowAndLifecycleTests:1221` (`cached Live Activity progress must beat durable apply by ≥5%`) | 6 amostras por perna: **antes 5/6 vermelhas** (3,85% / 4,57% / 4,70% / 4,35% / 4,21%), **depois 2/6 vermelhas** (4,54% / 4,33%) | flaky de timing pré-existente: a mesma faixa (~4,3–4,7%) abaixo do limiar de 5% aparece nas **duas** pernas |

Nenhuma linha de produto do caminho Pet/Live Activity foi tocada nesta iteração; o spec mede cache vs apply durável em milissegundos e é sensível à carga de outros agents na máquina.

### Backlog (repriorizado na iter 19)

1. ~~Janela de bot / agent em foco para ⌘W/⌘D~~ **fechado (19.1)**; ~~Navegação de abas (⌘⇧[ / ⌘⇧] / ⌘1..9) por janela-chave~~ **fechado (19.2)**.
2. **`reloadTokenSaverGovernance` N+1 com write por projeto** (15.2 #1, P2 confirmado) — `ensureDefaults` por projeto a cada abertura do popover.
3. **SidebarView P2 abertos** (inalterado): "Delete model" que mente e envenena o cache (`:3368-3369`); disco ilegível → "Not enough space" (`:1632-1643` + `:1298-1312`); `dragScrollEdge` reatribuído a 60-120 Hz no drag (`:5514-5518`); timer de auto-scroll de 16 Hz sem `onDisappear` (`:2987-3004`).
4. **BotsWindow P2** e **AppContext P2** (inalterados desde a iter 14).
5. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28 (`token_saver_attempt_*`); agregar falhas de um gesto multi-pasta numa única folha (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

Não reabrir (fechados com evidência): os itens do topo do `checklist.md` + os de 16–18.

### Áreas ainda não varridas (inalterado desde 17)

AppShell — `AppCommandRouter` (9,1k, parcial), `ScheduledTasksWindow` (parcial) e `ScheduledTaskRuntime` (1,1k), `TokenSaverDistillServiceController` (1,2k), `PrivateAccountIntegration` (1,8k), `BotScheduleTasksWindow`; `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs); `Sources/Persistence/` (`BotStore`, `Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority`, `SettingsStore` além dos setters); `Sources/AgentRuntime/` (fora dos providers e dos caminhos de stop/checkpoint). Feitos: ~~`MainWindowController`~~/~~`Pet/*`~~ (16.2), ~~`SidebarView`~~ (14.2).

### Commits da iteração

| Commit | Item |
|---|---|
| `ce09b2cf` | `test(shell): lock ⌘W/⌘D away from a key bot window` (19.1) |
| `a7e32191` | `fix(shell): keep ⌘W/⌘D off the workspace behind a key bot window` (19.1) |
| `63f9125b` | `test(shell): lock tab navigation to the key window` (19.2) |
| `3dc53308` | `fix(shell): route tab navigation by key window` (19.2) |
| `1c8a168a` | `test(shell): drive the tab-shortcut refusal through the menu path` (19.2) |
| `da35e6e1` | `test(shell): start the ⌘2 routing spec on a deterministic tab` (19.2) |

## Iteração 20 — 2026-09-18

Método: `/sam-goal` + `/sam-task` + `/sam-orchestrate`. `origin/production` avançou (merge do MR !385, librarian full surface) → `git merge origin/production` no worktree (limpo, sem conflito, commit `3f05b97e`) e baseline do filtro remedido **antes** de atribuir qualquer falha.

### Item 20.1 — Popover do Token Saver fazia N+1 de SQLite **com write** em toda abertura (CORRIGIDO)

Lead 15.2 #1 (P2 confirmado). `SidebarViewModel.reloadTokenSaverGovernance()` (`SidebarView.swift:838-878`) roda a cada abertura do popover (`toggleTokenSaverDetails`, `:3346`) e, **por projeto em escopo**, chamava `ensureDefaults(projectID:)` — que abria transação de escrita com 12 `INSERT OR IGNORE` + 2 `UPDATE` + `bumpRevision()` — seguido de `tokenSaverRolloverAdmission` e `list(projectID:)`. Ou seja: N transações de escrita no main actor, sempre idempotentes, no caminho de abrir o popover.

**Correção (menor escopo: probe de leitura antes de escrever, com a lista de lanes compartilhada):**

| Arquivo:linha | Mudança |
|---|---|
| `TokenSaverT003Persistence.swift:2734-2746` | `ensureDefaults` faz o probe e só abre a transação — e só incrementa a revisão — quando há lane faltando, linha de fábrica a reparar ou wire RCW1 a promover |
| `TokenSaverT003Persistence.swift:2798-2832` | `needsDefaults(database:projectID:)` — um único `SELECT` com três subconsultas que espelham exatamente as três escritas |
| `TokenSaverT003Persistence.swift:2871-2896` | lista de fábrica virou `defaultLanes` (struct + static) compartilhada por `insertDefaults` e pelo probe, para uma lane nova não poder ser semeada sem o probe notar |

**Antes / Depois** (mesmo filtro — `RepositoryRevisionTests` + `TokenSaverT003PersistenceTests` —, mesmo sandbox; "antes" com `Sources/Persistence/TokenSaverT003Persistence.swift` restaurado de `ab5821ac`):

| Rodada | Executados | Falhas |
|---|---|---|
| Antes | 41 | **1** — `test_ensureDefaults_isReadOnlyOnceTheProjectAlreadyHasItsLanes`: revisão 1 → 2 numa chamada sem efeito |
| Depois | 41 | **0** |

As 39 specs de T003 (seed inicial, reparo da fábrica legada, promoção RCW1, opt-out, recovery) ficam verdes nas **duas** pernas → o probe não pula trabalho real. O spec novo também fecha o falso-negativo do probe: apagar uma lane de fábrica faz a escrita (e a revisão) voltarem.

### Item 20.2 — Spec obsoleto `TokenSaverUXGatingTests:571` (CORRIGIDO)

Achado medido na varredura de regressão desta iteração (não estava em nenhuma lista): `test_ringsAccessibilityLabel_qualifiesReductionAsMeasured` estava vermelho exigindo `"measured save"`/`"est."` no rótulo de acessibilidade dos anéis, enquanto o produto diz `"estimated save … local tokens, ~N% of M goal"` — copy introduzida em `34fd7fcb` ("fixed ring goals") e que é exatamente o contrato do AGENTS.md ("It is labeled **Estimated save**… must not be relabeled as billed-only"). O spec vinha de `139263ce`/`9e9339d3`, anterior à nova copy.

- **Evidência de que não é desta iteração:** vermelho idêntico com a correção de 20.1 revertida; e o merge de `production` não tocou sidebar/rings (`git diff --name-only 1ebebee0 3f05b97e` → nenhum arquivo de sidebar).
- **Correção test-only**, alinhada ao contrato: exige `"estimated save"` + `"local tokens"` e proíbe `"billed"`. `--filter TokenSaverUXGatingTests`: **antes 23 executados / 1 falha → depois 23 executados / 0 falhas**, com o fonte de produto inalterado.

### Regressão / baseline da iteração

| Rodada | Executados | Falhas | Composição |
|---|---|---|---|
| Filtro da iteração (Persistence family), antes | 41 | 1 | só o spec novo de 20.1 |
| Filtro da iteração, depois | 41 | 0 | — |
| Varredura pós-merge de 8 classes (Token Saver + famílias de teclado da iter 19), depois | 58 (1 skip) | 1 | o spec obsoleto de 20.2 (corrigido e re-medido: 23/0) — as 3 famílias de teclado seguem verdes depois do merge |
| `--filter PersistenceTests` (alvo inteiro), depois | **923** (5 skip) | **4** | `RetentionCapTests.test_heavySession_allRetentionCapsTogetherBoundTheDatabase` (limite exato, `:704`) + `SessionDiagnosticsUpdateTests.test_updateDiagnostics_fasterThanGetAndUpsert` e `SessionMarkStoppedTests.test_markStopped_fasterThanGetAndUpsert` (micro-benchmarks de tempo real, `:647`/`:706`) |
| Mesmas 3 classes com o produto em `ab5821ac` (perna "antes" dirigida) | 28 | **4** | mesmo conjunto → **delta zero** atribuível a 20.1 |

- Nenhuma rodada `Executed 0 tests`; nenhum baseline de família se moveu.
- As 4 falhas do alvo Persistence são as pré-existentes já documentadas na iter 1/2 (`:101`, `:647`, `:704`, `:706`) e reproduzem sem esta correção.

### Backlog (repriorizado na iter 20)

1. ~~`reloadTokenSaverGovernance` N+1 com write por projeto~~ **fechado (20.1)**.
2. **SidebarView P2 abertos**: "Delete model" que mente e envenena o cache (`:3368-3369`); disco ilegível → "Not enough space" (`:1632-1643` + `:1298-1312`); `dragScrollEdge` reatribuído a 60-120 Hz no drag (`:5514-5518`); timer de auto-scroll de 16 Hz sem `onDisappear` (`:2987-3004`). Somam-se os "a confirmar" da 15.2 que ainda não tiveram veredito: walk síncrono da árvore Distill no `body` do toggle (`:1431-1443`/`:3193`), heal de 7 dias da economia no boot (`:584`/`:779-782`), "Today" mostrando o total de ontem depois da meia-noite (`:3578-3579`), `try?` engolindo mutações do router (`:1766`, `:2122`, `:2126`, `:2257`, `:2309`).
3. **BotsWindow ~9 P2** e **AppContext ~6 P2** (inalterados desde a iter 14).
4. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (inalterado desde 17)

AppShell — `AppCommandRouter` (9,1k, parcial), `ScheduledTasksWindow` (parcial) e `ScheduledTaskRuntime` (1,1k), `TokenSaverDistillServiceController` (1,2k), `PrivateAccountIntegration` (1,8k), `BotScheduleTasksWindow`; `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs); `Sources/Persistence/` (`BotStore`, `Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority`, `SettingsStore` além dos setters); `Sources/AgentRuntime/` (fora dos providers e dos caminhos de stop/checkpoint). Feitos: ~~`MainWindowController`~~/~~`Pet/*`~~ (16.2), ~~`SidebarView`~~ (14.2).

### Commits da iteração

| Commit | Item |
|---|---|
| `3f05b97e` | merge de `origin/production` (MR !385, librarian) |
| `ab5821ac` | `test(persistence): lock ensureDefaults as read-only once seeded` (20.1) |
| `d8882648` | `fix(persistence): keep the Token Saver popover reload read-only` (20.1) |
| `817e50f2` | `test(shell): assert the rings a11y copy VoiceOver actually reads` (20.2) |

## Iteração 21 — 2026-09-18

Método: `/sam-goal` + `/sam-task` + `/sam-orchestrate`. Fechados os **4 P2 verificados de `SidebarView`** (a prioridade (b) do loop) e feita mais uma passada da varredura (item (d)) com veredito para os achados "a confirmar". `origin/production` não avançou (0 commits à frente desde o merge da iter 20), então não houve merge nem rebaseline.

### Item 21.1 — `dragScrollEdge` era reatribuído a 60-120 Hz durante o drag (CORRIGIDO)

`WorkspaceDropDelegate.dropUpdated` roda a cada tick do drag e reatribuía `vm.dragScrollEdge` mesmo quando a direção não mudou (o ponteiro fica parado dentro da zona de 40 pt). Como o campo era `@Published`, cada escrita idêntica disparava `objectWillChange` e reconstruía o body da sidebar — até 120 invalidações por segundo durante um arrasto que só estava rolando a lista.

**Correção (8 linhas, sem mudar a API):** `dragScrollEdge` virou `var` com dedupe de mesmo valor no `willSet` (`guard newValue != dragScrollEdge else { return }; objectWillChange.send()`), o mesmo padrão que `AgentComposerState.cursorOffset` já usa (AA-13). `.onChange(of: vm.dragScrollEdge)` continua funcionando (só os valores realmente diferentes publicam).

| Rodada (mesmo filtro: `SidebarRefreshPerfGuardTests` + `TokenSaverDownloadConfirmDecisionTests`) | Executados | Falhas |
|---|---|---|
| Antes (produto em `0d8a6b02`) | 21 | **3** |
| Depois (`b89ca960`) | 21 | **0** |

Evidência vermelha do spec novo `test_dragScrollEdge_repeatedSameDirectionDoesNotPublish`: **121 publica ≠ 1** (as 120 escritas idênticas de 1 s a 120 Hz publicaram todas) e **122 ≠ 2** ao sair da zona. O `test_reload_doesNotPublishWhenSnapshotUnchanged` e os outros 8 specs da classe ficam verdes nas duas pernas.

### Item 21.2 — disco ilegível virava "Not enough disk space" e bloqueava o download (CORRIGIDO)

`volumeFreeDiskBytes()` devolvia **0 quando a consulta de volume falhava**, e `downloadConfirmDecision` lê 0 como disco cheio: o alerta de `hasEnoughDisk == false` só tem botão **OK** ("this Mac does not appear to have enough available"), então uma medição impossível bloqueava o download de ~3,8 GB de um disco saudável — com uma afirmação falsa na tela.

**Correção:** sentinela explícita `unknownFreeDiskBytes = -1` (free bytes nunca é negativo) devolvida pela probe; `downloadConfirmDecision` faz `guard freeDiskBytes >= 0 else { return .confirm }`. Desconhecido cai no diálogo normal de confirmação; se o disco estiver mesmo cheio, a escrita falha alto. O caso `0 → .insufficientDisk` (disco realmente cheio) fica intacto e continua coberto pelo spec que já existia.

| Spec | Antes | Depois |
|---|---|---|
| `test_downloadConfirmDecision_confirm_whenFreeDiskIsUnknown` (novo) | **falha** — `insufficientDisk` ≠ `confirm` | passa |
| `test_downloadConfirmDecision_insufficientDisk_whenFreeIsZero` (pré-existente) | passa | passa |

### Item 21.3 — "Delete model" mentia e envenenava o cache quando o unlink falhava (CORRIGIDO)

`deleteTokenSaverModel` fazia `try? FileManager.default.removeItem(...)` e em seguida **gravava 0 bytes** no cache de tamanho instalado. Se a remoção falhasse (permissão, diretório em uso), a sidebar mostrava o modelo como apagado: a linha "Delete model (N GB)" desaparecia (o botão só aparece com tamanho > 0) e o próximo enable re-baixava ~3,8 GB sem nada na tela explicando.

**Correção:** a remoção virou `SidebarViewModel.removeInstalledTokenSaverModel(at:fileManager:)`, que devolve o erro e **derruba o cache** quando o diretório sobrevive (uma remoção recursiva pode apagar o conteúdo e ainda falhar no unlink, então o tamanho sobrevivente não é conhecível ali — a próxima leitura mede o disco); só grava 0 quando o diretório realmente não existe. A view apresenta o erro pelo `operationPresenter` já injetado ("Could not delete Token Saver model") em vez de dizer que apagou.

| Spec novo (`TokenSaverModelDeleteTests`) | Antes (corpo antigo: `try?` + grava 0) | Depois |
|---|---|---|
| `test_removeInstalledTokenSaverModel_reportsFailureAndKeepsTheCachedSize` | **2 falhas** — erro engolido (`XCTAssertNotNil`) e cache `0` ≠ `4096` em disco | passa |
| `test_removeInstalledTokenSaverModel_recordsZeroOnceTheDirectoryIsGone` | passa | passa |
| `test_removeInstalledTokenSaverModel_missingDirectory_isNotAFailure` | passa | passa |

Executados: **3 antes / 3 depois**, falhas **2 → 0**.

### Item 21.4 — timer de auto-scroll de 16 Hz sobrevivia ao desaparecer da sidebar (CORRIGIDO, inspeção)

O `dragScrollTimer` só era invalidado no próximo `onChange` de `dragScrollEdge`. Se a sidebar saísse da árvore no meio do drag (fechar janela, trocar Agentic↔Bots), nada reatribui a aresta e o timer continuava disparando `scrollProxy.scrollTo` a 16 Hz contra uma view morta, segurando o proxy. **Correção:** `.onDisappear { dragScrollTimer?.invalidate(); dragScrollTimer = nil }` no container do body (8 linhas).

**Sem teste unitário, e o motivo é explícito:** o timer é `@State` de uma `SwiftUI.View` (`SidebarRootView`) e o repositório não tem costura de ciclo de vida de view (nenhum `onDisappear` é exercitado por spec; os specs de sidebar montam a view offscreen e não a desmontam no meio de um drag). Não há como produzir vermelho honesto aqui sem inventar uma abstração nova; fica registrado como cobertura por inspeção, e a classe da área segue verde na regressão da iteração. Candidato a fechar com teste se/quando existir um harness de desaparecimento de view.

### Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| Perna "antes" de 21.1+21.2 (produto `0d8a6b02`) | 21 | 3 (só os 2 specs novos) |
| Perna "depois" de 21.1+21.2 | 21 | **0** |
| Perna "antes" de 21.3 (reversão só de comportamento) | 3 | 2 (spec novo) |
| Perna "depois" de 21.3 | 3 | **0** |
| Regressão final: 4 classes (`SidebarRefreshPerfGuardTests`, `TokenSaverDownloadConfirmDecisionTests`, `TokenSaverModelDeleteTests`, `TokenSaverCardSeamTests`) | **91** | **0** |

Nenhuma rodada `Executed 0 tests`; nenhum baseline de família se moveu (as classes tocadas são as mesmas que já estavam verdes na iter 20).

### Lições de método desta iteração (para não repetir)

1. **`--filter` por classe pode omitir specs que vivem numa 2ª classe do mesmo arquivo.** `TokenSaverDownloadError*` tem duas classes; o filtro pegou 9 de 20 specs e a rodada saiu "verde" sem rodar o spec novo. Agora toda rodada confere o **nome do spec** no log, não só `Executed N > 0`.
2. **Compilar antes de commitar.** Dois commits de conserto nesta iteração (label `detail:` faltando no presenter; fixture de teste sem `@MainActor`/`router`) porque o commit saiu antes de qualquer build. Custo baixo (~40 s cada rodada) mas evitável.
3. **Perna "antes" de API nova não compila.** Para 21.3 o A/B honesto não é `git checkout <commit> --`: é reverter **só o corpo** do helper (mantendo a assinatura) e restaurar com `git checkout HEAD -- <caminho>` — registrado como tal no MR.
4. **Fixture pode tornar a asserção vacua.** Com o diretório-pai travado (0o500), o `removeItem` recursivo apagava o conteúdo e deixava 0 bytes, então `cache == modelDirSize` passava até no código bugado. A fixture passou a travar o **próprio** diretório do modelo: falha no primeiro unlink com os 4096 bytes intactos, e a asserção fica não-vacua (vermelha antes, verde depois).

### Varredura (item (d)) — vereditos desta iteração

| Área / ponto | Veredito | Evidência |
|---|---|---|
| `ScheduledTaskRuntime` timer de 30 s do scheduler | **descartado** | invalidado em `applicationWillTerminate` (`:1132`), junto dos observers |
| `FeedSurface` `Timer.publish` | **descartado** | a menção (`:303`) é o comentário do fix anterior; não há timer vivo |
| `PrivatePushTargetStore.save(pushToken:…)` / `clear()` (`PrivateAccountIntegration:852/:856`) | **confirmado P2 → próximo item** | `try? repo.set(...)` engole a falha de escrita, e `AppCommandRouter.privatePushTokenUpdate` (`:7992`) devolve `{"ok": true}` para o iOS: o registro de push some sem erro em lugar nenhum. Fix curto: `save` passa a `throws` (1 chamador) |
| `PrivateAccountSessionStore.save/clear` (`:679/:688`) | **confirmado P3** | `catch { return }`: sessão não persiste e o usuário só descobre no relogin, sem superfície de erro |
| `BotRemoteControlAuthority.deleteAndClean:750` | **confirmado P3** | `try? store.deleteQueuedFollowUps(botID:)` não entra em `residuals`, embora o resto da limpeza (container, guest) entre — inconsistente com o desenho ao redor |
| `AgentRunCoordinator` caminho de Stop (`:4304`, `:4312`, `:7708`) | **confirmado P3 — decisão de contrato** | `try?` em `markStopped`/`cancelIfActive` é deliberado (comentário de perf em `:4307`), mas escrita falha deixa run/thread ativos no banco com a UI dizendo parado; não corrigir sem o dono |
| `LocalStorageBudget`, `AgentSkillInstaller`, `TokenSaverModelInstaller` (`try? removeItem` de staged/tmp) | **descartado** | limpeza best-effort legítima de arquivos temporários |

### Backlog (repriorizado na iter 21)

1. ~~4 P2 de `SidebarView`~~ **fechados (21.1–21.4)**.
2. `PrivatePushTargetStore.save/clear` com falha silenciosa de registro de push (**P2 confirmado**, acima) — próximo item natural.
3. **"a confirmar" da 15.2 ainda sem veredito**: walk síncrono da árvore Distill no `body` do toggle (`:1431-1443`/`:3193`), heal de 7 dias da economia no boot (`:584`/`:779-782`), "Today" mostrando o total de ontem depois da meia-noite (`:3578-3579`), `try?` engolindo mutações do router (`:1766`, `:2122`, `:2126`, `:2257`, `:2309`).
4. **BotsWindow ~9 P2** e **AppContext ~6 P2** (inalterados desde a iter 14).
5. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2); +2 P3 da varredura desta iter (sessão privada, fila do bot).

### Áreas ainda não varridas (atualizado na iter 21)

Feitas nesta iter: ~~`ScheduledTaskRuntime`~~ (timer, descartado), ~~`FeedSurface`~~ (descartado), ~~`PrivateAccountIntegration`~~ (parcial: push targets + session store com veredito; falta o restante), ~~`BotRemoteControlAuthority`~~ (parcial: caminho de delete/limpeza), ~~caminho de Stop do `AgentRunCoordinator`~~ (parcial).

Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `ScheduledTasksWindow` (1,9k, parcial), `ScheduledTaskRuntime` (restante das 1,1k), `TokenSaverDistillServiceController` (1,2k), `BotScheduleTasksWindow` (703), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`BotStore`, `Schema`, `TokenSaverT003Persistence`, `SettingsStore` além dos setters); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos). Feitos: ~~`MainWindowController`~~/~~`Pet/*`~~ (16.2), ~~`SidebarView`~~ (14.2 + 21).

### Commits da iteração

| Commit | Item |
|---|---|
| `b89ca960` | `fix(shell): stop republishing the sidebar on unchanged drag edge and unmeasured disk` (21.1+21.2) |
| `05a7002f` | `test(shell): keep the unknown-disk spec compiling against the pre-fix probe` (método) |
| `c26cfb19` | `fix(shell): stop claiming the model was deleted when the unlink fails` (21.3) |
| `bdb79eda` | `fix(shell): pass the detail label to the delete-model error presenter` (conserto de build) |
| `b92a4f93` | `test(shell): build the delete-model fixture on the main actor with a router` (conserto de build) |
| `8c2ecbc7` | `fix(shell): re-measure the model dir after a failed delete instead of trusting a size` (21.3, fixture não-vacua) |
| `b9addd87` | `fix(shell): tear down the sidebar edge-scroll timer when the view goes away` (21.4) |

## Iteração 22 — 2026-09-18

Método: `/sam-goal` (precedência; `/sam-task` e `/sam-orchestrate` como contexto — o turno tem um item de valor + varredura, sem unidades independentes que justifiquem workers). `origin/production` não avançou desde o merge da iter 20 (0 commits à frente desde `3f05b97e`) → sem merge e sem rebaseline.

### Item 22.1 — registro de push engolido: o iOS recebia `{"ok": true}` sem alvo persistido (CORRIGIDO)

`PrivatePushTargetStore.save` fazia `try? repo.set(key, json)` e `AppCommandRouter.privatePushTokenUpdate` respondia `{"ok": true}` na linha seguinte. Com a tabela `settings` não gravável (disco cheio, DB travado), o telefone acreditava que o Mac estava registrado para alertas e Live Activity: nenhum alvo no banco, nenhum retry, e nada na tela. O router é o único consumidor de `save` que fala com o cliente.

**Correção (menor escopo):** `save` passou a `throws`; a leitura de `previous` deixou de ser `try?` também (uma leitura falha zerava o `liveActivityToken` guardado, exatamente o que o contrato do próprio método proíbe) e a chamada no router virou `try store.save(...)`, então o erro chega ao `Dispatcher` e volta como erro JSON-RPC. `clear()` fica como está: os 5 chamadores são limpezas best-effort pós-`shouldDropSubscription` e não há superfície de honestidade ali.

**Antes / Depois** (mesmo filtro: `AppIdentityNotificationTests` + `SilentWakeOutboxTests` + `LiveActivitySyncCoordinatorTests`, mesmo sandbox; a perna "antes" usa a **assinatura nova com o corpo antigo** que engolia — a API nova não compila contra o fonte pré-fix, então o A/B é por reversão de comportamento):

| Rodada | Executados | Falhas |
|---|---|---|
| Antes (corpo `try?` + `load()`) | 106 | **6** — os 2 specs novos + os 2 specs de ciclo de vida abaixo |
| Depois | 106 | **4** — só os 2 de ciclo de vida |

| Spec novo | Antes | Depois |
|---|---|---|
| `testPrivatePushTargetSaveSurfacesWriteFailureAndKeepsTheStoredTarget` | falha — "did not throw an error" | passa |
| `testPrivatePushTokenUpdateReportsWriteFailureInsteadOfOk` | falha — "did not throw an error" | passa |

Fixture: dois triggers SQLite (`BEFORE INSERT`/`BEFORE UPDATE ON settings`) abortando a escrita real do store, não um mock; o spec do router ainda confere que o alvo anterior sobrevive. As 39 specs pré-existentes da classe, as 12 do outbox e as 51 do coordenador ficam verdes nas **duas** pernas.

**Falhas não atribuíveis (delta zero):** `testAgentRunLifecycleEventsCarryAuthoritativeRunTiming` e `testStreamingErrorsDoNotEmitTerminalRunNotificationsBeforeFinish` (timeouts de 6 s esperando eventos de run) falham idênticas nas duas pernas → pré-existentes/flaky sob carga desta máquina, não desta mudança.

### Varredura (item (d)) — vereditos desta iteração

| Área / ponto | Veredito | Evidência |
|---|---|---|
| `TokenSaverDistillServiceController` (1,2k): ciclo do `restartTask` | **descartado** | os dois únicos `cancel()` (`:780` em `stop()`, `:926` em `start()`) zeram o campo logo depois, então o retorno antecipado por cancelamento não deixa task órfã travando o próximo `scheduleRestart` (`guard restartTask == nil`, `:891`); `:1087` zera `restartAttempts` no sucesso |
| `TokenSaverDistillServiceController`: sweep de servidores estrangeiros + gate de instância única | **descartado** | `terminateForeignServers` roda em `Task.detached` e re-checa `shouldRun`/processo no `MainActor` (comentário F3, `:935-951`); `try? psRows` (`:709`) devolve sweep vazio sem afirmar que matou algo |
| `BotScheduleTasksWindow` (703) | **descartado** | sem `try?`/`catch`/timer; só identificadores de filtro e um `providers.filter` de UI |
| `ScheduledTasksWindow:1561` `try? draft.makeTask()` | **descartado** | é o rótulo de pré-visualização ("Next run" / "Not scheduled yet") com fallback explícito, não caminho de escrita |
| `SettingsStore.load()` falha de leitura → `AppSettings()` (`:345`) | **descartado** | contrato legado do wrapper; a composição perigosa (load → mutar → save) é guardada em `update()` (`:398`, "A failed read must not turn into defaults and overwrite valid settings") e as 54 mutações em `Sources/` usam `.update` |
| `Persistence/BotStore`: `try? decodeBot/decodeConversation { continue }` | **descartado** | pula linha indecifrável em varredura de lista (mesma decisão já aceita de "outbox indecifrável → backlog vazio com log"); o `catch` de mutação (`:452`) faz rollback e re-lança |
| `BotRemoteControlAuthority.deleteAndClean:750` `try? store.deleteQueuedFollowUps` (P3 da iter 21) | **reclassificado: descartado** | `BotStore.delete:603` já apaga `bot_queued_follow_ups` na **mesma** transação antes dessa linha: a chamada é redundante e nenhuma linha pode sobrar por falha dela. Teste vermelho tentado: um trigger `BEFORE DELETE ON bot_queued_follow_ups` aborta o `store.delete` **primeiro** (`:748`), com rollback e re-throw — a falha engolida é inobservável. Mudança revertida (diff zero); o `try?` fica como está porque é código pré-existente e a remoção não foi pedida |

### Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| Filtro da iteração, antes (corpo revertido) | 106 | 6 — 2 specs novos (1 falha de asserção cada) + 2 specs de ciclo de vida (2 cada) |
| Filtro da iteração, depois | 106 | 4 (só os 2 de ciclo de vida, 2 cada) |
| `BotRemoteControlAuthorityTests` com a tentativa de 22.x (revertida) | 84 | 1 — o spec do trigger, que provou a redundância |
| `BotRemoteControlAuthorityTests` depois da reversão (baseline intacto) | 83 | **0** |

### Backlog (repriorizado na iter 22)

1. ~~P2 do push target (`save`/`clear`)~~ **fechado (22.1)**.
2. **"a confirmar" da 15.2 ainda sem veredito**: walk síncrono da árvore Distill no `body` do toggle (`SidebarView:1431-1443`/`:3193`), heal de 7 dias da economia no boot (`:584`/`:779-782`), "Today" mostrando o total de ontem depois da meia-noite (`:3578-3579`), `try?` engolindo mutações do router (`:1766`, `:2122`, `:2126`, `:2257`, `:2309`).
3. **BotsWindow ~9 P2** e **AppContext ~6 P2** (inalterados desde a iter 14).
4. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear` (sessão não persiste, sem superfície de erro), caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
5. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 22)

Feitas nesta iter: ~~`TokenSaverDistillServiceController`~~ (descartado), ~~`BotScheduleTasksWindow`~~ (descartado), ~~`ScheduledTaskRuntime` restante + `ScheduledTasksWindow` restante~~ (descartado), ~~`BotRemoteControlAuthority` delete/cleanup~~ (reclassificado), ~~`Persistence/BotStore` varredura + `SettingsStore` além dos setters~~ (descartado).

Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos). Feitos: ~~`MainWindowController`~~/~~`Pet/*`~~ (16.2), ~~`SidebarView`~~ (14.2 + 21).

### Commits da iteração

| Commit | Item |
|---|---|
| `4efe4fce` | `fix(shell): surface a failed push-target write to iOS instead of ok:true` (22.1) |
| `5b861f1d` | `test(shell): lock the push registration to a real settings-write failure` (22.1, prova vermelha) |

## Iteração 23 — 2026-09-18

Escopo: veredito dos 4 leads "a confirmar" da 15.2 em `SidebarView` (prioridade (a)) e a única correção acionável que sobrou deles. Método: auditoria read-only + A/B dirigido às três classes que chamam `select`.

### Vereditos (os 4 leads "a confirmar" da 15.2)

| Lead (linhas atuais) | Veredito | Evidência |
|---|---|---|
| Walk síncrono da árvore Distill no `body` do toggle (`SidebarView:1453-1466`, lido em `:3279`; era `:1431-1443`/`:3193`) | **descartado — já mitigado** | `installedTokenSaverModelBytes()` (`:1453`) devolve 0 com o Token Saver ligado e, desligado, anda na árvore só no 1º render por URL: o resultado fica em `tokenSaverInstalledModelSizeCache` (`:473`) e só é invalidado/re-medido em disable/download/delete (`:1468-1474`). `TokenSaverModelDeleteTests:60-115` já trava tamanho/delete/reclaim |
| Heal de 7 dias da economia no boot (`:607`, impl `:802-804`; 2ª chamada no popover `:1045`) | **por desenho — custo já limitado e travado** | Snapshot settings+usage.json carregado **1× por janela** (`AppContext:5625-5631`); `test_economyWindow_loadsSharedSettingsAndUsageOnce` exige 1 load e `test_usageChangedNotification_DoesNotRehealSevenDayWindow` exige "boot must heal the week once" sem re-heal em notificação. Medição read-only no banco vivo (1,4 GB, `sqlite3 -readonly`): o agregado de 7 dias (tabela `token_saver_savings`, 19.160 linhas) roda em **0,001 s**; sobra 1 load de settings + 7 upserts. Mover para fora do main mudaria a janela de frescor do Week sem ganho medido |
| "Today" com o total de ontem após a meia-noite (`:3605`, `:3657`, `:3752`) | **descartado — já tratado** | `tokenSaverNow` é atualizado pelo `tokenSaverDailyRolloverClock` (`:3119-3130`), preso por `.task` (`:3105-3107`), que dorme até `tokenSaverNextDailyResetDate` com teto de 86,5 s; o helper (`:4466-4476`) sempre devolve instante futuro (00:00:01 ou o do dia seguinte), sem busy-loop — `TokenSaverCardSeamTests:950` trava o agendamento |
| `try?` engolindo mutações do router (`:2199`, `:2203`, `:2335`, `:2386`, `:2472-2478`; `select` era `:1815`) | **só o `select` mentia — corrigido (23.1)**; os outros ficam no-op silencioso **com razão** | A única falha alcançável é `LayoutError.workspaceNotFound` do reducer (`Reducer.swift:99-124`, `:159-161`) numa corrida de id obsoleto; a persistência do snapshot é debounced e reportada por outro canal (`AppContext:6183-6231`), então o `try?` não esconde falha de escrita. Color/pin/reorder/batch-pin chamam `reload()` logo depois → a UI volta à verdade e não alega sucesso. `select` pintava o highlight otimista **sem reload no caminho de falha** (23.1). O restore do undo (`:2468-2479`) roda após `createWorkspace` bem-sucedido → guard inalcançável |

### 23.1 `select` rejeitado mantinha highlight otimista (`b1b3e9fe` código, `adc854a8` testes)

`SidebarViewModel.select(_:)` pinta a seleção antes de chamar o router (acknowledge imediato, regra de loading do repo). Com `try?`, um apply rejeitado (linha obsoleta fechada por baixo da lista) deixava esse highlight de pé **sem reload atrás** — a sidebar exibia uma seleção que o app nunca fez, indefinidamente. O catch agora faz `reload()` (`:1816-1824`).

**Teste novo (vermelho no "antes"):** `WorkspaceEditTests.test_select_snapsBackToHostTruth_whenRouterRejectsStaleWorkspace` (`:179`) — cria dois workspaces, fecha o segundo no estado sem recarregar a sidebar e clica na linha obsoleta; exige `selectedWorkspaceID == first.id` e a linha obsoleta fora de `vm.workspaces`.

### 23.2 Spec de drop pendurava a suíte em `runModal()` (`adc854a8`)

`test_sidebarDroppedFileIsRejectedForWorkspaceCreation` (`:402`) chama `createWorkspace(fromFolder:)` com um arquivo comum; a superfície honesta de erro adicionada em `b8e1f094` (iter anterior) leva esse caminho ao **presenter default**, cujo fallback headless é `NSAlert.runModal()` (`SidebarView:2426`) — sem key window no processo de teste, a chamada nunca retorna. A 1ª rodada desta iter ficou ~12 min parada e foi morta; `sample` do xctest: `WorkspaceEditTests.swift:410` → `createWorkspace(fromFolder:)` (`SidebarView:1917`) → `defaultOperationErrorPresenter` (`SidebarView:2426`). A spec agora injeta o seam `operationErrorPresenter` (mesmo idioma de `WorkspaceCwdDeduplicationTests`); a mensagem do usuário continua travada em `test_staleFolderAdd_surfacesTheFailureInsteadOfDoingNothing`.

**Lição registrada:** rodada filtrada por classe sem nenhuma janela é exatamente a que pendura, e "verde" não vale se a classe não terminou — conferir spec por nome nas duas pernas.

### Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| Filtro (WorkspaceEditTests + SidebarFilteredShiftSelectTests + SidebarReorderAndFilterTests), antes (`SidebarView.swift` revertido p/ `58400f1e`) | 41 | **2** — só `test_select_snapsBackToHostTruth...` (as 2 asserções) |
| Filtro, depois (`adc854a8`, HEAD) | 41 | **0** |
| 1ª tentativa "depois" (sem 23.2) | — | travou em `test_sidebarDroppedFileIsRejectedForWorkspaceCreation` (~12 min, morta) |

Specs conferidos por nome nas duas pernas: 22/22 `WorkspaceEditTests`, 16/16 `SidebarReorderAndFilterTests`, 3/3 `SidebarFilteredShiftSelectTests`.

### Backlog (repriorizado na iter 23)

1. ~~"a confirmar" da 15.2~~ **fechado (23.1 + vereditos acima)**.
2. **BotsWindow ~9 P2** e **AppContext ~6 P2** (inalterados desde a iter 14) — próximo alvo da prioridade (b).
3. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear` (sessão não persiste, sem superfície de erro), caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
4. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 23)

Nada novo varrido nesta iter (escopo foi o fecho da prioridade (a) em `SidebarView`, já contabilizada em 14.2 + 21). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `b1b3e9fe` | `fix(shell): a rejected workspace selection must not keep its optimistic highlight` (23.1) |
| `adc854a8` | `test(shell): lock the rejected-selection snap-back, and unhang the dropped-file spec` (23.1 + 23.2) |

## Iteração 24 — 2026-09-18

Escopo: prioridade (b) — o item de maior valor da lista de P2 do `BotsWindow` (o único de perda de dados do usuário).

### 24.1 `send()` consumia composer/anexos/rascunho antes da escrita que pode falhar (`a4251d07`, teste `9deae05e`)

`BotsViewModel.send(_:relayHop:)` (`BotsWindow.swift:6024`) limpava o composer, descartava os anexos staged e rodava `flushPendingDraftPersistence()` **antes** de `persistUserMessage` (chamada em `:6060`) — que pode falhar (`upsertConversation`, `BotStore.swift:829`). Numa falha de escrita o usuário via só `errorMessage`: a linha digitada, os arquivos anexados e o rascunho salvo já tinham sido consumidos.

Agora `consumeComposerForAcceptedSend()` (`:6086-6092`) roda **depois** do persist (mesmo turno síncrono, nenhum frame no meio: sem latência percebida a mais) e, no ramo de follow-up com run vivo, antes do `enqueueFollowUp` (`:6051`) — a fila é memória e não falha. Falha em `persistUserMessage` → editor, anexos e rascunho intactos para o retry; falha depois (em `enqueueSupervisedBotRun`) mantém o contrato antigo: a mensagem já está durável e pintada, então consumir o composer é o certo.

**Teste novo (vermelho no "antes", 3 asserções):** `BotsWindowTests.test_failedSendKeepsComposerWordsAttachmentsAndDraft_becauseNothingWasWritten` — falha de escrita real (trigger `BEFORE INSERT ON bot_conversations` com `RAISE(ABORT)`, não mock) e exige texto, anexo staged e rascunho persistido preservados.

### Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| Filtro dirigido (12 specs de send/fila/rascunho), antes (`BotsWindow.swift` revertido p/ `2fa9f6d5`) | 12 | **3** — só o spec novo (texto, anexo e rascunho) |
| Filtro, depois (`9deae05e`, HEAD) | 12 | **0** |

Specs conferidos por nome nas duas pernas: 12/12 — `test_failedSendKeepsComposerWords…`, `test_sendClearsComposerDraft…`, `test_sendAndSaveSynchronouslyFlushPendingDraftState…`, `test_deskSendAdmitsAndClearsAttachments…`, `test_sendAfterStopWaitsUntilStopSettles`, `test_queuedFollowUp{StaysOnOwningBot,CanBeRemoved,SurvivesRelaunch}…`, `test_hideCloseAndQuitFlushPendingDrafts…`, `test_sendContinuesSelectedConversation`, `test_sendDoesNotListConversations…`, `test_sendKeepsDestConversation…`.

### Backlog (repriorizado na iter 24)

1. ~~`send()` limpa composer/anexos/rascunho antes da escrita que pode falhar~~ **fechado (24.1)**.
2. **BotsWindow P2 restantes (8)** — números de linha da iter 14, reconferir ao pegar cada um: chip provider·model do rail de threads permanentemente velho (`:7321-7323` vs `:9495`); watch de 2 s faz SQLite no main por tick (`:9100-9105`); `refreshActiveBotCount()` no main e 2× por run terminado (`:3684`, `:10594`/`:10608`); até 3 reloads completos por delta de handoff (`:6930-6932`, `:10479-10486`); 2 `stat` de filesystem por avaliação do composer (`:7788-7790` vs TTL `:7795-7800`); `searchText` grava UserDefaults por tecla (`:3068-3070`); toda mutação de fila reescreve a tabela inteira com `createdAt: Date()` (`:7494-7512`); deletar bot deixa caches residentes (`:5576-5588`).
3. **AppContext ~6 P2** (inalterados desde a iter 14; lista completa na 15.2).
4. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear` (sessão não persiste, sem superfície de erro), caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
5. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 24)

Nada novo varrido (escopo foi um P2 de `BotsWindow`, já contabilizado nas iters 13.3/14). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `a4251d07` | `fix(bots): a failed send must not consume the words, files or draft` (24.1) |
| `9deae05e` | `test(bots): lock the failed-send retention of words, attachments and draft` (24.1, prova vermelha) |

## Iteração 25 — 2026-09-18

Escopo: prioridade (b) — o primeiro P2 da lista do `BotsWindow` (chip provider·model do rail de threads permanentemente velho, o único de dado mentiroso da lista).

### 25.1 O chip do rail pintava o modelo que a thread tinha **antes** do send (`93812bb9`, teste `73be562c`)

`BotsViewModel.deskThreadRailRoutingCache` (`BotsWindow.swift:7314`) é o memo que evita um `get` por linha por render: preenchido por `prefetchDeskThreadRailRouting` com **um** `listChrome` em lote e **só para ids ausentes** (`:7323`). `prepareSupervisedRun` (`:9484`) é o único escritor de provider·model de uma thread viva no VM (drift 1.3: `updated.model = model` + `threadRepo.upsert`, `:9515`) e não tocava o memo; o caminho quente de `reloadStudioSupport` (`:6994`, snapshot em cache) nem chega ao `removeAll` (`:7003`). Trocar o modelo no composer da Desk e enviar deixava o chip pintando o modelo antigo — indefinidamente, até um reload frio (troca de bot com cache frio ou reabertura).

`prepareSupervisedRun` agora republica a linha que acabou de escrever (`:9550`): `deskThreadRailRoutingCache[thread.id] = BotDeskThreadRailRouting(provider: thread.provider, model: thread.model)` — os valores vêm da própria thread pós-upsert, não do `routing`, então o chip nunca diverge do que está no banco.

**Por que aí e não no prefetch:** fazer o prefetch sobrescrever entradas existentes custaria um `listChrome` por republish do composer (todo keystroke da Desk) — exatamente o custo que o memo existe para evitar, travado por `test_deskThreadRailRouting_usesListChromeWithoutDurableGet`.

**Teste novo (vermelho no "antes"):** `BotsWindowTests.test_deskThreadRailRouting_followsTheModelTheSendWroteToTheThread` (`Tests/AppShellTests/BotsWindowTests.swift:1754`) — thread linkada em `opus`, `openDesk` (memo quente), `setDeskModel("sonnet")` e `send()` real com router real (`prepareSupervisedRun` roda no turno síncrono do send). A asserção de fixture exige que o rail **ainda** pinte `opus` antes do send (a escolha pendente do composer não pode repintar uma thread que não rodou nela) — é ela que prova que o memo está quente e que o verde não vem do fallback `deskRouting`. A asserção de WHY exige `sonnet` depois do send.

Falha no "antes": `XCTAssertEqual failed: ("opus") is not equal to ("sonnet") - WHY: the chip must follow the thread row the send just wrote…` (`BotsWindowTests.swift:1786`).

### Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| Filtro `BotsWindowTests/test_deskThreadRail`, antes (`BotsWindow.swift` revertido p/ `93812bb9^`) | 7 | **1** — só o spec novo |
| Filtro, depois (`73be562c`, HEAD) | 7 | **0** |

Specs conferidos por nome nas duas pernas (7/7): `…ResizesLikeAgentApp…`, `…Routing_usesListChromeWithoutDurableGet`, `…Routing_followsTheModelTheSendWroteToTheThread`, `…OrdersWorkingFirst…`, `…TreatsCoordinatorLiveThreadAsRunning`, `…MountsSharedAgentChrome…`, `…VisibilityPersists…`.

### Backlog (repriorizado na iter 25)

1. ~~chip provider·model do rail permanentemente velho~~ **fechado (25.1)**.
2. **BotsWindow P2 restantes (7)** — números de linha da iter 14, reconferir ao pegar cada um: watch de 2 s faz SQLite no main por tick (`:9100-9105`); `refreshActiveBotCount()` no main e 2× por run terminado; até 3 reloads completos por delta de handoff; 2 `stat` de filesystem por avaliação do composer; `searchText` grava UserDefaults por tecla; toda mutação de fila reescreve a tabela inteira com `createdAt: Date()`; deletar bot deixa caches residentes.
3. **AppContext ~6 P2** (inalterados desde a iter 14; lista completa na 15.2).
4. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear` (sessão não persiste, sem superfície de erro), caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
5. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 25)

Nada novo varrido (escopo foi um P2 de `BotsWindow`, já contabilizado em 13.3/14). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `93812bb9` | `fix(bots): the rail chip must follow the model a send writes to the thread` (25.1) |
| `73be562c` | `test(bots): lock the rail chip to the model the send actually wrote` (25.1, prova vermelha) |

## Iteração 26 — 2026-09-18

Escopo: prioridade (b) — o P2 da fila do `BotsWindow`, na metade que era **dado mentiroso** (a outra metade, amplificação de escrita, ficou registrada como custo sem valor compatível com um seam novo).

### 26.1 `persistQueuedFollowUps()` re-datava toda linha que não tinha tocado (`cade617f`, teste `829241a1`)

`BotsViewModel.persistQueuedFollowUps()` (`Sources/AppShell/BotsWindow.swift:7510`) reescrevia a fila de **todos** os bots em memória com `createdAt: Date()`. `created_at` é o momento em que as palavras entraram na fila e é o campo que `bot.queue.list` devolve ao dispositivo pareado (`BotRemoteControlAuthority.queueList` → `store.listQueuedFollowUps` → `encodeQueue`: `"created_at": record.createdAt.timeIntervalSince1970`). Efeitos:

- Remover um follow-up (ou o head ser drenado) re-datava os **sobreviventes** para agora — a hora que o iOS mostrava para as mesmas palavras deixava de ser a hora em que o usuário as digitou, e a linha no banco era sobrescrita (não só a pincelada).
- Uma mutação na fila do Piper re-datava **também** a fila do Quinn: dois bots, uma mutação em um.

`persistQueuedFollowUps()` agora reaproveita o `listAllQueuedFollowUps()` que já fazia (antes só para achar bot com fila órfã) e monta `queuedAtByID`; cada linha reescrita carrega o `created_at` do banco, com `now` de fallback apenas para linha nova (fila recém-enfileirada, ou migração do payload legado em UserDefaults, que nunca teve timestamp). `stored` passou a ser lido uma única vez fora do `if let`.

**Amplificação de escrita (DELETE+N INSERT por bot a cada mutação, mesmo com conteúdo idêntico): registrada, sem mudança.** É custo de transação numa tabela minúscula (`bot_queued_follow_ups`, ~1 linha por follow-up) e provar "não reescreveu" exigiria um contador novo no `BotStore` — claim de perf sem A/B, que não se atribui. A metade de correção (o valor reescrito) está fechada.

**Teste novo (vermelho no "antes", 2 asserções):** `BotsWindowTests.test_queueMutationKeepsTheEnqueueMomentOfEveryRowItDidNotTouch` (`Tests/AppShellTests/BotsWindowTests.swift:12934`) — semeia via store uma linha de 2023-11-14 para o Piper e outra para o Quinn, `reloadQueuedFollowUpsFromStore()` e remove o segundo item do Piper. A **asserção de fixture** exige que as duas linhas do Piper estejam em memória (`vm.queuedFollowUps`), provando que o verde não vem de fila vazia; as asserções de WHY exigem `queuedAt` preservado para o sobrevivente e para a fila do outro bot.

Falha no "antes": `XCTAssertEqual failed: ("Optional(2026-09-18 08:01:05 +0000)") is not equal to ("Optional(2023-11-14 22:13:20 +0000)") - removing one follow-up must not re-date the survivor to now` (`:12972`) e a mesma para `- a queue mutation must not re-date another teammate's queued words` (`:12977`).

### Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| Filtro `BotsWindowTests/test_(queue\|queued\|deletedBotDropsItsQueued\|hidingATeammate)`, antes (`BotsWindow.swift` revertido p/ `73be562c`) | 7 | **2** — só as 2 asserções do spec novo |
| Filtro, depois (`829241a1`, HEAD) | 7 | **0** |

Specs conferidos por nome nas duas pernas (7/7): `test_queueMutationKeepsTheEnqueueMoment…`, `test_queuedFollowUpCanBeRemoved…`, `test_queuedFollowUpSurvivesRelaunch…`, `test_queuedFollowUpStaysOnOwningBot…`, `test_deletedBotDropsItsQueuedFollowUp…`, `test_hidingATeammateKeepsTheQueuedFollowUp…`, `test_hidingATeammateKeepsTheComposerDraft…`. `git status` limpo depois do restore (`git checkout HEAD -- Sources/AppShell/BotsWindow.swift`).

### Backlog (repriorizado na iter 26)

1. ~~toda mutação de fila reescreve a tabela inteira com `createdAt: Date()`~~ **fechado na metade de dado (26.1)**; a metade de amplificação de escrita ficou registrada acima com motivo.
2. **BotsWindow P2 restantes (6)** — números de linha da iter 14, reconferir ao pegar cada um: watch de 2 s faz SQLite no main por tick (`startDeskLiveTurnWatch:9100`, tick chama `streamEventCursor` + `linkedRun`/`latestActive` no main); `refreshActiveBotCount()` 2×/run terminado (`didChangeStatus` terminal + `didFinish`, cada um com `liveWorkingBots()` = 2 queries + lock; o `adoptLinkedRunTerminal` já é dedupe por `settledTerminalRunIDByThread`); até 3 reloads por delta de handoff (`applyAttentionState` → `reloadActiveBotsScreen` por conversa + `reloadFinishedBots`); 2 `stat` por avaliação do composer (`claudeSlashCatalogRevision` roda **antes** do check de TTL em `claudeSlashEntries:7805`); `searchText` grava UserDefaults por tecla (`:3067` → `persistSearchText:7479`); deletar bot deixa caches residentes (`studioSupportByBot`/`revisionByID`/`lastLinkedRunIDByBot`/`attentionStateByBot` não são limpos em `delete(id:)`:5570).
3. **AppContext ~6 P2** (inalterados desde a iter 14; lista completa na 15.2).
4. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear` (sessão não persiste, sem superfície de erro), caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
5. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 26)

Nada novo varrido (escopo foi um P2 de `BotsWindow`, já contabilizado em 13.3/14). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `cade617f` | `fix(bots): a queue mutation must not re-date the rows it did not touch` (26.1) |
| `829241a1` | `test(bots): lock the enqueue moment of every queued row` (26.1, prova vermelha) |

## Iteração 27 — 2026-09-18

Escopo: prioridade (a) — o P2 do catálogo Claude do composer (`2 stat` por avaliação do composer). Fechado com a mudança de menor escopo; a ordenação `fingerprint → TTL` foi **confirmada como intencional** e fica registrada como contrato (ver 27.2).

### 27.1 O composer do Desk statava o catálogo Claude em texto comum (`7e939940`, teste `287cb04f`)

`BotsViewModel.composerSuggestions` (`Sources/AppShell/BotsWindow.swift:7834`) chamava `claudeSlashEntries()` **antes** de `AgentComposerSuggestions.suggestions`, e a barra do composer vive dentro de um `TimelineView` (`BotsWindow.swift:12803`, `BotsComposerTimelineSchedule`) — ou seja, cada repaint e cada tecla com texto comum pagava o fingerprint do catálogo (2 `attributesOfItem` em `~/.claude/skills` + `~/.claude/commands`, `claudeSlashEntries:7814-7818`) para, logo depois, `suggestions` retornar `[]` no guard de trigger (`AgentAppSurface.swift:10529`). Com cache frio, a mesma avaliação de texto comum ainda disparava uma varredura recursiva completa (`ClaudeSlashCommandDiscovery.discover`).

Agora o catálogo em disco só é lido quando o token ativo pode consumi-lo (`/` ou `$`), usando o mesmo `AgentComposerSuggestions.activeToken` que o Agent App já usa:

- `BotsWindow.swift:7837-7846` — gate por `trigger == "/" || trigger == "$"` em `extraSkillNames`.
- `AgentAppSurface.swift:10699` — `activeToken` passa a `nonisolated public static` (era `internal`), exatamente como seu irmão `activeTokenRange`; é o helper que o comentário de `:10697` já declara como compartilhado "so the VM can gate expensive bot/slash catalog loads".

**Paridade:** é a mesma correção F1 que `AgentAppViewModel.composerSuggestions` (`AgentAppSurface.swift:5649-5678`) já tinha; o VM de bots era o único composer que ainda carregava o catálogo incondicionalmente.

**Antes / Depois (contagens determinísticas pelo seam do spec, sem claim de wall-clock):**

| Por avaliação do composer | Antes | Depois |
|---|---|---|
| Texto comum (ex.: `"resuma o inbox do Quinn"`) — leituras do fingerprint | 1 (2 `stat`) | **0** |
| Texto comum — descoberta do catálogo com cache frio | 1 (varredura recursiva) | **0** |
| `/sam` — leituras do fingerprint | 1 | 1 (inalterado: é o que mantém a invalidação mid-TTL) |
| `/sam` — descoberta com fingerprint estável | 0 (cache) | 0 (inalterado) |

Custo de referência medido no mesmo harness (benchmark env-gated, fixture 64 skills + 32 commands): a varredura substituída custa ≈**1,06 ms** por avaliação (medianas `legacy_wall_ns` 1.760.667 − `candidate_wall_ns` 696.417). Não é o ganho desta mudança (o delta inclui o ranking de 96 candidatos) — é o teto do trabalho que texto comum evitava.

**Teste novo (vermelho no "antes", 4 asserções):** `BotsWindowTests.test_deskComposerOrdinaryTypingDoesNotLoadTheClaudeCatalog_becauseEveryRepaintReevaluates` (`Tests/AppShellTests/BotsWindowTests.swift:7761`) — texto comum com seams que contam fingerprint e descoberta; asserção de fixture: a **mesma** VM, com `/sam`, lista a skill (`/sam-work `), provando que os zeros são o gate e não um caminho morto; e `/sam-w` continua lendo o fingerprint (`revisionReads == 2`) com descoberta reaproveitada (`discoveries == 1`).

Falha no "antes": `XCTAssertEqual failed: ("1") is not equal to ("0") - plain text must not fingerprint the Claude catalog` (`:7786`) e `- plain text must not discover the Claude catalog` (`:7787`), com as duas asserções seguintes deslocadas por herança da primeira avaliação (`:7794` 2≠1, `:7801` 3≠2).

### 27.2 Veredito: `fingerprint` antes do check de TTL **não** é defeito

O item do backlog ("o fingerprint roda antes do check de TTL") sugeria inverter a ordem. Não é invertível sem quebrar contrato travado: `test_claudeComposerCachesUntilCatalogChanges_becauseTypingMustStayFastAndFresh` (`BotsWindowTests.swift:7740-7741`) exige que **remover `~/.claude/commands/<name>.md` invalide o cache dentro da janela de TTL** (`cacheTime` parado, `discoveryCount == 4`). O par de `stat` é justamente o preço dessa imediatez — um `stat` é ordens de magnitude mais barato que a varredura recursiva que ele evita. Registrado como contrato: **não reabrir**.

### Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| Filtro dirigido do composer, antes (`BotsWindow.swift` + `AgentAppSurface.swift` revertidos p/ `dc997605`) | 4 | **1** (4 asserções) — só o spec novo |
| Filtro dirigido, depois (`287cb04f`, HEAD) | 4 | **0** |
| Família composer/mention + benchmark, depois (HEAD) | 12 (1 skipped) | **0** |
| `RC2_BOTS_CLAUDE_SLASH_BENCHMARK=1` (benchmark do catálogo, HEAD) | 1 | **0** — ganho do caminho `/` preservado: **60,4%** (medianas 1.760.667 → 696.417 ns) |

Specs conferidos por nome nas duas pernas do A/B (4/4): `test_deskComposerOrdinaryTyping…`, `test_claudeComposerCachesUntilCatalogChanges…`, `test_deskComposerListsProviderSkills…`, `test_deskApplyComposerSuggestionUsesCursorOffset`. Na varredura de família (12, por nome): `test_botMention{ParserResolvesHandle,NeedsAttentionSurvivesReload,ShowsNamedWaitingThenClears}`, `test_deskComposer{OrdinaryTyping,ListsProviderSkills,TimelineSchedule_keepsOneHertzDuringLiveRun,TimelineSchedule_stopsAfterInitialIdleRender}`, `test_claudeComposerCaches…`, `test_deskApplyComposerSuggestionUsesCursorOffset`, `test_deskHeaderFollowsComposerRoute`, `AgentAppBotMentionTests/test_agentAppMentionsAreComposerIdentityOnlyUntilTheAIDelegates`; o `test_benchmarkCachedClaudeSlashDiscovery…` foi o **skipped** (env-gated) e rodou à parte com a env ligada. `git status` limpo depois do restore (`git checkout HEAD -- Sources/AppShell/BotsWindow.swift Sources/Surfaces/AgentAppSurface.swift`).

### Achado novo registrado (não corrigido nesta iter): reloads duplicados do Active Bots

Ao reconferir as linhas do backlog apareceu amplificação de hidratação **da mesma família** do item "até 3 reloads por delta de handoff", com evidência pronta para a próxima iter (não foi pega para manter o escopo em um item):

- `persistWorkingConversation` (`BotsWindow.swift:9469-9476`): `applyAttentionState(...)` já dispara `reloadActiveBotsScreen()` quando `screen == .activeBots` (`:6948-6950`) e a linha seguinte repete `if screen == .activeBots { reloadActiveBotsScreen() }` — **2 hidratações completas no mesmo turno síncrono** (cada uma: `liveWorkingBots()` = 2 queries + lock, `latestConversationUpdatedAt`, `listRecentFinished(limit: 200)` + `conversationsLinked` + `bots(ids:)` em `reloadFinishedBots:3997`).
- Delta de handoff (`:10512-10523`): o loop de até 2 conversas chama `applyAttentionState` por conversa → até 2 hidratações completas para um único delta, sem nenhum turno de runloop entre elas (o observer é `@MainActor` e `publish` chama os observers de forma síncrona, `:2503-2506`).
- Contador já existente para provar: `activeBotsHydrationCountForTesting` (`:3255`, incrementado em `:3926`).

### Backlog (repriorizado na iter 27)

1. ~~2 `stat` de filesystem por avaliação do composer~~ **fechado (27.1)**; a ordem `fingerprint → TTL` fica travada (27.2).
2. **Reloads duplicados do Active Bots** (achado desta iter, acima) — `persistWorkingConversation` (1 linha removível, redundância pura) + coalescing do loop de delta de handoff; contador existente.
3. **BotsWindow P2 restantes (4)** — números de linha da iter 14, reconferir ao pegar cada um: watch de 2 s faz SQLite no main por tick (`startDeskLiveTurnWatch:9110`); `refreshActiveBotCount()` 2×/run terminado (`didChangeStatus` terminal + `didFinish`, cada um com `liveWorkingBots()` = 2 queries + lock; o `adoptLinkedRunTerminal` já é dedupe por `settledTerminalRunIDByThread`); `searchText` grava UserDefaults por tecla (`:3067` → `persistSearchText:7479`); deletar bot deixa caches residentes (`studioSupportByBot`/`revisionByID`/`lastLinkedRunIDByBot`/`attentionStateByBot` não são limpos em `delete(id:)`:5570).
4. **AppContext ~6 P2** (inalterados desde a iter 14; lista completa na 15.2).
5. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear` (sessão não persiste, sem superfície de erro), caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
6. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 27)

Nada novo varrido (escopo foi um P2 de `BotsWindow`, já contabilizado em 13.3/14). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `7e939940` | `fix(bots): ordinary composer text must not stat the Claude catalog` (27.1) |
| `287cb04f` | `test(bots): lock the composer catalog gate to the slash/skill token` (27.1, prova vermelha) |

## Iteração 28 — 2026-09-18

Escopo: prioridade (a) — item 2 do backlog (reloads duplicados do Active Bots), fechado nos **dois** pontos com o contador determinístico que já existia (`activeBotsHydrationCountForTesting`, `BotsWindow.swift:3255` incrementado em `:3926`). Sem claim de wall-clock: a evidência é contagem de hidratações.

### 28.1 Um turno hidrata o Active Bots uma vez, não uma por bot (`9cd0e721`)

`applyAttentionState` (`BotsWindow.swift:6941`) hidrata o roster enquanto `screen == .activeBots`, e os dois chamadores que tocam **vários** bots no mesmo turno síncrono pagavam uma passada por bot:

- **Delta de handoff** (`botPeerHandoffAuthority(_:didApply:)`, loop em `:10529-10547`): um delta carrega `originConversationID` **e** `peerConversationID`; o loop chamava `applyAttentionState` por conversa → **2 hidratações completas** para um único `publish` (os observers são chamados de forma síncrona, `:2502-2506`, sem turno de runloop entre elas).
- **`persistWorkingConversation`** (`:9482`): `applyAttentionState(...)` já hidratava (`:6956`) e a linha seguinte repetia `if screen == .activeBots { reloadActiveBotsScreen() }` — **condição e chamada idênticas**, hidratação dupla por linha persistida (alcançável quando o usuário abre o Active Bots com um send em voo).

Cada hidratação = `liveWorkingBots()` (2 queries + lock) + `latestConversationUpdatedAt` + `listRecentFinished(limit: 200)` + `conversationsLinked` + `bots(ids:)` (`reloadActiveBotsScreen:3924`), tudo no main actor.

**Correção:** `applyAttentionState` ganha `reload: Bool = true`; o observer settle dos dois estados primeiro e hidrata **uma vez** no fim, só quando ao menos um estado foi aplicado (`appliedStates`) — o guard de destino continua dentro de `reloadActiveBotsScreen`. A linha redundante do persist foi removida.

**Antes / Depois (contador determinístico, mesmo spec e mesmo sandbox):**

| Fluxo no mesmo turno síncrono | Antes | Depois |
|---|---|---|
| Delta de handoff com origin + peer | **2** hidratações | **1** |
| Desk send com o Active Bots aberto | **3** (broadcast `.running` + 2 do persist) | **2** (broadcast + 1 do persist) |

**Prova vermelha do A/B** (`git checkout ede0799d -- Sources/AppShell/BotsWindow.swift`, specs novos inalterados):

```
BotsWindowTests.swift:3726: XCTAssertEqual failed: ("3") is not equal to ("2") -
  one handoff delta must hydrate Active Bots once, not once per conversation
BotsWindowTests.swift:3779: XCTAssertEqual failed: ("4") is not equal to ("3") -
  a desk send into Active Bots must hydrate the roster once per turn, not twice for the persist
Executed 2 tests, with 2 failures
```

`git status` limpo depois do restore (`git checkout HEAD -- Sources/AppShell/BotsWindow.swift`).

**Asserções de fixture** (para o vermelho/verde não vir de caminho morto): o spec do delta exige snapshot com `originConversationID` **e** `peerConversationID` e as duas conversas no `botStore` (senão o loop daria `continue` e a contagem do delta seria 0); o spec do send exige `lastSendStartedProviderRun` (o envio chegou ao provider) antes de medir.

Specs novos: `test_handoffDeltaHydratesActiveBotsOnce_becauseOneDeltaIsOneTurn` (`BotsWindowTests.swift:3684`) e `test_deskSendIntoActiveBotsHydratesOncePerTurn_becauseThePersistAlreadyReloaded` (`:3740`).

Nota de execução: a primeira rodada do spec do delta ficou **travada** (o spec lia `peerRunner.requests` antes de o run peer existir e nunca fechava o milestone → `await milestone.value` eterno). Rodada morta, spec corrigido com `waitUntil { !peerRunner.requests.isEmpty }` antes do `finish`; as rodadas registadas acima são todas pós-correção.

### 28.2 Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| Filtro dirigido (2 specs novos), antes (`ede0799d`) | 2 | **2** (as provas vermelhas acima) |
| Filtro dirigido, depois (`9cd0e721`) | 2 | **0** |
| Família dirigida (Active Bots + atenção + handoff), depois | 20 | **0** |

Specs conferidos por nome na família (20/20): `test_activeBots_batchColdStartedAt_withoutChangingLatestConversationTimestamp`, `test_activeBots_batchOnlyActiveHandoffOrigins_withoutScanningHistoricalRows`, `test_activeBotsSearchFiltersLiveRoster`, `test_botMentionNeedsAttentionSurvivesReload`, `test_botMentionParserResolvesHandle_excludingOpenTeammate`, `test_botMentionShowsNamedWaitingThenClearsWhenReplyArrives`, `test_BotsWindowAttention_userStopWritesNoItemAndProviderCancelledStaysActionable`, `test_clearAllDeskThreadsRetiresOnlyVictimActiveHandoffWithoutResurrectionOrV1Rewrite`, `test_deferredActiveBotsAppearanceAndTabCoalesce_onNextMainTurn`, `test_deskSendIntoActiveBotsHydratesOncePerTurn_becauseThePersistAlreadyReloaded`, `test_didChangeStatusSkipsConversationLinkedWhenThreadHasNoBot`, `test_handoffDeltaHydratesActiveBotsOnce_becauseOneDeltaIsOneTurn`, `test_openActiveBotsOpensActiveBotsScreen`, `test_openAttentionDestsBeforeAcknowledge_becauseAttentionRowMustNotWaitOnStore`, `test_peerFailureAndCancellationSettleOnlyTheirExactOwningHandoffs`, `test_petProjectsDestAttention_andHidesDisabledBots`, `test_reloadActiveBotsScreenNoopsWhenScreenIsDesk`, `test_setPhasePersistentConflictPublishesCanonicalSnapshotAndSaveAlert`, `test_setPhaseRetriesOneTransientConflictFromCanonicalStateWithoutAlert`, `test_waitingHandoffProjectsBothBotsActiveDespiteUnrelatedOriginAttention`.

Production: `git merge origin/production` → **Already up to date** (`81842144` já é ancestral do HEAD; 102 commits à frente, 0 atrás). Sem rebase/reset.

### Backlog (repriorizado na iter 28)

1. ~~2 `stat` de filesystem por avaliação do composer~~ **fechado (27.1)**; a ordem `fingerprint → TTL` fica travada (27.2).
2. ~~Reloads duplicados do Active Bots (`persistWorkingConversation` + loop de delta de handoff)~~ **fechado (28.1, `9cd0e721`)**.
3. **BotsWindow P2 restantes (4)** — números de linha da iter 14, reconferir ao pegar cada um: watch de 2 s faz SQLite no main por tick (`startDeskLiveTurnWatch:9110`); `refreshActiveBotCount()` 2×/run terminado (`didChangeStatus` terminal + `didFinish`); `searchText` grava UserDefaults por tecla (`:3067` → `persistSearchText:7479`); deletar bot deixa caches residentes (`studioSupportByBot`/`revisionByID`/`lastLinkedRunIDByBot`/`attentionStateByBot` não são limpos em `delete(id:)`:5570). A amplificação de escrita da fila continua só com A/B (contador no `BotStore`).
4. **AppContext ~6 P2** (inalterados desde a iter 14; lista completa na 15.2).
5. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear` (sessão não persiste, sem superfície de erro), caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
6. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 28)

Nada novo varrido (escopo foi um P2 de `BotsWindow`, já contabilizado em 13.3/14). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `9cd0e721` | `fix(bots): one turn hydrates Active Bots once, not once per teammate` (28.1, fix + 2 specs) |

## Iteração 29 — 2026-09-18

Escopo: prioridade (a) — item 3 do backlog, 2º dos 4 P2 restantes do `BotsWindow` (refresh duplicado do Active Bots por run terminado). Sem claim de wall-clock: a evidência é o contador determinístico `liveWorkingBotsCountForTesting` (já existente, `BotsWindow.swift:3251`, incrementado em `liveWorkingBots():3954`), que mede exatamente o custo removido (`liveWorkingBots()` = 2 queries SQLite + lock do coordinator no main, perf BT-01).

### 29.1 Um terminal duplicado atualiza o count uma vez, não duas (`f1785851`)

Confirmado no fonte: `didChangeStatus(terminal)` e `didFinish` entregam o **mesmo** terminal e ambos chamavam `refreshActiveBotCount()` sem nenhum guard (`runCoordinator(_:didChangeStatus:)` ramo terminal e `runCoordinator(_:didFinish:)`). O settle já era dedupado pelo BT-24 (`settledTerminalRunIDByThread`), mas o refresh que vinha **depois** re-rodava `liveWorkingBots()` no callback duplicado.

**Correção:** `adoptLinkedRunTerminal` passa a devolver `Bool` — `false` só no hit do guard de dedupe, `true` na primeira entrega (inclusive nos ramos de early-return, que fazem o primeiro passe: restore/`reloadActiveBotsScreen`). O refresh passa a montar nesse `true` nos dois call sites (`if self.adoptLinkedRunTerminal(...) { self.refreshActiveBotCount() }`). O wrapper `adoptLinkedRunTerminalForTests` continua igual (`@discardableResult` descarta o Bool). O ramo não-terminal de `didChangeStatus` fica intocado.

**Antes / Depois (contador determinístico, mesmo spec e mesmo sandbox):**

| Fluxo (mesmo run, mesmo turno) | Antes | Depois |
|---|---|---|
| `didChangeStatus(.completed)` + `didFinish` para o mesmo `(thread, run)` | **2** passadas de `liveWorkingBots()` | **1** |

**Prova vermelha do A/B** (`git checkout 106351d5 -- Sources/AppShell/BotsWindow.swift`, spec novo inalterado):

```
BotsWindowTests.swift:4403: XCTAssertEqual failed: ("10") is not equal to ("9") -
  the duplicate terminal callback must not re-run the Active Bots roster queries
Executed 1 test, with 1 failure
```

Só a asserção pretendida ficou vermelha (as asserções de fixture passaram nas duas pernas). `git status` limpo depois do restore (`git checkout HEAD -- Sources/AppShell/BotsWindow.swift`).

**Asserções de fixture** (para o vermelho/verde não vir de caminho morto): o spec exige run `.running` + conversa `.working` hidratada por `openDesk` (prova que a VM enxerga Working) e `followThroughApplyCountForTesting == 0` antes dos callbacks; depois persiste a linha terminal no `runRepo` (como o coordinator faz antes de emitir) e só então emite os dois callbacks. Depois do 1º callback exige `attentionState != .working` (o settle aconteceu, não foi o guard) e, no fim, `followThroughApplyCountForTesting == 1` (o 2º callback é o mesmo terminal) — senão o `liveWorkingBots()` medido poderia estar num path morto.

Spec novo: `test_terminalDeliveredTwiceRefreshesActiveBotCountOnce_becauseTheSecondCallbackIsADuplicate` (`BotsWindowTests.swift:4329`). Complementa o pin existente do BT-24 (`PerfMainThreadHogsTests.test_duplicateTerminalNotificationsApplyFollowThroughOnce`), que já provava o settle 1× mas não o refresh.

Nota de execução: a 1ª versão do fixture criava a conversa `.working` com o run já `.completed`; o `openDesk` **cura** esse estado na hidratação (`settleTerminalWorkingConversations`), então o assert de Working dava `.none` e o `followThroughApplyCountForTesting` já vinha 1. Fixture corrigido para persistir o terminal **depois** da hidratação — o que também espelha a ordem real (linha terminal gravada antes do broadcast).

### 29.2 Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| Filtro dirigido (spec novo), antes (`106351d5`) | 1 | **1** (a prova vermelha acima) |
| Filtro dirigido, depois (`f1785851`) | 1 | **0** |
| Família dirigida (terminal/settle/follow-through/handoff/attention/Active Bots), depois | 35 | **0** |

Specs conferidos por nome na família (34/34 nomes; 35 execuções somando a suíte): `test_BotsWindowAttention_userStopWritesNoItemAndProviderCancelledStaysActionable`, `test_activeBotCountSurvivesPublishesWithoutRosterQueries_andTracksRunTransitions`, `test_clearAllDeskThreadsDeletesOnlyThatBot_becauseClearAllMustNotWipeTheFleet`, `test_clearAllDeskThreadsHidesTokenSaverFooter`, `test_clearAllDeskThreadsLeavesEmptyRail_becausePlusStartsTheNextConversation`, `test_deferredActiveBotsAppearanceAndTabCoalesce_onNextMainTurn`, `test_deskLiveObserverWatermarkBoundsObservedBytesAndFallsBackAfterSwitch`, `test_deskLiveObserverWatermarkDetectsHistoricalRunMutationAtStableCount`, `test_deskLiveObserverWatermarkDoesNotMaskHistoricalMutationBehindObservedNewestAdvance`, `test_deskLiveObserverWatermarkDoesNotReplayTheDurableCopy_becauseTheEventAlreadyPainted`, `test_deskLiveObserverWatermarkFallsBackWhenExternalAppendKeepsRetainedCountStable`, `test_deskLiveObserverWatermarkFallsBackWhenTheObserverMissedAnExternalEvent`, `test_deskLiveObserverWatermarkPreservesOrderedTerminalTailWithoutReplay`, `test_deskLiveObserverWatermarkReconcilesObserverArrivingAfterTerminal`, `test_deskLiveObserverWatermarkReconcilesPersistPollObserverRaceAtTerminal`, `test_deskLiveTurnWatchDoesNotPollOnQuarterSecondCadenceWhilePushIsFlowing`, `test_deskStreamObserverDropsUnmatchedThreadBeforeMainHop`, `test_didChangeStatusSkipsConversationLinkedWhenThreadHasNoBot`, `test_didFinishAppliesFollowThrough_soActiveChipDrops`, `test_followThroughDoesNotListConversations_becauseSettleDestMustNotRereadThreads`, `test_followThroughDoesNotReloadFleet_becauseSettleDestMustNotScanEveryTeammate`, `test_followThroughKeepsDestConversation_becauseStaleEmptyMustNotLookCurrent`, `test_followThroughLeavesWorkingWhenRunCompletes_becauseTheDeskMustShowAResult`, `test_followThroughOnBackgroundBotDoesNotOverwriteOpenDesk`, `test_followThroughWorkLogStaysOnOwningConversation`, `test_handoffDeltaHydratesActiveBotsOnce_becauseOneDeltaIsOneTurn`, `test_openActiveBotsOpensActiveBotsScreen`, `test_peerFailureAndCancellationSettleOnlyTheirExactOwningHandoffs`, `test_reloadActiveBotsScreenNoopsWhenScreenIsDesk`, `test_staleWorkingConversationSettlesWhenLinkedRunIsTerminal`, `test_terminalDeliveredTwiceRefreshesActiveBotCountOnce_becauseTheSecondCallbackIsADuplicate`, `test_waitingHandoffProjectsBothBotsActiveDespiteUnrelatedOriginAttention`, `test_workingConversationStaysLiveWhenLinkedRunIsRunning`, `test_duplicateTerminalNotificationsApplyFollowThroughOnce` (PerfMainThreadHogsTests).

Production: `git merge origin/production` → **Already up to date** (`81842144` já é ancestral do HEAD; 105 commits à frente, 0 atrás). Sem rebase/reset.

### Backlog (repriorizado na iter 29)

1. ~~2 `stat` de filesystem por avaliação do composer~~ **fechado (27.1)**; a ordem `fingerprint → TTL` fica travada (27.2).
2. ~~Reloads duplicados do Active Bots (persist + delta de handoff)~~ **fechado (28.1)**; ~~refresh duplicado no terminal duplicado~~ **fechado (29.1)**.
3. **BotsWindow P2 restantes (3)** — reconferidos no fonte nesta iter: watch de 2 s faz SQLite no main por tick (`startDeskLiveTurnWatch:9129`); `searchText` grava UserDefaults por tecla (didSet em `:3068` → `persistSearchText():7487`); deletar bot deixa caches residentes (`studioSupportByBot`/`revisionByID`/`lastLinkedRunIDByBot`/`attentionStateByBot` não são limpos em `delete(id:)`:5570). A amplificação de escrita da fila segue só com A/B, contador no `BotStore`.
4. **AppContext ~6 P2** (inalterados desde a iter 14; lista completa na 15.2).
5. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear` (sessão não persiste, sem superfície de erro), caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
6. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 29)

Nada novo varrido (escopo foi um P2 de `BotsWindow`, já contabilizado em 13.3/14). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `f1785851` | `fix(bots): a duplicate terminal refreshes the Active Bots count once, not twice` (29.1, fix + 1 spec) |

## Iteração 30 — 2026-09-18

Escopo: prioridade (a) — 1º dos 3 P2 restantes do `BotsWindow` (watch de 2 s com SQLite no main por tick). Sem claim de wall-clock: a evidência é um contador determinístico por thread no repositório, que mede exatamente o acesso removido.

### 30.1 O watch de 2 s não lê SQLite no MainActor (`239ae5a0`)

Confirmado no fonte (pré-fix, `startDeskLiveTurnWatch`): cada tick de 2 s, no MainActor, fazia

1. `applyDeskLiveReplay(..., fetchOffMain: true)` → `context.coordinator.streamEventCursor(threadId:)` → `runRepo.streamEventCursor` (**SQLite**), mesmo no caso ocioso em que o cursor não mudou (early-return);
2. `linkedRun(for:botID:)` → `runRepo.latestActive` (**SQLite**, 10 colunas + decode) e, quando não há run ativo, `runRepo.get(id:)` ou `listRecentFinished(limit: 80)` (**SQLite**).

O risco não é throughput: `SQLite.swift` re-tenta lock transitório com teto de **8 tentativas / 2 s**, então uma escrita concorrente (turno do provider, LaunchAgent de run Path B, Insomnia) pode prender o main thread por segundos — a mesma classe que motivou BT-01/BT-23. O gate de push-quiet já existente (`lastDeskStreamPushAt < 1 s`) não cobre turnos longos e silenciosos, que é justamente quando o watch mais roda.

**Correção (menor escopo que remove a classe):** `deskLiveTurnWatchTick` resolve os dois fatos num único `Task.detached(priority: .userInitiated)` — `cursor` do coordinator + linked run — e no main só aplica o resultado. `applyDeskLiveReplay` ganha `prefetchedCursor: StreamEventCursor? = nil` (nenhum outro call site muda; o cursor pré-lido é o mesmo que a função leria no mesmo tick). `linkedRun` foi dividido em `resolveLinkedRun` (puro, sem estado de main actor, com o `knownRunID` memoizado passado por parâmetro) + `adoptLinkedRunProbe` (main: memo `lastLinkedRunIDByBot` e `deskFinishedRunScanCountForTesting`), preservando o comportamento dos 2 call sites síncronos (`restoreDeskWorkLog`, chip do rail). O `deskLiveTurnWatchApplyCountForTesting` continua 1 por tick e os pins BT-23 (fetch off-main do replay) e BT-24 (terminal duplicado) seguem intactos. Reordenação declarada: o linked run passou a ser lido **no mesmo batch** que o cursor (antes, depois do replay); as duas leituras são read-only e nada escreve `agent_runs` entre elas, então o valor observado é o mesmo.

**Instrumento novo (par):** `AgentRunRepository.latestActiveProbeCountForTesting` (total) e `latestActiveMainThreadProbeCountForTesting` (subconjunto em `Thread.isMainThread`). O A/B mede o que saiu do main; o total existe para o "0 no main" não ser vácuo.

**Antes / Depois (contador determinístico, mesmo spec e mesmo sandbox):**

| Fluxo (mesmo tick, mesmo estado) | Antes | Depois |
|---|---|---|
| Tick com run ativo (memo quente) | `latestActive` **1× no main** | `latestActive` 1× total, **0 no main** |
| Tick terminal (`stampTerminal(.completed)`) | `latestActive` **1× no main** | `latestActive` 1× total, **0 no main** |

**Prova vermelha do A/B** (corpo antigo do tick no lugar do probe, assinatura/instrumento novos mantidos):

```
PerfMainThreadHogsTests.swift:265: XCTAssertEqual failed: ("3") is not equal to ("2") -
  the watch tick must not read agent_runs on the main thread
PerfMainThreadHogsTests.swift:289: XCTAssertEqual failed: ("4") is not equal to ("3") -
  the terminal tick must not read agent_runs on the main thread either
```

Só as duas asserções pretendidas ficaram vermelhas: as de **comportamento** (`XCTAssertFalse` no tick com run vivo, `XCTAssertTrue` no tick terminal) e a de fixture (`latestActiveProbeCountForTesting == antes + 1`) passaram nas duas pernas — ou seja, o tick antigo também detectava o terminal, e o que a correção muda é só a thread da leitura. `git status` limpo depois do restore (`git checkout HEAD -- Sources/AppShell/BotsWindow.swift`).

Spec novo: `test_deskLiveTurnWatchTickResolvesAgentRunsOffTheMainThread` (`PerfMainThreadHogsTests.swift`). Fixture: run `.running` + conversa com `linkedAgentThreadID` + `openDesk`/`selectDeskThread`, com `XCTAssertTrue(vm.deskRunIsLive)` antes das medições; a segunda metade grava `stampTerminal(.completed)` e exige que o tick **pare o watch** (o seam `deskLiveTurnWatchTickForTesting()` passou a devolver o Bool do tick, `@discardableResult`), provando que o probe off-main ainda enxerga o terminal que o app não recebeu por callback. Nota de sintaxe: `await` dentro de `XCTAssert*` não compila (`async call in an autoclosure`) — a chamada é içada para uma `let` antes da asserção.

### 30.2 Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| Filtro dirigido (`deskLiveTurnWatch`), antes (corpo antigo do tick) | 3 | **2** (as duas provas vermelhas acima; BT-23 e o pin de cadência de 400 ms verdes) |
| Filtro dirigido, depois | 3 | 0 |
| Família dirigida (watch/desk live/follow-through/settle/handoff/Active Bots/attention), antes | 41 | **2** (só o spec novo) |
| Família dirigida, depois | 41 | 0 |
| Família `WorkLog` (13 specs, consumidores do `linkedRun`), baseline HEAD~1 (produto **e** specs revertidos) | 13 | 0 |
| Família `WorkLog`, depois | 13 | 0 |

Filtro da família: `--filter "(deskLive|deskWorkLog|FinishedRuns|followThrough|FollowThrough|staleWorking|WorkingConversation|waitingHandoff|peerFailure|activeBotCount|clearAllDeskThreads|handoffDelta|didFinish|didChangeStatus|BotsWindowAttention|deferredActiveBots|terminalDelivered|duplicateTerminalNotifications)"`. Os **41 nomes** foram conferidos um a um e o conjunto é **idêntico** nas duas pernas (`diff` vazio); inclui o pin do memo de `linkedRun` (`test_reopeningDeskDoesNotRescanFinishedRuns_becauseRosterSwitchMustNotListEveryRun`) e os pins de BT-23/BT-24. Sem falha pré-existente nesta família (0 vermelhos na perna "depois"). A 2ª rodada (`--filter "WorkLog"`) cobre `restoreDeskWorkLog`, que é o outro consumidor do `linkedRun` — 13 nomes idênticos nas duas pernas.

Armadilha de método desta iteração: reverter o **arquivo inteiro** (`git checkout HEAD~1 -- Sources/AppShell/BotsWindow.swift`) quebra a compilação do alvo de testes, porque o spec novo chama o seam com `await`/`Bool` e o arquivo antigo tem o seam síncrono/Void; a perna "antes" do filtro dirigido foi feita com **assinatura nova + corpo antigo**, como manda a regra. Para as famílias que não usam o seam, a perna "antes" pode reverter produto **e** specs juntos (baseline limpo).

Housekeeping antes de medir: `pgrep -fl "xctest|swift-test"` mostrou 2 restos de PPID 1, mas com cwd em **outros** worktrees (`agent-app-memperf-…`, `claude-provider-bugs-nocopy-…`) → não mortos, conforme a regra (só o cwd deste worktree). A medição desta iter é contador determinístico, não tempo, então a carga extra não afeta o resultado.

### Backlog (repriorizado na iter 30)

1. ~~watch de 2 s faz SQLite no main por tick~~ **fechado (30.1, `239ae5a0`)**.
2. **BotsWindow P2 restantes (2)** — reconferidos no fonte nesta iter: `searchText` grava UserDefaults por tecla (didSet em `:3068` → `persistSearchText():7487`; `publishRosterIfNeeded` já é guardado, o custo é só a escrita); deletar bot deixa caches residentes (`studioSupportByBot`/`revisionByID`/`lastLinkedRunIDByBot`/`attentionStateByBot` não são limpos em `delete(id:)`:5570). A amplificação de escrita da fila segue só com A/B, contador no `BotStore`.
3. **AppContext ~6 P2** (inalterados desde a iter 14; lista completa na 15.2).
4. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear` (sessão não persiste, sem superfície de erro), caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
5. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 30)

Nada novo varrido (escopo foi um P2 de `BotsWindow`, já contabilizado em 13.3/14). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `239ae5a0` | `fix(bots): the 2 s desk watch ticks without SQLite reads on the main thread` (30.1, fix + 1 spec + instrumento no repositório) |

## Iteração 31 — 2026-09-18

Escopo: prioridade (a) — 2º dos P2 restantes do `BotsWindow`: caches residentes que sobreviviam ao `delete(id:)`. Sem claim de wall-clock: a evidência é contagem determinística de entradas de dicionário.

### 31.1 Deletar um teammate descarta os caches residentes dele (`a9b28fbb`)

Confirmado no fonte (pré-fix, `delete(id:)`): o corpo limpava `bots`, `attentionItems`, `queuedFollowUpsByBot`, `composerDraftsByBot`, `inspectorDraftsByBot`, `studioDraftsByBot` e `studioFilesLocationsByBot`, mas deixava residentes pelo resto da vida da janela:

| Cache | Conteúdo retido por teammate apagado |
|---|---|
| `studioSupportByBot[id]` | snapshot do studio: conversas, itens de memória, rotinas, skill bindings, revisão selecionada |
| `revisionByID` (chave `BotRevisionID`) | toda revisão publicada, incluindo o `soul` |
| `messagesByConversation[conv]` | transcrição completa de cada conversa |
| `lastPreviewByBot`, `lastUpdatedByBot`, `lastLinkedRunIDByBot`, `lastStartedConversationByBot`, `selectedConversationByBot`, `messagesByBot`, `messagesConversationIDByBot`, `attentionStateByBot` | estado derivado por teammate |
| `liveObservedEventsByThread`, `settledTerminalRunIDByThread` | probes por thread ligada |

O `studioSupportByBot` é o pesado (`BotMemoryItem` + `BotRoutine` + `BotSkillBinding` + revisão). Uma sessão que cria e apaga teammates pagava para sempre por linhas que não existem mais.

Nota de leitura: o P2 registrado na iter 30 nomeava 4 caches (`studioSupportByBot`, `revisionByID`, `lastLinkedRunIDByBot`, `attentionStateByBot`); a varredura dos `ByBot`/`ByConversation`/`ByThread` mostrou que a classe tem 11 dicionários + 2 mapas por thread. A correção fecha a classe em vez de só os 4 citados.

**Correção (menor escopo que fecha a classe):** `forgetResidentCaches(for:leaving:)`, chamado de dentro do bloco de limpeza que `delete(id:)` já tinha (antes do `bots.removeAll`, para que `conversations` ainda exista quando o apagado é o desk aberto). Coleta as conversas do teammate dos dois únicos lugares que ainda as têm em cache — `studioSupportByBot[id]` e `conversations` quando `leaving` — mais os dois ids avulsos (`selectedConversationByBot[id]`, `messagesConversationIDByBot[id]`), e então derruba: os 9 dicionários por bot, `revisionByID` filtrado por `botID`, e por conversa/thread `messagesByConversation`, `clearDeskObservedEvents` e `settledTerminalRunIDByThread` (o mesmo idioma que `clearAllDeskThreads` já usa). Nenhum call site fora de `delete(id:)` mudou.

`deskRoutingByConversation` **não** é podado de propósito: é estado **persistido**, não cache residente. Derrubá-lo sem escrever só ressuscitaria as mesmas chaves no próximo `restoreDeskRoutingIfNeeded`, e escrever ali adicionaria um encode síncrono a um caminho com contrato dest-first (`test_deleteRunsDockerTeardownOffMain_becauseAStuckDaemonMustNotFreezeTheRoster`, teto de 0,1 s). Registrado como item separado no backlog.

**Instrumento novo:** 5 seams `…CacheCountForTesting` (studioSupport, revision, attentionState, lastPreview, transcript), cada um 1:1 com um dicionário — um somatório deixaria um cache cobrir pelo outro. Ressalva declarada: `lastLinkedRunIDByBot` **também é limpo** pelo fix, mas **não** ganhou asserção, porque sua única escrita no fixture (`lastLinkedRunIDByBot[bot.id] = started.runID`) vive dentro da task assíncrona do send; o fixture não o popula de forma determinística e a asserção seria vácuo. Não reivindicado.

**Antes / Depois (contador determinístico, mesmo spec e mesmo sandbox):**

| Fluxo (2 teammates; apaga o 2º) | Antes | Depois |
|---|---|---|
| snapshot do studio | **2** entradas (a do apagado fica) | **1** (== floor do sobrevivente) |
| revisões publicadas | **2** | **1** |
| transcrições | **2** | **1** |
| preview do desk | **2** | **1** |
| projeção de atenção | **2** | **1** |

**Prova vermelha do A/B** (perna "antes" com assinatura/instrumento novos e corpo antigo do `delete`, removida só a chamada `forgetResidentCaches`):

```
BotsWindowTests.swift:3306: XCTAssertEqual failed: ("2") is not equal to ("1") - delete must drop the deleted teammate's studio snapshot
BotsWindowTests.swift:3311: XCTAssertEqual failed: ("2") is not equal to ("1") - delete must drop the deleted teammate's published revisions
BotsWindowTests.swift:3316: XCTAssertEqual failed: ("2") is not equal to ("1") - delete must drop the deleted teammate's transcripts
BotsWindowTests.swift:3321: XCTAssertEqual failed: ("2") is not equal to ("1") - delete must drop the deleted teammate's desk preview
BotsWindowTests.swift:3326: XCTAssertEqual failed: ("2") is not equal to ("1") - delete must drop the deleted teammate's attention state
```

Só as 5 asserções pretendidas ficaram vermelhas. As 4 provas de fixture (`XCTAssertGreaterThan` depois de aquecer o Quinn) e o invariante de fixture (`attentionState == fleet.count == 2`) passaram nas **duas** pernas — o fixture realmente populava os caches do Quinn e o que a correção muda é só a limpeza no delete. `git status` limpo depois do restore (`git checkout HEAD -- Sources/AppShell/BotsWindow.swift`).

**Armadilha de leitura corrigida no caminho:** a 1ª versão do spec mediu a atenção contra o "floor" do Piper sozinho e ficou vermelha nas duas pontas (fixture `2 !> 2`; depois `1 != 2`). Causa confirmada no fonte: `attentionStateByBot` **não** é cache por bot sob demanda — o recompute de roster escreve uma chave para **cada** bot do roster (`attentionStateByBot = states` em `:7004`; a variante por bot é o `:7025`), então o id do Quinn já estava lá antes de aquecer o desk dele. A asserção virou invariante de roster (`== vm.fleet.count`, medida antes e depois), que é o contrato real: uma chave por teammate vivo.

Spec novo: `test_deleteDropsTheDeletedTeammatesResidentCaches_becauseTheWindowMustNotOutgrowTheRoster` (`BotsWindowTests.swift`). Fixture: 2 teammates, aquece só o Piper (floor), aquece o Quinn (prova de fixture), devolve o desk ao Piper para o delete **não** navegar e o spec medir os caches em vez do caminho de `adoptRemainingTeammate`.

### 31.2 Regressão / baseline da iteração

Filtro da família: `--filter "BotsWindowTests"` (a classe inteira — é a família que toca esses caches).

| Rodada (mesmo sandbox, mesmo filtro) | Executados | Falhas |
|---|---|---|
| Baseline (produto **e** specs revertidos juntos para `HEAD~1`, árvore limpa) | 429 | **1** — `test_peerHandoffMutationWithOneThousandRowsRetainsNineHundredNinetyNineUnderFiftyMillisecondP95` (p95 70,69 ms) |
| Depois (fix + spec novos) | 430 | **2** — o mesmo `peerHandoff` (p95 101,71 ms) + `test_saveStudioStartsFirstDockerProvisionOffMainAndMainActorKeepsTicking` (0,1317 s > 0,1 s) |
| Isolada (`--filter "test_peerHandoffMutationWithOneThousandRows\|test_saveStudioStartsFirstDockerProvisionOffMain"`) | 2 | **1** — o mesmo `peerHandoff` (p95 51,27 ms); o `saveStudio` **passou** (0,346 s) |

Atribuição das 2 vermelhas da perna "depois" (nenhuma é atribuível à mudança):

- `peerHandoff…P95` — **pré-existente**. Vermelho nas **três** pernas (baseline 70,69 ms; família depois 101,71 ms; isolada 51,27 ms, com `samples_ms` no log). O piso desta máquina para a mutação de 1000 linhas fica em ~50 ms, ou seja, no limite do teto. Confirmado no fonte que o spec **não** chama `delete(`, então a mudança não o alcança.
- `test_saveStudioStartsFirstDockerProvisionOffMainAndMainActorKeepsTicking` — **flaky sob carga**. Falhou só na rodada de família (430 specs, com 4 processos `xctest`/`swift-test` residentes de **outros** worktrees) e **passou isolada** (0,346 s). Também não chama `delete(`. Uma tentativa curta, como manda a regra.

Ambas ficam registradas como baseline do filtro `BotsWindowTests` para as próximas iterações: qualquer rodada futura desse filtro deve esperar essas 2 (e o `saveStudio` só aparece com a máquina carregada).

Housekeeping antes de medir: `pgrep -fl "xctest|swift-test"` mostrou 3 restos de PPID 1, **todos** com cwd em outros worktrees (`agent-app-memperf-20260911T151128Z`, `claude-provider-bugs-nocopy-…`) e 1 `xcodebuild` de iOS em `/Users/samuelfajreldines/dev/lacco` → **nenhum morto**, conforme a regra (só o cwd deste worktree). A medição do item é contador determinístico, não tempo, então a carga não afeta o A/B; ela afeta justamente os 2 specs de wall-clock acima, que é como foram classificados.

LFS: `Vendor/TailcatBridge/Artifacts/RCTailcat.xcframework/ios-arm64-simulator/libRCTailcat.a` já estava materializado (47 MB, magic `!<arch>`, não o pointer de 133 B) → nada a fazer nesta iter.

### Backlog (repriorizado na iter 31)

1. **BotsWindow — último P2:** `searchText` grava UserDefaults por tecla (didSet em `:3084` → `persistSearchText():7557`; `publishRosterIfNeeded` já é guardado, o custo é só a escrita). Reconferido no fonte nesta iter.
2. **BotsWindow — amplificação de escrita da fila** (só com A/B, contador no `BotStore`).
3. **Novo (desta iter):** `deskRoutingByConversation` nunca é podado no delete — estado persistido, cresce com toda conversa que já teve routing e é re-encodado inteiro por `persistDeskRouting()`. Podar exige decidir se o delete pode pagar a escrita síncrona (decisão de contrato do dono, junto da regra dest-first).
4. **AppContext ~6 P2** (inalterados desde a iter 14; lista completa na 15.2).
5. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear` (sessão não persiste, sem superfície de erro), caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
6. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 31)

Nada novo varrido (escopo foi um P2 de `BotsWindow`, já contabilizado em 13.3/14). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `a9b28fbb` | `fix(bots): deleting a teammate drops its resident caches` (31.1, fix + 1 spec + 5 seams de contagem) |

## Iteração 32 — 2026-09-18

Escopo: prioridade (a) — o **último** P2 do `BotsWindow`: `searchText` gravando UserDefaults a cada tecla. Sem claim de wall-clock: a evidência é contador determinístico de escritas (`searchTextWrites`).

### 32.1 A busca do roster escreve uma vez por rajada de digitação (`86770afa`)

Pré-fix (`:3084` → `persistSearchText`): `searchText.didSet` chamava `UserDefaults.standard.set/removeObject` a cada tecla. Reconferido no fonte que a escrita era o **único** custo por tecla — `publishRosterIfNeeded()` (`:3693`) já tem guarda (`next != publishedRoster`) — e que o filtro continua imediato, por isso a UI não muda com a correção.

**Correção (menor escopo, reusa o dono que já existe):** a escrita passa a ser do `BotDraftPersistenceAuthority` — o mesmo coalescing de 250 ms dos drafts, com flush em `willHide`/`willClose`/`willTerminate` — via `updateSearchText(_:)` + `searchDirty` + `persistSearchText()` dentro do `flushPending()` que já existia. **Nenhum** timer novo, nenhum observer novo, nenhuma chave nova: o texto de busca passa a ser do mesmo dono por AppContext que já ordena os rascunhos. `flushDraftPersistenceForTesting()` (que já existia) passou a cobrir a busca de graça.

**Segundo efeito, obrigatório para não trocar um P2 por staleness:** com a escrita adiada, ler o plist deixou de ser a verdade. `currentSearchText` devolve o valor pendente e é o que `restoreSearchTextIfNeeded()` usa, para uma superfície aberta dentro da janela de 250 ms não ressuscitar a query antiga. A perna LEG-3 isola exatamente isso.

**Antes / Depois (contador determinístico, mesmo spec e mesmo sandbox; 6 teclas com 40 ms entre elas):**

| Fluxo | Antes | Depois |
|---|---|---|
| escritas em UserDefaults | **6** | **0** até o deadline, **1** depois |
| deadlines armados | 0 (não existia) | 1 |
| valor persistido | a query (escrita já na 1ª tecla) | a query inteira, só no deadline |

**Prova vermelha do A/B** — 3 pernas, cada uma restaurada com `git checkout HEAD -- Sources/AppShell/BotsWindow.swift` (`git status` limpo depois de cada):

- **LEG-1 — corpo antigo com assinatura/instrumento novos** (`updateSearchText` escrevendo na hora e `currentSearchText` lendo o plist, como em HEAD): as 3 specs vermelhas.
  ```
  BotsWindowTests.swift:13602: XCTAssertEqual failed: ("6") is not equal to ("0")
  BotsWindowTests.swift:13603: XCTAssertEqual failed: ("0") is not equal to ("1")   // o corpo antigo não arma deadline
  BotsWindowTests.swift:13606: XCTAssertEqual failed: ("6") is not equal to ("1")
  ```
- **LEG-2 — sem o ramo `if searchDirty { persistSearchText() }` no `flushPending()`**: `13606: ("0") is not equal to ("1")` e `13607: ("nil") is not equal to ("Optional("xxxxxx")")`. Prova que o verde vem do flush, não de um caminho vazio/fixture.
- **LEG-3 — escrita adiada com o leitor ainda no plist**: só a spec de superfície fica vermelha (`13664: ("") is not equal to ("piper")`), as outras duas seguem verdes → isola `currentSearchText` (o que ele cobre não é coberto por mais nada).

Specs novos (3, família `BotsWindowTests`): `test_searchTextCoalescesUntilDeadline_becauseTypingMustNotWritePerKey`, `test_pendingSearchTextFlushesOnCloseAndQuit_becauseTheQueryMustSurviveRelaunch`, `test_searchTextPendingWriteIsVisibleToTheNextSurface_becauseADeferredQueryMustNotGoStale`. O fixture de cada um assere o **valor** persistido (a query inteira; `nil` depois de apagar), então um `0` de contagem não passa por vácuo. Armadilha de fixture corrigida no caminho: instalar o `BotDraftManualClock` antes do `flushDraftPersistenceForTesting()` deixa um deadline **real** já armado pelo `restoreSearchTextIfNeeded()` do init — o `scheduleFlush()` tem guarda `!flushScheduled` e o clock falso nunca armava nada (a spec ficava vermelha na ponta "depois"); a ordem correta é flush primeiro, clock depois, como as specs de draft já faziam.

### 32.2 Regressão / baseline da iteração

| Rodada (mesmo sandbox, mesmo filtro) | Executados | Falhas |
|---|---|---|
| Família `BotsWindowTests` depois (fix + 3 specs) | 433 | **1** — `test_peerHandoffMutationWithOneThousandRowsRetainsNineHundredNinetyNineUnderFiftyMillisecondP95` (p95 65,76 ms; amostras 49,9–73,9 ms) |

- `peerHandoff…P95` é **pré-existente**: é a vermelha do baseline registrado na iter 31 (51,27–101,71 ms em 3 pernas) e o spec não toca `searchText` nem a authority. Piso desta máquina no limite do teto de 50 ms.
- `test_saveStudioStartsFirstDockerProvisionOffMainAndMainActorKeepsTicking` (flaky sob carga na iter 31) **passou** nesta rodada — baseline do filtro segue: 1 vermelha esperada + 1 flaky ocasional.
- As 3 specs da iteração rodaram nome a nome dentro da família (433 = 430 da iter 31 + 3).
- Nenhuma medição de wall-clock é reivindicada para esta mudança; o ganho é a contagem de escritas, não tempo.

Housekeeping antes de medir: `pgrep -fl "xctest|swift-test"` mostrou 3 restos de PPID 1/4 com cwd em outros worktrees (`agent-app-memperf-…`, `claude-provider-bugs-nocopy-…`) e 1 `xcodebuild` de iOS em `/Users/samuelfajreldines/dev/lacco` → **nenhum morto**. Os specs desta iteração são contadores determinísticos, então a carga não afeta a medição (só o `peerHandoff` de wall-clock, que é justamente o classificado como pré-existente).

LFS: `Vendor/TailcatBridge/Artifacts/RCTailcat.xcframework/ios-arm64-simulator/libRCTailcat.a` já materializado (47 MB, magic `!<arch>`, não o pointer de 133 B); `git lfs status` sem objeto a commitar/pushar → nada a fazer.

### Backlog (repriorizado na iter 32)

1. **BotsWindow — amplificação de escrita da fila** (só com A/B, contador no `BotStore`). O último P2 "simples" do `BotsWindow` (busca por tecla) saiu nesta iteração; este é o que sobrou da prioridade (a) e exige contador instrumentado.
2. **`deskRoutingByConversation` nunca é podado no delete** — estado persistido (decisão de contrato do dono, junto da regra dest-first): podar exige decidir se o delete pode pagar a escrita síncrona.
3. **AppContext ~6 P2** (inalterados desde a iter 14; lista completa na 15.2).
4. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear`, caminho de Stop do `AgentRunCoordinator`.
5. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 32)

Nada novo varrido (escopo foi o último P2 de `BotsWindow`, já contabilizado em 13.3/14). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `86770afa` | `fix(bots): the roster search writes once per typing burst, not once per key` (32.1, fix + 3 specs + 1 contador) |

## Iteração 33 — 2026-09-18

Escopo: prioridade (b) — AppContext P2 #5 da 15.2 (leitura de fila que falha tratada como fila vazia). **Por que não a amplificação de escrita da fila** (1º da prioridade (a)): ver 33.3.

### 33.1 Uma fila ilegível não é uma fila vazia (`1eee7a7c`)

`AppContext.cancelQueueDrainWaiterIfQueueEmpty(threadId:)` (`:1876`) decidia com `try? queuedMessageRepo.list(...) ?? []`: uma falha transitória de SQLite (tabela locked/ausente, I/O) virava "fila vazia" e **descartava** duas coisas vivas — o `queueDrainWaiter` da thread e o `deferredQueuePromotion` (o alvo escolhido pelo usuário para o item enfileirado). As linhas continuavam no banco, para serem lidas de novo; o que se perdia era estado de agendamento em memória.

Dois call sites passam por essa função: `ensureQueueDrainWaiterIfNeeded` (`:1807`, quando o read falha **ou** quando a fila está genuinamente vazia) e `AppCommandRouter.cancelAgentQueuedMessage` (`:4441`, depois de apagar o item). A correção é num único ponto, a função de decisão:

```swift
guard let queued = try? queuedMessageRepo.list(threadId: threadId),
      queued.isEmpty else { return }
```

Doutrina já estabelecida no **mesmo arquivo**, em `pendingDeletedThreadRetirements` (`:528-531`): *"A transient thread readback failure cannot safely decide whether it may stop provider/queue ownership. Retain the exact deleted candidate until a later read proves it absent"*. A correção aplica a mesma regra à fila — nada de conceito novo.

Custo do fail-open: no pior caso (fila realmente vazia + read falhando) fica um waiter a mais na thread, que se aposenta sozinho no deadline (`removeQueueDrainWaiter`) e, se disparar, não acha nada para drenar. O `deferredQueuePromotions` é 1 entrada por thread (sobrescrita), então não cresce.

**Antes / Depois (contador determinístico, mesmo spec e mesmo sandbox — sem claim de wall-clock):**

| Fluxo (fila ilegível, 1 item enfileirado, 1 waiter, 1 promoção) | Antes | Depois |
|---|---|---|
| `queueDrainWaiterCountForTesting` | **0** (cancelado) | **1** (retido) |
| `deferredQueuePromotion(threadId:ownerId:)` | **nil** (descartada) | o alvo (retido) |

**Prova vermelha do A/B** (`git checkout HEAD -- Sources/AppShell/AppContext.swift` depois de cada perna; `git status` limpo nas duas):

- **LEG-1 — corpo antigo, spec novo** (a assinatura não mudou): só a spec nova fica vermelha, nas 2 asserções pretendidas, e as 3 specs pré-existentes da classe seguem verdes nas duas pernas.
  ```
  QueueDrainStatusProbeTests.swift:116: XCTAssertEqual failed: ("0") is not equal to ("1") - WHY: an unreadable queue must not cancel the waiter that would drain it
  QueueDrainStatusProbeTests.swift:121: XCTAssertNotNil failed - WHY: the promotion is the user's chosen target; a failed read must not drop it
  ```
- **LEG-2 — sem aposentadoria nenhuma (micro-baseline do guarda)**: só a spec de guarda fica vermelha, a nova continua verde → prova que o caminho "read ok + fila vazia" não é coberto pela outra spec (e que a mudança não é um "nunca cancele").
  ```
  QueueDrainStatusProbeTests.swift:166: XCTAssertEqual failed: ("1") is not equal to ("0") - WHY: an empty queue must not keep a waiter alive for an intent that is gone
  QueueDrainStatusProbeTests.swift:168: XCTAssertNil failed: "3EF07528-…" - WHY: the promotion is scoped to the deleted intent
  ```

**Fixtures provam o caminho exercitado, nas duas pernas:** cada spec assere (i) `queueDrainWaiterCountForTesting == 1` **antes** da falha (armou mesmo o waiter) e (ii) `XCTAssertThrowsError(try queuedMessageRepo.list(...))` depois do `ALTER TABLE agent_queued_messages RENAME TO agent_queued_messages_unreadable` — falha **real** de SQLite, não mock. Sem (ii), um `try?` que não falhasse deixaria a asserção verde por vácuo.

2 specs novos em `QueueDrainStatusProbeTests`: `test_unreadableQueueIsNotAnEmptyQueue_becauseAFailedReadMustNotDropTheDrainWaiter` e `test_drainedQueueStillRetiresTheWaiter_becauseOnlyAFailedReadIsNotEmptiness` (guarda do caminho não-deduplicado: o caminho "read ok + vazia" continua idêntico).

### 33.2 Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| `--filter "QueueDrainStatusProbeTests"` (classe inteira, fix + 2 specs) | 5 | **0** |
| `--filter "QueueDrainStatusProbeTests|QueueWorkspaceIdProbeTests"` (as 2 classes que tocam a mudança) | 9 | **0** |
| `--filter "ProviderSnapshotRuntimeTests"` (classe inteira) | — | **abortada: hang pré-existente** (ver 33.4) |

A classe `QueueDrainStatusProbeTests` já tinha baseline verde (rodada de 4 specs, 0 falhas) antes dos specs novos → qualquer vermelha futura é atribuível. `QueueWorkspaceIdProbeTests` cobre o outro call site (`cancelAgentQueuedMessage` no router) e também ficou verde.

### 33.4 `ProviderSnapshotRuntimeTests` travava a rodada — hang pré-existente, não atribuível

A rodada de família (`QueueDrainStatusProbeTests|QueueWorkspaceIdProbeTests|ProviderSnapshotRuntimeTests`) **travou**: 30 min com 8,6 s de CPU e processo `sleeping` (não era lentidão, era bloqueio). Achado, com evidência:

- O hang é sempre em `test_agentAppSurfaceRelationalDeleteRetiresQueuedVictimWhileActiveSiblingSurvives` — **isolado, sozinho, sem as outras classes**, também trava (10 min, 0,2 % CPU).
- Antes de travar, a spec **falha** em 2548 (`bothPeersStarted`), 2549 (`peerRunner.finish(...)` do vítima) e 2560 (`victimQueued`): os dois peer handoffs do fixture nunca chegam ao `ControlledBotHandoffRunner`. Depois disso ela trava nos `_ = await victimDispatch` / `_ = await siblingDispatch` (os `async let` das linhas 2530/2536 nunca terminam), ou seja **a spec se pendura por causa da própria falha de fixture** — falta um fast-fail antes dos awaits.
- **Atribuição medida**: com o corpo pré-fix da minha mudança (LEG-3, `try? … ?? []`) a spec reproduz **os mesmos** erros (2548, 2549, 2560, 2625) e o **mesmo hang**. Logo **não é atribuível** a esta iteração; é pré-existente e depende do ambiente (a classe já tinha 1 vermelha pré-existente registrada: `test_minimalCheckpointUpsertFailurePublishesOneNilIdentityAndNeedsAttention`).

Processos mortos só os meus (o xctest travado deste worktree, 2×); nada de outros worktrees. Registrado como item pendente (33.5 #1): enquanto a spec não tiver fast-fail, a classe inteira **não serve como rodada de regressão** — a medição desta iteração usou as 2 classes de fila (9 specs) e as specs novas nome a nome.

### 33.3 Veredito: por que a amplificação de escrita da fila ficou para depois

Reconferido no fonte antes de escolher. `persistQueuedFollowUps()` (`BotsWindow.swift:7614`) faz, por mutação, 1 `listAllQueuedFollowUps()` (scan da tabela inteira) + 1 `replaceQueuedFollowUps(botID:)` **por bot com fila** (transação DELETE + N INSERTs). Para uma fila de 1 item em 1 bot isso é 1 read + 1 transação — a amplificação é O(bots), não O(items) — e o custo absoluto é de micro/baixo ms.

O que impede a correção barata (escrever só os bots sujos): a mesma tabela é escrita por **outro componente do processo**, o `BotRemoteControlAuthority` (enqueue/remove/replace/dequeue em `:1007`, `:1142`, `:1154-1186`, `:1235`, `:3490`). Hoje o rewrite global significa "última escrita da janela ganha"; com um diff por VM, cada superfície passa a escrever só o que mudou — o que **reduz** clobber, mas muda semântica de propagação entre múltiplas janelas de bots sobre o mesmo AppContext, e isso é decisão de contrato do dono, não um P2 fechável em uma iteração. Registrado no backlog com essa análise.

### 33.5 Backlog (repriorizado na iter 33)

1. **Novo (desta iter): `ProviderSnapshotRuntimeTests` travando a rodada.** A spec `test_agentAppSurfaceRelationalDeleteRetiresQueuedVictimWhileActiveSiblingSurvives` falha o fixture (peers não iniciam) e depois trava nos `async let` — corrigir com fast-fail (`guard bothPeersStarted else { XCTFail(); return }` antes dos awaits) **e** investigar por que o handoff do Agent App não inicia nesse ambiente (pode ser achado de produto, não só de teste). Enquanto isso, a classe não pode ser usada como rodada de regressão inteira.
2. **BotsWindow — amplificação de escrita da fila** — análise de contrato em 33.3: só mexer depois de decidir a semântica multi-janela/`BotRemoteControlAuthority`.
3. **`deskRoutingByConversation` nunca é podado no delete** (estado persistido; decisão do dono, junto da regra dest-first).
4. **AppContext P2 restantes** (15.2 #4): installers de Token Saver por turno no main relendo PATH + 4 MCP configs (`:2128`, `:2134-2165`, `:2285-2333`); `graphifyItemBuffers` sem cap e saída que vaza entrada (`:792`, `:6050-6053`); `usage.json` read-modify-write no main por evento (`:3122`, `:3193`, `:3276`); retry eterno de 0,75 s em falha de escrita de usage (`:5349-5353`). ~~leitura de fila que falha tratada como vazia~~ **fechado nesta iteração (33.1)**.
5. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear`, caminho de Stop do `AgentRunCoordinator`.
6. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 33)

Nada novo varrido (escopo foi um P2 do `AppContext`, já contabilizado na 15.2). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila vistos nesta iter); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `1eee7a7c` | `fix(app-shell): an unreadable queue is not an empty queue` (33.1, fix) |
| `beb2949d` | `test(app-shell): the drained-queue path still retires the waiter` (33.1, spec de guarda) |

## Iteração 34 — 2026-09-18

Escopo: item #1 da 33.5 — `ProviderSnapshotRuntimeTests` que travava a rodada. **Correção de infraestrutura de medição, nenhum código de produto tocado.**

### 34.1 A rodada de handoff reporta em vez de pendurar a classe (`4e6b3dac`)

`AppCommandRouter.dispatchAgentAppBotMentions` (`:3581`, seam `#if DEBUG`) só retorna quando o handoff alcança um milestone: `BotsWindow.awaitAgentAppDispatch` (`:1307`) registra uma `CheckedContinuation` que apenas `resolveAgentAppDispatchWaiters` retoma, e essa só dispara com fase `hostRunning` / `completed` / `needsAttention` (`agentAppDispatchReachedMilestone`, `:1349`). Um run de peer que a spec nunca finaliza deixa o await **pendente para sempre**.

As 3 specs T005 esperavam esse dispatch sem limite: `_ = await (victimDispatch, siblingDispatch)` (`:2399` pré-fix), `_ = await victimDispatch` / `_ = await siblingDispatch` (`:2624`/`:2630`), idem na de rollback (`:2827`/`:2833`). Resultado: a spec **não produzia veredito nenhum** e a classe inteira tinha de ser morta — a iter 33 perdeu uma rodada de família inteira assim (30 min, processo `sleeping`, 8,6 s de CPU).

Correção: `MilestoneBoundedHandoffDispatch` (novo, escopo de arquivo, `Tests/AppShellTests/ProviderSnapshotRuntimeTests.swift:6099`) inicia o dispatch e oferece `settle(timeout:)`, que devolve `false` em vez de esperar indefinidamente. As 3 specs passam a asserir o assentamento com mensagem nomeada.

**Antes / Depois (mesmo comando, mesmo sandbox, mesmo filtro — a medição é tempo-até-veredito, não flip de passe/falha):**

| Rodada | Executados | Falhas | Veredito |
|---|---|---|---|
| **Antes** `test_deleteAgentThread…` | 1 | — | **nenhum**: pendurou >240 s, morto à mão |
| **Antes** `test_agentAppSurface…` | 1 | — | **nenhum**: pendurou >380 s, morto à mão |
| **Depois** as 3 juntas | 3 | 25 | **64,6 s** (16,8 s + 20,4 s + 27,4 s) |

Nenhuma medição de wall-clock de produto é reivindicada: o ganho é a existência de um veredito atribuível.

**Prova de que o travamento era real e não do meu bound:** em cada uma das 3 specs a asserção nova ficou **vermelha** — `:2404` e `:2406` (`test_deleteAgentThread…`), `:2643` (`test_agentAppSurface…`), `:2845` e `:2852` (`test_routerDeleteRollback…`), todas com "the … dispatch must reach its milestone". Ou seja, `settle` devolveu `false` para 5 das 6 pernas; o `await` ilimitado original espera exatamente a mesma condição, logo teria pendurado nas três. Em `test_agentAppSurface…` só a perna do *sibling* não assentou (a vítima é retomada pelo `commitDeletion`, `BotsWindow.swift:1401`), o que reproduz o hang observado no pré-fix em `:2630`.

**Baseline honesto:** o "antes" foi medido para `test_deleteAgentThread…` e `test_agentAppSurface…` (execuções isoladas, mesmas falhas de fixture em `2375/2376/2380` e `2548/2549/2560`). Para `test_routerDeleteRollback…` **não houve rodada "antes"** — a prova de que ele pendurava é o `settle == false` das duas pernas nas duas, não uma execução direta. Declarado como não medido.

### 34.2 Causa raiz das 3 specs: o runner do peer está registrado no provider errado

Achado, com evidência de código — **as 3 specs são permanentemente vermelhas por defeito de fixture, não por bug de produto**:

- `dispatchAgentAppBotMentions` passa `hostRunID: continueHost ? AgentRunID() : nil` (`AppCommandRouter.swift:3607`) — um id **novo**. Em `BotPeerHandoffAuthority.submitAgentAppMention`, `try? runRepo.route(of: hostRunID)` é `nil`, logo `activeCallerRoute == nil` (`BotsWindow.swift:1033-1039`).
- `BotDeskRouting(thread:activeRunRoute:)` resolve `provider = run?.provider ?? thread.provider` (`BotsWindow.swift:105-113`). Sem rota do caller congelada, vale `thread.provider`.
- As duas threads do fixture são `provider: .codex` (`ProviderSnapshotRuntimeTests.swift:2499`, `:2506`), então o **run do peer também é codex**.
- Mas as specs registram `peerRunner` em `.claude` e `hostRunner` em `.codex` (`:2288-2289`, `:2472-2473`). O peer vai para o `hostRunner`; `peerRunner.requests` fica vazio → `bothPeersStarted` / `peerRunner.finish(promptContaining:)` / `victimQueued` falham, e o run codex do peer nunca é finalizado (a spec só chama `peerRunner.finish`) → o handoff nunca chega ao milestone → pendura.

**O padrão que funciona para o mesmo seam já existe no repo:** `AgentAppBotMentionTests.swift:1139-1143` e `:1280-1310` registram **os dois** runners em `.codex` e os distinguem por instância com `CallerThreadHandoffRunner(hostRunner:peerRunners:)` (definido em `AgentAppBotMentionTests.swift:2979`), que roteia pelo `BotSelfConfigCatalog.callerEnvironmentKey` quando o run é de um bot conhecido e cai no host runner caso contrário. É esse o caminho para deixar as 3 specs verdes — **não** foi feito nesta iteração (mexe em ~40 asserções de deleção por spec e exige decidir se `TerminalRetiringOneShotAdapter` continua envolvendo o host).

### 34.3 Regressão / baseline da iteração

| Rodada (mesmo sandbox) | Executados | Falhas |
|---|---|---|
| `--filter "ProviderSnapshotRuntimeTests/test_{deleteAgentThread…,agentAppSurface…,routerDeleteRollback…}"` (depois) | 3 | 25 — todas de fixture, atribuídas nome a nome |

O alvo de compilação de testes é o pacote inteiro: `swift test` compilou todos os arquivos de teste antes de rodar (build ok), então o tipo novo não quebrou nenhuma outra classe. Nenhuma outra spec do arquivo referencia `victimDispatch`/`siblingDispatch` (verificado por grep).

Housekeeping: `pgrep -fl "xctest|swift-test"` antes de medir mostrou 1 `swift-test` de PPID 1 com cwd em outro worktree (`claude-provider-bugs-nocopy-…`) e 1 `xcodebuild` de iOS em `/Users/samuelfajreldines/dev/lacco` → **nenhum morto**. Os 2 processos que matei eram os meus (o xctest travado deste worktree).

LFS: `Vendor/TailcatBridge/Artifacts/RCTailcat.xcframework/macos-arm64/libRCTailcat.a` materializado (48 MB, magic `!<arch>`, não o pointer de 133 B); `git lfs status` sem objeto a commitar/pushar → nada a fazer.

(Incidente sem dano nesta iteração: um comando de placeholder acabou executando `script/build_and_run.sh`; o processo foi morto em <2 s, o log ficou vazio e nenhum app novo foi lançado — a instância debug viva em `.sandbox-worktrees/20260917T225441Z` tem 11h54m de uptime e é anterior a esta iteração.)

### 34.4 Backlog (repriorizado na iter 34)

1. **Fiação do `peerRunner` nas 3 specs T005** (34.2) — trocar para `CallerThreadHandoffRunner` com os dois runners em `.codex`, seguindo `AgentAppBotMentionTests.swift:1139-1143`. Isso as deixa verdes; sem isso elas só falham rápido. É o próximo item de maior valor.
2. **BotsWindow — amplificação de escrita da fila** — análise de contrato na 33.3: só mexer depois de decidir a semântica multi-janela/`BotRemoteControlAuthority`.
3. **`deskRoutingByConversation` nunca é podado no delete** (estado persistido; decisão do dono).
4. **AppContext P2 restantes** (15.2 #4): installers de Token Saver por turno no main relendo PATH + 4 MCP configs; `graphifyItemBuffers` sem cap; `usage.json` read-modify-write no main por evento; retry eterno de 0,75 s em falha de escrita de usage.
5. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear`, caminho de Stop do `AgentRunCoordinator`.
6. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 34)

Nada novo varrido (o escopo foi a infraestrutura de medição da classe de handoff). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila já vistos); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `4e6b3dac` | `test(app-shell): a handoff round reports instead of hanging the class` (34.1) |


## Iteração 35 — 2026-09-18

Escopo: item #1 da 34.4 — fiação do `peerRunner` nas specs T005 de `ProviderSnapshotRuntimeTests` (34.2). **Infraestrutura de teste; nenhum código de produto tocado.**

### 35.1 O runner do peer passa a ser registrado no provider do run (`37bd6dc6`)

`dispatchAgentAppBotMentions` despacha um id de host *futuro* (`hostRunID: AgentRunID()`, `AppCommandRouter.swift:3607`), então `BotDeskRouting(thread:activeRunRoute:)` não acha rota do caller e cai em `thread.provider` — host e peer rodam no **mesmo** provider. As fixtures registravam o `peerRunner` em `.claude` e o host em `.codex` (`:2288-2289`, `:2479-2480`, `:5797-5798` pré-fix), com threads `.codex`: todo run de peer caía no `hostRunner`, `peerRunner.requests` ficava vazio, e o run do peer nunca era finalizado.

Correção: `wireCallerThreadHandoff(context:peer:peerRunner:hostRunner:)` (novo, escopo de arquivo) registra **os dois** runners no provider do host via `CallerThreadHandoffRunner(hostRunner:peerRunners:)` — o mesmo seam que `AgentAppBotMentionTests.swift:1139-1143` já usa — dentro do `TerminalRetiringOneShotAdapter` que o host já tinha. O peer é escolhido pelo id do bot que o run carrega no environment (`RC_REMOTE_CODE_BOT_ID`). Nenhuma asserção de spec mudou.

Arquivo: `Tests/AppShellTests/ProviderSnapshotRuntimeTests.swift` (+45/−21).

**Antes / Depois (mesmo sandbox, mesmo filtro, mesma máquina; único delta é este commit):**

| Spec | Antes (falhas) | Depois |
|---|---|---|
| `test_deleteAgentThread…WithoutRedispatchOrV1Rewrite` | 7 — 2379, 2380, 2384, 2402, 2404, 2406, 2444 | **verde** (0,557 s) |
| `test_agentAppSurfaceRelationalDelete…` | 5 — 2559, 2560, 2571, 2637, 2643 | **verde** (0,507 s) |
| `test_routerDeleteRollbackResumesExactTerminalHandoff…` | 13 — 2712, 2771, 2783, 2807, 2808, 2813, 2817, 2821, 2832, 2841, 2845, 2846, 2852 | **verde** (0,484 s) |
| `test_checkpointEnrichmentBlockedAfterCallback…` (mesma fixture) | 7 — 5534, 5535, 5546, 5568, 5570, 5577, 5579 | **verde** (0,396 s) |
| `test_minimalCheckpointUpsertFailurePublishes…` (mesma fixture) | 6 — 5625, 5626, 5650, 5657, 5661, 5667 | **verde** (0,559 s) |
| **Total** | 5 executados, **38 falhas** (80,3 s) | 5 executados, **0 falhas** (2,5 s) |

Rodada conferida **nome a nome**: 5 linhas `Test Case … passed` + `Executed 5 tests, with 0 failures`; o build recompilou o arquivo na rodada "depois" (`[6/8] Compiling AppShellTests ProviderSnapshotRuntimeTests.swift`, `Build complete! (9.91s)`), então o verde é da árvore editada, não de binário velho.

Sensibilidade: o "antes" é o controle negativo — mesmo comando, mesmo sandbox, código pré-commit. As primeiras asserções vermelhas de cada spec são exatamente as pernas de fixture (`bothPeersStarted` em 2379/2559/2712, `peerStarted` em 5534/5625), então a fiação é o que decide o veredito, e as asserções de produto que vinham atrás (supressão do run futuro, retenção do sibling, rollback sem redispatch) só passaram a ser exercidas com o peer de verdade.

**Correções de registro causadas por esta iteração** (para as próximas rodadas não tratarem como regressão):
- `test_minimalCheckpointUpsertFailurePublishesOneNilIdentityAndNeedsAttention` estava listada como vermelha pré-existente desde a iter 1 (`:107`) e foi declarada "não atribuível / dependente do ambiente" na 33.4 (`:2486`): era **defeito de fixture**, e agora é verde.
- `test_checkpointEnrichmentBlockedAfterCallbackCannotDelayExactHostSettlement` não constava em nenhum baseline registrado e estava vermelha; agora verde.
- As 3 specs T005 "vermelhas até a fiação do 34.2" agora são verdes de fato — o 34.2 está fechado.

### 35.2 Achado novo: 5 specs da família peer-persistence também estão vermelhas (pré-existente, **não** atribuível)

Ao medir a família irmã (que não usa a fixture alterada) apareceram 17 asserções vermelhas em 5 specs, ausentes de todos os baselines registrados:

| Spec | Falhas | Linhas (árvore atual) |
|---|---|---|
| `test_peerHandoffAtomicCommitCutsConvergeSQLiteMirrorAndFreshAuthoritiesBeforeDispatch` | 9 | 2930, 2931, 2934 (×3 cuts) |
| `test_peerHandoffFutureMirrorDivergenceStaysByteExactAndMutationFailsClosed` | 2 | 3018, 3023 |
| `test_peerHandoffPostCacheOpaqueMirrorDriftFailsClosedWithoutOverwriteOrDispatch` | 2 | 5939, 5945 (dentro de `makeT005CachedPeerHandoffFixture`) |
| `test_peerHandoffCachedSQLiteCASMismatchRejectsStaleCandidateAndAdoptsCanonicalExactly` | 2 | 5939, 5945 |
| `test_peerHandoffSupportedMirrorDivergenceRepairsCanonicalWithoutApplyingFirstStaleMutation` | 2 | 5939, 5945 |
| **Total** | **17** | 5 executados |

**Atribuição medida**: a mesma rodada com a árvore pré-commit (`git checkout 37bd6dc6^ -- Tests/AppShellTests/ProviderSnapshotRuntimeTests.swift`, restaurada com `git checkout HEAD -- …`, `git status` limpo) dá **17 falhas, conjunto de asserções idêntico** (linhas deslocadas pelo diff) → pré-existente, não é efeito desta iteração. Hipótese registrada (não diagnosticada): `makeT005CachedPeerHandoffFixture` (`:5905`) exige `XCTAssertFalse(base.viewModel.send(…))` com o `peerHandoffMirrorCommitGateForTesting` lançando, e `candidateBytes` fica nil — o gate do espelho não está sendo consultado nesse caminho; o `makeT005PeerPersistenceContext` (`:5866`) repete o padrão de provider trocado (peerRunner `.claude` em `:5884`, host `.codex` em `:5885`) e as pernas de peer estão sob `if let` (`:2935`, `:3057`, `:3139`, `:3160`, `:3195`, `:3215`), ou seja, passariam vacuamente se o lookup voltasse nil.

### 35.3 Backlog (repriorizado na iter 35)

1. **Família peer-persistence (5 specs, 17 vermelhas — 35.2)**: diagnosticar o gate do espelho em `makeT005CachedPeerHandoffFixture` + decidir a fiação do `peerRunner` em `makeT005PeerPersistenceContext`; é o próximo item de maior valor (specs de contrato de commit/CAS do espelho hoje não exercitadas).
2. **BotsWindow — amplificação de escrita da fila** — só depois da decisão de semântica multi-window/`BotRemoteControlAuthority`.
3. **`deskRoutingByConversation` nunca é podado no delete** (decisão do dono).
4. **AppContext P2 restantes**: installers de Token Saver por turno no main relendo PATH + 4 MCP configs; `graphifyItemBuffers` sem cap; `usage.json` read-modify-write no main por evento; retry eterno de 0,75 s em falha de escrita de usage.
5. P3 restantes da varredura: `PrivateAccountSessionStore.save/clear`, caminho de Stop do `AgentRunCoordinator`.
6. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 35)

Nada novo varrido (o escopo foi a fixture da classe de handoff). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila já vistos); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `37bd6dc6` | `test(app-shell): the T005 peer runner registers on the run's provider` (35.1) |

## Iteração 36 — 2026-09-18

Escopo: item #1 da 35.3 — a família peer-persistence (5 specs, 17 vermelhas). **Infraestrutura de teste; nenhum código de produto tocado.**

### 36.1 Causa raiz: o gatilho das 5 specs foi removido do produto (`814506c7`)

As 5 specs nasceram em `2498debc` (2026-08-20 13:33) contra o `sendMention`: um send de desk que mencionasse um bot persistia a linha do handoff **sincronamente** e devolvia `false` quando o commit do espelho falhava (`peerHandoffs[outbox.id] = handoff; guard persistPeerHandoffs() else { … return false }`). Cinco horas depois, `814506c7` ("feat: delegate bot mentions through primary agents", 2026-08-20 19:54) substituiu o `sendMention` pela delegação por tool: um mention de desk agora só compila um turn directive (`BotPeerDelegation.turnDirective`) e o agente do host chama `askBotPeer` → socket → `askPeerFromActiveProvider` → `submitAgentAppMention`. `sendMention` não existe mais (`grep -n sendMention Sources/` → vazio).

Consequência medida (não inferida): `viewModel.send("@quinn …")` devolve `true` (o send do host é aceito), o `peerHandoffMirrorCommitGateForTesting` **nunca é consultado** e `candidateBytes` fica nil → exatamente as 17 asserções da 35.2 (9+2+2+2+2 em 2930/2931/2934 ×3 cuts, 3018/3023 e 5939/5945 ×3). `814506c7` só religou as specs irmãs que usam o seam DEBUG (`continueHost:`), então estas 5 ficaram mortas por ~4 semanas — vermelhas no `production`, não por efeito deste branch.

**Correção de registro (substitui a hipótese da 35.2)**: a suspeita de "provider trocado no `makeT005PeerPersistenceContext`" **não** é a causa. As fixtures registravam o `peerRunner` em `.claude` porque o `sendMention` congelava o routing do **desk do peer** (`.claude`, via `openDesk(quinn); setDeskProvider(.claude)`); com o gatilho removido nenhum handoff chega a ser submetido, então nenhum provider é consultado. Também não é defeito de fixture: o gate do espelho é consultado normalmente quando a mutação é submetida.

### 36.2 Correção (`b636242f`)

`submitT005DeskPeerMention(context:viewModel:host:peer:provider:text:)` (novo, escopo de arquivo) submete o handoff pelo caminho de produto que sobreviveu: a conversa de desk selecionada como origem (ligando uma thread de origem no provider em que o desk do peer foi fixado, reaproveitada nas chamadas seguintes do mesmo spec) mais `originBot`/`originConversation` → `submitAgentAppMention`. Nenhuma asserção de contrato foi removida: `XCTAssertFalse(send(…))` virou `XCTAssertNil(handle)` (mesma força — o commit recusado não aceita o handoff) e as duas pernas de aceite, que estavam sob `if let peerRunID = … { XCTAssertTrue(finish(…)) }` (pulavam o check quando o lookup voltava nil), agora esperam o run do peer alcançar o runner e fazem `XCTUnwrap`.

Arquivo: `Tests/AppShellTests/ProviderSnapshotRuntimeTests.swift` (+144/−20; +150/−22 no total com o 36.3).

**Antes / Depois (mesmo sandbox, mesmo filtro, mesma máquina; único delta é este commit):**

| Spec | Antes (`16bb99a6`) | Depois (`cf0f6dd6`) |
|---|---|---|
| `test_peerHandoffAtomicCommitCutsConvergeSQLiteMirrorAndFreshAuthoritiesBeforeDispatch` | 9 falhas (2930/2931/2934 ×3 cuts) | **verde** (2,204 s) |
| `test_peerHandoffFutureMirrorDivergenceStaysByteExactAndMutationFailsClosed` | 2 (3018, 3023) | **verde** (0,615 s) |
| `test_peerHandoffCachedSQLiteCASMismatchRejectsStaleCandidateAndAdoptsCanonicalExactly` | 2 (5939, 5945) | **verde** (0,328 s) |
| `test_peerHandoffPostCacheOpaqueMirrorDriftFailsClosedWithoutOverwriteOrDispatch` | 2 (5939, 5945) | **verde** (0,501 s) |
| `test_peerHandoffSupportedMirrorDivergenceRepairsCanonicalWithoutApplyingFirstStaleMutation` | 2 (5939, 5945) | **verde** (0,284 s) |
| **Total** | 5 executados, **17 falhas** (3,955 s) | 5 executados, **0 falhas** (3,932 s / 3,843 s) |

Rodada conferida nome a nome nas duas execuções do commit final (5 linhas `Test Case … passed` + `Executed 5 tests, with 0 failures`); o "antes" foi medido no pai `16bb99a6` com o mesmo comando e o mesmo sandbox. Cobertura recuperada: o contrato de commit do espelho (`replaceSnapshot`/`commitCandidateMirror`/`refreshStorageProjection`) nos três cortes de crash, o CAS perdendo para um irmão canônico mais novo, o reparo de espelho suportado-mas-velho e a preservação byte-a-byte do espelho v1 e de bytes opacos futuros não tinham nenhuma spec verde antes desta iteração (`grep peerHandoffMirrorCommitGateForTesting Tests/` → só 2 specs de `setPhase` em `BotsWindowTests`).

### 36.3 A rodada de família achou uma corrida introduzida aqui (`cf0f6dd6`)

Rodada de família (as 5 desta iteração + as 5 T005 da 35, 10 specs em um processo) → `test_peerHandoffSupportedMirrorDivergence…` falhou com `XCTAssertEqual failed: ("2") is not equal to ("1")`: o `mirrorGateCalls` era lido **depois** do `waitUntil` do dispatch, e a primeira escrita de fase do plano (`setPhase` → `persistPeerHandoffs` → `replaceSnapshot`) também passa pelo gate — às vezes ela chegava antes da leitura. Correção: o contador passa a ser lido **sincronamente logo após o `submit`**, onde só o commit da mutação passou pelo gate (mais determinístico e mais forte que a leitura tardia). Depois disso, 3 rodadas de família consecutivas verdes (10 executados, 0 falhas, 6,370 / 6,655 / 6,533 s) e 2 rodadas do filtro de 5 specs verdes.

### 36.4 Backlog (repriorizado na iter 36)

1. **AppContext P2 restantes**: installers de Token Saver por turno no main relendo PATH + 4 MCP configs; `graphifyItemBuffers` sem cap; `usage.json` read-modify-write no main por evento; retry eterno de 0,75 s em falha de escrita de usage.
2. **Varredura das áreas não auditadas** (inalterado): `AppCommandRouter` (parcial), `PrivateAccountIntegration` (restante), `Sources/Surfaces/` fora dos módulos já vistos, `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila), `Sources/AgentRuntime/` fora dos caminhos já vistos.
3. **`BotsWindow` — amplificação de escrita da fila** (decisão de semântica multi-window/`BotRemoteControlAuthority`), **`deskRoutingByConversation` sem poda no delete** (decisão do dono).
4. **P3 restantes da varredura**: `PrivateAccountSessionStore.save/clear`, caminho de Stop do `AgentRunCoordinator`.
5. **Demais itens antigos** (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 36)

Nada novo varrido (o escopo foi o gatilho da família T005). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila já vistos); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `b636242f` | `test(app-shell): the T005 peer-persistence specs trigger the delegation path` (36.1/36.2) |
| `cf0f6dd6` | `test(app-shell): read the fresh-candidate gate count on the mutation itself` (36.3) |

## Iteração 37 — 2026-09-18

Escopo: item #1 do backlog da 36.4 — **installers de Token Saver por turno, no main** (`AppContext.tokenSaverAgentEnvironment`). Código de produto + teste; nada de teste removido.

### 37.1 O custo por run (medido, read-only, nesta máquina)

`tokenSaverAgentEnvironment` roda no MainActor a cada run admitido (root, retry, recovery e cada subagent) e, dentro do bloco `receipt.capabilities.managedPath == true`, chamava `installer.installCommandWrappers(...)` **sem nenhuma reutilização**. Esse passe:

- lista **cada diretório do PATH** (`contentsOfDirectory`) — 20 diretórios, ~1.993 nomes aqui;
- para cada candidato (catálogo + nomes listados) faz `commandExistsOnSystem` = um `stat` por diretório até achar;
- percorre o bin gerenciado do usuário — **1.945 links** medidos com `ls ~/.remote-code/bin | wc -l` — com `destinationOfSymbolicLink` por link, mais o prune da mesma pasta.

Medição com contador determinístico (`AppContext.commandWrapperRefreshCountForTesting`) e wall-clock no sandbox, mesma máquina, mesmo workload (spec novo, 10 builds em sequência com a mesma PATH sintética):

| Perna | Passes / builds | Build reutilizado (warm, 5+ amostras) | Passe completo (warm) |
|---|---|---|---|
| Antes (`7aacb663^` com o seam novo e o corpo antigo) | **10 / 10** | — (todo build é passe completo) | 243, 244, 244, 244, 247 ms |
| Depois (`7aacb663`) | **3 / 8** (2 reusados + 3 invalidados por mudanças reais) | **1, 1, 1, 1, 1, 1, 1 ms** (7 amostras) | 279, 243, 257 ms |

Ou seja: ~243 ms de MainActor por run admitido → ~1 ms quando o sistema não mudou (3 ordens de grandeza; −99,6%). É **piso**, não teto: o spec usa uma PATH sintética com 2 nomes, então o passe medido paga só o walk do bin (1.945 links) + o catálogo; em produção soma-se a enumeração dos ~1.993 nomes do PATH real.

### 37.2 Correção (`7aacb663`)

`commandWrapperStateStamp(installer:searchDirectories:serviceBinary:)` (novo, `AppContext`) devolve a impressão digital das entradas do passe — o binário de serviço para o qual os links apontam, o bin gerenciado e cada diretório de PATH **com a data de modificação do diretório** (que muda exatamente quando uma entrada é criada, removida ou renomeada). O passe só roda quando a impressão difere da última; a impressão é capturada **depois** do passe (ele mesmo cria links no bin, que é um dos diretórios carimbados).

`ensureDistillCLI()` continua **incondicional** em todo turno — a garantia declarada no código ("missing or dangling ~/.remote-code/bin/distill is repaired before PATH is stamped") não depende do cache; o que foi amortizado é a enumeração, não o reparo.

Trade-off declarado: um wrapper cujo link o usuário apague é recriado no turno seguinte (a remoção muda o mtime do bin gerenciado, que está no carimbo), mas um comando **novo** instalado em um diretório do PATH só ganha wrapper quando aquele diretório mudar de novo — e ele mudou ao receber o comando, então o turno seguinte já o pega. Nenhum caminho perde wrapper de forma permanente.

Arquivos: `Sources/AppShell/AppContext.swift` (+40/−4), `Tests/AppShellTests/ProviderEnvironmentAttributionTests.swift` (+106).

### 37.3 Regressão / baseline

| Rodada (mesmo sandbox, mesma máquina) | Antes | Depois |
|---|---|---|
| `--filter ProviderEnvironmentAttributionTests/test_commandWrapperPass` | **4 falhas** (3 de contador + 1 de wrapper novo ausente; é o controle negativo: o spec novo é vermelho sem a correção) | **0 falhas** (1,327 s / 1,449 s) |
| `--filter "(ProviderEnvironmentAttributionTests\|TokenSaverIdentityProbeTests)"` (família que consome o env e o receipt) | — | 20 executados, **0 falhas** ×2 (11,676 s / 11,326 s), 20 nomes conferidos |

O "antes" foi medido com **assinatura nova e corpo antigo** (`git checkout 7aacb663^ -- Sources/AppShell/AppContext.swift` + só o seam do contador), restaurado com `git checkout HEAD -- …` e `git status` limpo. Os 4 installers MCP (`installBotSelfConfigMCP/Browser/Computer/Web`) foram deixados como estão: são 2 arquivos de config por chamada em vez de milhares de syscalls; **não medidos nesta iteração — não reivindicados**.

### 37.4 Backlog (repriorizado na iter 37)

1. **AppContext P2 restantes**: `graphifyItemBuffers` sem cap (cresce sem limite enquanto o Graphify está ligado); `usage.json` read-modify-write no main por evento (`recordTokenSaverAccountUsage`/`clearTokenSaverAccountUsagePercentages`/`reconcilePeriodicGrokMissIfReady`); retry eterno de 0,75 s em falha de escrita de usage.
2. **Varredura das áreas não auditadas** (inalterado): `AppCommandRouter` (parcial), `PrivateAccountIntegration` (restante), `Sources/Surfaces/` fora dos módulos já vistos, `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila), `Sources/AgentRuntime/` fora dos caminhos já vistos.
3. `BotsWindow` — amplificação de escrita da fila (decisão do dono); `deskRoutingByConversation` sem poda no delete (decisão do dono).
4. P3: `PrivateAccountSessionStore.save/clear`, caminho de Stop do `AgentRunCoordinator`.
5. Demais itens antigos (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 37)

Varrido nesta iteração: `AppContext` — `tokenSaverAgentEnvironment` (bloco `managedPath` completo, incluindo os 4 installers MCP e o caminho de PATH). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila já vistos); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `7aacb663` | `perf(token-saver): reuse the managed wrapper pass while the system is unchanged` (37.2) |

## Iteração 38 — 2026-09-18

Escopo: item #1 do backlog da 37.4 — **`graphifyItemBuffers` sem cap** (`AppContext`). Código de produto + 3 specs novos; nenhuma asserção existente foi alterada ou removida.

### 38.1 O vazamento (medido, não inferido)

`graphifyItemBuffers` só perdia entrada pelo evento terminal do **próprio item**: `finalizeGraphifyUsageItem` (chamado em `itemCompleted(.completed)`) ou `failGraphifyUsageItem` (em `itemState`/`itemCompleted` com `.failed`/`.cancelled`). O coordinator **não sintetiza evento terminal por item** quando o run é parado: `grep -n "finalState: .cancelled\|state: .cancelled" Sources/AgentRuntime/AgentRunCoordinator.swift` → o único `.cancelled` é o `onRunFinished?(threadId, stoppedRunId, .cancelled)` da linha 4371. Portanto todo run interrompido no meio de um item deixava a chave residente **para sempre** — nenhum caminho do produto revisitava aquela entrada.

Teto por entrada: `maxHaystackUTF8Bytes` (8.192 B de `body`) + `maxOutputUTF8Bytes` (8.192 B de `output`) + `failureScanOverlapUTF8Bytes` (96 B) + summary/provider ≈ **16,4 KiB**. O caminho normal do Claude **não** vaza: o `itemStarted` de `tool_result` reusa o `toolUseId` (`ClaudeParser.swift:347`), então é a mesma chave que finaliza.

Medição do "antes" (assinatura nova + corpo antigo; ver 38.3): depois de `onRunFinished?(.cancelled)`, `graphifyBufferCountForTesting() == 1` — a entrada do item interrompido segue residente e o contador de reclaim fica em 0.

### 38.2 Correção (`604928cb`)

Cada entrada passa a carregar `lastTouchedMs`, renovado por todo evento que a muta (3 pontos: `itemStarted`-merge, `itemDelta` existente, `itemDelta` novo). A entrada é reclamada quando o item passa **15 min sem nenhum evento**. O passe roda em dois gatilhos que já existem no produto:

- **fim de run** — `onRunFinished` → `finishPendingTokenSaverUsage(runId:)` (o hook terminal que já é usado para descarregar o usage pendente), com `force: true`;
- **capacidade** — `graphifyBufferCapacity = 512` entradas (≈8 MiB no teto de 16,4 KiB/entrada), verificado no fim dos dois caminhos de gravação.

**A ordem importa e está no código**: o passe roda *depois* do `processGraphifyBuffer` (que é quem marca `recordedInvocation`/`recordedExploration`). Na primeira versão ele rodava antes, e com o mapa sobre pressão o backstop podia derrubar a entrada recém-criada **antes** de a linha pendente ser carimbada — o spec 38.3-C pegou exatamente isso (3 asserções vermelhas na própria implementação nova).

Proteção do crédito: uma entrada que já tem linha pendente (`recordedInvocation`/`recordedExploration`) **nunca** é derrubada — nem pelo passe de idade, nem pelo backstop de capacidade. Derrubá-la deixaria a linha `ok=0` sem o flip para `ok=1`, que é justamente o crédito do Graphify no Estimated save. Se todas as entradas forem pendentes, o mapa fica acima da capacidade de propósito: o limite duro cede ao número do Token Saver.

Gatilho de teste: `graphifyBufferBackdateForTesting(runId:itemId:byMs:)` envelhece uma entrada (o único fator que um spec de limpeza não pode esperar); `graphifyBufferCapacity` é seam para o backstop. Nada mais do produto foi tocado.

Arquivos: `Sources/AppShell/AppContext.swift` (+75), `Tests/AppShellTests/TokenSaverLocalUsageSignalTests.swift` (+177).

### 38.3 Regressão / A/B

O "antes" foi medido com as **assinaturas novas e o corpo antigo** (script de medição em `/tmp`, não versionado): `git checkout HEAD~1 -- Sources/AppShell/AppContext.swift` + shim que adiciona só `graphifyBufferStaleAfterMs`, `graphifyBufferCapacity`, os 2 contadores, `graphifyBufferCountForTesting()` e um `graphifyBufferBackdateForTesting` no-op. Sem passe de limpeza nenhum, o comportamento antigo fica intacto e as specs novas falham. Restaurado com `git checkout HEAD -- …` e `git status` limpo.

| Spec novo | Antes (corpo antigo + shim) | Depois (`604928cb`) |
|---|---|---|
| `test_graphifyBuffer_runStoppedMidItemIsReclaimedAtRunFinish` | **falha**: `count == 1` após `onRunFinished(.cancelled)` e reclaim `0` (2 asserções) | **verde** (0,242 s / 0,327 s / 0,341 s) |
| `test_graphifyBuffer_capacityReclaimsTheOldestAndKeepsTheLiveStream` | **falha**: abandonada retém 256 B, `count == 2` > cap 1, stale `0` (3 asserções) | **verde** (0,281 s / 0,251 s / 0,185 s) |
| `test_graphifyBuffer_pendingGraphifyRowIsNeverSwept` | **falha**: entrada abandonada retém 384 B, over-capacity `0` (2 asserções) | **verde** (0,191 s / 0,204 s) |
| 3 specs pré-existentes do mesmo filtro (`eightMiBResultStream…`, `failureAfter8KiBPrefix…`, `stopsGrowingBodyAfterInvocationRecorded`) | verdes (controle: o "antes" não é um ambiente quebrado) | verdes |
| **Rodada do filtro** | 6 executados, **7 falhas** (5,501 s) | 6 executados, **0 falhas** (2,214 s) |

Rodada de família (mesma máquina, mesmo sandbox, `--filter "(TokenSaverLocalUsageSignalTests\|TokenSaverUsageDebounceTests\|TokenSaverFinishProviderProbeTests)"`): **35 executados, 0 falhas** (11,907 s), com os 3 nomes novos conferidos um a um — as classes que consomem o env/receipt e o caminho de fim de run (`finishPendingTokenSaverUsage`) seguem verdes.

Honestidade da medição: a prova é por **contador determinístico** (entradas residentes e entradas reclamadas), não por wall-clock — não há claim de performance aqui, e sim de limite de memória. O que **não** foi medido: RSS do app com N runs interrompidos (a fixture para no contador) e o crescimento real em produção (depende de quantos runs o usuário para por sessão); o teto por entrada é derivado dos caps já existentes, medidos no spec de 8 MiB da iter anterior. Sem redução de crédito: as 3 specs de crédito do Graphify (`signalCount`) continuam verdes, e o spec C faz o flip `ok=1` *depois* do passe para provar que a linha pendente não foi órfã.

### 38.4 Backlog (repriorizado na iter 38)

1. **AppContext P2 restantes**: `usage.json` read-modify-write no main por evento (`recordTokenSaverAccountUsage`/`clearTokenSaverAccountUsagePercentages`/`reconcilePeriodicGrokMissIfReady`); retry eterno de 0,75 s em falha de escrita de usage; os 4 installers de MCP (não medidos até agora).
2. **Varredura das áreas não auditadas** (inalterado): `AppCommandRouter` (parcial), `PrivateAccountIntegration` (restante), `Sources/Surfaces/` fora dos módulos já vistos, `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila), `Sources/AgentRuntime/` fora dos caminhos já vistos.
3. `BotsWindow` — amplificação de escrita da fila (decisão do dono); `deskRoutingByConversation` sem poda no delete (decisão do dono).
4. P3: `PrivateAccountSessionStore.save/clear`, caminho de Stop do `AgentRunCoordinator`.
5. Demais itens antigos (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 38)

Varrido nesta iteração: `AppContext` — ciclo de vida completo de `graphifyItemBuffers` (`recordGraphifyUsageFromAssistantItem`, `recordGraphifyUsageFromItemDelta`, `processGraphifyBuffer`, `finalizeGraphifyUsageItem`, `failGraphifyUsageItem`, `finishPendingTokenSaverUsage`) e `graphifyProviderByThread` (já tinha limite de 128). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila já vistos); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `604928cb` | `fix(token-saver): reclaim a Graphify item buffer its run never closes` (38.2) |

## Iteração 39 — 2026-09-18

Escopo: item #1 do backlog da 38.4 — **`usage.json` read-modify-write no main a cada evento** (`AppContext.recordTokenSaverAccountUsage` → `TokenSaverUsageStore.recordAccountUsage`). Código de produto + 5 specs; nenhum assert existente foi alterado.

### 39.1 A evidência (medida, não inferida)

- `AppDelegate.swift:135`: `tokenSaverAccountUsageRefreshInterval = 60`. O loop é iniciado **incondicionalmente no launch** (`:390`) e só invalidado no teardown (`:628`) — probe a cada 60 s enquanto o app estiver aberto (~1.440/dia). Cada conclusão com usage chama `recordTokenSaverAccountUsage` **no MainActor** (`AppContext:3309`), que fazia o RMW inteiro: `open` do lock + `fchmod` + `flock(LOCK_EX)` **cross-process** + decode de usage.json + encode + `write(.atomic)` + `close`. O caminho de evento (`.accountUsage`, `AppContext:1562`) compartilha a mesma função.
- Redundância no banco vivo do dono (read-only, `agent_stream_events`, 26 dias 2026-08-22→09-17): **80 eventos `accountUsage(...)`**, dos quais **56 (70%) repetem a porcentagem anterior do mesmo provider** — `accountUsage(codex 0%)` ×29, `17%` ×9, `18%` ×10, `26%` ×5, etc.
- Arquivo real medido: `~/Library/Application Support/RemoteCode/TokenSaver/usage.json` = **3.323 B** (3 providers + 7 linhas diárias).
- `recordAccountUsage` tem **um único chamador no app** (`grep` em `Sources/`): o `AppContext`, então nada escreve % de conta por fora dele.

### 39.2 Correção (`e60fe65b`)

`recordAccountUsage` decodifica o arquivo primeiro e **retorna sem escrever** quando a linha armazenada já tem exatamente os campos que a chamada gravaria (weekly %, janela semanal, `weeklyResetsAt`, sessão %, `currentSessionResetsAt`). Sem lock, sem encode, sem rename. `saveUnlocked` substitui o arquivo atomicamente, então essa leitura simples vê uma geração completa; e como o caminho de skip **não escreve nada**, ele não pode perder update. Argumentos opcionais significam "manter o valor armazenado" (o RMW faz `novo ?? atual`), então um `nil` nunca pode fazer a linha diferir.

A comparação usa `decodeStoredSnapshot` (decode cru), não `loadUnlocked`: o read model dobra janela semanal expirada para 0%, e comparar contra o valor dobrado faria uma escrita real 45%→0% parecer no-op. Tudo o mais em `loadUnlocked` é o mesmo código extraído (sem mudança de comportamento).

### 39.3 A/B (mesmo sandbox, mesma máquina, arquivo de fixture de 1.245 B)

| Spec | Antes (store antigo, `e60fe65b^`) | Depois (`e60fe65b`) |
|---|---|---|
| `test_accountUsageEventsWithUnchangedPercentagesWriteUsageOnce` (funil real: 10 eventos `.accountUsage` idênticos) | **falha** (mtime muda a cada evento) | **verde** (0,259–0,617 s) |
| `test_recordAccountUsage_unchangedPercentagesLeaveTheFileUntouched` (50 repetições + bytes idênticos) | **falha** | **verde** |
| `test_recordAccountUsage_nilFieldsKeepStoredValuesAndSkipTheWrite` | **falha** | **verde** (0,001 s) |
| `test_recordAccountUsage_expiredWindowStillPersistsTheZeroItReports` (guarda) | verde | verde |
| `test_recordAccountUsage_zeroPercentOnMissingFileStillCreatesTheFile` (guarda) | verde | verde |
| **Filtro (5 specs)** | 5 executados, **3 falhas** | 5 executados, **0 falhas** (0,624 s) |

Wall-clock das 50 repetições idênticas: **12,72 ms** e **32,56 ms** (duas amostras; variância de disco) → **1,58 / 1,60 / 1,70 ms**. Ou seja, ~0,22 a 0,62 ms por escrita redundante evitada — **piso**, não teto: a fixture é um processo só e um arquivo de 1.245 B, enquanto o arquivo real tem 3.323 B e há um segundo processo (proxy Distill) disputando o mesmo flock. A evidência determinística é o **mtime do arquivo** (+ bytes idênticos), não o wall-clock.

Rodada de família (`TokenSaverUsageSnapshotTests|TokenSaverAppContextTests|TokenSaverLocalUsageSignalTests|TokenSaverSidebarSnapshotTests|TokenSaverUsageDebounceTests`, 140 specs): **antes 6 falhas / depois 3 falhas**. As 3 restantes são **pré-existentes e idênticas nas duas pernas**: `test_itemHostMetadataPublishesDistillAppliedAsAdditiveWireEvent` (casing de UUID vindo do socket), `test_managedDistillCLIUsesLocalMacDistillService` ("unit tests passed with no failures" vs "PASS") e `test_rolloverProtectedCapacityFailsBeforeGraphWritesAndPublishesNothing`. As outras 3 eram os specs novos desta iteração.

### 39.4 Guardas: dentes provados por mutação (não é claim, é experimento)

Os dois specs de guarda são verdes no "antes", então foram testados contra implementações erradas do próprio fast path:

| Mutação aplicada ao fast path | `expiredWindow…` | `zeroPercentOnMissingFile…` |
|---|---|---|
| `Optional(loadUnlocked(...))` (usa o read model dobrado) | **VERMELHO** (arquivo mantém 45% em vez do 0% reportado) | passa |
| `(row.weeklyUsedPercent ?? 0) == weeklyUsedPercent` (nil tratado como 0) | passa | passa |
| as duas juntas (implementação ingênua) | — | **VERMELHO** (arquivo não é criado; 2 asserções) |

Leitura honesta: a guarda do arquivo ausente só cai na combinação ingênua, porque duas defesas independentes a protegem — `decodeStoredSnapshot` devolve `nil` (não chega à comparação) e `weeklyUsedPercent` é `Double?`, então uma linha nunca sondada (nil) nunca é igual a um `Double` reportado. Ela fica registrada como **guarda de observável** (primeiro record cria o arquivo), **não** como teste vermelho-no-antes. A guarda da janela expirada tem dentes diretos e é o que justifica o decode cru.

### 39.5 Backlog (repriorizado na iter 39)

1. **AppContext P2 restantes**: retry eterno de 0,75 s em falha de escrita de usage (`:5349-5353`); os 4 installers de MCP (`installBotSelfConfigMCP/Browser/Computer/Web`) — não medidos até agora, medir antes de mexer.
2. **Varredura das áreas não auditadas** (inalterado): `AppCommandRouter` (parcial), `PrivateAccountIntegration` (restante), `Sources/Surfaces/` fora dos módulos já vistos, `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila), `Sources/AgentRuntime/` fora dos caminhos já vistos.
3. `BotsWindow` — amplificação de escrita da fila (decisão do dono); `deskRoutingByConversation` sem poda no delete (decisão do dono).
4. P3: `PrivateAccountSessionStore.save/clear`, caminho de Stop do `AgentRunCoordinator`.
5. Demais itens antigos (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 39)

Varrido nesta iteração: `AgentRuntime/TokenSaverUsageStore.swift` — ciclo completo (`load`/`loadUnlocked`/`decodeStoredSnapshot`/`record`/`recordAccountUsage`/`clearAccountUsage`/`save`/`saveUnlocked`/`withExclusiveStoreLock`, codecs e flock cross-process) — e os chamadores no AppShell (`recordTokenSaverAccountUsage`, `clearTokenSaverAccountUsagePercentages`, `refreshPeriodicTokenSaverAccountUsage`, o loop do `AppDelegate`). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila já vistos); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `e60fe65b` | `perf(token-saver): an unchanged account-usage report no longer rewrites usage.json` (39.2) |
| `1220d0b5` | `test(token-saver): pin the no-op account-usage write against folded reads and missing files` (39.4) |

## Iteração 40 — 2026-09-18

Escopo: item #1 do backlog da 39.5 — **retry de gravação de usage de 0,75 s que nunca desiste** (sem backoff, sem teto). Código de produto + 2 specs; nenhuma asserção existente foi alterada.

### 40.1 A evidência (lida no código, não inferida)

`flushPendingTokenSaverUsage` escreve em `backgroundWriterQueue`; quando `TokenSaverUsageStore.record` lança, `completeTokenSaverUsageWrite` apenas reagendava `schedulePendingUsageFlush()` — a **mesma** função do debounce, com o mesmo `tokenSaverUsageDebounceInterval = 0,75 s`. Sem backoff, sem teto, sem desistência: o delta fica em `pendingUsageByRun` (o `persisted` não avança em falha, de propósito), então o app tentava de novo a cada 0,75 s **para sempre** enquanto o store estivesse inescrevível.

- **80 tentativas/min = 4.800/h ≈ 115.200/dia** com o app aberto.
- Cada tentativa paga o caminho inteiro: `withExclusiveStoreLock` (`open` + `fchmod` + `flock(LOCK_EX)` **cross-process**, disputado com o proxy Distill), decode do `usage.json` inteiro, encode, `saveUnlocked` que falha, `close`.
- Cada falha emite `NSLog("RemoteCode Token Saver usage record failed: …")` → 80 linhas de log/min.
- O gatilho existe: o probe de conta roda a cada 60 s desde o launch e o caminho de evento `.accountUsage` usa a mesma função; App Support somente-leitura ou disco cheio deixa o estado durar a sessão toda.

### 40.2 Correção (`551e8bc5`)

`tokenSaverUsageRetryDelay(consecutiveFailures:)` = `min(0,75 × 2^(n−1), 60 s)`, com contador de falhas consecutivas zerado por qualquer escrita bem-sucedida. `schedulePendingUsageFlush(retryAfterFailure:)` aplica o backoff **só** no reagendamento pós-falha; o caminho de evento continua no debounce de 0,75 s (evento novo é tráfego real e coalescido, não timer).

Decisões explícitas:

- **O primeiro retry continua em 0,75 s** — falha transitória isolada se comporta exatamente como antes; a mudança só aparece em falhas consecutivas.
- **O retry nunca desiste**: derrubar o delta pendente seria a única forma de perder linha de usage (`actualProviderTokens`/`eligibleRuns` são o que o `usage.json` acumula), então o teto é de **frequência**, não de tentativas. O fail-loud continua por `NSLog`, agora ≤1×/min.
- Sucesso zera o contador; falha nova depois de um sucesso volta a 0,75 s.

Arquivos: `Sources/AppShell/AppContext.swift` (+49/-4), `Tests/AppShellTests/TokenSaverUsageDebounceTests.swift` (+121).

### 40.3 A/B (mesmo sandbox, mesma máquina)

"Antes" medido com **assinatura nova e corpo antigo**: `git checkout HEAD~1 -- Sources/AppShell/AppContext.swift` + shim em `/tmp` (não versionado) adicionando só a função estática devolvendo a janela de debounce, os dois contadores e o append no ramo de falha — sem backoff e **sem reset no sucesso**. Restaurado com `git checkout HEAD -- …`, `git status` limpo, `grep "A/B shim"` = 0.

| Spec | Antes (corpo antigo + shim) | Depois (`551e8bc5`) |
|---|---|---|
| `test_failedUsageWritesBackOffAndASuccessResetsTheRetryWindow` (funil real: 3 falhas → sucesso → falha nova) | **4 asserções vermelhas**: retry 2 = 0,75 (não 1,5), retry 3 = 0,75 (não 3,0), contador não zera no sucesso (3 ≠ 0), retry pós-sucesso ausente (`-1.0`) | **verde** (0,527 s) |
| `test_usageWriteRetryDelayDoublesAndSaturatesAtTheCap` (0/1/2/3/7/8/1.000 falhas) | **5 asserções vermelhas** (1,5 / 3 / 48 / 60 / 60, todas 0,75) | **verde** (0,000 s) |
| 12 specs pré-existentes da classe (controle negativo do ambiente) | verdes | verdes |
| **Filtro `TokenSaverUsageDebounceTests`** | 14 executados, **9 falhas** (5,445 s) | 14 executados, **0 falhas** (4,598 s) |

Família (`TokenSaverUsageSnapshotTests|TokenSaverAppContextTests|TokenSaverLocalUsageSignalTests|TokenSaverSidebarSnapshotTests|TokenSaverUsageDebounceTests`): **antes 12 falhas → depois 3**. As 3 restantes são **pré-existentes e idênticas nas duas pernas** — `test_itemHostMetadataPublishesDistillAppliedAsAdditiveWireEvent` (casing de UUID vindo do socket), `test_managedDistillCLIUsesLocalMacDistillService` ("unit tests passed with no failures" vs "PASS") e `test_rolloverProtectedCapacityFailsBeforeGraphWritesAndPublishesNothing`, as mesmas da iteração 39. Depois: 142 executados em 40,384 s; antes: 142 em 39,568 s.

**Ganho**: 1,0 tentativa/0,75 s → 1,0/1,5/3/6/12/24/48/60/60… s. Regime permanente: **80× menos** (1/min contra 80/min; 4.800/h → 60/h). Primeiros 10 min de falha contínua: t = 0 · 0,75 · 2,25 · 5,25 · 11,25 · 23,25 · 47,25 · 95,25 · 155,25 + 7×60 → **15 tentativas contra 800** (**53× menos**).

### 40.4 Honestidade da medição

A prova é **determinística**: valores de delay agendados, contador de falhas consecutivas e o delta pendente pousando 1×. Os números 80×/53× são **aritmética sobre o cronograma asseverado**, não um contador de tentativas medido em produção; o spec exercita **uma** escrita falhando, não uma taxa. **Não medido**: com que frequência uma escrita de usage falha de verdade em produção (não há telemetria para isso), RSS, I/O real com App Support inescrevível e wall-clock de uma tentativa falha. Não há claim de performance por wall-clock.

**Crédito do Token Saver**: nada foi reduzido. O delta parado atravessa as falhas e pousa exatamente 1× quando o store volta a aceitar escrita — o spec assevera 200 tokens com `eligibleRuns == 1` **depois** das 4 falhas, e o irmão pré-existente `test_failedWriteRetriesWithoutLosingOrDoubleCountingUsage` (idempotência) segue verde.

Nota de processo: a primeira versão do spec **derrubou a classe** (`Fatal error: Index out of range`) porque o "flush que falha" final não tinha delta novo depois de um sucesso; a rodada foi descartada como inválida, o spec passou a gerar um delta novo e a asserção final usa `dropFirst(...).first ?? -1` em vez de indexar.

### 40.5 Backlog (repriorizado na iter 40)

1. **AppContext P2 restante**: os 4 installers de MCP (`installBotSelfConfigMCP/Browser/Computer/Web`) — não medidos até agora; medir antes de mexer (a 37 mediu o passe de wrappers, que é outro caminho).
2. **Varredura das áreas não auditadas** (inalterado): `AppCommandRouter` (parcial), `PrivateAccountIntegration` (restante), `Sources/Surfaces/` fora dos módulos já vistos, `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila), `Sources/AgentRuntime/` fora dos caminhos já vistos.
3. `BotsWindow` — amplificação de escrita da fila (decisão do dono); `deskRoutingByConversation` sem poda no delete (decisão do dono).
4. P3: `PrivateAccountSessionStore.save/clear`, caminho de Stop do `AgentRunCoordinator`, `reconcilePeriodicGrokMissIfReady` (a outra metade do item #1 da 39.5).
5. Demais itens antigos (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 40)

Varrido nesta iteração: `AppContext` — ciclo completo do flush de usage (`enqueueTokenSaverUsage`, `schedulePendingUsageFlush`, `flushPendingTokenSaverUsage`, `completeTokenSaverUsageWrite`, `finishPendingTokenSaverUsage`, `archiveCompletedUsage`/`archiveCompletedUsageIfSettled`, tombstones) e o merge de `TokenSaverUsageStore.record`. Restam: AppShell — os 4 installers de MCP, `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila já vistos); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `551e8bc5` | `perf(token-saver): a failed usage write backs off instead of retrying every window` (40.2 + 40.3) |

## Iteração 41 — 2026-09-18

Escopo: item #1 do backlog da 40.5 — **os 4 installers de MCP** (`installBotSelfConfigMCP/Browser/Computer/Web`). A medição pedida foi feita primeiro, e foi ela que mostrou onde estava o custo. Código de produto + 3 specs novos; nenhuma asserção existente foi alterada.

### 41.1 A evidência (medida no sandbox isolado, rodada interleaved, fixture de 362 linhas / 9.287 B de `config.toml` + 1.033 B de `settings.json`)

- Os 4 entry points rodam **em sequência** em três caminhos: `tokenSaverAgentEnvironment` (pré-turn, por turno), `subagentTelemetryEnvironment` (por env de subagente) e `reconcileComputerUseMCP` (open). Cada um: lê `~/.claude/settings.json` (`Data` + `JSONSerialization`), checa e lê `~/.codex/config.toml` e **percorre todas as linhas** do TOML (`split` + `trimmingCharacters` por linha) para achar **um** resíduo.
- **3,527 ms por turn-set** (p10 3,406; máx 4,694; 150 amostras) com **4** probes do `config.toml` compartilhado com ChatGPT.app.
- O perfil **não é I/O**: 2 reads mmap dos dois arquivos = **0,026 ms**; um único `range(of:)` sobre o texto de 9 KB = **0,136 ms**. O custo era (a) 4 varreduras de linha completas e (b) as buscas Foundation por resíduo — não os arquivos.
- `tokenSaverAgentEnvironment` é `@MainActor`: isso rodava no main thread, por turno.

### 41.2 Correção (`9aebbccc`)

- `stripManagedBotMCPResidue()` (novo): **um** passe para os 4 resíduos, com o catálogo `ManagedBotMCPResidue` derivado dos 4 `*MCPAdmit` (sem literais duplicados). Os 4 entry points por servidor seguem públicos e viram fachadas de 1 elemento do mesmo caminho (nada de duas implementações).
- `stripClaudeManagedMCP(serverNames:)`: 1 leitura, 1 parse, remove todos os presentes, **no máximo 1 rewrite** (antes: até 4 replaces atômicos com o mesmo conteúdo final).
- `stripCodexManagedMCP(residues:)`: 1 `fileExists` + 1 leitura, um **gate grosso derivado do catálogo** (prefixo comum dos 8 markers e dos 4 nomes de servidor), N remoções em memória, **no máximo 1 rewrite**.
- `removingManagedMCP` ganhou early-out: sem o texto do marker **nem** o *leaf* da tabela no texto, nenhuma das três passadas pode casar → devolve `text` sem varrer linha nenhuma (o caso do turno normal, com config limpo).
- `AppContext`: 12 blocos `do/catch` (4 por call site) viram 3 chamadas de um passe, com o mesmo tratamento de erro e log.

Trade-offs declarados:

1. Se a **escrita** falhar, o passe combinado deixa os 4 resíduos para o próximo turno (antes, 4 escritas separadas podiam aterrissar um subconjunto). Cada escrita é atômica — nunca há arquivo parcial — e o resíduo é retentado no turno seguinte; fail-loud continua no `NSLog`.
2. Os needles do gate **não são literais soltos**: são o prefixo comum calculado a partir do catálogo, então renomear um servidor não "estranda" resíduo (o gate cai para "sempre rodar" se os nomes não compartilharem prefixo).

### 41.3 A/B (mesmo sandbox, mesma máquina, mesma fixture, rodada interleaved, 150 amostras por perna)

"Antes" medido com **corpo antigo + assinatura nova**: `git checkout HEAD~1 -- Sources/AgentRuntime/AgentSkillInstaller.swift` + shim em `Sources/AgentRuntime/` (não versionado) definindo `stripManagedBotMCPResidue()` exatamente como a fiação antiga (as 4 chamadas por servidor). Restaurado com `git checkout HEAD -- …`, shim removido, `git status` limpo.

| Métrica | Antes (HEAD~1 + shim) | Depois (`9aebbccc`) |
|---|---|---|
| Passe por turn-set (mediana) | **3,527 ms** (p10 3,406; máx 4,694) | **0,332 ms** (p10 0,315; máx 0,677) |
| p10 / pior amostra | 3,406 / 4,694 ms | 0,315 / 0,677 ms |
| Probes do `~/.codex/config.toml` por turn-set | **4** | **1** |
| Rewrites atômicos de cada config por turn-set | até 4 | **0** (config limpo) / **1** (com resíduo) |
| Filtro `BotMCPResidueStripTests` (3 specs) | 3 executados, **1 falha** (spec novo) | 3 executados, **0 falhas** (0,016 s) |
| Família MCP (7 classes, 20 specs, mesmo filtro) | 20 executados, **1 falha** | 20 executados, **0 falhas** |

**Ganho: −91% (−3,2 ms por turn-set)** no caminho pré-turn do MainActor, mais −3 probes do arquivo compartilhado com ChatGPT.app. Leitura honesta do número: **3,2 ms é ganho absoluto pequeno**; o que dá escala é a frequência (por turno e por env de subagente) e o fato de estar no main thread. Os 0,332 ms restantes são ~2 buscas `String.contains` (0,13 ms cada) + 2 reads mmap (0,026 ms) — o piso medido do passe já com o gate grosso.

### 41.4 Dentes das guardas novas (mutação, não claim)

Os dois gates introduzidos foram quebrados de propósito (arquivo restaurado depois; nenhuma mutação ficou no branch):

| Mutação | Resultado |
|---|---|
| Gate grosso **sem** a cláusula do prefixo dos nomes (só markers) | `BotMCPResidueStripTests`: **3 specs → 3 falhas** (a tabela sem marker do computer-use e a tabela de header citado do web sobrevivem) |
| Early-out por resíduo **sem** a cláusula do *leaf* | **3 specs → 6 falhas** |

O spec vermelho-no-antes é `test_combinedStripChecksTheSharedCodexConfigOncePerPass` (falha `("4") is greater than ("1")` na perna do antes). Os outros dois são declarados como **igualdade (LEG-2)** — o caminho não deduplicado (os 4 entry points por servidor) continua existindo e é comparado byte a byte com o passe combinado — e **guarda observável**: um segundo passe sobre configs já limpos não muda bytes, mtime nem inode.

### 41.5 Honestidade da medição

- A fixture usa contagem de linhas do arquivo real (`config.toml` do dono: 363 linhas / 16.052 B; fixture: 362 linhas / 9.287 B) e `settings.json` de 1.033 B contra 1.132 B reais. O custo é dominado por linhas/buscas, não por bytes — mas a fixture **não** é o arquivo real.
- **Não medido**: wall-clock do caminho de subagente com AppContext real (medido no installer isolado), RSS, e o custo em disco das escritas evitadas (as escritas só aconteciam com resíduo presente).
- Os 3 specs são determinísticos (contagem de probes, bytes, mtime/inode); o A/B de wall-clock é a única parte sensível a máquina e foi feito em uma rodada interleaved no mesmo processo.

### 41.6 Backlog (repriorizado na iter 41)

1. **`uninstallComputerUseMCP` escreve incondicionalmente** os dois configs compartilhados (`Sources/AgentRuntime/AgentSkillInstaller.swift`, chamado por `reconcileComputerUseMCP` no open): o ramo Claude reescreve `settings.json` sempre que existe uma chave `mcpServers` e o ramo Codex **sempre** substitui `config.toml` atomicamente, mesmo sem marker nenhum para remover (os irmãos `stripClaudeManagedMCP`/`stripCodexManagedMCP` já têm essa guarda). Evidência de campo: o `~/.codex/config.toml` do dono (16 KB, compartilhado com ChatGPT.app) tem só o bloco legado do `installRetrieveMCP` — nenhum marker de computer-use — e é reescrito a cada open. Escopo pequeno (2 guardas, mesmo padrão da iter 39), spec com mtime/inode vermelho-no-antes.
2. **Varredura das áreas não auditadas** (inalterado): `AppCommandRouter` (parcial), `PrivateAccountIntegration` (restante), `Sources/Surfaces/` fora dos módulos já vistos, `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila), `Sources/AgentRuntime/` fora dos caminhos já vistos.
3. `BotsWindow` — amplificação de escrita da fila (decisão do dono); `deskRoutingByConversation` sem poda no delete (decisão do dono).
4. P3: `PrivateAccountSessionStore.save/clear`, caminho de Stop do `AgentRunCoordinator`, `reconcilePeriodicGrokMissIfReady`.
5. Ideia medida e **não** tomada: um carimbo de estado (mtime+size/inode dos dois configs, padrão da iter 37) pularia o passe inteiro no caso estável → ~0,05 ms (`stat` puro) contra 0,332 ms. Exigiria estado em `AppContext` nos 3 call sites e interação com o caminho de open; ganho absoluto de ~0,3 ms por turno — registrado com número para uma iteração futura decidir com dado, não agora.
6. Demais itens antigos (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 41)

Varrido nesta iteração: `AgentSkillInstaller` — os 4 entry points de resíduo de MCP (`installBotSelfConfigMCP/Browser/Computer/Web`), `stripClaudeManagedMCP`, `stripCodexManagedMCP`, `removingManagedMCP`, `removingTOMLTable`/`isExactTOMLTableHeader`, `tomlTableHeader` — e os 3 call sites em `AppContext` (`tokenSaverAgentEnvironment`, `subagentTelemetryEnvironment`, `reconcileComputerUseMCP`), incluindo `uninstallLegacyExternalHostArtifacts` e `uninstallComputerUseMCP` (achado registrado no backlog #1). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados), `PrivateAccountIntegration` (restante das 1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila já vistos); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint, MCP/resíduo e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `9aebbccc` | `perf(agent-runtime): the bot MCP residue pass reads and scans the shared configs once` (41.2 + 41.3 + 41.4) |

## Iteração 42 — 2026-09-18

Escopo: item #1 do backlog da 41.6 — **`uninstallComputerUseMCP` reescrevia os dois configs compartilhados sem ter o que remover**. Ao auditar o caminho, o irmão `uninstallRetrieveMCP` tinha exatamente o mesmo defeito, então a iteração fecha a classe "uninstall legacy reescreve config que não mudou" (2 funções, 4 ramos). Código de produto + 5 specs novos; nenhuma asserção existente foi alterada.

### 42.1 A evidência (lida no código + medida no sandbox; arquivos reais inspecionados read-only)

- Os dois uninstalls rodam no caminho de abertura: `AppContext.init` → `reconcileComputerUseMCP()` → `uninstallComputerUseMCP()`; e `applyTokenSaverLifecycle` → `reconcileManagedDistillSkills` → `uninstallRetrieveMCP()` (Token Saver desligado).
- **Nenhum dos quatro ramos checava se tinha algo para remover**: o ramo Claude reescrevia `~/.claude/settings.json` sempre que existia a chave `mcpServers` (re-serializando com `prettyPrinted`+`sortedKeys`, ou seja **reformatando** um arquivo do Claude Code) e o ramo Codex **sempre** substituía `~/.codex/config.toml` atomicamente, byte a byte, mesmo sem marker.
- Estado real do dono, read-only: `~/.claude/settings.json` (1.132 B) tem `mcpServers` com `slack` e **nenhuma** chave de computer-use, e seus bytes **não** estão na forma canônica → era reformatado a cada abertura. `~/.codex/config.toml` (16.052 B) só tem o bloco legado do retrieve (nenhum marker de computer-use) → era substituído a cada abertura.
- Custo medido (fixture com o formato dos arquivos reais: `settings.json` 715 B, `config.toml` 13.386 B/363 linhas): **0,677 ms por chamada** (p10 0,581) contra **0,040 ms** de piso (2 reads mmap). 0,6 ms de trabalho puro por abertura, mais a janela de lost-update contra o ChatGPT.app/Codex CLI, que escrevem o mesmo arquivo.

### 42.2 Correção (`ac75bdc6` + `a8038b20`)

- `uninstallComputerUseMCP`: o ramo Claude só escreve quando `servers[ComputerUseMCPAdmit.serverName] != nil`; o ramo Codex só escreve quando `removingMarkerBlock` mudou o texto (`guard stripped != text`). São exatamente as guardas que os irmãos `stripClaudeManagedMCP`/`stripCodexManagedMCP` já usavam.
- `uninstallRetrieveMCP`: as mesmas duas guardas (`servers[Self.retrieveMCPName] != nil` e `guard stripped != text`).
- Nada mais muda: quando há resíduo, os bytes escritos são os de antes (mesmo `JSONSerialization`/mesmo texto removido). O que desaparece é a escrita **sem** resíduo.

Trade-off declarado: um arquivo já limpo deixa de ser reformatado. Isso é o ponto, não um efeito colateral: o `settings.json` pertence ao Claude Code e o `config.toml` ao ChatGPT.app; o RemoteCode não deve normalizar formatação de arquivo alheio em que não escreveu nada.

### 42.3 A/B (mesmo sandbox, mesma máquina, mesmo filtro, perna "antes" = installer em `HEAD~1`/`HEAD~2` via `git checkout`)

| Métrica | Antes | Depois |
|---|---|---|
| `uninstallComputerUseMCP` por chamada (mediana, 100 amostras, fixture 13,4 KB) | **0,677 ms** (p10 0,581) | **0,235 ms** (p10 0,229) |
| Inode/mtime dos dois configs após a chamada | **mudam sempre** (substituição atômica) | **inalterados** |
| `ComputerUseMCPUninstallTests` (3 specs) | 3 executados, **9 falhas** | 3 executados, **0 falhas** |
| `RetrieveMCPInstallTests` (7 specs, 2 novos) | 7 executados, **9 falhas** | 7 executados, **0 falhas** |
| `LaunchUserProviderConfigTests` (1 spec, caminho real do `AppContext.init`) | 1 executado, **5 falhas** (settings.json 57 → 92 B + os dois arquivos substituídos) | 1 executado, **0 falhas** (0,206 s) |
| Família MCP (8 classes, 30 specs) | — (não medido no antes; ver nota) | 30 executados, **0 falhas** |

Ganho: **−65% (−0,44 ms) por abertura** e, o que importa mais, **zero reescrita de arquivo alheio** quando não há resíduo (antes: 1 substituição atômica de 16 KB + 1 reformatação de `settings.json` por abertura; hoje: 0). Ganho absoluto pequeno em tempo; o valor está em não tocar arquivo de outro app sem necessidade.

Nota de honestidade: a rodada de família foi medida só no "depois" (30/0); as classes que tocam a mudança foram medidas nas duas pernas (3+7+1 specs). A fixture do probe é menor que o arquivo real (13,4 KB × 16,0 KB, 363 linhas iguais), e o custo da escrita escala com o tamanho — o número do "antes" é **piso**, não teto. **Não medido**: o caminho real de abertura do app empacotado (medido no `AppContext.init` em teste, não no app rodando), RSS e I/O de disco real.

### 42.4 Dentes das guardas novas (mutação, não claim)

Os specs novos atacam as guardas por construção — a perna "antes" é o próprio código sem elas:

| Guarda | Spec que fica vermelho sem ela |
|---|---|
| Claude: só escrever com a chave presente | `test_uninstallComputerUseMCP_leavesCleanSharedConfigsUntouched` (bytes 55 → 90 no retrieve, 57 → 92 no launch), `test_uninstallRetrieveMCP_leavesCleanSharedConfigsUntouched` |
| Codex: só escrever quando o marker block sai | `test_uninstallComputerUseMCP_leavesCleanSharedConfigsUntouched` (inode/mtime do `config.toml` mudam), `test_uninstallRetrieveMCP_secondPassLeavesAlreadyCleanedConfigsUntouched` |

`test_uninstallComputerUseMCP_removesTheLegacyEntryAndKeepsUserContent` é a **guarda de comportamento** (verde nas duas pernas): com resíduo presente, a entrada legacy sai e o conteúdo do usuário fica — é ela que impede a "correção" de virar um no-op.

### 42.5 Backlog (repriorizado na iter 42)

1. **Varredura das áreas não auditadas** (agora o topo): `AppCommandRouter` (parcial), `PrivateAccountIntegration` (restante das 1,8k), `Sources/Surfaces/` fora dos módulos já vistos, `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila), `Sources/AgentRuntime/` fora dos caminhos já vistos.
2. `reconcilePeriodicGrokMissIfReady` (prioridade (a) do prompt, ainda não auditado).
3. `BotsWindow` — amplificação de escrita da fila (decisão do dono); `deskRoutingByConversation` sem poda no delete (decisão do dono).
4. P3: `PrivateAccountSessionStore.save/clear`, caminho de Stop do `AgentRunCoordinator`.
5. Ideia medida e **não** tomada (iter 41.6 #5, mantida): carimbo de estado dos dois configs pularia o passe de resíduo inteiro (~0,05 ms contra 0,332 ms) — exigiria estado em `AppContext`.
6. Demais itens antigos (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL (decisão do dono); Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `command_receipts` sem prune (decisão do dono); `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget` (decisão do dono); EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Áreas ainda não varridas (atualizado na iter 42)

Varrido nesta iteração: `AgentSkillInstaller` — `uninstallComputerUseMCP`, `uninstallRetrieveMCP`, `installRetrieveMCP`/`installCodexRetrieveMCP`, `removingMarkerBlock`/`upsertMarkerBlock`, `uninstallLegacyExternalHostArtifacts` — e o caminho de abertura em `AppContext` (`init` → `reconcileComputerUseMCP`; `applyTokenSaverLifecycle` → `reconcileManagedDistillSkills` → uninstalls). Restam: AppShell — `AppCommandRouter` (9,1k, parcial), `PrivateAccountIntegration` (1,8k); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed); `Sources/Persistence/` (`Schema`, `TokenSaverT003Persistence`, `BotRemoteControlAuthority` fora do delete e dos pontos de fila); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint, MCP/resíduo/uninstalls e dos itens já vistos).

### Commits da iteração

| Commit | Item |
|---|---|
| `ac75bdc6` | `fix(agent-runtime): the legacy computer-use uninstall no longer rewrites untouched configs` (42.2 + 42.3) |
| `a8038b20` | `fix(agent-runtime): the legacy librarian uninstall no longer rewrites untouched configs` (42.2 + 42.3) |
| `5ca8c164` | `test(app-shell): the launch reconcile leaves clean user provider configs alone` (42.3 + 42.4) |

## Iteração 43 — 2026-09-18

Escopo: prioridade (c) do prompt — o P3 registrado `PrivateAccountSessionStore.save/clear` — fechando junto a varredura restante de `PrivateAccountIntegration` (o `PrivateNotificationBridge` inteiro, lido na íntegra) e o item (b) `reconcilePeriodicGrokMissIfReady`. Método: `/sam-goal` + `/sam-task` (um item de valor + varredura, sem unidades independentes que justifiquem workers). `origin/production` não avançou (`git log HEAD..origin/production` vazio no início da iteração) → sem merge e sem rebaseline.

### 43.1 Item (b) — `reconcilePeriodicGrokMissIfReady` (`AppContext:3349`): varrido, **sem achado** (já coberto por spec)

- A guarda fecha as cinco condições do ciclo: id igual (`:3351`), `grokFinished`, `!grokSucceeded`, `otherProvidersSucceeded`, `!reconciledMiss` (`:3350-3356`).
- Os dois lados chamam o reconcile: o término do refresh dos outros providers (`:3319-3324`, no mesmo bloco MainActor que carimba `otherProvidersFinished` e só quando o id do ciclo ainda é aquele) e o término da task coalescida do Grok (`:3464-3469`) — quem termina por último destrava o clear, então o miss não fica pendurado dentro do ciclo.
- O clear em si delega a `TokenSaverUsageStore.providersToClearAfterPartialAccountUsageRefresh` (`TokenSaverUsageStore:455`), que **não** limpa com janela semanal viva (`weeklyResetsAt > now`, `:465-468`) e é chamado com `managed: [.grok]`.
- Um probe obsoleto não escreve no ciclo: a checagem de geração (`:3438`) vem antes de qualquer mutação, e o `defer` (`:3433-3437`) só limpa o campo da própria task.
- `reconciledMiss` (`:3365`) garante no máximo um clear por ciclo; um ciclo novo zera os três flags (`:3336-3342`).
- Cobertura: `TokenSaverAppContextTests.test_periodicCycleSurvivesSecondTickWhileFullRefreshIsStillBusy` (`:1143`) exercita exatamente Grok-miss + full-refresh-ok → `weeklyUsedPercent` do Grok vai a 0, inclusive com um tick no meio; e `test_periodicAccountUsageRunsOneGrokProbeAndCoalescesAnOverlappingTick` (`:1121`) trava o probe único por ciclo. O predicado puro tem specs em `TokenSaverUsageSnapshotTests:85/105`.
- Nuance registrada (não é defeito, e nenhuma mudança feita): `otherProvidersSucceeded` não é zerado quando uma segunda passada dos outros providers começa no mesmo ciclo (só `otherProvidersFinished`, `:3251-3254`), então um `true` da passada anterior pode admitir o clear. Continua sendo "outro provider provou conectividade neste ciclo" — o mesmo clear teria acontecido antes se o miss do Grok tivesse chegado primeiro.

### 43.2 Varredura de `PrivateAccountIntegration` (restante das 1,8k): o `PrivateNotificationBridge` inteiro, sem achado

| Ponto | Veredito | Evidência |
|---|---|---|
| `deliver(_:)` (`:1253`) | **ok** | guarda sessão/assinatura/alvo antes de qualquer rede; `sessionRefresher.perform` faz 1 refresh em 401 e re-tenta 1×; falha de alerta ainda tenta o wake silencioso com `force: true` (`:1285-1293`) em vez de desistir |
| `deliverSilentCatchUp` (`:1355`) | **ok** | bucket por classe de 30 s decidido sob `NSLock` com check+set no mesmo lock (dois desfechos concorrentes não enviam dois); o bucket é consumido antes do envio, então uma falha não re-envia na mesma janela — é o contrato "≤1 wake por classe/30 s", com o outbox durável cobrindo o retry |
| `performSilentCatchUpDelivery` (`:1454`) | **ok** | mantém a idempotency key original e re-lança `notDelivered` em vez de inventar sucesso (`:1483-1490`) |
| `sendLiveActivityAcceptance` (`:1657`) | **ok** | failover para `push_to_start` com key `.dismiss-reopen` quando o token de `activity_update` morre (`:1702-1736`); o prune roda protegido **antes** da invalidação terminal (`:1739-1757`) |
| `acceptanceTargets` (`:1596`) | **ok** | fallback em 4 degraus documentado; `newest` resolve empate por ordem de upsert numa passada, sem array temporário (`:1626-1633`) |
| `isLiveActivityUpdateChannelArmed` (`:1218`) | **ok** | `try? records()` falho → canal não armado → o alerta visível é entregue (fail-visible), não silencioso |

Nada corrigido aqui: nenhum desses pontos engole falha com superfície de usuário, e os `catch` que existem ou re-lançam ou são de caminho de push sem superfície local.

### 43.3 Correção (P3) — a sessão que não persistia pintava "Subscription active" e sumia no relogin

- **Antes**: `PrivateAccountSessionStore.save/clear` faziam `catch { return }` — sem valor de retorno, sem log. `SettingsViewModel.connectPrivateAccount` chamava `save` e, na linha seguinte, limpava a senha e pintava "Subscription active"; `refreshPrivateAccount` gravava o refresh token **rotacionado** e, se a escrita falhasse, deixava em disco o token que o servidor acabou de consumir. `load()` (e portanto o router, o push e o usage) leem sempre das settings: a sessão "logada" não existia para ninguém.
- **Depois**: `save`/`clear` devolvem `Bool` (`@discardableResult`) e logam a falha; o login e o refresh rotacionado usam `guard … save(…) else` e reportam `"Signed in, but the session could not be saved"` (novo status, incluído em `signInFailureStatuses` e com hint próprio: "This Mac could not save the session to disk…"), sem pintar painel assinado e mantendo a senha para retry.
- Arquivos: `Sources/AppShell/PrivateAccountIntegration.swift` (`save`/`clear` + logger), `Sources/AppShell/SettingsWindow.swift` (status, guarda nos 2 escritores, hint), `Tests/AppShellTests/AppIdentityNotificationTests.swift` (3 specs).

### 43.4 A/B (mesmo filtro `PrivateAccount`, mesmo sandbox, mesma máquina; "antes" = corpos antigos com a assinatura nova — a API antiga não compila contra os specs novos, como na 22.1)

| Rodada | Executados | Falhas |
|---|---|---|
| Antes (`save`/`clear` engolindo + os 2 escritores sem guarda) | 9 | **8** (4 no login, 2 no refresh, 2 no store) |
| Depois | 9 | **0** |

Specs medidos, nome a nome — nas duas pernas: `testPrivateAccountLoginReportsAnUnwritableSessionInsteadOfSuccess`, `testPrivateAccountRefreshReportsAnUnwritableRotatedSession`, `testPrivateAccountSessionStoreReportsWriteFailuresInsteadOfSilence` (vermelhas no antes, verdes no depois) e, verdes nas duas, `testPrivateAccountLoginIsOptionalAndPersistsSessionForBackendPush`, `testPrivateAccountRefreshUsesRefreshTokenBeforeDroppingOptionalSession`, `testDisconnectPrivateAccountLogsOutWithoutRevokingLocalPairing`, `testSamePrivateAccountPairingAutoApprovesWithoutMacPrompt`, `HTTPPairingTests.test_pairRequestPassesPrivateAccountTokenToAuthProvider`, `SidebarRefreshPerfGuardTests.test_reload_doesNotRedecodeUnchangedPrivateAccount`.

### 43.5 Dentes (mutação = a própria perna "antes")

| Guarda | Spec vermelho sem ela |
|---|---|
| `save` devolve se a escrita pousou | `testPrivateAccountSessionStoreReportsWriteFailuresInsteadOfSilence` (2 asserções), `testPrivateAccountLoginReportsAnUnwritableSessionInsteadOfSuccess` |
| login só pinta sucesso com sessão gravada | `testPrivateAccountLoginReportsAnUnwritableSessionInsteadOfSuccess` (4 asserções: user não-nil, status "Subscription active", fora do `signInFailureStatuses`, senha limpa) |
| refresh rotacionado idem | `testPrivateAccountRefreshReportsAnUnwritableRotatedSession` (2 asserções) |

Anti-vacuidade (o verde não pode vir de fixture saudável nem de login que nunca rodou): cada spec asserta o caminho exercitado — probe `set` que **precisa** lançar depois do bloqueio, `save` inicial que precisa devolver `true`, `load()` não-nil antes do bloqueio, e `api.loginRequests`/`api.refreshRequests` provando que o backend respondeu. A fixture bloqueia a escrita com os dois triggers SQLite (`fail_settings_insert`/`fail_settings_update`, helper `blockSettingsWrites` da 22.1) — leitura continua funcionando, ao contrário de um `DROP TABLE`.

### 43.6 Baseline da classe

`AppIdentityNotificationTests` inteira no "depois": **46 executados, 4 falhas** — as duas pré-existentes/flaky sob carga já registradas na 22.1 (`testAgentRunLifecycleEventsCarryAuthoritativeRunTiming` e `testStreamingErrorsDoNotEmitTerminalRunNotificationsBeforeFinish`, 2 asserções cada; são timeouts de 6 s esperando eventos de run). Nenhuma outra falha na classe.

Rodada de família (os outros consumidores do store, mesmo sandbox, só o "depois"): `LiveActivitySyncCoordinatorTests` + `SilentWakeOutboxTests` = **63 executados, 0 falhas** (51 + 12) — idêntico ao baseline verde da 22.1 para essas classes; a perna "antes" não foi rodada aqui porque a mudança é assinatura-compatível (`@discardableResult`) e o caminho medido do A/B é o filtro `PrivateAccount`.

### 43.7 Escopo declarado como não tocado

- `disconnectPrivateAccount` e os três pontos do `PrivatePushSessionRefresher` (`clear`, `save`, `clear`, `:1119/:1143/:1148`) descartam o `Bool`: são caminhos sem superfície de usuário e o store agora loga a falha. Falha de `clear` no disconnect deixa a sessão legível — o próximo `reload()`/reabertura mostra a conta de volta (observável); o P3 registrado era o `save` do login.
- `clear()` continua gravando `""` (não `DELETE`), como antes: nenhuma mudança de formato de dado.

### Áreas ainda não varridas (atualizado na iter 43)

Varrido nesta iteração: `PrivateAccountIntegration` inteiro (o restante que faltava: `PrivateNotificationBridge` — entrega de alerta/wake silencioso/outbox durável/Live Activity v2/acceptance targets — e os 2 escritores de sessão do `SettingsViewModel`) + `reconcilePeriodicGrokMissIfReady` (item (b), sem achado). Restam: AppShell — `AppCommandRouter` (9,1k, parcial: só os pontos citados nas iters 11/12/16), `AppContext` (6,3k, parcial: os pontos já citados); `Sources/Surfaces/` (fora de AgentApp/Browser/Terminal/SSH/Files/PaneTabs/Feed — p.ex. `DiffPanelSurface` 2,2k, `AgentChatUXPresentation` 1,6k, `SubagentActivity` 1,3k, `ANSIRenderer` 865); `Sources/Persistence/` (`Schema` 1,8k, `TokenSaverT003Persistence` 3,0k, `BotRemoteControlAuthority` 3,6k fora do delete); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint, MCP/resíduo/uninstalls e dos itens já vistos).

### Backlog (repriorizado na iter 43)

1. **Varredura das áreas não auditadas** (agora o topo de novo): `AppCommandRouter` (parcial), resto de `Surfaces/`, `Persistence/Schema` + `TokenSaverT003Persistence` + `BotRemoteControlAuthority` (fora do delete), resto de `AgentRuntime/`.
2. P3 restante: caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
3. Decisões do dono em aberto (não bloqueiam a varredura): transcript do undo, retenção por idade de `agent_turn_checkpoints`, `lfs --skip-smudge`, limite/TTL das sessões de edição, retenção de `command_receipts`, caminho de Stop do coordinator, poda de `deskRoutingByConversation` no delete, escrita incremental da fila × semântica multi-janela.
4. Ideia medida e **não** tomada (iter 41.6 #5, mantida): carimbo de estado dos dois configs de provider pularia o passe de resíduo inteiro (~0,05 ms contra 0,332 ms) — exigiria estado em `AppContext`.
5. Demais itens antigos (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL; Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `provider_pending_callbacks`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget`; EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Commits da iteração

| Commit | Item |
|---|---|
| `d6d8f5ff` | `fix(shell): report a private-account session that could not be written` (43.3) |
| `9276669e` | `test(shell): lock the private-account session to a real settings-write failure` (43.4 + 43.5) |

## Iteração 44 — 2026-09-18

### 44.1 Varredura (cobertura registrada nesta iteração)

| Ponto varrido | Veredito |
|---|---|
| `Surfaces/DiffPanelSurface.swift` (2.218) | **sem achado** |
| `Surfaces/AgentChatUXPresentation.swift` (1.623) | **sem achado** |
| `Surfaces/SubagentActivity.swift` (1.281) | **sem achado** |
| `Surfaces/ANSIRenderer.swift` (865) | **sem achado** |
| `Persistence/Schema.swift` (1.831) | **sem achado** |
| `Persistence/TokenSaverT003Persistence.swift` (3.013) | **sem achado** |
| `Persistence/BotRemoteControlAuthority.swift` (fora do delete) | **achado** (44.2) |

- `DiffPanelSurface`: `runAction` pinta `lastError`/`lastErrorRaw` em toda falha de git (o cabeçalho do método diz isso e o corpo cumpre); o rebuild do diff é generation-guarded (`styledDiffGen`, com o `selectFile(nil)` bumpando a geração para não deixar patch velho sobrescrever o clear); `cwd` só é escrito no `init` (`:378`) e nenhum caminho re-aponta o painel, então não existe summary de repo antigo pousando sobre o novo; o watcher FSEvents tem `stopFSWatcher` + `deinit` liberando o `passRetained`. Duas observações registradas sem mudança: (a) `reloadAll()` faz no-op silencioso enquanto `isLoading` (`:549`) — o spinner visível reconhece o clique, então não é "nada acontece"; (b) `GitDiff.log/summary/branches` devolvem vazio quando o comando git falha, o que pinta "sem mudanças/sem commits" numa falha dura de git — é comportamento da camada `GitDiff` inteira (não do painel) e mudar o retorno exige mexer na assinatura do `GitClient`: decisão do dono, registrada no backlog.
- `AgentChatUXPresentation`: helpers puros de parsing/formatação. Os `try? JSONSerialization` são parse fail-soft onde `nil` significa "não há diff para sintetizar" e o chamador cai no texto cru; `normalizedFinalTextsMatch` é heurística de reparo de ordem limitada a mensagens que pintam **acima** do seu turno; `try!` são regexes literais estáticas.
- `SubagentActivity`: `project`/`belongsToThreadScope` montam `Dictionary(uniqueKeysWithValues:)` sobre `activityReceipts`, que deduplica por id (`latestByID` + `keptIDs` em `AgentOrchestrationRuntime:909-938`) e guarda o append de ancestral fora da janela com `contains` (`:2452`) — sem trap de id duplicado. `mapPhase` não inventa sucesso por ausência. O cache do badge (`:655`/`:667`) usa assinatura (count, maxID) de um ledger append-only, então atualização de lifecycle sempre muda o count — sem badge preso.
- `ANSIRenderer`: sem `catch`, `try?` ou timer.
- `Schema`: nenhum `catch`/`try?`; `migrateSteps` aplica cada passo em transação e re-lança (passo que falha não deixa schema nem `schema_meta` meio aplicado) e finaliza o statement da versão antes de rebuild de tabela.
- `TokenSaverT003Persistence`: os `catch` são de `BatchAbort`/`FinalizeAbort` (re-lançam com rollback) e o `_ = try? store.discardAbandoned` (`:1378`) é compensação dentro de um caminho que lança o erro real de qualquer forma (objeto órfão limitado pela retenção).
- `BotRemoteControlAuthority` fora do delete: **achado (44.2)**. Lidos sem achado: `queueUpdate`/`queueReorder`/`queueRemove` (escrita que falha lança para o chamador e o receipt não alega sucesso), `persistSidecar` (devolve as chaves que falharam), `pruneDeletedBotHomes`, `loadSidecar`. Observação registrada sem mudança: o rollback do `queueForceNow` (`:1186`) é `try?` — se a reescrita da ordem falhar depois de um force recusado, o item fica no topo mesmo com o RPC devolvendo erro; só manifesta em falha de escrita SQLite e o efeito é de ordenação.

### 44.2 Correção (P3) — a migração da fila legacy apagava a única cópia das linhas que o store recusou

- **Antes**: `migrateSidecarQueueIfNeeded` (`:3478-3503`) engolia três falhas e depois limpava a chave `bot.remote.queue` inteira: `(try? store.get(id:))?.deletedAt == nil else { continue }` tratava **leitura falha** como "bot deletado" (linhas do bot descartadas); `((try? store.listQueuedFollowUps(...)) ?? []).isEmpty == false` tratava **leitura falha** como "fila vazia" (e ainda podia duplicar linhas); `_ = try? store.enqueueQueuedFollowUp(...)` descartava a **escrita que falhou**. A chave era então zerada incondicionalmente. Essa chave é a única cópia da fila que precede `bot_queued_follow_ups`: disco cheio/`SQLITE_BUSY`/banco travado na abertura apagavam os follow-ups pendentes do usuário sem erro, sem log e sem retry.
- **Depois**: cada linha só sai do sidecar quando o store aceitou. Leitura do bot que falha → linhas mantidas; leitura da fila que falha → linhas mantidas (sem re-enqueue, para não duplicar); insert que falha → linha volta para o sidecar com log (`io.remotecode.persistence` / `bot-sidecar-queue-migration`, seguindo `Bootstrap.swift`). Bot deletado continua com as linhas descartadas (comportamento antigo) e fila já migrada continua com as linhas descartadas.
- Arquivos: `Sources/Persistence/BotRemoteControlAuthority.swift` (`migrateSidecarQueueIfNeeded` + `sidecarQueueLog`), `Tests/PersistenceTests/BotRemoteControlAuthorityTests.swift` (2 specs + 2 helpers).

### 44.3 A/B (mesmo sandbox, mesma máquina; "antes" = corpo antigo com os specs novos — a API não mudou, então nada precisou de assinatura nova)

| Rodada | Executados | Falhas |
|---|---|---|
| Antes (`try?` nos três ramos + chave zerada) | 2 | **1** |
| Depois | 2 | **0** |

| Classe inteira | Executados | Falhas |
|---|---|---|
| Antes | 85 | **1** (só o spec novo) |
| Depois | 85 | **0** |

Specs nome a nome: `test_legacyQueueMigrationKeepsRowsTheStoreRefused` — vermelho no antes (`("nil") is not equal to ("Optional(["first pending", "second pending"]))"`), verde no depois; `test_legacyQueueMigrationMovesRowsAndClearsTheKeyOnceTheyLand` — **verde nas duas pernas** (declaração LEG-2: o caminho sem falha continua idêntico — mesmas chamadas de enqueue, mesma limpeza da chave quando tudo pousou; nenhuma linha é deduplicada nesse caminho). Nenhuma falha pré-existente na classe.

### 44.4 Dentes (mutação = a própria perna "antes")

| Guarda | Spec vermelho sem ela |
|---|---|
| linha recusada pelo store fica no sidecar | `test_legacyQueueMigrationKeepsRowsTheStoreRefused` |
| leitura falha ≠ "bot deletado" | idem (o corpo antigo engolia os três ramos; a perna "antes" exercita a leitura que falha, o insert que falha e a chave zerada) |

Anti-vacuidade: a fixture injeta um trigger SQLite (`BEFORE INSERT ON bot_queued_follow_ups`) e semeia a chave real (`INSERT INTO settings … 'bot.remote.queue'`), ou seja, o caminho exercitado é o do `init` da autoridade — o mesmo da abertura do app. O spec de linhas retidas asserta **também** que as linhas do bot deletado sumiram: isso só acontece se a migração realmente rodou e chegou naquele bot, então ele não pode passar vazio. O spec do caminho feliz prova que a fixture semeia e lê a chave de verdade (linhas aparecem no `bot.queue.list` **e** a chave é limpa).

### 44.5 Áreas ainda não varridas (atualizado na iter 44)

Varrido nesta iteração: os 4 arquivos restantes declarados de `Sources/Surfaces/` (`DiffPanelSurface`, `AgentChatUXPresentation`, `SubagentActivity`, `ANSIRenderer`), `Persistence/Schema`, `Persistence/TokenSaverT003Persistence` e `Persistence/BotRemoteControlAuthority` inteiro (delete + fila + sidecar). Restam: `AppShell` — `AppCommandRouter` (9,1k, parcial: só os pontos citados nas iters 11/12/16/23), `AppContext` (6,3k, parcial); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint, MCP/resíduo/uninstalls, receipts de orquestração e dos itens já vistos).

### 44.6 Backlog (repriorizado na iter 44)

1. **Varredura do que falta** (topo): `AppCommandRouter` (parcial — 9,1k com só os pontos citados), resto de `AppContext`, resto de `AgentRuntime/`.
2. P3 novo: `queueForceNow` (`BotRemoteControlAuthority:1186`) — rollback `try?` da ordem quando o force é recusado.
3. P3 restante: caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
4. Decisões do dono em aberto (não bloqueiam a varredura): transcript do undo, retenção por idade de `agent_turn_checkpoints`, `lfs --skip-smudge`, limite/TTL das sessões de edição, retenção de `command_receipts`, caminho de Stop do coordinator, poda de `deskRoutingByConversation` no delete, escrita incremental da fila × semântica multi-janela, **`GitDiff` devolvendo vazio em falha dura de git** (pinta "sem mudanças/sem commits"), `reloadAll()` no-op durante `isLoading`.
5. Ideia medida e **não** tomada (iter 41.6 #5, mantida): carimbo de estado dos dois configs de provider pularia o passe de resíduo inteiro (~0,05 ms contra 0,332 ms) — exigiria estado em `AppContext`.
6. Demais itens antigos (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL; Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; `provider_pending_callbacks` (um callback com payload indecifrável é pulado sem log em `AppCommandRouter.listPendingCallbacks:201/216` → um pedido de aprovação pendente some da superfície); índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget`; EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Commits da iteração

| Commit | Item |
|---|---|
| `33d3e01d` | `fix(bots): the legacy queue migration no longer erases rows the store refused` (44.2) |
| `87a72199` | `test(bots): lock the legacy queue migration to a real write failure` (44.3 + 44.4) |

## Iteração 45 — 2026-09-18

### 45.1 Varredura (cobertura registrada nesta iteração)

| Ponto varrido | Veredito |
|---|---|
| `AppContext` — escritas do ledger Graphify (`processGraphifyBuffer`, `:6113-6145` e `:6210`) | **achado** (45.2, corrigido) |
| `AppCommandRouter` — SSH hosts (`sshHostList/Upsert/Delete/Connect`, `:2240-2290`, `readSSHHosts` `:8441`) | **achado** (45.4, corrigido) |
| `AppContext` — handler de evento do provider, `provider_pending_callbacks` (`:1505/:1523/:1530/:1564`) | **achado** (45.6 #2, registrado) |
| `AppCommandRouter` — `listPendingCallbacks` (`:198/:201/:216`) e o gêmeo `listAgentPendingCallbacks` (`:5950/:5953/:5961`) | **achado** (45.6 #1, registrado) |
| `AppCommandRouter` — `filesStateGet/Update` + `filesEdit*` (`:8074-8170`) | **sem achado**: delegações `try` (erro sobe até o RPC); nada de `try?` em escrita |
| `AppCommandRouter` — `readSSHHosts/writeSSHHosts` fora do decode (segredo no Keychain, `password` nunca volta no blob) | **sem achado** |
| `AppCommandRouter` — `makeSurface` catch final (`:8388`) | observação (45.6 #3) |
| `AppCommandRouter` — `reconcileBotBrowserActions` (`:7490`) + `persistBotBrowserNavigation` (`:7472`) | **sem achado**: `takePendingActions()` que falha → nada drenado nesta passada (as ações continuam pendentes para a próxima), `writeActionResult` que falha só perde o recibo |
| `AppContext` — `markOpenStale` no boot (`:1256`) + as 4 escritas de sessão/uso Graphify fora do ledger | **sem achado** |
| `AgentRuntime/TokenSaverModelInstaller.modelArtifactsPresent` (`:258`) | **sem achado**: listing que falha → `false` = "não instalado" → reinstala; direção fail-safe, não apaga nada |
| `AgentRuntime/AgentSkillInstaller` candidatos de wrapper (`:1517`) | observação: listing de diretório que falha encolhe o conjunto de candidatos em silêncio (menos wrappers, menos savings) — não é perda de dado; registrado, não corrigido |

### 45.2 Correção 1 (P2) — o crédito Graphify sumia quando a linha pendente não era gravada

- **Antes**: `signalCount`/`answerTokensSum` contam só linhas `ok = 1` de `query|path|explain` (`Persistence/GraphifyUsage.swift:127/:145`) e essas linhas vêm de duas escritas `try?`: o insert pendente (`ok = 0`) e o `markSucceeded` que flipa para `ok = 1`. Disco cheio/`SQLITE_BUSY`/I/O error em qualquer uma delas deixava a resposta **entregue** fora da contagem: `signalCount` caía (possivelmente a 0 → leg 0 pela regra "sem sinais → 0") e **o Estimated save diminuía** — a direção proibida pela regra mais dura do repo. O `markSucceeded` também não tinha como saber que o UPDATE casou zero linhas.
- **Depois**: `markSucceeded` devolve se existe linha contada para o item; o insert pendente e o flip reportam falha (`io.remotecode.agent` / `graphify-usage`); quando o UPDATE não casa nada, o caminho de sucesso **regrava a resposta entregue** (`insert` com `ok: true`, mesma chave de dedupe `(run_id,item_id,subcommand)`, então é idempotente) em vez de descartar o sinal. Os subcomandos ficam no `GraphifyItemBuffer` porque o sucesso roda numa chamada posterior de `processGraphifyBuffer` (a versão local não sobrevivia à chamada — medido, ver 45.3).
- Arquivos: `Sources/Persistence/GraphifyUsage.swift` (`markSucceeded` → `Bool`), `Sources/AppShell/AppContext.swift` (`pendingInvocationSubcommands` no buffer, `do/catch` + log nas 3 escritas, recuperação no sucesso), `Tests/AppShellTests/TokenSaverLocalUsageSignalTests.swift` (2 specs).

### 45.3 A/B #1 (mesmo sandbox, mesma máquina; "antes" = corpos antigos, mesmos specs — os specs não chamam `markSucceeded` direto, então a assinatura antiga compila)

| Rodada | Executados | Falhas |
|---|---|---|
| Antes | 22 | **2** (só o spec novo) |
| Depois | 22 | **0** |

Specs nome a nome: `test_graphifyUsageCreditsAnswerWhosePendingInsertFailed` — vermelho no antes nas duas asserções (`signalCount` 0 e `answerTokensSum` 0), verde no depois; `test_graphifyUsageCreditsOnceWhenThePendingInsertLanded` — **verde nas duas pernas** (LEG-2: o caminho em que a linha pendente pousa continua idêntico — uma linha, sem insert de recuperação). Classe `GraphifyUsageRepositoryTests` no "depois": **6 executados, 0 falhas** (a mudança de assinatura do repositório não quebrou o consumidor de teste). Nenhuma falha pré-existente nesta classe.

### 45.4 Correção 2 (P2) — a edição de host SSH apagava a lista que não conseguia ler

- **Antes**: `readSSHHosts` (`AppCommandRouter:8441`) devolvia `[]` quando o payload de `ssh.hosts.<workspace>` não decodificava (`(try? decode) ?? []`). Como `sshHostUpsert` e `sshHostDelete` **reescrevem o array inteiro a partir do que leram**, o próximo "adicionar host" substituía todos os hosts salvos pelo novo e "apagar host" gravava lista vazia — levando junto a senha do Keychain (`sshPasswordStore.delete(account:)` roda antes do write). É exatamente a doutrina "leitura que falhou não é prova de vazio" no caso destrutivo.
- **Depois**: payload ilegível **lança** (`JSONRPCError.internalError`) — a edição é recusada e os bytes ficam intactos para reparo; `SSHSurface.reloadHosts` já envolvvia a leitura em `do/catch` e mostra `viewModel.error`, então a superfície passa a reportar em vez de pintar lista vazia.
- Arquivos: `Sources/AppShell/AppCommandRouter.swift` (`readSSHHosts`), `Tests/AppShellTests/PaneActionTests.swift` (2 specs).

### 45.5 A/B #2 (mesmo filtro `PaneActionTests`, mesma máquina; "antes" = corpo antigo do `readSSHHosts`, specs novos)

| Rodada | Executados | Falhas |
|---|---|---|
| Antes | 68 | **8** (5 do spec novo + 3 pré-existentes/flaky) |
| Depois | 68 | **5** (só as pré-existentes/flaky) |

Specs nome a nome: `test_sshHostCommandsRefuseToEraseHostsTheyCannotRead` — **5 asserções vermelhas no antes**, com a prova no próprio output: o blob gravado virou `[{"id":"2FEE…","label":"New Host",…}]`, ou seja os dois hosts armazenados (incluindo o legível "Keep Me") foram **apagados** pelo upsert, o delete gravou o mesmo blob de um host só e a senha do Keychain do host alvo foi removida; verde no depois (bytes intactos + senha preservada). `test_sshHostCommandsStillRoundTripAReadableList` — **verde nas duas pernas** (LEG-2: append mantém os hosts existentes, delete remove só o alvo e ainda apaga a senha do alvo, que é o comportamento antigo). Falhas pré-existentes nas duas pernas: `test_sidebarSeamStaysSeamlessAndExactAcrossToggleCycle_becauseDriftDrewAStrayLine` (3 asserções), `test_terminalBusyRuntimeRefreshUpdatesTabSpinnerWithoutRebuildingPane` (2) e `test_collapsedSidebarToggleRestoresUsableWidth_becauseZeroWidthLeavesNoEscape` (aparece em 2 das 3 rodadas — **flaky sob carga**, é geometria de sidebar com timers), todas de layout/terminal e nenhuma tocando SSH ou Graphify.

### 45.6 Achados registrados sem correção (novos, com arquivo:linha)

1. **`provider_pending_callbacks` ilegível some da superfície — `AppCommandRouter.swift:198`, `:201`, `:216`** (e o gêmeo `listAgentPendingCallbacks` `:5950`, `:5953`, `:5961`): payload que não decodifica (ou que não é UTF-8) é pulado com `continue`, sem log. A linha existe no banco, mas o snapshot — que é o que o iOS e o `PetAttentionStore` hidratam — não a mostra: um pedido de aprovação pendente fica invisível para o device pareado enquanto o run espera. O mapeador de linha ainda normaliza `payload_json` NULL para `"{}"` (`Repositories.swift:9148`), que também não decodifica → mesmo skip. Correção mínima: reportar o skip (log) e nunca tratar "não decodificou" como "não existe" (é a mesma doutrina de "fila ilegível não decide cancelamento do drain waiter"). **Candidato nº 1 da próxima iteração.**
2. **As 4 mutações de `provider_pending_callbacks` no handler de evento são `try?` — `AppContext.swift:1505`, `:1523`, `:1530`, `:1564`**: `record` que falha deixa a aprovação só no event bus ao vivo (a superfície macOS lê o stream; o iOS lê a tabela) e `resolve` que falha deixa um pedido já resolvido reaparecendo como pendente no próximo hydrate. Correção mínima: reportar a falha (o caminho é consumidor de stream, então não dá para lançar) — mesmo padrão da 45.2.
3. **`makeSurface` catch final — `AppCommandRouter.swift:8388`**: `catch { return descriptor }` devolve o descriptor pedido sem registrar surface nenhuma; o chamador trata como criada. Sem repro de superfície encontrado (falha de construção é rara) — observação.
4. **`AgentSkillInstaller.swift:1517`**: `contentsOfDirectory` que falha → aquela pasta não contribui candidatos de wrapper, em silêncio (menos wrappers instalados, menos savings). Sem perda de dado; observação.
5. **`queueForceNow` (`BotRemoteControlAuthority:1186`)** — segue aberto da 44.5: o rollback da ordem é `try?`, e escrever estado de ordenação não tem como "desfazer" um write bloqueado; só resta reportar. Valor baixo (ordem visível e reordenável pelo usuário).

### 45.7 Áreas ainda não varridas (atualizado na iter 45)

Varrido nesta iteração: `AppCommandRouter` — caminho de `filesState`/`filesEdit*`, SSH hosts (leitura/escrita/segredo), `listPendingCallbacks` + `listAgentPendingCallbacks`, `reconcileBotBrowserActions`, `makeSurface` (parcial); `AppContext` — região do ledger Graphify (`processGraphifyBuffer` inteiro), handler de evento na parte de pending callbacks, `markOpenStale` no boot. Restam: `AppShell` — **`AppCommandRouter` (ainda parcial: notificações `:7872-7942`, `privatePushTokenUpdate` `:7942-8019`, transferência SSH `:8483-8581`, `runCommand`/listagens SSH `:8635-8800`, attachments `:7075-7250`, git `:7041-7075`)**, resto de `AppContext` (`:3000-6400` fora dos pontos já vistos); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint, MCP/resíduo/uninstalls, receipts de orquestração e dos itens já vistos).

### 45.8 Backlog (repriorizado na iter 45)

1. **Achado 45.6 #1** — snapshot de pending callbacks não pode sumir com payload ilegível (iOS/Pet).
2. **Achado 45.6 #2** — as 4 escritas `try?` de `provider_pending_callbacks` no `AppContext` devem reportar falha.
3. **Varredura do que falta** (topo, contínua): o restante listado em 45.7.
4. `queueForceNow` (`:1186`) + `makeSurface:8388` + wrapper candidates (`AgentSkillInstaller:1517`) — observações de valor baixo, sem correção.
5. P3 restante: caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
6. Decisões do dono em aberto (não bloqueiam a varredura): transcript do undo, retenção por idade de `agent_turn_checkpoints`, `lfs --skip-smudge`, limite/TTL das sessões de edição, retenção de `command_receipts`, caminho de Stop do coordinator, poda de `deskRoutingByConversation` no delete, escrita incremental da fila × semântica multi-janela, `GitDiff` devolvendo vazio em falha dura de git, `reloadAll()` no-op durante `isLoading`.
7. Ideia medida e **não** tomada (iter 41.6 #5, mantida): carimbo de estado dos dois configs de provider pularia o passe de resíduo inteiro (~0,05 ms contra 0,332 ms) — exigiria estado em `AppContext`.
8. Demais itens antigos (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL; Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget`; EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Commits da iteração

| Commit | Item |
|---|---|
| `bdda0e6f` | `fix(tokensaver): a delivered Graphify answer is credited even when its pending row was lost` (45.2) |
| `4c44f9c5` | `test(tokensaver): lock the Graphify credit to a refused pending insert` (45.3) |
| `062e5384` | `fix(appshell): SSH host edits refuse to erase a list they cannot read` (45.4) |
| `ac1a65b8` | `test(appshell): lock the SSH host edit to an unreadable stored list` (45.5) |

## Iteração 46 — 2026-09-18

### 46.1 Varredura (cobertura registrada nesta iteração)

| Ponto varrido | Veredito |
|---|---|
| `AppCommandRouter` — `listPendingCallbacks` (`:193`) e o gêmeo `listAgentPendingCallbacks` (`:5945`) | **achado** (46.2, corrigido) |
| `AppContext` — handler de evento, as 4 escritas de `provider_pending_callbacks` (`:1505/:1523/:1530/:1564`) | **achado** (46.4, corrigido) |
| `Persistence/BotRemoteControlAuthority` — rollback do `queueForceNow` (`:1192`) | **achado** (46.6, corrigido) |
| `Surfaces/AgentAppSurface` — quem lê o snapshot no macOS | **sem achado, delimita o raio**: a superfície macOS monta `timeline.pendingRequests` do **stream** de eventos; o snapshot (`agent.pending_callbacks.list` → `listAgentPendingCallbacksOffMain`) é o que o device pareado hidrata. O `PetAttentionStore` monta o item **da linha** (`callbackItem`, `:184-218`), não do payload — um payload ilegível só degrada o rótulo da ação (`approvalActionLabel` → `nil`), nunca some com o callback |
| `AppCommandRouter` — notificações (`:7872-7942`) e `privatePushTokenUpdate` (`:7942-8019`) | **sem achado**: a faixa inteira não tem `try?` nem catch vazio (o `try?` anterior é `:7758`, o seguinte é `:8056`) |
| `AppCommandRouter` — `settingsGet` (`:8052-8060`) | **achado P3 (registrado, não corrigido)**: leitura de setting que falha vira `""` na resposta ao device pareado — "falha de leitura apresentada como vazio". Não corrigido porque a correção honesta muda o contrato do RPC (devolver erro em vez de `[key: ""]` faz o hydrate inteiro das settings do iOS falhar por uma chave) → decisão do dono (46.8 #4) |
| `AppCommandRouter` — transferência SSH (`:8483-8581`), `runCommand`/listagens SSH (`:8635-8800`) | **sem achado** na varredura de `try?`/catch: `:8709` é `try? removeItem` de script temporário (categoria já descartada na iter 44); `:8752` (`makeLocalEntry`: `resourceValues` que falha → linha da listagem local com size 0 e data vazia) é **observação P3** — pinta valor fabricado, mas a linha continua lá e é listagem local |
| `AppCommandRouter` — attachments (`:7075-7250`) | **sem achado**: `:7121` cai para o path staged (fail-open com caminho válido); `:7143` (`attributesOfItem` que falha → limite de 25 MB não aplicado num arquivo já legível do workspace) e `:7192` (`setAttributes` 0o600 do hardlink que falha → permissões default dentro de dir 0o700) ficam como observações de valor baixo |
| `AppCommandRouter` — git (`:7041-7075`) | **sem achado**: `:7043` (`configuredProviderBinary`: setting que falha → "sem binário configurado") alimenta a resolução de binário, que cai no caminho default/PATH — não apaga nem sobrescreve nada |
| `AppCommandRouter` — varredura dos 28 `catch {` do arquivo | único catch realmente vazio: `makeSurface:8412` (`return descriptor` sem registrar surface), já registrado em 45.6 #3 |

### 46.2 Correção 1 (P2) — payload ilegível apagava um pedido de aprovação pendente do snapshot do device pareado

- **Antes**: os dois mapeadores de `provider_pending_callbacks` para `AssistantPendingCallbacksSnapshot` faziam `guard let ... = try? decoder.decode(...) else { continue }` — linha com payload que não decodifica era **pulada em silêncio** (sem log). O mapeador de linha ainda normaliza `payload_json` NULL para `"{}"` (`Repositories.swift:9148`), que também não decodifica: os dois casos caem no mesmo skip. Consequência: o pedido de aprovação/pergunta **existe** no banco e o run está **parado esperando**, mas o snapshot que o iOS hidrata não o mostra — o usuário não tem como aprovar do device pareado.
- **Depois**: um mapeador único (`PendingCallbackSnapshotMapper`, usado pelos dois caminhos) reporta o skip (`io.remotecode.appshell` / `router`, `pending_callback.payload_unreadable` com thread/request/kind/state/bytes — nunca o payload) e emite uma entrada **degradada** com a mesma identidade: `id` = `request_id`, `state`, `createdAtMs`/`resolvedAtMs` preservados, título/detalhe dizendo que o payload armazenado não pôde ser lido. O pedido continua **respondível por `request_id`** (é assim que `agent.approval.respond` / `agent.user_input.respond` roteiam). Payload legível decodifica exatamente como antes.
- Arquivos: `Sources/AppShell/AppCommandRouter.swift` (`PendingCallbackSnapshotMapper` + os dois chamadores), `Tests/AppShellTests/PersistenceRestoreTests.swift` (spec novo).

### 46.3 A/B #1 (mesmo sandbox, mesma máquina, mesmo filtro; "antes" = corpo antigo de `AppCommandRouter.swift`, com o spec novo no lugar)

| Rodada | Executados | Falhas |
|---|---|---|
| Antes | 10 | **1** (só o spec novo, com 7 asserções vermelhas) |
| Depois | 10 | **0** |

Specs nome a nome: `test_pendingCallbacksWithUnreadablePayloadStayVisibleToThePairedDevice` — **vermelho no antes com 7 asserções**, com a prova no próprio output: o snapshot hidratado trouxe `["approval-2"]` onde o esperado é `["approval-1", "approval-2"]` (a aprovação ilegível **sumiu**), `[]` onde o esperado é `["question-1"]` (a pergunta ilegível **sumiu**), `createdAtMs` `1500 != 1000` e o detalhe degradado ausente; verde no depois. Os outros 9 specs da classe ficaram **verdes nas duas pernas**, incluindo os dois que declaram a LEG-2 do caminho não deduplicado: `test_providerCallbackState_persistsAndMarksOpenCallbacksStaleOnRestart` (payload legível: título/detalhe/estado/stale-reason idênticos) e `test_failedProviderCallbackResponseMarksStoredCallbackStale` (merge do `stale_reason` no detalhe). Nenhuma falha pré-existente na classe.

Anti-vacuidade: a fixture grava as duas linhas pelo caminho de produção (`providerPendingCallbackRepo.record`), corrompe o payload com SQL real (`'{}'` — exatamente o que o mapeador escreve quando o payload nunca pousou — e um JSON truncado), **asserta que a corrupção aconteceu** (`payloadJSON == "{}"` antes de hidratar), e mantém uma terceira linha legível (`approval-2`) que precisa decodificar normalmente: o spec não pode passar se o mapeador degradar tudo nem se a fixture não semear nada.

### 46.4 Correção 2 (P2) — as 4 escritas de `provider_pending_callbacks` no handler de evento falhavam em silêncio

- **Antes**: `record` (aprovação e pergunta) e `resolve` (aprovação e pergunta) eram `try?` dentro do handler de evento. `record` que falha deixa o pedido **só** no stream ao vivo — e o device pareado hidrata a **tabela**, então o pedido não existe para ele; `resolve` que falha deixa um pedido **já respondido** reaparecendo como pendente no próximo hydrate (botão morto até o boot marcá-lo stale).
- **Depois**: cada uma das 4 escritas reporta a falha (`io.remotecode.agent` / `app-context`, `provider_pending_callback.record_failed` / `.resolve_failed` com thread/request/kind/state), sem inventar retry: o caminho é consumidor de stream e não pode lançar, e `busy_timeout` já é 5 s — um retry manual só cobriria erro duro de I/O, que ele não conserta.
- **Dentes**: mudança **apenas observável** (não há comportamento novo testável sem inventar retry especulativo) — declarado como tal; nenhum spec novo, para não adicionar verde vácuo.
- Arquivo: `Sources/AppShell/AppContext.swift`.

### 46.5 Verificação de compilação/regressão do 46.6 — `--filter BotRemoteControlAuthorityTests`

| Rodada | Executados | Falhas |
|---|---|---|
| Depois (`queueForceNow` reportando o rollback) | 85 | **0** |

Mesma contagem da iter 44 na mesma classe (85/0), ou seja sem regressão; serve também de compile-check do arquivo alterado.

### 46.6 Correção 3 (P3) — o rollback do `queueForceNow` engolia a própria falha

- **Antes**: quando o runtime recusava o force-now, o rollback da ordem era `try? store.replaceQueuedFollowUps(... items: originalRows)`. Rollback que falha deixa o item **preso no topo** da fila enquanto o chamador só recebe o erro original — a fila fica reordenada sem nenhum registro.
- **Depois**: o rollback que falha é reportado (`io.remotecode.persistence` / `bot-remote-control`, `bot.queue.force_now_rollback_failed` com bot/item). Nada é "desfeito" a mais: a ordem é visível e reordenável pelo usuário, então a correção para aqui (mesma avaliação de valor da 45.6 #5).
- **Dentes**: **apenas observável** (sem spec novo; um teste de log seria vácuo).
- Arquivo: `Sources/Persistence/BotRemoteControlAuthority.swift` (logger novo + `do/catch` no rollback).

### 46.7 Áreas ainda não varridas (atualizado na iter 46)

Varrido nesta iteração: `AppCommandRouter` — os dois mapeadores de pending callbacks e os chamadores do snapshot, notificações `:7872-7942`, `privatePushTokenUpdate` `:7942-8019`, `settingsGet` `:8052-8060`, transferência SSH `:8483-8581`, `runCommand`/listagens SSH `:8635-8800`, attachments `:7075-7250`, git `:7041-7075` e os 28 `catch` do arquivo; `AppContext` — as 4 escritas de `provider_pending_callbacks`; `Persistence/BotRemoteControlAuthority.queueForceNow` (fecha o item aberto desde a 44.5); confirmação de quem consome o snapshot (`AgentAppSurface` via stream, `PetAttentionStore` via linha, iOS via RPC). Restam: `AppShell` — `AppCommandRouter` (parcial: só as regiões acima; falta varrer o corpo dos handlers de layout/surface um a um) e o resto de `AppContext` (`:3000-6400` fora dos pontos já vistos); `Sources/AgentRuntime/` (fora dos providers, stop/checkpoint, MCP/resíduo/uninstalls, receipts de orquestração e dos itens já vistos).

### 46.8 Backlog (repriorizado na iter 46)

1. **Varredura do que falta** (topo, contínua): o restante listado em 46.7.
2. Observações de valor baixo, sem correção: `makeSurface` catch final (`AppCommandRouter:8388`), candidatos de wrapper (`AgentSkillInstaller:1517`), `onReviewRequested` com `_ = try? createSurface` (`AppCommandRouter:8314`, "Review" que não abre a superfície e não reporta), `makeLocalEntry` (`:8752`), `attributesOfItem` do import de attachment (`:7143`), `setAttributes 0o600` do hardlink (`:7192`).
3. P3 restante: caminho de Stop do `AgentRunCoordinator` (decisão de contrato do dono).
4. Decisões do dono em aberto (não bloqueiam a varredura): transcript do undo, retenção por idade de `agent_turn_checkpoints`, `lfs --skip-smudge`, limite/TTL das sessões de edição, retenção de `command_receipts`, caminho de Stop do coordinator, poda de `deskRoutingByConversation` no delete, escrita incremental da fila × semântica multi-janela, `GitDiff` devolvendo vazio em falha dura de git, `reloadAll()` no-op durante `isLoading`, **`settingsGet` devolvendo `""` para leitura que falhou** (contrato do RPC: erro em vez de vazio).
5. Ideia medida e **não** tomada (iter 41.6 #5, mantida): carimbo de estado dos dois configs de provider pularia o passe de resíduo inteiro (~0,05 ms contra 0,332 ms) — exigiria estado em `AppContext`.
6. Demais itens antigos (nada mudou): `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL; Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget`; EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).

### Commits da iteração

| Commit | Item |
|---|---|
| `cbc4ddfc` | `fix(appshell): a pending callback with an unreadable payload stays in the snapshot` (46.2) |
| `a1dc3810` | `test(appshell): lock the unreadable pending callback to the hydrated snapshot` (46.3) |
| `657600a3` | `fix(appshell): provider callback writes stop failing silently` (46.4) |
| `2b7d9878` | `fix(bots): report a failed force-now rollback instead of swallowing it` (46.6) |

## Iteração 47 — 2026-09-18

### 47.1 Varredura (cobertura registrada nesta iteração)

| Ponto varrido | Veredito |
|---|---|
| `AppCommandRouter` — corpos dos handlers de layout/surface: `createSurface` (`:1492`), `splitPane` (`:1588`), `ensureGitSurface` (`:1546`), `filesOpenTab`/`filesSplitTab` (`:1590`/`:1602`), `openFileInAdjacentSplit`/`openURLInAdjacentSplit` (`:1622`/`:1660`), `splitSurface`/`closeSurface`/`closeSurfaces`/`reopenClosedSurface` (`:1741-1828`), `permanentlyCloseRuntimeSurface` (`:1789`), `focusSurface`/`focusPane` (`:2133`/`:2162`), `paneList`/`paneSurfaces`/`paneResize`/`surfaceMove`/`surfaceReorder` (`:7793-7884`) | **achado** em `createSurface`, `splitPane` (47.3/47.4) e no destino de `surfaceMove` (47.2) |
| `CoreModel/Reducer` — os três caminhos que colocam uma superfície num pane (`.addSurface`, `.splitPane`, `.moveSurfaceToPane`) e os helpers `split`/`addSurface`/`removeSurface`/`insertSurface` | **achado**: os três aceitavam pane fora do layout (classe fechada nas 47.2-47.4) |
| `AppContext:3000-6400` — usage/refresh/publish (`:3245-3660`), admissão distill/escopo/observação (`:3681-3930`), seleção outbound + RCW1 provisório (`:4025-4640`), session learn (`:4647-4760`), ledger de usage (`:5157-5720`), economia diária (`:5721-5880`), crédito Graphify + `processGraphifyBuffer` (`:5877-6210`) | **sem achado**: `_ = try? store.discardAbandoned(...)` (`:4502/:4515/:4611/:4639`) falha para o lado seguro (a linha de recovery fica); flush de usage tem backoff/teto e não desiste; nenhuma leitura que falha decide apagar/limpar/sobrescrever |
| `AgentRuntime/` fora dos caminhos já vistos — `ProviderProcessSweeper` (inteiro), `ProviderProcessOwnership` (`load`/`append`/`removeExact`/`commitSweep`), `AgentRuntimeResourceBundle`, `GraphifyGitProbe`, `GraphifyWorkspaceService` (staging/promote/rollback) | **sem achado**: ledger de ownership já trata "ilegível ≠ vazio"; promote do Graphify é cancel-aware com rollback. Observação P3: `discoverChildRepos` (`GraphifyGitProbe:58`) pula diretório que não pode listar (menos repos, nenhuma deleção) |
| `AppCommandRouter.openFileInAdjacentSplit`/`openURLInAdjacentSplit` — publicam `surface.created`/`pane.split` mesmo quando o `try? ctx.apply(...)` falha | **P3 registrado, não corrigido**: pane alvo vem do layout lido na mesma chamada (só corrida de fechamento); o guard novo faz o apply lançar e o `try?` descarta o erro preservando o publish — saída visível igual à de antes. Follow-up de 1 linha (publicar só com apply ok) no backlog |
| `AppCommandRouter.paneList` (`:7793`) devolve `[]` para workspace inexistente | **P3 registrado, não corrigido**: mesma família do `settingsGet` (falha de leitura apresentada como vazio) e mesmo motivo — contrato do RPC com o device pareado, decisão do dono |

### 47.2 Correção 1 (P1) — mover a aba única para o próprio painel apagava a aba

- **Antes**: `moveSurfaceToPane` remove antes de adicionar; quando a superfície era a **única** aba de um painel dentro de um split, a remoção podava o painel, `addSurface` no-opava no pane que sumiu e o reduce **retornava sucesso** com a superfície fora do layout (aba irreabrível — não passa pelo `closedTabBuffer` — runtime órfã e snapshot sem a aba). `surface.move` é RPC de device pareado → alcançável pelo iOS. Mesmo buraco já fechado para `reorderSurface`.
- **Depois**: guard `paneNotFound` após a remoção (mesmo formato do guard do reorder); o reduce lança e o estado do chamador fica intacto.
- Arquivos: `Sources/CoreModel/Reducer.swift`; `Tests/CoreModelTests/MoveSurfaceLoneTabSelfDropTests.swift` (3 specs).

### 47.3 Correção 2 (P2) — superfície criada num pane fora do layout virava aba fantasma

- **Antes**: `surface.create`/`files.open_tab` recebem `pane_id` do cliente; `addSurface` no-opa quando ele não existe e o router devolvia descritor criado, **registrava a runtime** e publicava `surface.created` (cacheado pelo command receipt) para uma aba que o layout nunca ganhou — o device pareado pinta a aba, o Mac não a tem.
- **Depois**: `createSurface` verifica o pane **antes** de construir a runtime + guard no reducer.
- Arquivos: `Sources/AppShell/AppCommandRouter.swift`, `Sources/CoreModel/Reducer.swift`; `Tests/AppShellTests/CreateSurfaceGhostPaneTests.swift` (2 specs, um deles de controle).

### 47.4 Correção 3 (P2) — split num pane fora do layout prendia o foco num painel inexistente

- **Antes**: `split()` devolve o layout intacto quando o pane pedido não existe, mas o reducer guardava o resultado com `focusedPaneID` = pane novo inexistente; `surface.split` respondia sucesso e publicava `pane.split` de painel que nunca nasceu; o foco pendurado envenenava os adds sem pane id seguintes (resolvem por `focusedPaneID`).
- **Depois**: guard no reducer antes do split + verificação do pane no router antes de construir a runtime.
- Arquivos: `Sources/CoreModel/Reducer.swift`, `Sources/AppShell/AppCommandRouter.swift`; `Tests/CoreModelTests/SplitPaneGhostPaneTests.swift` (2 specs, um de controle).

### 47.5 A/B por correção (mesmo sandbox, "antes" = corpo antigo com os specs novos no lugar)

| Correção | Filtro | Antes | Depois |
|---|---|---|---|
| 47.2 | `MoveSurfaceLoneTabSelfDropTests` | 3 executados, **2 falhas** (4 asserções) | 3 executados, **0** |
| 47.3 | `CreateSurfaceGhostPaneTests` | 2 executados, **1 falha** (3 asserções) | 2 executados, **0** |
| 47.4 | `SplitPaneGhostPaneTests` | 2 executados, **1 falha** (3 asserções) | 2 executados, **0** |

Specs nome a nome:
- `test_loneTabSelfMove_intoVanishedPane_doesNotDropSurface` e `test_move_intoNonexistentPane_doesNotDropSurface` — vermelhos no antes (`move reported success but the surface left the layout`; `did not throw`).
- `test_createSurface_intoUnknownPane_failsWithoutPublishingOrRegistering` — vermelho no antes (`did not throw`; `must not publish surface.created`; `no runtime may be registered`).
- `test_splitPane_intoUnknownPane_doesNotCorruptFocusOrPublishASplit` — vermelho no antes (`the reported split never added its surface`; `focus must never be left on a pane id that is not in the layout`; `did not throw`).
- Controles verdes nas duas pernas: `test_move_crossPaneMove_stillSucceeds`, `test_createSurface_intoExistingPane_stillCreatesAndPublishes`, `test_splitPane_intoExistingPane_stillSplitsAndFocuses`.

Anti-vacuidade: in the "antes" leg each guard spec proves the *observable* damage (surface left the layout / event published / focus on a ghost pane), not just the missing error.

### 47.6 Baseline-diff da rodada (mesma máquina, mesmos filtros; "antes" = `9e453dc2` nos dois fontes com os specs novos no lugar)

`--filter CoreModelTests --filter PaneActionTests --filter TabReorderParityTests --filter SurfaceMirrorEventGoldenTests --filter Phase4MutationReceiptContractTests`

| Rodada | Executados | Falhas | Métodos distintos |
|---|---|---|---|
| Antes | 968 (2 skip) | 704 | 8 |
| Depois | 968 (2 skip) | **697** | 5 |

- Nenhum método passou a falhar. Os 4 métodos que só falhavam no "antes" são os specs novos desta iteração.
- `AppShellTests.PaneActionTests.test_sidebarSeamStaysSeamlessAndExactAcrossToggleCycle_becauseDriftDrewAStrayLine` falhou no "depois" e não no "antes" → **flaky sob carga, não atribuível**: 3 execuções isoladas no mesmo HEAD, 0 falhas (`-22.0 != 0.0` em geometria de painel).
- `CoreModelTests.ComputerUseHostQueueTests.test_excessiveSameTargetWaitersFailExplicitly` apareceu só no "antes" → mesma conclusão (flaky).
- **Pré-existentes registradas** (idênticas antes e depois, nenhuma tocada): `TokenSaverTypedCrushersTests.test_defaultOff_deniesAllCrushers` (3 asserções; com `masterEnabled` omitido o gate consulta o registro e `enableAllForTesting()` é bypass explícito — expectativa do spec × gate autoritativo do registro; área de Token Saver, **não** mexida), `Phase4MutationReceiptContractTests.test_everyCanonicalMutationRunsPureSyntacticPreflightBeforeReceiptClaim`, `Phase4MutationReceiptContractTests.test_liveMutationRequiresClientRequestIdAndBearerOwnerOnly`, `PaneActionTests.test_terminalBusyRuntimeRefreshUpdatesTabSpinnerWithoutRebuildingPane`. (O `--filter CoreModelTests` isolado dá 848 executados, 2 skip, **3 falhas** — todas as 3 do `test_defaultOff_deniesAllCrushers`.)

### 47.7 Nota de processo (vale para as próximas iterações)

- O repo tem `status.showUntrackedFiles=no` no config (`file:.git/config`): `git status --short` **esconde** arquivo novo. Spec/correção novos precisam de `git status --untracked-files=all` (ou `git add` explícito) para não ficar fora do commit.
- `glab api -X PUT ... --input` precisa de `-H "Content-Type: application/json"` (sem o header: HTTP 415) e o título do MR tem teto de 255 caracteres.

### 47.8 Backlog (repriorizado na iter 47)

1. **Varredura do que falta** (topo, contínua): `AppContext` fora das faixas varridas (`:1-3000` e sobra de `:3000-6496`), `AppCommandRouter` nos handlers de bot/paired-guest (`:2800-3600`) e emissores de notificação/browser de bot (`:7390-7700`), `AgentRuntime/` — `AgentRunCoordinator` fora de stop/checkpoint, providers fora dos runners e arquivos pequenos de suporte (login shell, stdin guard, `MacOSLocalUserCatalog`, leases).
2. P3 novo, correção de 1 linha: `openFileInAdjacentSplit`/`openURLInAdjacentSplit` publicam `surface.created`/`pane.split` mesmo quando o `try? ctx.apply(...)` falha (47.1). Idem `paneList` devolvendo `[]` para workspace inexistente (família do `settingsGet`, decisão do dono).
3. P3 novo: `GraphifyGitProbe.discoverChildRepos` pula diretório que não pode ser listado (menos repos descobertos; sem deleção).
4. Herdados desta iteração-1 do loop e ainda abertos: `agent.history.partial.<threadID>` nunca apagado; timer do SSH; `files.edit.*` no main actor; `FileEditSessionStore` sem cap/TTL; Insomnia; rename inline de aba; COW do replay unhosted; `reasonPhrase(204)`; índice/retenção de `agent_runs`; itens de `SettingsWindow` da iter 12; `agent_turn_checkpoints` fora do `LocalStorageBudget`; EV-28; agregar falhas de um gesto multi-pasta (16.1); `WorkspaceWindowController.refreshFromState` sem coalescing (16.2 #2).
5. Decisões do dono em aberto (não bloqueiam a varredura): transcript do undo, retenção por idade de `agent_turn_checkpoints`, `lfs --skip-smudge`, limite/TTL das sessões de edição, retenção de `command_receipts`, caminho de Stop do coordinator, poda de `deskRoutingByConversation` no delete, escrita incremental da fila × semântica multi-janela, `GitDiff` vazio em falha dura do git, `reloadAll()` no-op enquanto `isLoading`, `settingsGet` devolvendo `""` para leitura que falhou.

### Commits da iteração

| Commit | Item |
|---|---|
| `b91a941a` | `fix(coremodel): a surface move that cannot land no longer drops the tab` (47.2) |
| `10ba775d` | `test(coremodel): lock the lone-tab self-move to the surface invariant` (47.2) |
| `f988f032` | `fix(appshell): a surface created into a pane outside the layout is refused` (47.3) |
| `fcbf5db8` | `fix(coremodel): a split into a pane outside the layout is refused` (47.4) |
