# TODO — Agent App e Bots leves conforme o chat cresce e com N runs simultâneos

Auditoria de 2026-09-14 (branch `production` @ `2d5d2eb5`), feita com o app do dono rodando ao vivo (release 2.0.160, pid 43041, 3 runs ativos: 2 Codex `/goal` + 1 Grok). Objetivo do dono: **o chat do Agent App e dos Bots não pode ficar lento nem travar conforme a conversa cresce**, nem com várias coisas rodando ao mesmo tempo. Este arquivo é auto-suficiente para outro agente executar do começo ao fim.

Relação com planos anteriores: `TODO-Performance.md` (2026-09-02, PF-00..41) e o `TODO.md` de 2026-09-01 (AA/BT/CH/X) estão **todos marcados como feitos** e mergeados em `production` (`da4170d9`, `2cd5a9d4`). Não duplique itens deles. Este arquivo cobre o que a amostra ao vivo de hoje mostrou que **continua** acordando o main thread, e o que ainda cresce com o tamanho do transcript.

## Regras obrigatórias para quem executar

1. Leia `AGENTS.md` §"Loading and perceived performance" e §"Isolated sandbox". Todo build/test/run em worktree isolado: `cd "$(scripts/isolated-sandbox.sh ensure)"`. O RemoteCode do dono (`io.remotecode.desktop`, `/tmp/RemoteCode.sock`, porta 18217, `~/Library/Application Support/RemoteCode/remotecode.sqlite`) é intocável. Nunca `pkill RemoteCode`.
2. Testes: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Alvo>`. `swift test` completo **não** é verde na base. Baseline-diff obrigatório: rode o filtro ANTES (ou com `git stash`), guarde a lista de métodos que falham, compare DEPOIS. Nunca escreva "tests pass" sem essa comparação. Baseline de hoje para `AgentRuntimeTests\..*Codex`: 5 métodos falham (`ClaudeRunnerArgsTests.test_listModels_…`, 4 de `TokenSaverCrossProviderMatrixTests`).
3. Medição sem Instruments: `sample <pid> 8 1 -mayDie -file out.txt`; separe o bloco `Main Thread` e agregue os símbolos `(in RemoteCode)`. A amostra de hoje está em `/private/tmp/claude-501/…/scratchpad/sample-live-8s.txt` da sessão; refaça a sua. Meça em build **release**.
4. Um commit por item. Mensagens: `perf(tokensaver): PL-01 …`, `perf(pet): PL-03 …`, `perf(bots): PL-02 …`, `perf(db): PL-05 …`. Não refatore código adjacente. Não mude schema sem bump em `Schema` + teste de migração.
5. `SQLiteDB.performSync` é thread-safe (`operationLock` + fila serial, `Sources/Persistence/SQLite.swift:437`). Repositórios podem ser chamados de `Task.detached`. **Cuidado:** `Task { }` dentro de classe `@MainActor` herda o MainActor — não é "off-main" (PL-02 nasceu disso).
6. Ao terminar um item marque `[x]` com hash do commit e o número medido (antes → depois, amostras do main thread).
7. Paridade iOS (AGENTS.md): quando um item cortar eventos, corte só diagnóstico/ruído e prove que `workspace.*`, `surface.*`, `agent.thread.*`, `agent.item.*` e `agent.run.*` continuam saindo.

## Evidência ao vivo (2026-09-14 14:14 -03, app do dono, 8 s @ 1 ms = 6.153 amostras)

Main thread ocupado em ~1.600 amostras (~26%) com o app **sem interação** e CPU total 0,3%. Quem ocupou:

| Amostras | Caminho no main thread | Item |
|---|---|---|
| 955 | `AppContext.completeTokenSaverUsageWrite` → `recomputeTokenSaverDailyEconomyToday` → 7 SELECTs + 1 UPSERT esperando `NSRecursiveLock` do `SQLiteDB` | PL-01 |
| 372 | `PetController.handle` → `refreshActiveThreadsFromCoordinator` → `applyActiveThreadIDs` → `BotStore.conversationsLinked` (`performSync` no main) | PL-03 |
| 130 | `PetWindowController.revalidateDockPlacementCache` → `PetDockFrameProvider.frame(for:)` (IPC WindowServer, laço a cada 30 s) | PL-04 |
| 107 | `BotsViewModel.reloadTokenSaverThreadSavings` closure → `SettingsStore.load()` (3×) + `PrivateAccountSessionStore.load()` no main | PL-02 |
| 45 | `completeTokenSaverUsageWrite` → `loadTokenSaverDailyEconomySharedSnapshot` → `SettingsStore.load()` | PL-01 |

Fila `RemoteCode.SQLiteDB` (530 amostras): `EventLogRepository.append` 345, `TokenSaverSavingsRepository.summary` 100, `TokenSaverDailyEconomyRepository.windowTotalCredible` 73. Tabela `events` nos últimos 10 min: `agent.item.started` 590, `agent.item.completed` 193, `token_saver.digest` 155, `agent.account.usage` 113, `agent.thread.token_usage` 80, `agent.account.usage.refresh` 42 (PL-05).

Escala real do transcript: `agent_messages` é pequeno (maior thread: 10 msgs / 24 KB). O que cresce é a timeline em memória do VM dentro da sessão; em disco `agent_stream_events` é janela rolante (~100 linhas por run vivo) e `agent_turn_snapshots` está vazio. Ou seja, "chat grande" = VM com centenas de items/turns na mesma sessão, não linhas no SQLite.

## Modelo mental (3 causas)

1. **Trabalho de contabilidade no main thread por evento de stream** (PL-01, PL-02, PL-03). Cada run ativo dispara isso; com 3 runs o main é interrompido várias vezes por segundo esperando a fila do SQLite, e a UI do chat (digitar, scroll, stream) perde frames independentemente do tamanho do chat.
2. **Custo proporcional ao tamanho do transcript por evento / por tecla / por body** (seção F2, em levantamento).
3. **Volume na fila única do SQLite** (PL-05): quanto mais se grava por evento, mais tempo toda leitura da UI espera.

## F0 — Já entregue nesta rodada

- [x] **G-01 · P0 · Codex `/goal` — thread aparecia como finalizada (sidebar/composer/DB `completed`) enquanto o Codex continuava rodando.** `2d5d2eb5`. Causa: a cada iteração do goal o app-server emite `status idle → turn/completed → status active → turn/started` no mesmo segundo; o adapter fechava o run no `turn/completed` porque o `idle` recém-chegado desarmava a deferral. Fix em `CodexAppServerAdapter.swift` (`goalActive`, `dropPendingFinishForContinuingGoal`, `takePendingFinish`); testes `test_activeGoalKeepsRunOpenAcrossIterationTurnBoundaryUntilGoalCleared` e `test_activeGoalFinishesFromAuthoritativeThreadReadWhenNoNewerTurnAppears`. **Não validado ao vivo** (precisa reiniciar o app com a build).

## F1 — Parar de acordar o main thread por evento (P0)

- [ ] **PL-01 · P0 · idle-com-runs — recálculo da economia diária do Token Saver roda no main thread a cada flush de uso.**
  `Sources/AppShell/AppContext.swift:5155` faz `DispatchQueue.main.async { completeTokenSaverUsageWrite }` após gravar `usage.json` na `backgroundWriterQueue`; `:5197` chama `recomputeTokenSaverDailyEconomyToday()` que em `:5430-5530` faz `SettingsStore.load()` + decode de `usage.json` + `measuredPipes`, `signalCount`, `answerTokensSum`, `medianExplorationTokens`, `prune`, `threadCacheAmortizationInputs` e `upsert` — 8 idas ao `SQLiteDB` no main, cada uma esperando os escritores dos runs. Frequência: debounce de 0,75 s **por run** (`:610`), então com 3 runs é ~1–4×/s. 955 + 45 amostras = ~16% do main thread parado.
  Fazer: mover `recomputeTokenSaverDailyEconomy` para a mesma `backgroundWriterQueue`, logo depois do `record(...)` (já está fora do main, já tem o snapshot); no main só atualizar `pendingUsageByRun` e agendar a notificação. `recomputeTokenSaverDailyEconomyWindow` (chamado no boot) idem, em `Task.detached`. Manter a ordem: o upsert do dia precisa terminar antes de `.rc2TokenSaverUsageChanged` ser postado, senão o rodapé lê o valor antigo.
  Verificar: teste em `AppContextTokenSaver…Tests` com `beforeTokenSaverUsageWriteForTesting` + contador `PerfSwitchMetrics.mainThreadSyncCountForTesting()` = 0 durante o flush; reamostrar 8 s: 0 amostras de `recomputeTokenSaverDailyEconomy` no main.

- [ ] **PL-02 · P0 · stream — rodapé do Token Saver (Bots e Agent App) lê SQLite no main achando que está off-main.**
  `Sources/AppShell/BotsWindow.swift:4120-4190`: `reloadTokenSaverThreadSavings` faz o `reduce` de `deskMessages` (O(n) em mensagens) **no main** antes do `Task`, e o `Task { }` (herda MainActor) faz `SettingsStore(db:).load()` 2×, `PrivateAccountSessionStore.load()`, `loadDeliveredTotal` e `currentDayGraphifySignalCount` — 4–5 `performSync` no main por disparo. Disparos: `.rc2TokenSaverUsageChanged` (≥ a cada 2 s com runs ativos, `AppContext.swift:606`), `selectDeskThread`, `performThreadFreshness`, `reloadSelectedBot`, `restoreDeskMessages`. `Sources/Surfaces/AgentAppSurface.swift:2014-2070` tem o mesmo padrão (comentário "off-main" falso); os closures vêm de `AppCommandRouter.swift:3646 wireTokenSaverThreadFooter`. 107 amostras (Bots) na janela de 8 s.
  Fazer: trocar por `Task.detached` capturando `db`/repos (thread-safe, regra 5) e valores `Sendable`; mover o `reduce` do Bots para dentro da task com snapshot de `deskMessages`; cachear `SettingsStore` (uma instância por VM, ou ler `tokenSaverEnabled`/`isGraphifyRuntimeActive` do `AppContext` que já observa settings) para não carregar 3× a mesma linha.
  Verificar: teste fonte/comportamental: publicar `.rc2TokenSaverUsageChanged` 20× → `PerfSwitchMetrics.mainThreadSyncCountForTesting()` não cresce; rodapé continua atualizando (valor igual ao de antes).

- [ ] **PL-03 · P0 · stream — o Pet consulta `bot_conversations` no main a cada `agent.item.started/completed` de qualquer run.**
  `Sources/AppShell/Pet/PetController.swift` `shouldResyncActiveRuns` devolve true para `agentItemStarted/Completed` (1,4/s por run) → `refreshActiveThreadsFromCoordinator` → `applyActiveThreadIDs` → `context.botStore.conversationsLinked(to:)` e `bots(ids:)` (`Sources/Persistence/BotStore.swift:672`, `db.performSync` no main). 372 amostras (~6%). PF-03 tirou o `listChrome` do main mas esta segunda consulta ficou.
  Fazer: só consultar quando o **conjunto** de threads ativas mudar (cache `linkedBotByThread` invalidado por `agentRunStarted/Finished`, não por item); e fazer a consulta em `Task.detached` com `activeThreadChromeGeneration`, como `fetchActiveThreadChromeOffMain` já faz. Item events só reaplicam os ids com o cache.
  Verificar: `PetControllerTests`: 50 `agent.item.completed` para o mesmo conjunto de threads → `botStore.conversationsLinked` chamado 0× (contador no fake); `agent.run.started` de thread nova → 1× off-main.

- [ ] **PL-04 · P1 · idle — o Pet revalida a posição do Dock a cada 30 s com hit-test no WindowServer para todas as telas.**
  `Sources/AppShell/Pet/PetWindowController.swift:962-990`: `dockPlacementRevalidateTask` loop de 30 s → `revalidateDockPlacementCache` → `petPlacementContext(for:)` por `NSScreen` → `PetDockFrameProvider.frame(for:)`. Um tick = 130 amostras (≈130 ms de main thread travado) na janela de 8 s. PF-02 cacheou a chamada por pose, mas o laço periódico ficou.
  Fazer: remover o laço; manter só a invalidação por `didChangeScreenParametersNotification` / `com.apple.dock.prefchanged` (já observadas) e recomputar preguiçosamente no próximo uso. Se precisar de fallback, 1× ao trazer o Pet para frente.
  Verificar: teste: após `install…Observers`, nenhum `frame(for:)` é chamado sem notificação em 60 s simulados (relógio injetável); notificação → 1 chamada.

- [ ] **PL-05 · P1 · db — a tabela `events` recebe contabilidade a 5/s que nenhum cliente reproduz.**
  Em 10 min: `token_saver.digest` 155, `agent.account.usage` 113, `agent.account.usage.refresh` 42, `agent.thread.token_usage` 80 — cada um é `EventLogRepository.append` (345 amostras da fila SQLite, o maior escritor) + fan-out para Pet, Bots VMs e WebSocket. `agent.item.started` 590 é legítimo (iOS espelha).
  Fazer: (a) descobrir quem publica `token_saver.digest` e `agent.account.usage.refresh` nessa frequência (`Sources/RemoteCodeTreaty/Events.swift:4,5,138`; publicação em `AppContext`) e coalescer para ≤ 1 a cada 5 s por run; (b) marcar `token_saver.digest` e `agent.account.usage.refresh` como efêmeros (publicar sem `append` na tabela `events`) **se** o iOS não os usar em `events.recent` — confirmar em `Sources/SocketServer/Dispatcher.swift:4633` e no app iOS antes; decisão do dono se usar.
  Verificar: contagem por `kind` na tabela `events` em 10 min de 3 runs: contabilidade ≤ 10% do total; `agent.item.*` inalterado.

## F2 — Custo que cresce com o tamanho do transcript (em levantamento)

Três auditorias de código estavam em andamento quando este arquivo foi escrito (transcript do Agent App em `AgentAppSurface.swift`/`AssistantTimelineState`; chat dos Bots em `BotsWindow.swift`; persistência e fan-out por evento em `AgentRunCoordinator.swift`/`AppContext.swift`/EventBus). Os itens `AA-2x`, `BT-2x`, `EV-2x` entram aqui com file:line, custo (O(n) por evento / por tecla / por body) e fix, no mesmo formato de F1. Até lá, o que já se sabe:

- O transcript grande vive só em memória (ver Evidência). Qualquer `firstIndex`/`filter`/`reduce` sobre `timeline.turns`/`items`/`messages` num caminho por evento ou por tecla é suspeito; `reloadTokenSaverThreadSavings` (PL-02) é um exemplo já confirmado (`reduce` de todas as mensagens por disparo).
- Verificar se `mutateItem` newest-first, memo de turnos finalizados, `visibleTranscriptWindow` e `acceptsStreamEvent` continuam íntegros depois dos merges de 2026-09-07 (`34ba39fb`, `0e7a71c8`).

## Critérios de aceite

- Amostra de 8 s, release, 3 runs ativos, sem interação: main thread ocupado ≤ 5% (hoje ~26%); 0 amostras de `performSync` no main vindas de Token Saver ou Pet.
- Digitar no composer de um thread com ≥ 300 items: nenhum frame > 16 ms atribuível a `AgentAppSurface`/`BotsWindow` (medir com `sample` durante digitação).
- Nenhum item pode mudar o que o iOS recebe em `agent.item.*`, `agent.run.*`, `agent.thread.*`.

## Não verificado (dizer a verdade sobre o que falta)

- Nenhum item de F1 foi implementado ainda; os números são da amostra de hoje, não de antes/depois.
- G-01 não foi validado com um run `/goal` real na build nova; `thread/goal/cleared` nunca foi observado no wire, então o encerramento depende do reconcile por `thread/read` (~2 s depois do último turno).
- A amostra foi tirada com o app sem interação. Falta amostrar durante digitação/scroll num thread grande para fechar F2.
