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

- [x] **G-02 · P0 · Computer-use nativo — `doctor` dizia `screen_capture: false, accessibility: false, capture_mode: unavailable` com RemoteCode "ligado" nos Ajustes.** `b18a10ca` + `62181a96`. Prova: o mesmo binário `RemoteCodeDistillService computer-use-mcp` rodado a partir do Terminal devolve os dois `true`; a cadeia TCC do bot é helper → grok → `RemoteCode.app` (pid 43041, `responsibility_get_pid_responsible_for_pid`); nos Ajustes há **duas** linhas "RemoteCode" em Acessibilidade e uma em Gravação de Tela, todas ligadas, mais "RemoteCodeDebug" — o app nunca pediu permissão por código (`grep CGRequestScreenCaptureAccess|AXIsProcessTrustedWithOptions` = 0), logo as linhas foram adicionadas à mão e pertencem a identidades de código antigas. Fix: `doctor` inclui `launched_by` + `remediation`; `ComputerUsePermissionBroker.requestOnceIfMissing()` pede as duas permissões em nome do app quando um bot de desktop nativo é admitido. **Ação do dono pendente:** remover as linhas "RemoteCode" (−) e adicionar `/Applications/RemoteCode.app` (+) em Gravação de Tela e Acessibilidade; iniciar um run novo.

## F1 — Parar de acordar o main thread por evento (P0)

- [x] **PL-01 · P0 · idle-com-runs — recálculo da economia diária do Token Saver roda no main thread a cada flush de uso.**
  **FEITO `30f1ff5d`** — `scheduleTokenSaverDailyEconomyRecompute` coalesce (1 s) + `Task.detached`; notificação só após o upsert; gatilhos Graphify/sidecar migrados. Teste `test_tokenSaverDailyEconomyRecompute_coalescesTriggersAndPostsUsageChangedAfterUpsert` (10 gatilhos → 1 recompute). Medição antes→depois ao vivo pendente (precisa build release rodando).
  `Sources/AppShell/AppContext.swift:5155` faz `DispatchQueue.main.async { completeTokenSaverUsageWrite }` após gravar `usage.json` na `backgroundWriterQueue`; `:5197` chama `recomputeTokenSaverDailyEconomyToday()` que em `:5430-5530` faz `SettingsStore.load()` + decode de `usage.json` + `measuredPipes`, `signalCount`, `answerTokensSum`, `medianExplorationTokens`, `prune`, `threadCacheAmortizationInputs` e `upsert` — 8 idas ao `SQLiteDB` no main, cada uma esperando os escritores dos runs. Frequência: debounce de 0,75 s **por run** (`:610`), então com 3 runs é ~1–4×/s. 955 + 45 amostras = ~16% do main thread parado.
  Fazer: mover `recomputeTokenSaverDailyEconomy` para a mesma `backgroundWriterQueue`, logo depois do `record(...)` (já está fora do main, já tem o snapshot); no main só atualizar `pendingUsageByRun` e agendar a notificação. `recomputeTokenSaverDailyEconomyWindow` (chamado no boot) idem, em `Task.detached`. Manter a ordem: o upsert do dia precisa terminar antes de `.rc2TokenSaverUsageChanged` ser postado, senão o rodapé lê o valor antigo.
  Verificar: teste em `AppContextTokenSaver…Tests` com `beforeTokenSaverUsageWriteForTesting` + contador `PerfSwitchMetrics.mainThreadSyncCountForTesting()` = 0 durante o flush; reamostrar 8 s: 0 amostras de `recomputeTokenSaverDailyEconomy` no main.

- [x] **PL-02 · P0 · stream — rodapé do Token Saver (Bots e Agent App) lê SQLite no main achando que está off-main.**
  **FEITO `b17d0ea6`** — `Task.detached` nos dois VMs; reduce do Bots movido para dentro da task. Pin `test_tokenSaverFooterReloadsAreDetachedFromTheMainActor`.
  `Sources/AppShell/BotsWindow.swift:4120-4190`: `reloadTokenSaverThreadSavings` faz o `reduce` de `deskMessages` (O(n) em mensagens) **no main** antes do `Task`, e o `Task { }` (herda MainActor) faz `SettingsStore(db:).load()` 2×, `PrivateAccountSessionStore.load()`, `loadDeliveredTotal` e `currentDayGraphifySignalCount` — 4–5 `performSync` no main por disparo. Disparos: `.rc2TokenSaverUsageChanged` (≥ a cada 2 s com runs ativos, `AppContext.swift:606`), `selectDeskThread`, `performThreadFreshness`, `reloadSelectedBot`, `restoreDeskMessages`. `Sources/Surfaces/AgentAppSurface.swift:2014-2070` tem o mesmo padrão (comentário "off-main" falso); os closures vêm de `AppCommandRouter.swift:3646 wireTokenSaverThreadFooter`. 107 amostras (Bots) na janela de 8 s.
  Fazer: trocar por `Task.detached` capturando `db`/repos (thread-safe, regra 5) e valores `Sendable`; mover o `reduce` do Bots para dentro da task com snapshot de `deskMessages`; cachear `SettingsStore` (uma instância por VM, ou ler `tokenSaverEnabled`/`isGraphifyRuntimeActive` do `AppContext` que já observa settings) para não carregar 3× a mesma linha.
  Verificar: teste fonte/comportamental: publicar `.rc2TokenSaverUsageChanged` 20× → `PerfSwitchMetrics.mainThreadSyncCountForTesting()` não cresce; rodapé continua atualizando (valor igual ao de antes).

