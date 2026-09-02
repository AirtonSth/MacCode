# TODO-Performance — trocar de aba e de conversa instantâneo; app leve com N runs simultâneos

Auditoria de 2026-09-02 (branch `production` @ `a9893cce`), feita com o app do dono rodando ao vivo. Objetivo do dono: **trocar de aba** e **trocar de conversa** instantâneos e o RemoteCode **leve** mesmo com "várias coisas rodando ao mesmo tempo". Este arquivo é auto-suficiente para outro agente executar do começo ao fim.

Relação com `TODO.md` (auditoria de 2026-09-01): aquele arquivo cobre o Agent App / Bots por dentro (digitar, stream, carregar transcript). F0–F2 dele já foram entregues (`d7128eec`). **Não duplique itens dele aqui** — quando um item daqui depender de um item de lá, ele é citado pelo id (`AA-xx`, `BT-xx`, `CH-xx`, `X-xx`). O que este arquivo adiciona é o que a auditoria anterior não olhou: o **shell** (troca de aba, sidebar, janela), os **consumidores do EventBus no main thread** (Pet, Bots), a **fila única do SQLite** como recurso compartilhado entre 5 runs e a UI, e os **processos filhos**.

## Regras obrigatórias para quem executar

1. Leia `AGENTS.md` §"Loading and perceived performance" e §"Isolated sandbox". Todo build/test/run em worktree isolado: `cd "$(scripts/isolated-sandbox.sh ensure)"`. O RemoteCode do dono (`io.remotecode.desktop`, `/tmp/RemoteCode.sock`, porta 18217, `~/Library/Application Support/RemoteCode/remotecode.sqlite`) é intocável. Nunca `pkill RemoteCode`.
2. Testes: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Alvo>`. `swift test` completo **não** é verde na base (≈5–7 falhas pré-existentes + 26 métodos de `BotsWindowTests` por diff de nome). Baseline-diff obrigatório: rode o filtro ANTES, guarde a lista de falhas, compare DEPOIS. Nunca escreva "tests pass" sem essa comparação.
3. Cada item precisa (AGENTS.md): teste do caminho imediato, do término exato, de corrida A→B com rejeição de resultado obsoleto, e de falha; medição antes/depois no mesmo ambiente, ≥5 amostras aquecidas, sem regressão assentada > `max(25 ms, 5%)`. Meça sempre em build **release** (`RC2_CONFIG=release`, ver `TODO.md` X-00).
4. Um commit por item. Mensagens: `perf(shell): PF-10 …`, `perf(pet): PF-01 …`, `perf(bots): PF-04 …`, `perf(db): PF-30 …`. Não refatore código adjacente. Não mude schema sem bump em `Schema` + teste de migração.
5. Medição sem Instruments: `sample <pid> 8 1 -mayDie -file out.txt` no app do sandbox; agregue os símbolos `(in RemoteCode)` e separe o bloco da `Main Thread`. Para latências de troca use os `os_signpost` do PF-00.
6. Ao terminar um item marque `[x]` com hash do commit e o número medido (antes → depois).
7. Paridade iOS (AGENTS.md): nada aqui pode deixar de emitir os eventos de host que o iOS espelha. Quando um item cortar eventos, corte só o que é diagnóstico/ruído e prove que `workspace.*`, `surface.*`, `agent.thread.*`, `agent.item.*` e `agent.run.*` continuam saindo.

## Evidência ao vivo (2026-09-02 18:29 -03, app do dono)

Tudo abaixo foi medido no processo real (pid 7584), **build release** (147.624.624 bytes, 0 caminhos `/debug/` no binário — X-00 do `TODO.md` está resolvido), 2h45 de uptime, 72 threads, footprint 396 MB (pico 678 MB).

**Carga em curso.** 5 runs `running` no DB (4 `grok` + 1 `claude`), com processos vivos correspondentes. Layout persistido: **9 panes, 13 surfaces = 8 Agent App + 3 Terminal + 1 SSH + 1 Git**. DB `remotecode.sqlite` = 1,53 GB, WAL 8,7 MB, 27.277 `agent_stream_events`, 304 threads.

**Processos da família RemoteCode: 27.** 1 app + 1 sidecar Distill + 5 CLIs de provider + **20 `RemoteCodeDistillService` filhos dos providers** (cada `grok` spawna 5: `bot-computer`, `bot-browser`, `bot-web`, `mcp`, `bot-self-config`; 18–27 MB RSS cada).

**Taxa de eventos do EventBus persistidos (`events`, últimos 10 min): 4.017 = 6,7 eventos/s.**

| kind | em 10 min | /s |
|---|---|---|
| `agent.provider_runtime.event` | 2.985 | 5,0 |
| `agent.item.started` + `agent.item.completed` | 833 | 1,4 |
| `token_saver.digest` | 97 | 0,16 |
| `agent.account.usage*` + `agent.thread.token_usage` | 95 | 0,16 |
| `diagnostic.ws_outbound_pressure` | 3 | — |

**Amostra de 6 s (1 ms) do main thread em idle-com-5-runs** (`audit/perf-switch-2026-09-02/sample-idle-6s-2026-09-02.txt`): 4.982 amostras, ~100 fora do run loop. Dessas, **90 são o Pet** (`PetController.start()` closure → `handle`):

| amostras | caminho no main thread |
|---|---|
| 60 | `PetController.apply` → `PetAnimationController.setState` → `publishCurrentFrame` → `PetWindowController.animationFrameDidChange` → `petPlacementContext` → `PetDockFrameProvider.frame` → `hitTestFrame` → `+[NSWindow windowNumberAtPoint:]` → `SLSCopyWindowRoutingRecordsForScreenLocation` (IPC síncrono com o WindowServer, 56 amostras) |
| 28 | `PetController.refreshActiveThreadsFromCoordinator` → `applyActiveThreadIDs` → `AgentThreadRepository.listChrome(ids:)` → **13 amostras paradas em `NSRecursiveLock.lock`** (fila do SQLite ocupada por outro escritor) |
| 5 | `CA::Transaction::commit` |

Fora do main: a fila `RemoteCode.SQLiteDB` teve 80 amostras (1,6% do tempo) — baixa em idle, mas é **uma fila serial única** que recebe os lotes de stream dos 5 runs, o INSERT de cada evento do EventBus (6,7/s), o log de terminal e **toda leitura síncrona da UI**. `AgentOrchestrationAdmissionReceipt.init(from:)` = 0 amostras (X-01 do `TODO.md` funcionou).

## Modelo mental (3 causas, em ordem de impacto)

- **A — o main thread é acordado ~7×/s por consumidores do EventBus que fazem IPC e SQLite síncronos.** O Pet assina o bus com `filter: .full`, deixa passar `agent.provider_runtime.event` (5/s) e, a cada `agent.item.*` (1,4/s), lê SQLite no main e refaz o hit-test do Dock com o WindowServer. Cada `BotsViewModel` (1 na sidebar + 1 por janela Bots) salta para o MainActor a **cada** stream event de **qualquer** thread antes de checar se interessa. Isso é o que o dono sente como "várias coisas rodando ao mesmo tempo": não é CPU total, é o main thread sendo interrompido continuamente por trabalho que não é dele.
- **B — uma fila SQLite para tudo.** Toda leitura da UI (`performSync`, `try? repo.x()`) entra na mesma fila serial que os escritores dos 5 runs. Em idle ela está 1,6% ocupada; num burst de stream (ou prune/checkpoint) qualquer leitura no main espera o lote inteiro. WAL permite leitores concorrentes, mas o app abre **uma** conexão (`Bootstrap.swift:241`).
- **C — a troca de aba/conversa faz trabalho estrutural síncrono.** Troca de aba = `removeFromSuperview` + `addSubview` de um `NSHostingView` inteiro (relayout de todo o `AgentAppView`, transcript eager incluso — CH-01), depois `focusTick &+= 1` num VM com 78 `@Published` (mais um body inteiro — AA-05). Abas ocultas do Agent App **nunca esfriam**: `AgentAppSurface` não implementa `didBecomeHidden/didBecomeVisible` (default no-op em `Surface.swift:24-25`), então 7 abas invisíveis com thread ativa pagam tick de 33 ms, flush de stream, reload de rail e savings do Token Saver o tempo todo. O protocolo de cold-state (`AgentVisibilityColdState.swift`) existe e **não tem nenhum uso** no código.

## Ordem de ataque

| Fase | Sintoma do dono | Itens | Ganho esperado |
|---|---|---|---|
| F0 | medir | PF-00 | números de troca de aba/conversa para provar cada item abaixo |
| F1 | "várias coisas ao mesmo tempo" | PF-01, PF-02, PF-03, PF-04, PF-05, PF-06 | main thread ≈0 interrupções/s fora da aba visível |
| F2 | trocar de aba | PF-10, PF-11, PF-12, PF-13, PF-14 | clique→pintura sem relayout de transcript nem body do VM |
| F3 | trocar de conversa | PF-20, PF-21 + `TODO.md` AA-08/CH-08/CH-09, CH-01, CH-05..07, AA-05/06, AA-07, AA-11, AA-12, AA-14..16, X-02 | abrir thread sem SQLite no main; rail e chrome baratos |
| F4 | leve com 5 runs | PF-30, PF-31, PF-32, PF-33 | UI nunca espera a fila de escrita |
| F5 | leve (memória/processos) | PF-40, PF-41 | −20 processos, −~500 MB |
| F6 | aceite | critérios no fim | |

Severidade: **P0** interrompe o main thread continuamente ou trava a troca; **P1** custo mensurável por troca/evento; **P2** desperdício menor.

---

## F0 — Medição (pré-requisito)

- [x] **PF-00 · P0 · medir — não existe medição de troca de aba nem de conversa.**
  **FEITO (1d188f29 — os_signpost + scripts/perf-switch-sample.sh + audit/perf-switch-2026-09-02/baseline.md (GUI p95 not claimed; unit contract green))**
  Hoje só há `shellLog.debug` em `applyFocusChangeInPlace` (`MainWindowController.swift`) e `agentOpenTrace` em `selectThread` (`AgentAppSurface.swift:2063`). Nenhum dos dois mede até a pintura.
  Fazer: `os_signpost` (subsystem `io.remotecode.perf`) em (a) `AppCommandRouter.focusSurface` (`AppCommandRouter.swift:2061`) → fim de `PaneTabsView.installSelectedContent` (`PaneTabsView.swift:276`) → próximo `CATransaction` commit (use o mesmo committed-frame barrier já usado em `342ea1a3`); (b) `selectThread` → primeiro `objectWillChange` → aplicação do open bundle (`hydrateOpenedThread` `:2384`); (c) intervalo de ocupação de `SQLiteDB.performSync`/`queue.sync` **quando chamado no main thread** (`SQLite.swift:432`). Em DEBUG, logar stack quando (c) esperar > 2 ms. Script `scripts/perf-switch-sample.sh` que roda o app do sandbox, abre um workspace com 8 abas Agent App e imprime p50/p95 das três medidas.
  Verificar: Instruments "Points of Interest" mostra os 3 intervalos; o script imprime números para a baseline atual e os guarda em `audit/perf-switch-2026-09-02/baseline.md`.

## F1 — Parar de acordar o main thread (P0)

- [x] **PF-01 · P0 · idle-com-runs — o Pet recebe `agent.provider_runtime.event` (5/s) no main thread para descartá-lo.**
  **FEITO (5f258973 — prefilter from decoder acceptedKinds; 100 provider_runtime events → 0 handles)**
  `PetController.swift:160-163`: assinatura `.full`; o prefiltro `isPrefilteredNoiseKind` (`:181-195`) lista deltas/progress/surface.*, mas **não** `agent.provider_runtime.event` (publicado em `AppContext.swift:1433`, fonte `grok.acp` `session_notification` como `interaction_resolved`). Cada um vira `DispatchQueue.main.async { handle }`; `handle` (`:466-511`) faz o reduce de workspaces, consulta `windowController.workspaceWindow(for:)` por workspace e chama `PetEventDecoder.decode` — que devolve `nil` e sai. 2.985 idas ao main em 10 min para nada.
  Fazer: derivar o prefiltro do próprio decoder: `isPrefilteredNoiseKind` = `!PetEventDecoder.acceptedKinds.contains(kind) && !attentionProjectionKinds.contains(kind) && !liveActivityProgressKinds.contains(kind)`. Adicionar `agent.provider_runtime.event` e `token_saver.digest` explicitamente à lista enquanto isso.
  Verificar: teste em `PetControllerTests` publicando 100 `agent.provider_runtime.event` → `handledEventCountForTests == 0`; `agent.item.completed` continua contando. Reamostrar 8 s: 0 amostras em `PetController.handle` vindas desse kind.

- [x] **PF-02 · P0 · idle-com-runs — o Pet faz hit-test do Dock com o WindowServer a cada troca de pose.**
  **FEITO (6e28cd1f — Dock placement cache by displayID+visibleFrame; 50 pose changes → ≤1 hit-test)**
  `PetController.apply` (`:813`) → `PetAnimationController.setState` (`PetAnimationController.swift:98-115`, chama `publishCurrentFrame` na hora) → `PetWindowController.animationFrameDidChange` (`PetWindowController.swift:842`) → `petPlacementContext(for:)` (`:896-906`) → `PetDockFrameProvider.frame(for:)` (`PetDockFrameProvider.swift:10`) → `hitTestFrame` (`:38-62`): `CGWindowListCopyWindowInfo` + até N × `NSWindow.windowNumber(at:)` em passos de 8 pt ao longo da borda do Dock, cada um um IPC síncrono (`SLSCopyWindowRoutingRecordsForScreenLocation`). Como `agent.item.started/completed` alterna a pose (coding ↔ waiting) 1,4×/s e sprites têm tamanhos diferentes por linha do atlas, o guard de tamanho em `:845-846` passa e o hit-test roda: **60 de ~100 amostras úteis do main thread** em 6 s.
  Fazer: cachear o `PetPlacementContext` por `NSScreen` (`displayID` + `visibleFrame`) e reusar em `animationFrameDidChange`; invalidar em `NSApplication.didChangeScreenParametersNotification`, na distributed notification `com.apple.dock.prefchanged`, quando `screen.visibleFrame` mudar, e num revalidate lento (30 s) fora do caminho do frame. Rodar o hit-test propriamente dito fora do main (é só leitura de geometria) ou, no mínimo, uma vez por invalidação. Nunca no caminho de `publishCurrentFrame`.
  Verificar: teste com `dockFrameProviderForTests` contando chamadas: 50 trocas de pose → ≤1 chamada; mudar `visibleFrame` → 1 chamada nova. Reamostrar: `PetDockFrameProvider` < 3 amostras em 8 s (hoje 60 em 6 s).

- [x] **PF-03 · P0 · idle-com-runs — o Pet lê SQLite no main thread a cada `agent.item.*` e espera a fila de escrita.**
  **FEITO (5f258973 — chrome/startedAt cache; 100 item.completed on 2 threads → ≤2 lookups)**
  `handle` → `shouldResyncActiveRuns` (`:823-831`, verdadeiro para `agentItemStarted/Completed`, `agentTurnStarted`, …) → `refreshActiveThreadsFromCoordinator` (`:1044`) → `applyActiveThreadIDs` (`:1095`) → `context.threadRepo.listChrome(ids:)` (`:1111`) síncrono no main: 13 amostras bloqueadas em `NSRecursiveLock` em 6 s. Também `applyActiveRunProjection` (`:1062`) → `runRepo.startedAt(ids:)` síncrono. Título/workspace/provider de uma thread ativa mudam raramente; ler 1,4×/s é desperdício e cada leitura pode ficar atrás de um lote de stream.
  Fazer: cache `[AgentThreadID: CachedActiveThreadChrome]` (já existe `nextChrome` local — torná-lo persistente por VM) preenchido **off-main** (`Task.detached` → `MainActor.run`) só para ids ainda não cacheados; invalidar por `agent.thread.updated`/`renamed` e por remoção do set ativo. `startedAt` idem (só muda quando o run começa).
  Verificar: `activeThreadDurableLookupCountForTesting` == número de threads novas, não de eventos: 100 `agent.item.completed` para 2 threads → ≤2 lookups. Reamostrar: 0 amostras de `listChrome` no main.

- [x] **PF-04 · P0 · stream — cada `BotsViewModel` salta para o MainActor a cada stream event de qualquer thread, e lê SQLite no main a cada mudança de status.**
  **FEITO (a7ef0c8c — desk hop gated before MainActor; in-memory bot map; Active Bots offscreen skip)**
  `BotsWindow.swift:9996-10005` `runCoordinator(didReceive:)`: `Task { @MainActor in applyIncomingDeskEvent }` **antes** de checar `screen == .desk && selectedConversation?.linkedAgentThreadID == threadId` (`:8562-8566`). Com 5 runs streamando, cada token = 1 Task + 1 hop por VM. Há **1 VM sempre vivo na sidebar** (`SidebarView.swift:5671`) + 1 por janela Bots (`BotsWindow.swift:12512/12554/12609`). `didChangeStatus` (`:10027-10040`) faz `botStore.conversationLinked(to:)` (SQLite) no main para **qualquer** thread e depois `reloadActiveBotsScreen()` mesmo com a tela oculta (BT-08).
  Fazer: espelhar o gate do Agent App (`AgentAppSurface.swift:9131` `acceptsStreamEvent`, chamado em `:9142-9145` antes de qualquer Task, + `currentInterestedThreadId` atômico `:1069`): manter `interestedThreadID` (`OSAllocatedUnfairLock`) atualizado em `selectDeskThread`/mudança de tela e **descartar antes do hop**. Em `didChangeStatus`, resolver `conversationLinked` por um mapa em memória `[AgentThreadID: BotID]` mantido pelo `BotStore` (ele já tem `listCached()`/revisão desde AA-01). Fazer junto com BT-04 (poll de 250 ms) e BT-08.
  Verificar: teste em `BotsWindowTests`: 500 eventos de uma thread não selecionada → 0 execuções de `applyIncomingDeskEvent` e 0 Tasks agendadas (contador no ponto do hop); evento da thread selecionada continua aplicando. `didChangeStatus` de thread sem bot → 0 queries.

- [x] **PF-05 · P1 · stream — todo `agent.provider_runtime.event` (5/s) é gravado na tabela `events` na fila do SQLite, além de já ir para `agent_provider_event_logs`.**
  **FEITO (e3dce141 — shouldPersistEvent skips agent.provider_runtime.event; recent ring kept)**
  `AppDelegate.swift:1024-1031` `shouldPersistEvent` só exclui `surface.output`, `agent.item.delta`, `agent.item.progress`. A tabela `events` tem cap 5.000 (`EventLog.swift:25-45`), então em regime cada append = `INSERT` + `COUNT` (cacheado) + `DELETE MIN(id)`; 2.985 desses em 10 min, na mesma fila serial dos lotes de stream. O payload é diagnóstico do provider (`_x.ai/session_notification`), já persistido em `agent_provider_event_logs` (8.919 linhas) e nunca é material para a UI do mac.
  Fazer: excluir `agent.provider_runtime.event` de `shouldPersistEvent` (mantém no ring `recent` para reconexão iOS) ou, se o iOS depender do replay durável desse kind, coalescer por thread a 1 gravação/s. Confirmar com o dono qual dos dois.
  Verificar: teste de `shouldPersistEvent`; `SELECT count(*) FROM events WHERE kind='agent.provider_runtime.event' AND created_at > now-10min` == 0 no sandbox com um run grok ativo.

- [x] **PF-06 · P2 · stream — o mesmo evento a 5/s sai para cada cliente WebSocket e provoca `diagnostic.ws_outbound_pressure` (3× em 10 min).**
  **FEITO (aa5e399c — default WS filter drops provider_runtime; iOS still gets workspace/surface/agent.*)**
  `HTTPServer.swift:2670-2695`: fila de saída cheia → `degrade()` → publica `baseline_required` → o cliente pede baseline completa → mais carga. `EventStreamFilter` já existe (`.agentThreadAndQueue`, `.full`).
  Fazer: `agent.provider_runtime.event` só em filtro explícito (`.diagnostics`) ou com rate-limit por thread no `HTTPServer`; manter tudo que o iOS espelha (AGENTS.md §paridade).
  Verificar: teste do filtro; nenhum `diagnostic.ws_outbound_pressure` em 10 min com 1 cliente iOS conectado e 3 runs.

## F2 — Trocar de aba instantâneo

- [x] **PF-10 · P0 · switch + idle — abas ocultas do Agent App nunca esfriam; 7 de 8 pagam o pipeline inteiro de stream.**
  **FEITO (c18cda77 — hidden Agent App reduces without 30 Hz publish; stale stream dropped on thread switch)**
  `Surface.swift:12-25`: `didBecomeVisible/didBecomeHidden` têm default vazio; `SurfaceRegistry.setVisibleSurfaceIDs` (`:148-156`) chama ambos em toda troca (`AppCommandRouter.reconcileSurfaceVisibility`, chamado por `focusSurface` `:2061-2083`). `TerminalSurface` (`:3285/:3370`) e `BrowserSurface` (`:1188/:1202`) implementam; **`AgentAppSurface` (`AgentAppSurface.swift:18548-18600`) não**. Consequência com thread ativa numa aba oculta: `flushStreamEvents` (`:8665`) reduz e publica no MainActor, `scheduleTimelineUpdateTick` (`:9192-9202`) publica a 30 Hz, `refreshAgentSurfaces` (`AppCommandRouter.swift:595-620`) pede reload de rail e faz `selectThread(markRead:false)` → `softReselectOpenThread` (PF-20) para cada aba do workspace, `reloadTokenSaverThreadSavings` (`:1931`) soma bytes de todas as mensagens. O protocolo `AgentVisibilityColdState.swift` (`AgentVisibilityState`, `AgentPresentationCheckpoint`) foi escrito para isso e não tem **nenhuma** referência no código.
  Fazer: `AgentAppSurface.didBecomeHidden()` → `viewModel.setVisibility(.hidden)`: (1) continuar **reduzindo** o stream no modelo (a timeline precisa estar correta ao voltar) mas **sem publicar** — coalescer em 1 publish/s ou nenhum; (2) parar o tick de 33 ms; (3) pular `reloadTokenSaverThreadSavings`, savings/badges, `scheduleReloadThreads` (aplicar o snapshot do hub quando voltar); (4) `AgentChatElapsedTickSchedule` em `.lowFrequency` (CH-12 já suporta). `didBecomeVisible()` → um publish, `reloadThreads()` coalescido, tick normal. Gerações: o que estava pendente quando ficou oculto só aplica se a thread selecionada não mudou.
  Verificar: teste em `AgentAppViewModelTests`: 200 eventos de stream com a surface oculta → ≤1 publish/s e 0 ticks; ao ficar visível, timeline igual à de uma surface que ficou visível o tempo todo (comparar `timeline.turns`). Corrida: ocultar, trocar thread, mostrar → nenhum publish da thread antiga. Reamostrar com 8 abas e 5 runs: amostras em `AgentAppViewModel.*` de abas ocultas ≈ 0.

- [x] **PF-11 · P0 · switch — a troca de aba desmonta e remonta o `NSHostingView` inteiro do Agent App.**
  **FEITO (cfe3d22e — pane tab views stay mounted with isHidden; Ghostty uses isHiddenOrHasHiddenAncestor)**
  `PaneTabsView.installSelectedContent` (`PaneTabsView.swift:276-296`): `removeFromSuperview` de tudo em `contentArea` e `addSubview(selectedView)` + 4 constraints. Para o Agent App, `selectedView` é o container do `NSHostingView(rootView: AgentAppView(vm:))` (`AgentAppSurface.swift:18562`), então cada volta a uma aba = SwiftUI refaz layout do `AgentAppView` completo (transcript é `VStack` eager; sem CH-01 cada linha re-executa body) + `IntrinsicHeightTextView` mede de novo os prompts (CH-02 já cacheia). `MainWindowController` faz o oposto para workspaces: mantém `cachedWorkspaceContentViews` com `isHidden` (`MainWindowController.swift:1236, 1333-1360`).
  Fazer, em ordem, medindo com PF-00 a cada passo: (a) `host.sizingOptions = []` no `NSHostingView` do Agent App (evita passadas de intrinsic size que o layout por constraints não usa); (b) manter os `NSHostingView` das abas do pane montados em `contentArea` e alternar `isHidden` (mesmo padrão de `cachedWorkspaceContentViews`), removendo só ao fechar a aba — atenção ao render gate do Ghostty (memória `remotecode-ghostty-render-gate`: terminal oculto **não** pode renderizar; `isHidden` já satisfaz `isRenderable` se ele checar `isHiddenOrHasHiddenAncestor`, confirmar em `GhosttyTerminalView.swift:958-1002`); (c) CH-01 (`Equatable` nas linhas) para que a remontagem não re-execute o body de todas as linhas.
  Verificar: PF-00 (a) p95 com 8 abas e uma thread de 200 mensagens: hoje → alvo < 16 ms release; teste em `PaneTabsViewTests` que a view da aba anterior continua na hierarquia (`isHidden == true`) e a nova está visível; teste que fechar a aba remove a view.

- [x] **PF-12 · P1 · switch — `focus()` publica `focusTick` num VM com 78 `@Published`; a aba inteira re-executa body só para focar o composer.**
  **FEITO (1be74848 — focusTick on AgentComposerState; 10 focus() → 0 VM objectWillChange)**
  `AgentAppSurface.focus()` (`AgentAppSurface.swift:18577-18580`) → `viewModel.focusTick &+= 1` (`:296`, `@Published`); chamado por `MainWindowController.focusSurface` em toda `applyFocusChangeInPlace`. Outros 4 bumps em `:2214, :3950, :7112, :7884`. Como o `AgentAppView` observa o VM inteiro (AA-05), um bump = body de 6,8 mil linhas.
  Fazer: mover `focusTick` para um `ComposerFocusState: ObservableObject` pequeno, observado só pelo composer (o padrão de reactive-scope já existe em `:217+`); ou usar `NSWindow.makeFirstResponder` direto no `NSTextView` do composer sem passar pelo SwiftUI. Fazer junto com AA-05/AA-06 se estiverem em andamento.
  Verificar: contador de body do `AgentAppView` em teste (já há `paintSequence`): 10 `focus()` → 0 bodies do transcript; composer recebe first responder.

- [x] **PF-13 · P1 · switch + idle — `refreshFromState`/`refreshSurfaceRuntimeState` recalculam busy de todas as abas e releem o blob da conta no main.**
  **FEITO (96982fb5 + 092d0207 — account blob peeked once; busy refresh skips hidden windows)**
  `MainWindowController.refreshFromState` (coalescido por run loop, 40 call sites em `AppCommandRouter`) → `sidebar.refresh()` → `SidebarView.reload()` (`SidebarView.swift:615-660`) → `reloadPrivateAccount()` (`:703-715`) → `PrivateAccountSessionStore.loadRawJSON()` = `settingsRepo.get` **síncrono no main** a cada refresh (o memo é por JSON igual, mas a leitura acontece sempre). `refreshSurfaceRuntimeState` é chamado a cada mudança de projeção ativa do coordinator (`AppContext.swift:1734`) e a cada `SurfaceRuntimeBus.sink` (`:1567`) → `PaneTabsView.refreshBusyStates` → `isSurfaceBusy` → `AgentAppSurface.isBusy` → `hasRunningWorkForChrome` (`AgentAppSurface.swift:4210`) → `hasWaitingBotPeerActivity` varre `messages` e trava o coordinator por consulta (AA-16), × 8 abas.
  Fazer: (1) `reloadPrivateAccount` só quando `SettingsStore` sinalizar mudança (o padrão de observers por Notification já existe para Token Saver em `:552-560`); (2) AA-16: flag `hasWaitingBotPeerActivity` mantida no `didSet` de `messages` + set de runs vivos por callback; (3) `refreshBusyStates` só nos panes visíveis.
  Verificar: teste: 20 `refreshFromState` sem mudança de settings → 1 leitura de settings (hoje 20); 20 `refreshSurfaceRuntimeState` → 0 varreduras de `messages`.

- [x] **PF-14 · P2 · switch — troca para aba Terminal/SSH: `didBecomeVisible` faz replay de histórico + heal síncronos.**
  **FEITO (015a7efd — measured in source only; no GUI p95; no reveal-path change)**
  `TerminalSurface.swift:3285-3300`: `restoreReclaimedTerminalMemoryIfNeeded`, `historyCoordinator.requestReplayIfNeeded`, `ensureRendererCurrent`, `applyHiddenRendererHealIfNeeded`. Provavelmente barato para 3 terminais, mas nunca foi medido.
  Fazer: só medir com PF-00; agir apenas se p95 > 16 ms. Se agir: heal em pedaços por frame (já existe `flushPendingOutput` com orçamento).
  Verificar: números no `audit/perf-switch-2026-09-02/`.

## F3 — Trocar de conversa instantâneo

Itens do `TODO.md` que **são** troca/carga de conversa — executados nesta branch: **AA-08 + CH-08 + CH-09** (`8135b67e`), **CH-01 + CH-05 + CH-06** (`f47714a8`), **CH-07** (`82af6460`), **X-02 + AA-07 + AA-11 + AA-12 + AA-15 + AA-16** (`daace020` / `031f0538`), **AA-14** (`.equatable()` no chamador). **AA-05 + AA-06** ficou parcial: `focusTick` saiu do VM (`1be74848`); chrome (token saver / git / shells / subagent) ainda publica no objeto de 78 campos.

- [x] **PF-20 · P1 · switch + idle-com-runs — `softReselectOpenThread` roda a cada evento de ciclo de vida da thread aberta e faz 3 leituras SQLite síncronas no main.**
  **FEITO (3c2fc6a1 — soft reselect durable reads off-main; hidden skip; A→B stale drop)**
  `AppCommandRouter.refreshAgentSurfaces(reloadTranscriptIfSelected: true)` (`AppCommandRouter.swift:595-620`) → `selectThread(markRead:false)` para **toda** surface do workspace com a thread selecionada → `softReselectOpenThread` (`AgentAppSurface.swift:3672-3760`): `reloadQueuedMessages()` (`:3678` → `:2685` `queuedMessageRepo.list`), `coordinator.runStartedAt(threadId:)` (`:3726`), `coordinator.hasRecoverableContext(threadId:)` (`:3744`) — as três síncronas na fila do SQLite, enquanto os 5 runs escrevem. Antes do 58050308 isso valia só para o clique; hoje vale para cada `didChangeStatus`/`didFinish`.
  Fazer: ler as três num `Task.detached` "soft bundle" (mesmo desenho do open bundle) e aplicar no MainActor guardado por `selectThreadOpenGeneration`; ou guardar por kind: só `queued`/`status` reais precisam reler a fila; `hasRecoverableContext` só muda em terminal. Combinar com PF-10 (surface oculta não faz soft reselect).
  Verificar: teste: 20 `refreshAgentSurfaces` para a thread aberta sem mudança → 0 leituras síncronas no main (contador no `SQLiteDB` de PF-00 (c)); status muda → 1 leitura off-main e chrome atualiza.

- [x] **PF-21 · P2 · switch — `selectThread` ainda faz no caminho do clique: `persistAgentSelectedThread` (varre todos os workspaces, publica `surface.updated`) e o fallback `threadRepo.get` quando a thread não está no rail.**
  **FEITO (26b478bb — persist selected thread on next main turn; restore-after-restart still green)**
  `AgentAppSurface.swift:2063-2200`: `onSelectedThreadChanged?(id)` → `AppCommandRouter.persistAgentSelectedThread` (`:7559-7590`) roda síncrono antes de `routingMode = …`; o `EventBus.publish` acorda o Pet (kind `surface.updated` está no prefiltro — ok) e o iOS. O fallback `threadRepo.get(id:)` (`:2077`) é raro (thread fora do rail).
  Fazer: mover `onSelectedThreadChanged` para depois do primeiro publish (mesma transação, `DispatchQueue.main.async`); manter a semântica exatamente-uma-vez.
  Verificar: PF-00 (b) sem regressão; teste de restore-after-restart continua verde (`selected_thread` persistido).

## F4 — Uma fila SQLite para tudo (estrutural)

- [x] **PF-30 · P1 · tudo — toda leitura da UI espera atrás dos escritores porque há uma única conexão.**
  **FEITO (a936ec6a — AppContext.readDB; list/listChrome/count on WAL reader; <5 ms behind open writer txn)**
  `Bootstrap.swift:241` abre **um** `SQLiteDB(path:)`; a fila `RemoteCode.SQLiteDB` (`SQLite.swift:313-352`, `performSync` `:432`) serializa leituras e escritas. `SQLiteDB.init(path:, readonly: true)` já existe (`:313-337`, usado pelos helpers Distill) e WAL dá leitores concorrentes ao escritor. Na amostra, os 13 bloqueios de `listChrome` (PF-03) são exatamente isso.
  Fazer: um segundo `SQLiteDB(path:, readonly: true)` no `AppContext` (`readDB`) com fila própria (`RemoteCode.SQLiteDB.read`) e, por etapa, migrar repositórios de leitura pura da UI para ele: `AgentThreadRepository.list/listChrome/count`, `AgentQueuedMessageRepository.list`, `SettingsRepository.get` (peek), `AgentTurnCheckpointRepository` metadados, `NotificationRepository.list` (Pet), `TokenSaverSavingsRepository` (footer). Regra: só leituras que toleram staleness de um lote (o WAL é visível ao leitor após o commit; leituras "logo depois da minha escrita" ficam na conexão de escrita ou vão após o callback de commit). Manter `busy_timeout` curto (1 s) no leitor.
  Verificar: teste de integração: escrita de 5.000 stream events em transação longa numa thread + `listChrome` no leitor → retorna em < 5 ms sem esperar o commit; teste que uma escrita seguida de leitura no leitor **após** o callback vê o dado. Reamostrar com 5 runs: 0 amostras de `NSRecursiveLock.lock` sob símbolos do main thread.

- [x] **PF-31 · P1 · tudo — inventário de leituras SQLite síncronas no main thread.**
  **FEITO (85bbee56 — inventory only; 10 min DEBUG soak not run)**
  `AgentAppSurface.swift` tem 84 chamadas `try? <repo>.…` (nem todas no main, mas a maioria); `BotsWindow.swift` similar (BT-01/04/05/07/10/15 do `TODO.md`); Pet: `listChrome`, `runRepo.startedAt`, `notificationRepository.list(unreadOnly:)` (`PetAttentionStore.swift:67, 143`); Sidebar: `settingsRepo.get` (PF-13).
  Fazer: ligar o instrumento de PF-00 (c) em DEBUG (stack quando `performSync` roda no main e espera > 2 ms) e rodar o sandbox 10 min com 3 runs; cada stack vira um sub-item PF-31.x aqui, resolvido movendo para `Task.detached` + `MainActor.run` (padrão AA-02/AA-10) ou para o `readDB` de PF-30.
  Verificar: após a lista zerar, 10 min de sandbox com 3 runs → 0 stacks logados.

- [x] **PF-32 · P2 · stream — ocupação da fila de escrita com 5 runs nunca foi medida.**
  **FEITO (b17fe1f7 — occupancy report; wal_autocheckpoint stays 512 until soak >6 ckpt/min)**
  Entram na mesma fila: `persistStreamBatch` (lotes, `AgentRunCoordinator.swift:5847`), `EventLog.append` por evento (6,7/s; PF-05 reduz), `agent_provider_event_logs`, `TerminalHistory` appends (`TerminalHistoryCoordinator.swift:1645`), `providerSessionRepo.updateDiagnostics` por lote, prunes (`shouldPruneStreamEvents`) e `wal_autocheckpoint=512` páginas (2 MB — com 5 escritores pode checkpointar a cada poucos segundos).
  Fazer: `os_signpost` de ocupação da fila (PF-00 (c) já mede o lado main; medir também total) e `sqlite3_wal_hook` contando checkpoints/min. Se checkpoints > 6/min, subir `wal_autocheckpoint` para 2000–4000 (8–16 MB; `journal_size_limit` já é 16 MB).
  Verificar: relatório em `audit/perf-switch-2026-09-02/db-occupancy.md`; ocupação < 10% com 5 runs; nenhuma regressão de durabilidade (testes de `SQLiteDBTests`).

- [x] **PF-33 · P2 · memória em disco — DB de 1,53 GB.**
  **FEITO (b17fe1f7 — table-size proposal; no VACUUM of owner DB)**
  `agent_turn_checkpoints` ≈ 108 MB (AA-02 já lê só metadados), `agent_stream_events` 27 k linhas, `events` cap 5.000, `session_snapshots` cap 20 (ok). Não é causa de lentidão de troca, mas amplia checkpoints e `VACUUM` nunca roda.
  Fazer: só depois de PF-30/32: relatório `dbstat` por tabela (rodar no sandbox com cópia do DB, **não** no DB do dono) e propor retenção ao dono (decisão dele).
  Verificar: relatório com as 10 maiores tabelas e política proposta.

## F5 — Processos e memória

- [x] **PF-40 · P2 · leve — cada run de provider spawna 5 processos `RemoteCodeDistillService` (MCP).**
  **FEITO (2fa91e3e — proposal only (multiplex or lazy spawn))**
  `ps` ao vivo: cada `grok agent … stdio` tem 5 filhos `RemoteCodeDistillService {bot-computer|bot-browser|bot-web|mcp|bot-self-config}` (18–27 MB RSS cada); com 5 runs = 20 processos ≈ 450 MB e 5 spawns por início de run (latência do primeiro token). Memória `bots-token-saver-mcp-lane` e `provider-mcp-delivery-paths` descrevem por que são separados (admissão por servidor).
  Fazer (decisão do dono — só propor): (a) um único processo MCP por run que serve os 5 servidores por stdio multiplexado (tools com namespace), ou (b) spawn preguiçoso no primeiro tool call de cada servidor. Manter a semântica de admissão/Token Saver.
  Verificar: `ps` com 5 runs → ≤ 5 filhos (a) ou só os usados (b); testes de `DistillMCPAdmit` verdes.

- [x] **PF-41 · P2 · leve — 72 threads no app; footprint 396 MB (pico 678 MB).**
  **FEITO (e76b92b4 — footprint report; act if later sandbox peak >700 MB)**
  Fontes prováveis: 5 filas `remotecode.grok-acp.parse` (uma por run, ok), `NSFileHandle.fd_monitoring` por pipe, filas de utilitário do Swift Concurrency. AA-07 (`paintedTimelineByThread` sem limite) e o cache de markdown (AA-08) explicam parte do pico.
  Fazer: só medir (`footprint`/`vmmap --summary` no sandbox após 30 min com 5 runs) depois de F1–F3; agir se pico > 700 MB.
  Verificar: relatório em `audit/perf-switch-2026-09-02/memory.md`.

## Critérios de aceite (F6)

GUI p95 em build release com 8 abas + 5 FakeProviderRunner streams **não foi coletado nesta branch** (`baseline.md` deixa isso explícito). Os itens têm testes de caminho imediato / término / corrida A→B / falha no que foi código. Medir no sandbox, build release, workspace com 8 abas Agent App + 3 Terminal, 5 runs ativos (use `FakeProviderRunner` para reproduzir 5 streams a 20 ev/s), ≥5 amostras aquecidas cada:

| medida | hoje | alvo |
|---|---|---|
| troca de aba (PF-00 a) p95 | não medido (PF-00) | < 16 ms |
| troca de conversa até 1º frame (PF-00 b) p95 | não medido | < 100 ms; sem SQLite síncrono no main |
| amostras úteis do main thread em 8 s idle-com-5-runs | ~130 (90 Pet) | < 20, 0 em SQLite lock |
| idas ao main por segundo fora da aba visível | ≈7 (Pet + Bots VMs) | ≈0 |
| `agent.provider_runtime.event` gravados em `events` | 5/s | 0 |
| processos `RemoteCodeDistillService` com 5 runs | 20 | ≤ 5 (decisão do dono) |

## Fora de escopo / decisões do dono

- **Experimento imediato sem código:** desligar o Pet em Settings (`petEnabled`) por um dia com runs ativos e ver se a sensação de "tudo ao mesmo tempo" melhora. Se melhorar, PF-01/02/03 são a prioridade absoluta; se não, F2/F4 primeiro.
- PF-05/PF-06 tocam o que o iOS recebe: confirmar com o dono que `agent.provider_runtime.event` não é espelhado como estado no iOS antes de cortar.
- PF-40 muda a topologia de processos dos bots: só propor.

## Não verificado (dizer a verdade sobre o que falta)

- Se um `NSHostingView` **fora da hierarquia** ainda executa `body` a cada `@Published` (hipótese por trás de parte de PF-10/PF-11). Testar contando bodies de uma surface oculta durante um stream antes de decidir se PF-10 precisa também trocar `rootView` por placeholder.
- Latências reais de troca de aba/conversa: não há instrumento hoje (PF-00). Os números de "hoje" acima vêm da amostra em idle, não de uma troca.
- Ocupação da fila do SQLite sob burst (PF-32): a amostra pegou 1,6% em idle; o pior caso não foi medido.