- [x] **PL-03 · P0 · stream — o Pet consulta `bot_conversations` no main a cada `agent.item.started/completed` de qualquer run.**
  **FEITO `ed85970e`** — `linkedBotByActiveThread` (cache do BotStore primeiro, 1 lookup off-main por thread desconhecida, generation guard). Teste `test_petResolvesLinkedBotOnceOffMainAndReusesItAcrossActiveRunRefreshes` (20 reaplicações → 1 lookup).
  `Sources/AppShell/Pet/PetController.swift` `shouldResyncActiveRuns` devolve true para `agentItemStarted/Completed` (1,4/s por run) → `refreshActiveThreadsFromCoordinator` → `applyActiveThreadIDs` → `context.botStore.conversationsLinked(to:)` e `bots(ids:)` (`Sources/Persistence/BotStore.swift:672`, `db.performSync` no main). 372 amostras (~6%). PF-03 tirou o `listChrome` do main mas esta segunda consulta ficou.
  Fazer: só consultar quando o **conjunto** de threads ativas mudar (cache `linkedBotByThread` invalidado por `agentRunStarted/Finished`, não por item); e fazer a consulta em `Task.detached` com `activeThreadChromeGeneration`, como `fetchActiveThreadChromeOffMain` já faz. Item events só reaplicam os ids com o cache.
  Verificar: `PetControllerTests`: 50 `agent.item.completed` para o mesmo conjunto de threads → `botStore.conversationsLinked` chamado 0× (contador no fake); `agent.run.started` de thread nova → 1× off-main.

- [x] **PL-04 · P1 · idle — o Pet revalida a posição do Dock a cada 30 s com hit-test no WindowServer para todas as telas.**
  **FEITO `1614385c`** — laço removido; invalidação só por notificação. Pin `test_petDockPlacementCacheHasNoPeriodicRevalidationLoop`.
  `Sources/AppShell/Pet/PetWindowController.swift:962-990`: `dockPlacementRevalidateTask` loop de 30 s → `revalidateDockPlacementCache` → `petPlacementContext(for:)` por `NSScreen` → `PetDockFrameProvider.frame(for:)`. Um tick = 130 amostras (≈130 ms de main thread travado) na janela de 8 s. PF-02 cacheou a chamada por pose, mas o laço periódico ficou.
  Fazer: remover o laço; manter só a invalidação por `didChangeScreenParametersNotification` / `com.apple.dock.prefchanged` (já observadas) e recomputar preguiçosamente no próximo uso. Se precisar de fallback, 1× ao trazer o Pet para frente.
  Verificar: teste: após `install…Observers`, nenhum `frame(for:)` é chamado sem notificação em 60 s simulados (relógio injetável); notificação → 1 chamada.

- [ ] **PL-05 · P1 · db — a tabela `events` recebe contabilidade a 5/s que nenhum cliente reproduz.**
  Em 10 min: `token_saver.digest` 155, `agent.account.usage` 113, `agent.account.usage.refresh` 42, `agent.thread.token_usage` 80 — cada um é `EventLogRepository.append` (345 amostras da fila SQLite, o maior escritor) + fan-out para Pet, Bots VMs e WebSocket. `agent.item.started` 590 é legítimo (iOS espelha).
  Fazer: (a) descobrir quem publica `token_saver.digest` e `agent.account.usage.refresh` nessa frequência (`Sources/RemoteCodeTreaty/Events.swift:4,5,138`; publicação em `AppContext`) e coalescer para ≤ 1 a cada 5 s por run; (b) marcar `token_saver.digest` e `agent.account.usage.refresh` como efêmeros (publicar sem `append` na tabela `events`) **se** o iOS não os usar em `events.recent` — confirmar em `Sources/SocketServer/Dispatcher.swift:4633` e no app iOS antes; decisão do dono se usar.
  Verificar: contagem por `kind` na tabela `events` em 10 min de 3 runs: contabilidade ≤ 10% do total; `agent.item.*` inalterado.

## F2 — Custo que cresce com o tamanho do transcript (Agent App)

Auditoria de código de 2026-09-14 (leitura de `AgentAppSurface.swift`, `AssistantEvents.swift`, `AgentChatLiveTurnChrome.swift`, `AgentChatUXPresentation.swift`, `AgentLinkedInlineText.swift`). Íntegros e sem regressão: isolamento do composer (`AgentComposerState`), `mutateItem` newest-first, `mergeTranscriptEntries`, `enforceAggregateHotTextBudget`, `acceptsStreamEvent`, memo de turnos finalizados via `.equatable()`. O que ainda cresce:

- [x] **AA-20 · P0 · por frame — `turnView` calcula `turnRenderInputs(for:)` inteiro e só usa `turnPlans`; no turno vivo inclui normalização O(mensagens × tamanho do corpo).**
  **FEITO `be3ce49b`** — `turnView` só filtra planos; `equalsAny/matchesAny` normalizam o LHS 1×; plumbing morto removido. Pin `test_turnViewDoesNotComputeTheFullTurnRenderModel`.
  `AgentAppSurface.swift:15941` chama `turnRenderInputs(for: turn)`; só `inputs.turnPlans` (`:15953`) é lido — `visibleBlocks`, `completedWorkBlocks`, `expandedWorkSourceItems`, `shouldRenderFinal` não têm consumidor (`completedWorkDisclosure` `:16004` tem 0 call sites). Para turno vivo o memo é pulado (`:13462`) e `computeTurnRenderInputs` (`:12040`) → `renderableItems` → `shouldRenderAssistantItemBody` → `assistantText(_:equalsAny:)` (`:12173`) normaliza o corpo **vivo** de novo para cada mensagem persistida (`:12196`), e acima de 16 KiB (`:12215`) sem cache: laço por scalar com `CharacterSet.contains` 2× por candidata. Custo `O(itemsAssistente × mensagens × tamanhoCorpo)` por frame.
  Fazer: em `turnView` usar só o filtro de planos (como `turnSegmentView:15875` já faz); em `equalsAny/matchesAny` normalizar o LHS uma vez fora do laço; subir/remover o limite de 16 KiB do cache (chave por `(utf8.count, Hasher)`).
  Verificar: teste que conta chamadas de `normalizedAssistantText` por frame com corpo de 64 KB e 200 mensagens → O(1) no LHS; snapshot visual igual.

- [x] **AA-21 · P0 · por frame — `placingMatchingFinalsAfterTurns` renormaliza todo texto assistente do thread a cada body, com fallback O(n²) de `contains`.**
  **FEITO `be3ce49b`** — `paintOrderedTranscriptEntriesCached` memoiza a permutação por (assinatura, turnos finalizados, mensagens); aplica sobre entradas frescas.
  `AgentChatUXPresentation.swift:683-760`, chamado de `paintOrderedTranscriptEntries:12836` → `transcriptColumnPaint:12881` → body `:14192`, sem memo. `compactFinalText` por scalar até 32 KiB; `turnFinals.last(where: normalizedFinalTextsMatch)` (`:713`) faz `a.contains(b) || b.contains(a)` contra todos os finais para toda mensagem sem chave exata. `turnFinalText` (`:12823`) é `items.last(where:)` por turno.
  Fazer: memoizar o resultado de `transcriptColumnPaint`/`allEntries` na mesma `transcriptSignature` (`:13348`) que `transcriptEntries` já usa; cachear `normalizedText` por id+digest; remover o fallback linear.
  Verificar: teste: 300 mensagens/150 turnos, 100 deltas → `placingMatchingFinalsAfterTurns` roda ≤ 2×.

- [x] **AA-22 · P0 · por linha — `visibleHiddenPersistedIDs` faz `messages.first(where:)` por id escondido, por linha assistente, mesmo em cache hit.**
  **FEITO `be3ce49b`** — lookup lazy via índice construído sob demanda só quando `requiresDurableRow`.
  `AgentAppSurface.swift:13603`: argumento `messageText:` avaliado eager (`vm.messages.first(where:)`) antes do early-return de `keepsTokenSaverPersistedHidden` (`:13594`); ambos os ramos de cache (`:13572`, `:13580`) chamam; lido em `messageRow:15564`. `tokenSaverRequiresDurableMessageRow` (`:890`) termina em `turns.contains(where:)`. Custo `O(linhas × ids × mensagens)` por frame.
  Fazer: `@autoclosure`/lookup após o guard; índice `[AgentMessageID: AgentMessage]`; guardar o conjunto filtrado junto de `hiddenPersistedAssistantMessageCache`.

- [x] **AA-23 · P1 · por delta — `AgentChatLiveTurnView` recompõe e reagrupa "Ran N commands" do zero no turno vivo, sem cap de items.**
  **FEITO `ef5e7fef`** — só a parte do memo de `toolGroupSummary` (chave por hash antes do scan; verbos só em miss). Cap de items no turno vivo NÃO feito (mudaria o render do Bots também; decisão do dono).
  `AgentChatLiveTurnChrome.swift:866`: `compose(turn)` + `workBlocks` por delta; `==` (`:852`) compara `finalAssistantMessage` inteiro; caps `liveTurnRenderableItemLimit = 48` / `visibleLiveTurnItems` (`:12403`, `:12525`) só existem no caminho morto de AA-20 — turno com 300 tool calls monta 300 linhas. `toolGroupSummary` (`:319`) monta a chave memo com `ids.joined` (~11 KB) **antes** do lookup.
  Fazer: aplicar `visibleLiveTurnItems`/`liveRenderableCopy` a `composition.activity` quando `live`; chave do memo por `(count, first.id, last.id, last.state)` antes do scan; `==` comparar `utf8.count` do final antes do texto.

- [x] **AA-24 · P1 · por quantum — `safelyIndexedTokenSaverItemTranslations` percorre todos os items do thread a cada quantum de stream.**
  **FEITO `be3ce49b`** — reindexa só quando translations ou `timelineItemStructureKey` mudam. Teste `test_timelineItemStructureKey_changesOnlyWhenTheItemSetChanges`.
  `AgentAppSurface.swift:795`, via `refreshTokenSaverOptimizationStateFromTimeline` (`:9782`) chamado em `commitStreamQuantum:9213` (gap 4 ms). Duas passadas `for turn { for item }` + `Set(messages.filter user)` (`:9742`); guard `:9118` só curto-circuita quando tudo vazio; `applyRefusedStreamEventDirectly:9278` chama sem guard.
  Fazer: recomputar só quando `itemTranslations`/contagens mudarem (assinatura) ou indexar incrementalmente pelos ids tocados no quantum.

- [x] **AA-25 · P1 · por frame — `transcriptEntries` rematerializa dois dicionários do thread inteiro 3× por body.**
  **FEITO `be3ce49b`** — `transcriptEntries` materializado 1× por body; `visibleEntries` e `activeBotPeerReviewName(in:)` reutilizam; `last(where:)` no lugar de `reversed().compactMap`.
  `:13030` → `rematerializedTranscriptEntries:13069` mesmo em hit de assinatura; lido em `:14193`, `:14228` (`visibleTranscriptEntries`), `:13127` (`activeBotPeerReviewName`). Também `:14209` `reversed().compactMap{}.first`; `makeChatRowPaintContext:12700` roda `peerHopIdentity` por linha e `assistantBodies(in:)` + `compactFinalText` 2× por turno (`:12738-12748`).
  Fazer: calcular uma vez em `let` no topo do body e passar adiante; rematerializar só a janela visível; `first(where:)` lazy; `assistantBodies` uma vez por turno.

- [x] **AA-26 · P1 · por delta — `AgentTranscriptState.timeline didSet` compara o corpo assistente inteiro contra o próprio prefixo a cada delta (O(n²) por resposta).**
  **FEITO `be3ce49b`** — `utf8.count` antes da igualdade de String.
  `AgentAppSurface.swift:123` → `hideSetRelevantTurnEquals:204`, `:230` `body != body`; turnos históricos já curto-circuitam por `itemsShareStorage` (`:191`), o último não.
  Fazer: comparar `body.utf8.count` primeiro; igualdade completa só se contagens iguais.

- [x] **AA-27 · P1 · por evento — reducer ainda faz `firstIndex` oldest-first em `itemStarted`/`turnStarted`/`turnCompleted`.**
  **FEITO `cec5132a`** — `turnIndex`/`itemIndex` newest-first + seam `turnLookupComparisonsForTesting`; teste 500 turnos × 300 eventos linear.
  `AssistantEvents.swift:1480`, `:1487` (O(items²) por turno e por replay ao abrir thread), `:1595`, `ensureTurn:1730`; `indexTokenSaverTranslation:1752` varre a timeline inteira quando não acha o id.
  Fazer: `lastIndex(where:)` (mesma semântica em ordem append; `mutateItem(turnId:itemId:)` `:1842` já faz).
  Verificar: teste de replay com 2.000 items em 1 turno: contagem de comparações linear.

- [x] **AA-28 · P2 · por layout — `AgentLinkedInlineText` paga O(texto) por linha montada 2× (fingerprint = só `characters.count`, fallback `attributed != attributed`).**
  **FEITO `390af3ad`** — `sourceFingerprint` (hash UTF-8 do texto fonte) desce até o representable; `contentFingerprinted` dispensa o `AttributedString ==`. Teste `test_updatePlan_contentFingerprintsMakeEqualRowsNoOpWithoutDeepCompare`.
  `AgentLinkedInlineText.swift:305`, `:205`; `apply(to:)` chamado em `updateNSView:300` e `sizeThatFits:296`; `AgentMessageMarkdown.cacheKey:82` faz `hasher.combine(text)` por bloco mesmo em hit. Vale para Agent App e Bots (mesma view).
  Fazer: fingerprint pelo conteúdo (reaproveitar a chave do markdown) e remover o fallback `||`.

- [x] **AA-29 · P2 — `TimelineItemIndex` é construído (`:2328`, `:2661`, `:2771`, `:5907`, `:9330`) e nunca lido em produção (`timelineItemLocation:1954` só em testes).** Remover as construções ou ligar em `mutateItem`.
  **FEITO `09bf5cdc`** — propriedade, 7 construções e acessor removidos (sem leitor em produção); struct + testes mantidos. Pin `test_viewModelNoLongerBuildsTheUnreadTimelineItemIndex`.

- [ ] **AA-30 · P2 · scheduled — `tickScheduledLivePoll:5882` zera a timeline e replays todos os eventos a cada 2 s.** Replays só além de `scheduledLiveStreamCount`.

- [x] **AA-31 · P2 · memória — `sr1TranslationsByItemId` guarda 2 entradas por item (`AssistantEvents.swift:1751,1755`), só poda no teto de 5.000 turnos; `hiddenPersistedAssistantContentKey:12314` monta String O(mensagens+turnos+items) a cada delta; `workDisclosureRevealByTurn` fora de `pruneExpandedItemIds:14380`.** Trocar a String por fold de `Hasher`; incluir no prune.
  **FEITO `09bf5cdc`** — chave do hide-set cacheada por mensagem (`AgentTranscriptState.messagesGeneration`, só bump em mudança real) e por turno finalizado (items.count + tamanho do final); só o turno vivo é re-hasheado por delta; `workDisclosureRevealByTurn` entrou no prune. `sr1TranslationsByItemId` (2 entradas/item) ficou como está (memória, sem custo por frame). Testes `test_hiddenPersistedContentKeyPartsComposeToTheFullKey`, `test_messagesGenerationMovesOnlyWhenMessagesChange`.

## F3 — Custo que cresce com o tamanho do chat (Bots)

Auditoria de código de 2026-09-14 (`BotsWindow.swift`, `BotsDeskFollowThrough.swift`, `AgentChatLiveTurnChrome.swift`, `AgentChatTimelineChrome.swift`). PF-04 ficou pela metade: `runCoordinator(didReceive:)` (`:10241`) pré-filtra por thread antes do hop (bom), mas `didFinish`/`didChangeStatus` (`:10249-10300`) **não** — hopam para todo run de todo thread e chamam `refreshActiveBotCount` → `liveWorkingBots` (`:3581`, `:3850`) → `conversationsLinked` + `bots(ids:)` no main. Íntegros: composer isolado (`BotsComposerState`, `BotsComposerReactiveScope`), drafts em UserDefaults com 250 ms, mensagens paginadas em 80, rails em `LazyVStack`, scroll-to-bottom coalescido, `AgentLinkedInlineText` sem invalidação síncrona.

- [x] **BT-20 · P0 · por delta — nenhum batching: um `Task { @MainActor }` + um `@Published` write no `BotsViewModel` monolítico por token → toda a árvore Bots (rail, header, timeline, inspector) reavalia por token.**
  **FEITO `58db877d`** — versão lite: `DeskStreamEventBatchBox` (1 hop + 1 publish por lote; bookkeeping por evento preservado). `BotsTranscriptState` separado NÃO feito (refator maior). Teste `test_deskStreamEventsCoalesceIntoOneMainHopAndOnePublishPerBatch` (200 eventos → 1 hop).
  `BotsWindow.swift:8746-8790` (`applyIncomingDeskEvent`, de `:10244`); `BotsRootView:10739` observa o VM inteiro. Além disso `liveTimelineByThread[threadId] = next` (`:8760`) mantém 2ª referência ao struct → o `var next = deskLiveTimeline` seguinte copia `turns` e `items` inteiros (CoW derrotado) a cada evento. Agent App já tem `streamEventBatch` + flush por tick + `timelineUpdateTick` 33 ms + `AgentTranscriptState` separado (`AgentAppSurface.swift:9368-9436`, `:98`).
  Fazer: portar batching + tick de 30 Hz; mover `deskLiveTimeline`/`deskMessages`/`deskWorkLog` para um `BotsTranscriptState: ObservableObject` consumido num `BotsTranscriptReactiveScope` (o padrão `BotsComposerReactiveScope:10723` já existe); não espelhar em `liveTimelineByThread` enquanto o thread está selecionado (só em deselect/terminal).
  Verificar: teste: 300 deltas em 100 ms → ≤ 4 publishes do transcript state e 0 do VM raiz.

- [x] **BT-21 · P0 · por frame — `AgentChatLiveTurnView` sem `.equatable()` no Bots Desk (Agent App tem).**
  **FEITO `58db877d`** — `.equatable()` nos 2 sites. Pin `test_botsDeskLiveTurnRowsAreEquatableAndRailTakesOneLiveSnapshot`.
  `BotsWindow.swift:12065-12078` vs `AgentAppSurface.swift:15901`, `:15958`. Sem isso todo turno roda `compose(turn)` + `workBlocks` por passada (`AgentChatLiveTurnChrome.swift:866`). Idem `AgentChatAssistantReply` (`:12123`) e `AgentChatUserBubble` (`:12114`). Mudança de 2 linhas; maior relação esforço/impacto do Bots.

- [x] **BT-22 · P0 · por frame — `vm.deskTimeline` (computed, sem memo) reconstrói o modelo do transcript a cada body com scan O(mensagens × turnos × items × bytes).**
  **FEITO `58db877d`** — `deskTimeline` memoizado por chave estrutural + rematerialização dos turnos vivos; segmentos de turno vivo caem no recálculo. Teste `test_deskTimelineIsMemoizedAcrossBodyPassesAndRematerializesLiveBodies`.
  `BotsWindow.swift:3999-4007` → `BotsDeskFollowThrough.swift:147-186`, lido no body em `:11979`. `messageDuplicatesTurn` (`AgentChatLiveTurnChrome.swift:178-184`) itera todos os turnos, `assistantBodies` + `trimming`, `assistantTextsMatch` (`:164`) com `a.contains(b) || b.contains(a)`; `compose(turn)` roda ~4× por turno por passada (`:163-171`, `deskPaintsLiveTurnChrome` 2× em `:4004-4005`); `sorted(by: turnSortDate)` recalcula `items.min` dentro do comparador (`:176`, `AgentChatLiveTurnChrome.swift:281`); `composeConversationOrder:262` reordena tudo; `BotDeskTimelineItem.createdAt:2580` idem.
  Fazer: `deskTimeline` como stored, recomputado só quando `deskMessages`/`deskWorkLog`/estrutura de turnos mudar; `sortDate` pré-computado por turno; `compose` 1× por turno em dicionário por `turnId`; dedupe por `Set` normalizado (o `shouldHideAssistantOutput:209` já faz O(1)).

- [ ] **BT-23 · P1 · 2 s — o watch do turno vivo replays até 4.096 eventos do SQLite no main a cada 2 s depois que um turno longo estoura o budget observado.**
  `BotsWindow.swift:8795-8826` → `applyDeskLiveReplay:8649` → `:8713-8715` `coordinator.latestStreamEvents` (`AgentRunCoordinator.swift:5307`, até 4.096 eventos / 32 MiB, decode síncrono no MainActor) + `timelineByReplaying`. O caminho incremental (`:8669-8711`) é desligado quando `liveObservedEventOverflowThreads` contém o thread (`:8780`) — que é exatamente o turno grande; fica no replay cheio até `clearDeskObservedEvents`.
  Fazer: fetch+replay em `Task.detached` com generation; overflow recuperável (re-seed do cursor pelo próximo sufixo atestado).

- [x] **BT-24 · P1 · por terminal — qualquer run terminal (de qualquer bot) dispara restore completo do desk 2×, mesmo com o bot não selecionado e Bots invisível.**
  **FEITO `58db877d`** — só o dedupe por `(thread, run)`; o gating dos restores por bot selecionado foi REVERTIDO porque `test_authorityDeltaUpdatesTwoLiveWindows…` pina que a segunda janela atualiza o cache do desk no terminal. Teste `test_duplicateTerminalNotificationsApplyFollowThroughOnce`.
  `adoptLinkedRunTerminal:9974` chamado de `didFinish:10262` e do ramo terminal de `didChangeStatus:10278`; `applyFollowThrough:9662` faz `restoreDeskMessages` (listRecent 80 + decode + 2 queries rcw1), `restoreDeskWorkLog`, `restoreDeskLiveTurn` (→ BT-23), `refreshPublishedIdentity`, `upsertConversation`, `applyAttentionState` → `refreshActiveBotCount` (2 queries). `settledTerminalRunIDByThread` (`:9975`) não é usado para dedupe.
  Fazer: dedupe por `settledTerminalRunIDByThread[threadId] == runId`; pular `restoreDeskMessages`/`restoreDeskLiveTurn` quando `selectedBotID != bot.id || screen != .desk`; pré-filtrar `didFinish`/`didChangeStatus` por interesse antes do hop.

- [x] **BT-25 · P1 · por linha — lock global do coordinator + `Set` novo por linha do rail por passada.**
  **FEITO `58db877d`** — `liveDeskThreadIDsSnapshot()` 1× por passada do rail.
  `:12369` `vm.isDeskConversationRunning(conversation)` → `:4836` → `liveDeskThreadIDs():4839` → `coordinator.activeThreadIdsSnapshot()` (`NSLock` global, aloca `Set`), por linha visível + `filteredDeskConversations:4820` + `deskThreadActiveCount:4823`, dentro do body que roda por token (BT-20). Contenção direta main ↔ thread de stream.
  Fazer: calcular o `Set` 1× por passada/tick e passar para as linhas.

- [x] **BT-26 · P2 · memória — caches por thread nunca podados na sessão.** `BotsWindow.swift:3362-3371`: `liveTimelineByThread` (até 32 MiB **por thread**, `AssistantEvents.swift:1038`), `liveStreamCountByThread`, `liveStreamCursorByThread`, `settledTerminalRunIDByThread`, `messagesByConversation`; janelas destacadas multiplicam. LRU de 3-5 threads; o replay do SQLite já reidrata.
  **FEITO `f9a331dc`** — LRU de 6 timelines com o thread selecionado fixado (`lruEvictions`), cursores/contagens evictados junto; `messagesByConversation` (≤80 msgs cada) ficou como está. Teste `test_liveTimelineLRUEvictsOldestButNeverThePinnedThread`.

- [x] **BT-27 · P2 · por turno — `tokenSaverMessage(forTurnId:)` (`:4280`) filtra `deskMessages` por turno por passada (`:12069`, `:12077`).** Índice `[String: BotDeskMessage]` ao atribuir `deskMessages`.
  **FEITO `58db877d`** — índice `tokenSaverMessagesByTurnId` no `didSet` de `deskMessages`.

- [x] **BT-28 · P2 · por body — `vm.selectedBot` (`:3528`) cai em `botStore.get(id:)` (SQLite) no body quando o bot não está em `bots` (janelas destacadas, roster filtrado); lido em `:11471` e `deskWorkingContext:5473`.** Cachear o fallback.
  **FEITO `58db877d`** — `selectedBotFallbackCache` invalidado no `didSet` de `bots`.

- [ ] **BT-29 · P2 · por render — `ForEach(Array(historyItems.enumerated()))` (`:12003-12024`) aloca array de tuplas com `AssistantTurnSnapshot` inteiro por render; `splitLiveTail` (`BotsDeskFollowThrough.swift:189-199`) copia 2× O(n).** `ForEach(historyItems)` + índice lateral; `ArraySlice`. (Não voltar para `LazyVStack`: hang registrado em `AgentChatTimelineHistoryLayout.usesLazyLayout`.)

## F4 — Persistência e fan-out por evento

Auditoria de código de 2026-09-14 (`AgentRunCoordinator.swift`, `AppContext.swift`, `EventBus.swift`, `EventLog.swift`, `Repositories.swift`, `PerfSwitchMetrics.swift`). Saudáveis: persistência de stream events em batch por thread (250 ms / count / bytes, uma transação), `storage_usage_counters` (1 página suja por transação), `EventLogRepository.append` off-main na `backgroundWriterQueue`, sem VACUUM/checkpoint no main, `agent_turn_snapshots` **não tem escritor** (tabela morta), Graphify por delta com curto-circuito, `persistProviderNativeSubagentLifecycle` gated.

- [x] **EV-20 · P0 · main — `PerfSwitchMetrics` grava toda espera de SQLite no main em dois arrays sem limite e, acima de 2 ms, simboliza a stack (`Thread.callStackSymbols`) no main — em release.**
  **FEITO `842ec837`** — ring de 512 + captura de stack só em DEBUG. Teste `test_recordedIntervalsAndMainWaitsStayBounded`.
  `SQLite.swift:453-458` → `PerfSwitchMetrics.swift:147-180`, `:214-216`; `slowMainSyncNanoseconds = 2 ms`; só o `NSLog` está em `#if DEBUG`. Realimentação positiva: quanto mais contenção, mais tempo o main gasta simbolizando. Nenhum leitor em produção (só `*ForTesting`).
  Fazer: `isCapturing` false em release (ou `#if DEBUG` no corpo); arrays em ring de 512; remover `callStackSymbols` em release.

- [x] **EV-21 · P0 · por evento — `BotPeerHandoffAuthority` hopa para o MainActor em todo `AssistantEvent` de todo run, sem filtro.**
  **FEITO `b17d0ea6`** — `PeerProgressStamps` com lock, escrito na thread do stream; poda em `didFinish`. Teste `test_peerHandoffAuthorityStampsStreamProgressWithoutMainActorHop`.
  `BotsWindow.swift:2499-2508` (registrado em `:792`): `Task { @MainActor { lastPeerProgressByRunID[run] = Date() } }` por delta (~90 tasks/s com 3 runs); lido só em `:2485`; nunca poda runs terminados.
  Fazer: dicionário com `NSLock` escrito na thread chamadora, ou early-return se `run` não é peer rastreado; podar em `didFinish`.

- [x] **EV-22 · P0 · main — `recomputeTokenSaverDailyEconomyToday` também dispara do caminho Graphify, por item de tool finalizado.** (complementa PL-01)
  **FEITO `30f1ff5d`** junto com PL-01 (os 3 gatilhos Graphify usam o mesmo agendador coalescido).
  `AppContext.swift:5865`, `:5881` (`processGraphifyBuffer` → `DispatchQueue.main.async { recomputeTokenSaverDailyEconomyToday() }` por `markSucceeded`/falha), `:5725` (`failGraphifyUsageItem`). `loadTokenSaverDailyEconomySharedSnapshot` (`:5432-5433`) instancia `SettingsStore` novo (cache por instância → miss garantido, `SettingsStore.swift:317,343`) e lê+decodifica `usage.json` no main.
  Fazer: junto com PL-01 — debounce ~2 s, `Task.detached` com generation, um `SettingsStore` compartilhado no `AppContext` invalidado por `SettingsStore.revision` (padrão em `:5536-5552`).

- [x] **EV-23 · P1 · por `.tokenUsage` — 12-25 leituras SQLite por evento na thread de parse do provider, segurando o lock da conexão única.**
  **FEITO `62181a96`** — memo por `(run, lane, SettingsStore.revision, TokenSaverLaneStateRepository.revision, AgentThreadRepository.identityRevision)` (exato: `test_providerUsageCreatesAppendOnlyAttemptEvidence…` promove a lane no meio do run e continua passando); `isTokenSaverRuntimeActive()` cacheado por (revisão, admitted), invalidado em mudança de conta/admissão. Revisões em `51688fd8`.
  `AppContext.swift:4885` (`recordTokenSaverUsage`): `tokenSaverProjectObservation` (`:3530-3553`: `runRepo.threadId` + `isTokenSaverRuntimeActive()` [`SettingsStore` novo + `PrivateAccountSessionStore.load()`] + `threadRepo.identity` + `laneStateRepo.get`) chamado 3-4× por evento (`:4915`, `:5005`, `:4962`, dentro de `beginTokenSaverAttempt:4965` com `ledger.attempt` + `provider` + `model`). Não é CPU do main: é starvation das leituras da UI. Também é corrida: `AppContext` é `@MainActor` mas `onAssistantEvent` (`:1255`) roda na thread de parse (`AgentRunCoordinator.swift:2409`) e muta `pendingUsageByRun`.
  Fazer: memoizar `tokenSaverProjectObservation` por `(runId, lane)` pela vida do run (limpar em `onRunFinished`); `isTokenSaverRuntimeActive()` cacheado por `(settingsRevision, accountIdentity)` como `isGraphifyUsageRecordingAdmitted:5536`.

- [x] **EV-24 · P1 · db — `knownProviderEventIds` copia um `Set<String>` sem limite a cada insert de provider event (CoW derrotado) e nunca poda.**
  **FEITO `51688fd8`** — `contains` em escopo próprio + limite de 2.000 ids por thread (re-seed). Teste `test_knownProviderEventIdsStayBoundedPerThread`.
  `Repositories.swift:6013`, `:6035`, `:6039-6078`: `known` vivo enquanto `rememberProviderEventId` insere no `Set` do dicionário → cópia completa por evento; retenção mantém 100 linhas mas o `Set` guarda todos os ids do run. Único custo O(eventos acumulados) por evento na persistência, dentro da transação.
  Fazer: `let isKnown = knownProviderEventIds(...).contains(id)` em escopo próprio; limitar o `Set` a `providerLogCountPerThread * 2` (re-seed por SELECT).

- [x] **EV-25 · P1 · db — `token_saver.digest` publica sem dedupe (155/10 min) com I/O de arquivo + SQLite no main; `events` persiste kinds efêmeros.**
  **FEITO `62181a96`** — dedupe em `cacheAndPublish` (corpo igual módulo `updated_at_ms`) + `publishFromDisk` fora do MainActor. Persistência dos kinds na tabela `events` NÃO alterada (decisão do dono, paridade iOS). Teste `testIdenticalDigestsAreNotRepublished`.
  `AppContext.swift:3371-3382` (`publishTokenSaverWidgetDigestFromDisk`: `SettingsStore` novo + `PrivateAccountSessionStore.load()` + `TokenSaverUsageStore.load()` + `economyRepo.record` + `windowTotalCredible`, no main) → `TokenSaverWidgetDigest.swift:126-159`, `cacheAndPublish:180-185` publica sempre (`updated_at_ms` sempre novo). Prefiltro de persistência `AppDelegate.swift:1026-1036` só exclui `surface.output`, `agent.item.delta`, `agent.item.progress`, `agent.provider_runtime.event`. Cada append é BEGIN IMMEDIATE/INSERT/prune/COMMIT (`EventLog.swift:79-92`) e, no teto de 5.000 linhas, roda `DELETE FROM command_receipt_events WHERE NOT EXISTS (...)` (`:49-55`, sem índice) por append.
  Fazer: comparar `body` sem `updated_at_ms` com `lastBody`; leituras em `Task.detached`; `token_saver.digest` e `agent.account.usage.refresh` fora da tabela `events` **após** confirmar que o iOS não depende de `events.recent` para eles (`Dispatcher.swift:4633`) — decisão do dono; `deleteOrphanedReceiptLinks` na cadência de 50 appends de `eventLogPruneInterval`; batch de appends por ~100 ms.

- [ ] **EV-26 · P1 · main — `EventBus.publish` do MainActor bloqueia em `deliveryQueue.sync` atrás do backlog de 3 runs e do fan-out (filter + encode WS) inline.**
  `EventBus.swift:288-294`, `:376-392`; publicadores no main: `publishTokenSaverWidgetDigestFromDisk`, `publishTokenSaverAccountUsageRefresh` (`AppContext.swift:3358`), `onRunFinished:1486`.
  Fazer: `publishAsync(kind:payload:)` (ramo `async`) para publicações originadas no main; a fila serial já garante ordem.

- [ ] **EV-27 · P2 · db — `streamRetentionIsUnderBudget` faz `SELECT SUM(LENGTH(payload))` (até 8 MiB) a cada 25 eventos por thread quando **abaixo** do teto de 100 linhas (estado normal).**
  `Repositories.swift:6200-6226`; cadência `AgentRunCoordinator.swift:1314`; caps `LocalStorageBudget.swift:37-40`. Fazer: contador por thread em `storage_usage_counters` (triggers já existem) ou confiar no cap de linhas + reclaim imediato (`:5421-5426`).

- [ ] **EV-28 · P2 · db — `token_saver_attempt_events` cresce sem retenção; 3 `performSync` separados por `.tokenUsage`.** `TokenSaverT003Persistence.swift:1693-1720`, `Schema.swift:767-775`. Uma `db.transaction`; poda por idade no `runCCRRetention` de 24 h (`AppDelegate.swift:997-1017`).

- [x] **EV-29 · P2 · main — Pet: `noteLiveActivityProgress` (`PetController.swift:576-612`) aceita `agent.item.delta` e cai em `applyActiveThreadIDs` → `conversationsLinked` (`:1178`) quando algum chrome não está cacheado.** (complementa PL-03)
  **FEITO `ed85970e`** junto com PL-03 (`cachedBotID(linkedTo:)` primeiro; SQLite só off-main para misses). Usar `botStore.cachedBotID(linkedTo:)` (`BotStore.swift:92`, sem lock de DB) e só cair no SQLite off-main para misses.

- [ ] **EV-30 · P2 — `.rc2TokenSaverUsageChanged` a cada 2 s faz cada surface aberta reduzir todos os corpos assistente + 2 leituras SQLite (`AgentAppSurface.swift:2012+`).** (complementa PL-02) `assistantChars` incremental; pular quando `surfaceVisibility != .visible`.

## F5 — Achados da 2ª varredura (2026-09-14, tarde)

- [x] **S-01 · P1 · por frame — `makeChatRowPaintContext` (Agent App) e `BotsDeskFollowThrough.timeline` (Bots) normalizavam todos os corpos assistente de todos os turnos visíveis a cada body pass (laço por scalar até 32 KiB por texto).**
  **FEITO `7ee72473`** — `AgentChatLiveTurnChrome.normalizedAssistantFinals(for:)` memoiza turnos finalizados por (turnId, items.count, tamanho do final) em `NSCache` de 512; turnos vivos sempre recalculados. Teste `test_normalizedAssistantFinalsMemoizeFinishedTurnsOnly`.

- [ ] **EV-25(c) · P1 · db — uma transação SQLite por evento publicado (`EventLogRepository.append`: BEGIN IMMEDIATE / INSERT / prune / COMMIT) e, no teto de 5.000 linhas, `DELETE FROM command_receipt_events WHERE NOT EXISTS (…)` por linha.**
  `AppContext.wireBackgroundPersister` (`AppContext.swift:6053`), `EventLog.swift:79-92`. Fazer: buffer com lock + flush enfileirado na `backgroundWriterQueue` assim que o buffer deixa de estar vazio (latência igual quando ocioso; coalesce só sob tempestade) → `appendBatch` em uma transação; o `DELETE` de órfãos passa a rodar 1× por lote. Verificar: 40 eventos publicados com a fila segurada → todas as linhas no disco após o `persistenceCommitFence` e `eventLogFlushCountForTesting < 40`.

- [ ] **AA-32 · P2 · por frame — `AgentMessageMarkdown.cacheKey(for:)` faz `hasher.combine(text)` (O(texto)) a cada lookup de bloco/inline por linha montada por passada, mesmo em hit de cache; `AgentLinkedInlineText.body` paga o mesmo hash de novo para o `sourceFingerprint` (AA-28).**
  `AgentMessageMarkdown.swift:82-88`, `AgentLinkedInlineText.swift` body. Fazer: calcular o hash 1× por body e reutilizar como chave do cache e como fingerprint (passar `sourceFingerprint` para `attributedInline`/`blocks` como chave pré-computada); ou chavear por identidade estável do dono (id da mensagem + `messagesGeneration`, id do item + `utf8.count` para corpos vivos). Não medido: precisa de amostra durante scroll com histórico revelado.

## Adiados nesta rodada (com motivo)

- **PL-05 / EV-25(b)** — tirar `token_saver.digest` e `agent.account.usage.refresh` da tabela `events`: depende de confirmar no app iOS que `events.recent` não é usado para eles (decisão do dono). O dedupe do digest (EV-25) já derruba a maior parte do volume.
- **BT-23** — replay de até 4.096 eventos no main a cada 2 s: o watch só roda quando não há push nos últimos 1 s (`lastDeskStreamPushAt`), então não dispara durante streaming ativo; o caminho de cursor/observed events é delicado e precisa de teste de corrida próprio antes de ir off-main.
- **BT-20 (parte estrutural)** — `BotsTranscriptState` separado do `BotsViewModel`: refator grande; a versão lite já reduz a 1 publish por lote.
- **BT-26 / BT-29 / AA-29 / AA-30 / AA-31** — memória e limpezas P2 sem evidência de custo por frame; fazer junto com uma amostra de memória em sessão longa.
- **AA-23 (cap de items do turno vivo)** — muda o que o Bots renderiza para turnos com centenas de tool calls; precisa decisão de UX.
- **EV-26** — `publishAsync` no EventBus: após EV-25 o publish do digest a partir do main ficou raro; sem evidência restante.
- **EV-27 / EV-28** — SUM de payload por thread e retenção de `token_saver_attempt_events`: mudam schema/retention; precisam de bump em `Schema` + teste de migração.
- **EV-30** — `assistantChars` incremental: PL-02 já tirou o reduce do main; o custo restante é O(mensagens ≤ 80) off-main.

## Critérios de aceite

- Amostra de 8 s, release, 3 runs ativos, sem interação: main thread ocupado ≤ 5% (hoje ~26%); 0 amostras de `performSync` no main vindas de Token Saver ou Pet.
- Digitar no composer de um thread com ≥ 300 items: nenhum frame > 16 ms atribuível a `AgentAppSurface`/`BotsWindow` (medir com `sample` durante digitação).
- Nenhum item pode mudar o que o iOS recebe em `agent.item.*`, `agent.run.*`, `agent.thread.*`.

## Não verificado (dizer a verdade sobre o que falta)

- Nenhum item tem medição antes→depois no app release ainda: os números da tabela são da amostra de hoje ANTES das mudanças. Falta reamostrar 8 s com a build nova e 3 runs ativos (critério: main ≤ 5%).
- Baseline-diff das suítes tocadas (`SurfacesTests`, `CoreModelTests`, `AppShellTests` selecionadas, `PersistenceTests`): 0 regressões; todas as falhas restantes falham igual no HEAD (`AgentAppViewModelTests` crasha em `swift test` na base — pulado com `--skip`).
- G-01 não foi validado com um run `/goal` real na build nova; `thread/goal/cleared` nunca foi observado no wire, então o encerramento depende do reconcile por `thread/read` (~2 s depois do último turno).
- A amostra foi tirada com o app sem interação. Falta amostrar durante digitação/scroll num thread grande para fechar F2.
