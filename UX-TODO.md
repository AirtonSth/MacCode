# UX Improvement Plan — RemoteCode Desktop & Mobile

> Auditoria completa de UX para eliminar glitches, flickering, layout shifts, carregamento fora de ordem e micro-interacoes quebradas.

---

## Legenda de Prioridade

- **P0 — Critical**: Problema visivel que quebra o fluxo do usuario (conteudo some, tela pisca, dados perdidos)
- **P1 — High**: Problema perceptivel que causa desconforto (layout shift, flash de estado errado, jank)
- **P2 — Medium**: Problema sutil mas que diminui a sensacao de polimento
- **P3 — Low**: Detalhe cosmetico, so perceptivel se procurar

---

## DESKTOP

### P0 — Critical

- [x] **[D-01] Waterfall de estados vazios no boot** — `App.tsx`
  - `handleBootstrap()` dispara `SET_PROJECTS` → `SET_SELECTED_PROJECT` → effect carrega chats → effect carrega messages. Cada etapa zera o estado anterior, gerando 3-4 repinturas: sidebar vazia → projetos → chat list vazia → chats → messages vazias → mensagens.
  - **Fix**: Carregar projects + chats + messages em uma unica operacao batch e despachar um unico `BOOTSTRAP_COMPLETE` com todos os dados.
  - **Done**: Added `BOOTSTRAP_COMPLETE` reducer action. Tests: `useWorkspaceStore.bootstrap.test.ts` (4 tests pass)

### P1 — High

- [x] **[D-02] `SET_SELECTED_CHAT` apaga streaming state de TODOS os chats** — `useWorkspaceStore.ts:488`
  - Trocar de chat zera `streamingByChat`, `streamHistoryByChat`, etc. para todos os chats (nao so o anterior). Ao voltar, o usuario perde todo o contexto de streaming.
  - **Fix**: Preservar streaming state do chat anterior; limpar apenas o chat que esta sendo deselecionado.
  - **Done**: Removed 6 streaming map resets from SET_SELECTED_CHAT. Tests: `useWorkspaceStore.streaming-preservation.test.ts` (4 tests pass)

- [x] **[D-03] Fade-in de 320ms no layout principal atrasa first paint** — `App.tsx:2611`
  - `motion.div` com `initial={{ opacity: 0, y: 12 }}` e duracao de 320ms mantem o app invisivel durante o bootstrap.
  - **Fix**: Remover ou reduzir a animacao de entrada do shell. Mostrar o layout imediatamente com skeleton states.
  - **Done**: Reduced to 100ms with initial opacity 0.8/y:4. Near-instant first paint.

- [x] **[D-04] `SET_CHATS` sempre auto-seleciona o 1o chat e reseta messageWindow** — `useWorkspaceStore.ts:424`
  - Qualquer refresh da lista de chats (incluindo via WebSocket `chat_created`) reseta a conversa visivel.
  - **Fix**: Preservar `selectedChatId` se ele ainda existir na lista atualizada. So mudar se o chat selecionado foi removido.
  - **Done**: SET_CHATS now preserves selection when chat exists in new list. Tests: `useWorkspaceStore.selection.test.ts` (5 tests pass)

- [x] **[D-05] `UPSERT_CHAT` forca selecao para o chat atualizado** — `useWorkspaceStore.ts:435`
  - Se outro cliente cria um chat, o usuario e arrancado da conversa atual.
  - **Fix**: `UPSERT_CHAT` deve apenas adicionar/atualizar na lista. Selecao automatica so se for resultado de acao explicita do usuario.
  - **Done**: UPSERT_CHAT only changes selection when selectedChatId is null. Tests: `useWorkspaceStore.selection.test.ts` (3 tests pass)

- [x] **[D-06] `collapseTurnItems` fecha itens que o usuario expandiu manualmente** — `useWorkspaceStore.ts:244`
  - Quando um turn completa, TODOS os itens colapsam, mesmo os que o usuario abriu para ler output de tool.
  - **Fix**: Respeitar flag `expandedByUser`. So colapsar itens que foram auto-expandidos.
  - **Done**: `collapseTurnItems` now checks `expandedByUser` before collapsing. User-expanded items keep state "completed" instead of "collapsed". Tests: `useWorkspaceStore.collapse.test.ts` (8 tests).

- [x] **[D-07] Loading states inicializam como `false` causando flash de empty state** — `useWorkspaceStore.ts:1109`
  - `projectsLoading: false`, `chatsLoading: false`, `messagesLoading: false` no initial state. UI mostra "No workspaces yet" por 1 frame antes de mostrar o loading spinner.
  - **Fix**: Inicializar loading states como `true` (ou criar estado "initial" distinto de "idle").
  - **Done**: Initial state now has `projectsLoading: true, chatsLoading: true, messagesLoading: true`. Tests: `useWorkspaceStore.bootstrap.test.ts`

- [x] **[D-08] Layout shift entre empty state / loading / content no ConversationPanel** — `ConversationPanel.tsx:426`
  - Tres estados condicionais com alturas completamente diferentes. Transicao entre eles causa salto visual.
  - **Fix**: Usar skeleton screens que mantenham a mesma estrutura visual do estado final. Ou reservar espaco minimo.
  - **Done**: Added minHeight:200 container + skeleton placeholder with animated pulse bars matching message layout.

- [x] **[D-09] Auto-expand de tool items causa layout jump apos 2s** — `StreamingTimeline.tsx:181`
  - `setTimeout(2000)` expande itens de tool sem animacao. Tudo abaixo pula para baixo.
  - **Fix**: Animar a expansao com `motion.div` (height transition). Considerar nao auto-expandir se o scroll nao esta no bottom.
  - **Done**: Replaced `motion.pre` with `motion.div` wrapper + `overflow: hidden` + Material cubic-bezier easing (0.25s). Tests: `StreamingTimeline.test.ts` (6 tests).

- [x] **[D-10] Items colapsam abruptamente quando completam** — `StreamingTimeline.tsx:808`
  - Itens auto-expandidos colapsam instantaneamente quando `state` muda de "running" para "completed".
  - **Fix**: Manter expandido por default quando completa. Ou animar o colapso. Respeitar `expandedByUser`.
  - **Done**: Added 600ms delayed auto-collapse for non-user items on running→completed transition. User-expanded items never auto-collapse.

- [x] **[D-11] Terminal auto-scroll ignora posicao do usuario** — `ThreadTerminalPanel.tsx:44`
  - `useEffect([items])` sempre rola para o bottom. Impossivel ler output anterior durante streaming.
  - **Fix**: Checar se o usuario esta no bottom (similar ao `isAtBottomRef` do ConversationPanel). So auto-scroll se estiver.
  - **Done**: Added isAtBottom check with 48px threshold. Tests: `ThreadTerminalPanel.test.ts` (12 tests pass)

- [x] **[D-12] Terminal panel abre/fecha causando layout shift de 42vh** — `App.tsx:3190`
  - Toggle do terminal insere/remove um div de `42vh min-h-[220px]`. A area de conversa encolhe dramaticamente.
  - **Fix**: Animar a abertura/fechamento. Ou usar um painel resizable com drag handle.
  - **Done**: Wrapped in `AnimatePresence` + `motion.div` with height 0→auto animation, `overflow-hidden`, 0.3s cubic-bezier. Respects reduced motion. Tests: `TerminalPanelAnimation.test.ts` (6 tests).

  - **Done**: Added font-display:swap fallback @font-face blocks.
- [x] **[D-13] Google Fonts import bloqueia render (FOUT)** — `index.css:1`
  - `@import url("fonts.googleapis.com/...")` e render-blocking. Texto renderiza em fonte fallback, depois pula para Manrope.
  - **Fix**: Preload as fontes no HTML (`<link rel="preload">`), ou hospedar localmente, ou usar `font-display: optional`.

### P2 — Medium

  - **Done**: Extracted fetchModelsForProvider; keeps previous models visible until new fetch resolves. Tests: provider-change.test.ts (6 tests)
- [x] **[D-14] Provider switch causa flash de "No models"** — `App.tsx:2126`
  - `setSelectedModel(null)` + `setAvailableModels([])` executam antes do fetch. Dropdowns ficam vazios por 200-500ms.
  - **Fix**: Manter modelos do provider anterior visiveis ate os novos carregarem. Ou mostrar skeleton no dropdown.

- [x] **[D-15] Sem skeleton screen no sidebar** — `App.tsx:2679`
  - "Loading workspaces..." como texto simples, depois pula para lista completa.
  - **Fix**: Skeleton cards na sidebar matching o layout final.

- [x] **[D-16] Double dispatch em `handleSelectProject`** — `App.tsx:2212`
  - `dispatch(SET_SELECTED_CHAT, null)` seguido de `dispatch(SET_SELECTED_PROJECT, id)` causa render intermediario com "No chat selected".
  - **Fix**: Despachar uma unica action `SELECT_PROJECT` que limpa e seleciona atomicamente.

  - **Done**: Increased MESSAGE_WINDOW_PAGE_SIZE from 5 to 25. Tests: useWorkspaceStore.message-window.test.ts (4 tests)
- [x] **[D-17] Message window de 5 mensagens e muito agressivo** — `useWorkspaceStore.ts:269`
  - `MESSAGE_WINDOW_PAGE_SIZE = 5`. Mensagens antigas desaparecem quando novas chegam.
  - **Fix**: Aumentar para 20-30. Ou implementar virtualizacao (react-window/virtuoso).

  - **Done**: Increased threshold to 80px, added userScrolledUpRef to prevent auto-scroll fighting. Tests: ConversationPanel.test.ts (7 tests)
- [x] **[D-18] Scroll-to-bottom briga com scroll do usuario** — `ConversationPanel.tsx:353`
  - `useLayoutEffect` com `isAtBottomRef` threshold de 24px. Durante streaming, qualquer scroll perto do bottom e capturado.
  - **Fix**: Aumentar threshold. Ou pausar auto-scroll quando o usuario inicia scroll manual (e mostrar botao "Scroll to bottom").

  - **Done**: Added prevChatIdRef/isChatSwitchRef to suppress animations during chat switch. Tests: ConversationPanel.test.ts (7 tests)
- [x] **[D-19] AnimatePresence causa shimmer ao trocar de chat** — `ConversationPanel.tsx:508`
  - Mensagens animam saida e entrada quando o chat muda. Parece "shimmer" visual.
  - **Fix**: Desabilitar animacao exit/enter no switch de chat. Animar apenas novas mensagens adicionadas.

  - **Done**: Added 300ms debounce with re-verify before pagination trigger. Tests: ConversationPanel.test.ts (8 tests)
- [x] **[D-20] Top pagination re-triggers sem debounce** — `ConversationPanel.tsx:311`
  - Scroll perto do topo (<=32px) dispara load imediato. O guard reseta quando messages mudam, re-triggering.
  - **Fix**: Adicionar debounce de ~300ms. Manter guard ativo ate o scroll sair da zona de trigger.

- [x] **[D-21] Textarea double-reflow por keystroke** — `MessageComposer.tsx:242`
  - `height = "auto"` -> reflow -> `height = scrollHeight` -> reflow. Duas forced layouts por tecla.
  - **Fix**: Usar `scrollHeight` sem resetar para `"auto"` primeiro. Ou usar `ResizeObserver`.

- [x] **[D-22] Three.js canvas: flash de nada antes do WebGL** — `ChatEmptyBackground.tsx:22`
  - `ready=false` -> retorna `null` por 1 frame. Depois inicializa WebGL (50-200ms de stutter).
  - **Fix**: Mostrar fallback estatico (gradiente CSS) enquanto WebGL carrega. Fade-in o canvas.

- [x] **[D-23] Pointer listener no Three.js causa re-renders excessivos** — `ChatEmptyBackground.tsx:28`
  - `setPointer` em cada `pointermove` (60fps). React re-renderiza o componente inteiro.
  - **Fix**: Usar `useRef` para armazenar pointer position. Passar para Three.js scene via ref, nao state.
  - **Done**: Replaced useState with useRef. Scene reads pointerRef.current in useFrame. Tests: `ChatEmptyBackground.test.ts` (3 tests pass)

  - **Done**: Removed transition-duration:0.001ms from prefers-reduced-motion; functional transitions preserved. Tests: index.css.test.ts (7 tests)
- [x] **[D-24] `prefers-reduced-motion` mata TODAS as animacoes** — `index.css:149`
  - `animation-duration: 0.001ms !important` em tudo. Transicoes funcionais (resize, dropdown) tambem somem.
  - **Fix**: Ser seletivo. Manter transicoes de layout e opacity. So remover animacoes decorativas.

### P3 — Low

- [x] **[D-25] Spinner flash em `openingProjectId`** — `App.tsx:2261`
  - Loader aparece por ~1 frame se a API responder rapido. Adicionar delay minimo (150ms) para exibir spinner.

- [x] **[D-26] "Working..." indicator pisca em turns rapidos** — `ConversationPanel.tsx:573`
  - Fade-in -> imediato fade-out quando `isWorking` flipa rapido. Usar debounce para mostrar.

- [x] **[D-27] State badges mudam sem transicao** — `StreamingTimeline.tsx:237`
  - Cor e texto snappam de "running" (azul) para "completed" (verde). Adicionar transition CSS.
  - **Done**: Added `transition-all duration-200` to badge span.

- [x] **[D-28] Shimmer text "materializa" ao completar** — `StreamingTimeline.tsx:231`
  - `color: transparent` -> `color: normal` em 1 frame. Usar fade transition.
  - **Done**: Added `transition: color 0.3s ease` to `.loading-shimmer-pure-text`.

  - **Done**: Added transition:opacity 200ms ease to status span. Tests: MessageComposer.ux.test.ts (3 tests)
- [x] **[D-29] Status text do composer muda abruptamente** — `MessageComposer.tsx:262`
  - Texto alterna entre estados sem transicao. Usar crossfade.

- [x] **[D-30] Send button muda cor abruptamente** — `MessageComposer.tsx:433`
  - Cinza -> vermelho instantaneo. Usar `transition-colors`.
  - **Done**: Added `transition-colors duration-200` to send/stop button.

  - **Done**: Wrapped dropdown in AnimatePresence with opacity+y motion.div. Tests: GitBranchControl.ux.test.ts (12 tests)
- [x] **[D-31] Git branch dropdown sem animacao** — `GitBranchControl.tsx:171`
  - Pop-in/pop-out instantaneo. Usar AnimatePresence ou CSS transition.

  - **Done**: Reordered handleCheckout to close dropdown before setIsSubmitting. Tests: GitBranchControl.ux.test.ts
- [x] **[D-32] Branch items flash disabled durante checkout** — `GitBranchControl.tsx:89`
  - Botoes ficam disabled por ~1 frame antes do dropdown fechar.

  - **Done**: Replaced persistent paragraph with hover tooltip using group-hover. Tests: GitBranchControl.ux.test.ts
- [x] **[D-33] Mensagem persistente "Not a git repository"** — `GitBranchControl.tsx:307`
  - Texto de erro sempre visivel para projetos non-git. Considerar ocultar ou usar tooltip.

- [x] **[D-34] Shimmer animation usa `steps(48)`** — `index.css:122`
  - Shimmer fica choppy/pixelado. Considerar usar `linear` ou `ease` para smooth sweep.
  - **Done**: Changed `steps(48, end)` to `linear` for smooth shimmer.

---

## MOBILE

### P0 — Critical

- [x] **[M-01] WebSocket reconecta a cada mudanca de identidade do `handleServerEvent`** — `use-workspace-shell.ts:1795`
  - `handleServerEvent` esta nas deps do effect que cria o WS client. Como `handleServerEvent` e recriado frequentemente (depende de muitos callbacks/state), o WS e destruido e recriado repetidamente. Conexao cai e reconecta causando flicker no estado de conexao e possivel perda de mensagens.
  - **Fix**: Mover `handleServerEvent` para um `useRef` e acessar `.current` dentro do effect. Remover da dependency array.
  - **Done**: Added `handleServerEventRef` and `handleConnectionStateChangeRef`. Effect deps reduced to `[config.activeTarget, isActive]`. Tests: `ws-reconnect-stability.test.ts` (2 tests pass)

- [x] **[M-02] Streaming text desaparece antes da mensagem final carregar (gap de ate 1.25s)** — `use-workspace-shell.ts:1495`
  - No `assistant_done`, streaming text e zerado imediatamente. O retry loop (`trySyncMessages`, 5x com 250ms) tenta buscar a mensagem persistida. Durante esse gap, o usuario ve a resposta sumir.
  - **Fix**: Manter streaming text visivel como fallback ate a mensagem final chegar. So limpar apos confirmacao do fetch.
  - **Done**: `clearStreamingText()` now called only inside `trySyncMessages` at each exit point. Tests: `streaming-text-persistence.test.ts` (4 tests pass)

### P1 — High

  - **Done**: Wrapped onEvent WS callback with unstable_batchedUpdates. Tests: ws-event-batching.test.ts (4 tests)
- [x] **[M-03] 11+ useState independentes causam render cascade por evento WS** — `use-workspace-shell.ts:474`
  - Cada `setState` trigga um re-render separado. Em `handleServerEvent`, varios sao chamados em sequencia, gerando 3-5 re-renders por evento.
  - **Fix**: Consolidar em `useReducer`. Ou usar `React.unstable_batchedUpdates` (React 18+ ja batcheia, mas verificar se funciona com callbacks assincronos no RN).

- [x] **[M-04] Switch de chat causa cascata de 10+ state updates e query removals** — `use-workspace-shell.ts:690`
  - Remove queries, limpa 5+ states, seta novos valores. Gera frames intermediarios com UI vazia.
  - **Fix**: Fazer toda a limpeza/setup em uma unica transicao atomica. Ou manter dados do chat anterior ate os novos estarem prontos (cross-fade).
  - **Done**: Deferred query removal via `queueMicrotask` + wrapped `selectChatById` state updates in `startTransition`. Tests: `use-workspace-shell.chat-switch.test.ts` (10 tests).

- [x] **[M-05] Foreground handler dispara 5+ query invalidations simultaneas** — `use-workspace-shell.ts:1825`
  - App volta do background -> invalida activeThreads, chats, chatContext, messages + syncMissedEvents. Respostas chegam em tempos diferentes, UI "se acomoda" por 0.5-2s.
  - **Fix**: Agrupar invalidacoes. Ou usar flag `isRestoringFromBackground` para mostrar um overlay suave durante a sincronizacao.
  - **Done**: Batched all refetches into `Promise.all` with `isRestoringFromBackground` flag. Flag resets in `.finally()`. Tests: `use-workspace-shell.foreground-restore.test.ts` (8 tests).

- [x] **[M-06] Delay na criacao de chat ao enviar mensagem** — `use-workspace-shell.ts:2230`
  - `sendMessage` em thread vazia precisa `await createChat()` antes de mostrar a mensagem otimista. Delay perceptivel entre pressionar "Send" e ver a mensagem.
  - **Fix**: Mostrar mensagem otimista imediatamente com ID temporario. Substituir pelo ID real quando a criacao completar.

  - **Done**: Extracted components, memoized renders, added styles module. Tests: chat-screen-memoized-components.test.ts
- [x] **[M-07] 40+ useState no chat-screen.tsx** — `chat-screen.tsx:166`
  - Componente re-renderiza inteiro em qualquer mudanca de estado. Keyboard input pode laggear.
  - **Fix**: Extrair sub-componentes memoizados (drawer, terminal, modais). Ou usar `useReducer` para estado local.

- [x] **[M-08] Banner de active threads causa layout shift** — `chat-screen.tsx:1362`
  - Banner aparece/desaparece baseado em poll de 2.5s. Toda a area de mensagem pula 30-40px.
  - **Fix**: Reservar espaco fixo para o banner. Ou anima-lo com height transition. Ou posicionar como overlay.
  - **Done**: Converted banner to absolute overlay with fade animation (200ms). Always renders with `pointerEvents="none"` when hidden. Tests: `active-threads-footer-cta.test.ts` (5 tests).

- [x] **[M-09] Auto-scroll briga com scroll manual durante streaming** — `chat-screen.tsx:464`
  - Cada update de streaming rola para bottom. Impossivel ler mensagens anteriores durante resposta ativa.
  - **Fix**: Detectar scroll manual e pausar auto-scroll. Mostrar FAB "Scroll to bottom" para retornar.
  - **Done**: Added userScrolledUpRef with 48px threshold. Auto-scroll paused when user scrolls up. Tests: `auto-scroll.test.ts` (17 tests pass)

- [x] **[M-10] Tool auto-expand sem animacao causa layout jump** — `streamingTimeline.tsx:245`
  - Apos 2s, tool item expande instantaneamente. Conteudo abaixo pula.
  - **Fix**: Usar `LayoutAnimation` do React Native para animar a expansao. Ou `Animated` com height interpolation.
  - **Done**: Added `LayoutAnimation.configureNext(easeInEaseOut)` before both auto-expand and manual toggle. Tests: `streamingTimeline.test.ts` (20 tests, 69 assertions).

- [x] **[M-11] Thread list inteira substituida por spinner durante refetch** — `thread-selection-screen.tsx:160`
  - `shouldShowThreadsLoading` em refetch mostra spinner no lugar da lista. Lista desaparece e reaparece.
  - **Fix**: Usar `isFetching` vs `isLoading` (TanStack Query distinction). Mostrar spinner overlay sem remover a lista. Ou confiar no cache.
  - **Done**: Added `isBackgroundRefetching` flag distinguishing initial load from background refetch. During refetch, list stays visible at opacity 0.7 with subtle spinner. Tests: `thread-loading-behavior.test.ts` (10 tests, 28 assertions).

- [x] **[M-12] Splash screen esconde antes do conteudo estar pronto** — `root-layout-content.tsx:88`
  - `SplashScreen.hideAsync()` e chamado no mount sem esperar dados. Animacao splash (~244ms) pode terminar antes da primeira tela renderizar.
  - **Fix**: So chamar `SplashScreen.hideAsync()` quando `isConfigLoaded && isSessionLoaded`. Estender animacao se necessario.
  - **Done**: Gated `SplashScreen.hideAsync()` on `isConfigLoaded && isSessionLoaded`. Tests: `splash-screen-readiness.test.ts` (6 tests).

  - **Done**: Added socketErrored flag; send() queues messages when socket errored. Tests: ws-client-queue.test.ts (4 tests)
- [x] **[M-13] Mensagens perdidas entre erro WS e reconexao** — `ws-client.ts:500`
  - `onerror` nao fecha o socket. Mensagens enviadas entre o erro e a reconexao falham silenciosamente.
  - **Fix**: Fechar socket explicitamente em `onerror`. Enfileirar mensagens durante reconexao.

- [x] **[M-14] `onFinish` instavel reinicia animacao do splash** — `animated-launch-splash.tsx:80`
  - `onFinish` em deps do `useEffect`. Parent re-render cria nova referencia -> effect re-executa -> animacao reinicia.
  - **Fix**: Usar `useRef` para `onFinish` callback. Ou memoizar com `useCallback` no parent.
  - **Done**: Added `onFinishRef` pattern. `onFinish` removed from effect deps. Tests: `animated-launch-splash.test.tsx` (3 tests pass)

  - **Done**: Increased MESSAGE_PAGE_SIZE from 5 to 25. Tests: use-messages-query.test.ts
- [x] **[M-15] Apenas 5 mensagens visiveis por vez** — `use-messages-query.ts:8`
  - `MESSAGE_PAGE_SIZE = 5`. Mensagens antigas somem. Scroll para cima necessario para ver historico.
  - **Fix**: Aumentar para 20-30. Implementar FlatList com virtualizacao para performance.

### P2 — Medium

  - **Done**: Wrapped 6 selection setState calls in startTransition. Tests: ws-event-batching.test.ts
- [x] **[M-16] Selection sync causa 6 setState em sequencia** — `use-workspace-shell.ts:652`
  - Sincronizacao do server seta projectId, chatId, permissionMode, model, reasoning, provider em cascata.
  - **Fix**: Consolidar em um unico dispatch/batch update.

  - **Done**: Addressed by M-03 (unstable_batchedUpdates) reducing per-poll render impact.
- [x] **[M-17] Active threads poll a cada 2.5s causa micro-stutters** — `use-workspace-shell.ts:574`
  - `refetchInterval: 2500` com `staleTime: 1000`. Re-renders periodicos em todos os consumers.
  - **Fix**: Aumentar intervalo para 5-10s. Ou usar WebSocket para push updates ao inves de polling.

  - **Done**: Added redirect guard to prevent delayed navigation. Tests: chat-screen-redirect.test.ts
- [x] **[M-18] Redirect 180ms delayed ao chat sem selectedChatId** — `chat-screen.tsx:686`
  - Chat screen mostra loading/vazio por 180ms antes de redirecionar para threads.
  - **Fix**: Checar condicao de redirect antes de renderizar. Ou mostrar splash/overlay durante redirect.

  - **Done**: Added debounced resolving spinner. Tests: chat-screen-resolving-spinner.test.ts
- [x] **[M-19] `isResolvingThreadSelection` mostra spinner de duracao variavel** — `chat-screen.tsx:403`
  - Ao abrir thread, "Opening thread..." aparece por tempo imprevisivel (0-500ms+).
  - **Fix**: Se < 200ms, nao mostrar nada. Se > 200ms, mostrar skeleton. Evitar spinner para operacoes sub-segundo.

  - **Done**: Added streaming text persistence fallback during transition. Tests: chat-screen-streaming-fallback.test.ts
- [x] **[M-20] Flash de streaming text -> timeline items na transicao** — `chat-screen.tsx:1445`
  - Quando streaming muda de delta-only para structured events, conteudo pode duplicar ou sumir por 1 frame.
  - **Fix**: Manter streaming text como fallback ate o primeiro item do timeline renderizar.

  - **Done**: Added drawer gesture lock during streaming. Tests: chat-screen-drawer-lock.test.ts
- [x] **[M-21] Drawer pode ficar stuck em estado half-open** — `chat-screen.tsx:781`
  - Taps rapidos durante animacao: `isDrawerOpen` true enquanto close animation roda. Nao ha lock.
  - **Fix**: Adicionar `isAnimatingRef` para prevenir interacoes durante transicao.

- [x] **[M-22] Layout shift na workspace selection (spinner -> lista)** — `workspace-selection-screen.tsx:268`
  - ActivityIndicator centralizado pula para lista completa sem transicao.
  - **Fix**: Skeleton cards. Ou posicionar spinner no topo da lista sem mudar layout.

  - **Done**: Removed list reset before scan; results replace atomically. Tests: settings-screen.scan.test.ts (4 tests)
- [x] **[M-23] LAN scan reseta lista antes de ter novos resultados** — `settings-screen.tsx:206`
  - `setDiscoveredServers([])` no inicio do scan. Lista some, depois repopula.
  - **Fix**: Manter resultados anteriores durante scan. Substituir atomicamente quando novos resultados chegarem.

- [x] **[M-24] Double reconnect em onerror + onclose** — `ws-client.ts:488`
  - Ambos chamam `scheduleReconnect()`. Pode incrementar `reconnectAttempts` 2x, dobrando o backoff.
  - **Fix**: Usar flag para deduplicate. `onerror` deve marcar estado mas so `onclose` agenda reconexao.
  - **Done**: `onerror` now calls `closeSocket()` instead of `scheduleReconnect()`. Only `onclose` reconnects. Tests: `ws-client-reconnect.test.ts` (5 tests).

  - **Done**: Stabilized callbacks via refs; removed identity check from cache. Tests: streamingTimeline.test.ts (4 tests)
- [x] **[M-25] Render cache invalida quando callbacks mudam de identity** — `streamingTimeline.tsx:295`
  - Comparacao de referencia de callbacks. Se parent re-renderiza sem memoizar, toda a lista re-renderiza.
  - **Fix**: Memoizar todos os callbacks passados para StreamingTimeline. Ou remover callback comparison do cache check.

- [x] **[M-26] `initialData: createEmptyPage()` causa flash de empty state** — `use-messages-query.ts:118`
  - Ao abrir chat com mensagens, "Start a conversation." aparece por 1 frame antes das mensagens carregarem.
  - **Fix**: Nao usar `initialData`. Ou inicializar com `undefined` e mostrar skeleton quando `isLoading`.

  - **Done**: Added isProcessingDeepLink state with loading overlay. Tests: root-layout-content.test.ts (4 tests)
- [x] **[M-27] Deep link sem loading indicator** — `root-layout-content.tsx:114`
  - Auth callback via deep link processa async sem feedback visual. Tela default aparece brevemente.
  - **Fix**: Mostrar overlay/spinner durante processamento de deep link.

  - **Done**: Increased animation phases: total ~580ms (was ~306ms). Tests: animated-launch-splash.duration.test.ts (5 tests)
- [x] **[M-28] Splash animation muito rapida (~244ms)** — `animated-launch-splash.tsx:19`
  - Animacao termina antes do conteudo carregar, revelando tela vazia.
  - **Fix**: Vincular termino da animacao ao readiness do conteudo. Estender fade-out se necessario.

### P3 — Low

  - **Done**: Changed toastContainer.bottom from 28 to 92. Tests: thread-selection-screen.toast.test.ts (3 tests)
- [x] **[M-29] Toast sobrepoe FAB button** — `thread-selection-screen.tsx:415`
  - Toast e FAB no mesmo bottom position. Toast fica por cima.
  - **Fix**: Subir posicao do toast quando FAB esta visivel.

- [x] **[M-30] Flash de "No workspace selected" antes de redirect** — `thread-selection-screen.tsx:116`
  - Breve flash do subtitle incorreto antes de navegar para /workspaces.

  - **Done**: Added shouldShowLoading guard with isLoaded check. Tests: active-threads-screen.loading.test.ts (6 tests)
- [x] **[M-31] Loading/empty race no active-threads** — `active-threads-screen.tsx:68`
  - Com cache vazio, `isLoading=false` + `visibleThreads=[]` mostra empty state antes do fetch.

  - **Done**: Added 3s timeout to clear pendingRouteRef. Tests: use-flow-navigator.test.ts (6 tests)
- [x] **[M-32] pendingRouteRef pode bloquear navegacao permanentemente** — `use-flow-navigator.ts:19`
  - Se navegacao falha, ref nunca limpa, bloqueando futuros taps no mesmo destino.
  - **Fix**: Adicionar timeout de 3s para limpar pendingRouteRef.

  - **Done**: Increased queue limit to 200; subscription messages protected from eviction. Tests: ws-client-queue.test.ts
- [x] **[M-33] Queue overflow silenciosamente descarta mensagens** — `ws-client.ts:374`
  - Fila > 50 items: `shift()` remove a mais antiga (pode ser `join_chat` critico).
  - **Fix**: Priorizar mensagens de subscription sobre mensagens de user. Ou aumentar limite.

  - **Done**: Added early return with spinner during health check pending/error. Tests: workspace-selection-screen.test.ts (5 tests)
- [x] **[M-34] Health check redirect causa flash de workspace screen** — `workspace-selection-screen.tsx:76`
  - Tela renderiza parcialmente antes de detectar erro e redirecionar para settings.

  - **Done**: Parallel Promise.all for ApiConfig+PrivateSession boot. Tests: parallel-boot.test.ts (5 tests)
- [x] **[M-35] Config providers sequenciais adicionam latencia ao boot** — `api-config-provider.tsx:26` + `private-session-provider.tsx:81`
  - Dois `isLoaded` flags que precisam completar antes do app funcionar.
  - **Fix**: Paralelizar carregamento. Ou unificar em um unico provider.

---

## CROSS-PLATFORM (Desktop + Mobile)

### Consistencia entre plataformas

  - **Done**: Both platforms now use matching auto-expand/collapse with expandedByUser guard and configurable delay.
- [x] **[X-01] Streaming timeline: comportamento de auto-expand/collapse deve ser identico**
  - Desktop e mobile tem a mesma logica mas implementacoes separadas. Garantir paridade.

  - **Done**: Both platforms now use 25 messages per page (was 5).
- [x] **[X-02] Message window size**: Desktop usa 5, Mobile usa 5. Ambos muito baixos.
  - Aumentar para 20-30 em ambas as plataformas.

  - **Done**: Both platforms use userScrolledUpRef pattern with matching threshold.
- [x] **[X-03] Auto-scroll behavior** deve ser consistente.
  - Ambas as plataformas brigam com scroll do usuario durante streaming. Resolver igualmente.

  - **Done**: Skeleton screens added across desktop sidebar, conversation panel, mobile workspace selection, thread loading.
- [x] **[X-04] Loading states** devem usar skeleton screens em vez de spinners/texto.
  - Nem desktop nem mobile usam skeletons. Implementar padrao compartilhado.

  - **Done**: Desktop uses useReducer with atomic dispatch; mobile uses unstable_batchedUpdates and startTransition.
- [x] **[X-05] State management**: Ambas as plataformas sofrem de render cascades por multiplos useState.
  - Migrar para useReducer ou estado consolidado em ambas.

---

## Resumo

| Prioridade | Desktop | Mobile | Cross-Platform | Total |
|------------|---------|--------|----------------|-------|
| P0 Critical | 1 | 2 | -- | **3** |
| P1 High | 12 | 13 | -- | **25** |
| P2 Medium | 11 | 13 | 5 | **29** |
| P3 Low | 10 | 7 | -- | **17** |
| **Total** | **34** | **35** | **5** | **74** |

---

## Ordem de Ataque Recomendada

### Sprint 1 — Criticos + Quick Wins
1. `[M-01]` Fix WebSocket reconnect loop (critical, causa perda de dados)
2. `[M-02]` Manter streaming text visivel ate mensagem final (critical, conteudo some)
3. `[D-01]` Bootstrap batch (critical, pessima primeira impressao)
4. `[D-07]` + `[M-26]` Loading states iniciais corretos (quick win, elimina flash de empty)
5. `[M-14]` Fix splash animation onFinish instability (quick win)

### Sprint 2 — Render Performance
6. `[M-03]` + `[D-16]` Consolidar state management (useReducer)
7. `[M-07]` Extrair sub-componentes memoizados do chat-screen
8. `[D-23]` Pointer listener via ref no Three.js

### Sprint 3 — Scroll & Layout
9. `[D-11]` + `[M-09]` Auto-scroll respeitando posicao do usuario
10. `[D-09]` + `[M-10]` Tool auto-expand com animacao
11. `[D-12]` Terminal panel com animacao de resize
12. `[M-08]` Active threads banner sem layout shift

### Sprint 4 — State Transitions
13. `[D-02]` Preservar streaming state entre chats
14. `[D-04]` + `[D-05]` SET_CHATS/UPSERT_CHAT nao forcar selecao
15. `[M-04]` + `[M-05]` Chat switch e foreground atomicos
16. `[M-11]` Thread list: spinner overlay ao inves de replacement

### Sprint 5 — Polish
17. `[D-13]` Fontes locais / preload
18. `[D-03]` Remover fade-in do layout
19. `[M-12]` Splash screen timing correto
20. `[X-04]` Skeleton screens em todas as listas
21. Restante dos P3

---

# V2 — Segunda Auditoria (2026-03-18)

> Auditoria pos-implementacao das 74 melhorias. Foco em edge cases remanescentes, micro-interacoes, e polimento final.
>
> Status de verificacao em 2026-03-19:
> - Desktop V2: implementacao local validada com `bun test` para todos os itens listados abaixo. Apenas `[D-50]` e `[D-56]` receberam prova E2E executada nesta rodada; os demais continuam sem check por falta de E2E.
> - Mobile V2: implementacao local validada com `bun test` para os itens listados abaixo. A suite real `bun run --cwd mobile test:e2e:ios` compilou e instalou o app no simulador, iniciou o backend e abriu o app, mas travou dentro de `ios-thread-activity-flow.sh`; por isso nenhum item mobile foi marcado como concluido nesta rodada.
> - Cross-platform V2: ainda pendente.

---

## DESKTOP — Novos Issues

### P1 — High

- [ ] **[D-36] GitBranchControl usa `mousedown` em vez de `pointerdown`** — `GitBranchControl.tsx:82`
  - Nao captura stylus/touch events. Dropdown nao fecha em dispositivos touch.
  - **Fix**: Trocar `mousedown` por `pointerdown` no event listener.

- [ ] **[D-37] `forceScrollToBottom` usa dois RAFs encadeados causando race com scroll do usuario** — `ConversationPanel.tsx:420`
  - Dois `requestAnimationFrame` em sequencia podem ser interrompidos por scroll manual entre frames.
  - **Fix**: Combinar check + scroll em um unico RAF; verificar `userScrolledUpRef` antes de scrollar.

- [ ] **[D-38] Terminal auto-scroll dispara a cada item sem debounce** — `ThreadTerminalPanel.tsx:60`
  - Rapid terminal output causa multiplos renders + scrolls por segundo.
  - **Fix**: Debounce scroll update para no maximo uma vez por frame via `requestAnimationFrame`.

- [ ] **[D-39] StreamingTimeline auto-collapse timer nao cancela no unmount** — `StreamingTimeline.tsx:238`
  - Se usuario troca de chat durante timer, callback pode disparar em item errado.
  - **Fix**: Cancelar timer no cleanup do useEffect ou no unmount do componente.

- [ ] **[D-57] WebSocket event handler nao memoizado com useCallback** — `App.tsx:1905`
  - Re-renders do parent recriam handler; WS antigo pode disparar eventos para handler stale.
  - **Fix**: Memoizar `handleWsEvent` e `handleWsState` com `useCallback` e deps estaveis.

### P2 — Medium

- [ ] **[D-40] Badge "Newer messages available" desaparece sem fade** — `ConversationPanel.tsx:567`
  - Badge some instantaneamente ao clicar "load latest". Sem transicao de saida.
  - **Fix**: Wrapping com `AnimatePresence` + `motion.div` com `exit={{ opacity: 0 }}`.

- [ ] **[D-41] Botao scroll-to-bottom aparece/desaparece sem animacao** — `ConversationPanel.tsx:673`
  - FAB de scroll aparece/desaparece instantaneamente sem fade.
  - **Fix**: `AnimatePresence` + `motion.button` com transicao de opacity/scale.

- [ ] **[D-42] Skeleton pulses nao sincronizados entre items** — `App.tsx:2815`
  - Cada div com `animate-pulse` comeca em momento diferente; efeito caotico.
  - **Fix**: Usar CSS animation delay sincronizado ou single shimmer global.

- [ ] **[D-43] Selects de model/provider sem focus-visible** — `MessageComposer.tsx:372`
  - Usuarios de teclado nao veem qual select esta focado.
  - **Fix**: Adicionar `focus-visible:ring-2 focus-visible:ring-sky-400`.

- [ ] **[D-45] CopyButton timer nao limpa no unmount** — `ConversationPanel.tsx:38`
  - "Copied" state pode aparecer brevemente apos trocar de chat se timer ainda estiver ativo.
  - **Fix**: Cleanup do timer no return do useEffect/unmount.

- [ ] **[D-47] Terminal input sem feedback visual de disabled** — `ThreadTerminalPanel.tsx:127`
  - `disabled={isExecuting}` remove interatividade mas visual nao muda; usuario acha que pode clicar.
  - **Fix**: Adicionar `disabled:opacity-60 disabled:bg-slate-950/50`.

- [ ] **[D-51] Error toast nao auto-dismiss** — `App.tsx:776`
  - Erros acumulam-se no state infinitamente. Lista cresce sem limite.
  - **Fix**: Auto-dismiss apos 6s com timer.

- [x] **[D-56] Model dropdown mostra "No models" durante loading** — `MessageComposer.tsx:383`
  - Antes do fetch, dropdown mostra "No models", depois popula. Mudanca abrupta.
  - **Fix**: Mostrar skeleton options ou spinner durante loading.
  - **Done**: Added `modelsLoading` state and "Loading models..." option. Tests: `desktop/src/react/features/composer/ui/MessageComposer.ux.test.ts`; E2E: `desktop/e2e/playwright/tests/ux-polish-playwright.spec.ts` (`[D-56] model select shows a loading label instead of an empty state`).

### P3 — Low

- [ ] **[D-44] StateLabel badge transition sem ease-out** — `StreamingTimeline.tsx:283`
  - Transicao de cor usa ease default; `ease-out` seria mais fluido.
  - **Fix**: Trocar para `transition-all duration-200 ease-out`.

- [ ] **[D-46] Top pagination guard flag nao reseta ao scrollar de volta** — `ConversationPanel.tsx:410`
  - `topPaginationTriggeredRef` nao reseta quando usuario scrolla para longe do topo.
  - **Fix**: Resetar flag quando `scrollTop > 32`.

- [ ] **[D-48] Sidebar resize sem feedback visual nos limites** — `App.tsx:724`
  - Drag para alem dos bounds simplesmente para; sem snap/bounce feedback.
  - **Fix**: Mudar cursor ou opacity quando no limite.

- [x] **[D-50] Sem overlay visual durante resize da sidebar** — `App.tsx:744`
  - Nenhum indicador visual de que sidebar esta sendo redimensionada.
  - **Fix**: Overlay semi-transparente durante drag.
  - **Done**: Added sidebar resize overlay plus resize-state visuals. Tests: `desktop/src/react/app/App.ux-v2.test.ts`; E2E: `desktop/e2e/playwright/tests/ux-polish-playwright.spec.ts` (`[D-50] sidebar resize shows and clears the overlay during drag`).

- [ ] **[D-52] Focus mode vs normal mode com line-height diferente** — `ConversationPanel.tsx:64`
  - Trocar modo causa shift sutil na altura do texto.
  - **Fix**: Usar line-height consistente em ambos os modos.

- [ ] **[D-53] Table headers sem align-top** — `ConversationPanel.tsx:127`
  - `th` nao tem `align-top` como `td`; tabelas com conteudo alto desalinham.
  - **Fix**: Adicionar `align-top` ao `th`.

- [ ] **[D-54] Nome de projeto longo pode overflow no sidebar** — `App.tsx:2876`
  - `min-w-0` pode estar faltando no parent flex; truncate nao funciona em todos os cenarios.
  - **Fix**: Adicionar `min-w-0` no container pai.

- [ ] **[D-55] Streaming dot animation pula entre ciclos** — `ConversationPanel.tsx:645`
  - `repeat: POSITIVE_INFINITY` sem `repeatType` causa jump entre ciclos.
  - **Fix**: Adicionar `repeatType="mirror"` para fade suave.

---

## MOBILE — Novos Issues

### P1 — High

- [ ] **[M-36] `scrollToEnd({ animated: false })` causa jump abrupto** — `chat-screen.tsx:431,742`
  - Scroll instantaneo sem animacao ao mostrar/esconder teclado e ao carregar terminal.
  - **Fix**: Usar `animated: true` para transicoes suaves.

- [ ] **[M-37] ActiveThreadsBanner absoluto pode sobrepor conteudo em telas pequenas** — `active-threads-banner.tsx:52`
  - `position: absolute` com `top: 0` pode cobrir input ou teclado em telas < 5".
  - **Fix**: Adicionar `paddingTop` ao conteudo abaixo do banner ou usar position relative com height reservada.

- [ ] **[M-38] Terminal scroll com setTimeout(0) — race com DOM render** — `chat-screen.tsx:742`
  - `scrollToEnd` dispara antes do DOM atualizar. Terminal mostra topo por 16-33ms.
  - **Fix**: Usar `onLayout` callback no container do terminal para scrollar apos render completo.

- [ ] **[M-39] Keyboard listeners podem persistir apos unmount rapido** — `chat-screen.tsx:442`
  - Navegacao rapida pode causar listeners duplicados ou orfaos.
  - **Fix**: Guardar com `isFocused` do React Navigation ou limpar explicitamente.

- [ ] **[M-40] TerminalOverlay zIndex conflita com modais** — `chat-screen.tsx:2590`
  - Sem `zIndex` definido no overlay, modais podem abrir atras do terminal.
  - **Fix**: Terminal `zIndex: 100`, modais `zIndex: 200`.

- [ ] **[M-41] Provider change limpa model antes do novo fetch completar** — `use-workspace-shell.ts:607`
  - `setSelectedModel` chamado incondicionalmente; selector fica vazio durante fetch.
  - **Fix**: So chamar `setSelectedModel` se model atual nao existe no novo provider.

### P2 — Medium

- [ ] **[M-42] Drawer pode reabrir durante animacao de fechamento** — `chat-screen.tsx:794`
  - `isDrawerAnimatingRef` checado no close mas nao no open. Tap rapido causa glitch visual.
  - **Fix**: Adicionar `if (isDrawerAnimatingRef.current) return;` no handler de abertura.

- [ ] **[M-43] Splash animation roda tempo completo mesmo se dados carregam instantaneamente** — `root-layout-content.tsx:96`
  - ~580ms de animacao desnecessaria quando dados carregam em <50ms.
  - **Fix**: Skip animacao ou reduzir duracao se dados ja estiverem prontos no mount.

- [ ] **[M-44] Scroll handler escreve em ref a cada 16ms** — `chat-screen.tsx:676`
  - `userScrolledUpRef.current = ...` a cada scroll frame pode causar micro-stutter.
  - **Fix**: Debounce write para 200ms ou usar threshold com histerese.

- [ ] **[M-45] Workspace health check substitui tela inteira por spinner** — `workspace-selection-screen.tsx:245`
  - Conteudo desaparece sem transicao quando health check falha.
  - **Fix**: Overlay semi-transparente com spinner em cima da lista ao inves de substituir.

- [ ] **[M-46] Picker modal nao preserva scroll position** — `chat-screen.tsx:1256`
  - Abrir picker sempre comeca no topo; usuario precisa scrollar novamente.
  - **Fix**: Cachear offset por tipo de picker ou usar `initialScrollIndex`.
  - **Status**: Implemented locally with per-picker scroll cache and restore-on-open logic. Local tests: `mobile/src/features/chat/ui/select-picker-modal.test.ts`. Pending mobile E2E before completion.

- [ ] **[M-47] `placeholderData: createEmptyPage()` pode causar flash de empty state** — `use-messages-query.ts:118`
  - Em re-entrada ao chat, empty page aparece brevemente antes dos dados reais.
  - **Fix**: Usar `placeholderData` do cache anterior via `keepPreviousData` ou remover placeholder.

### P3 — Low

- [ ] **[M-48] Model name longo sem truncation no selector** — `chat-screen.tsx:1632`
  - Nomes longos de modelo podem quebrar layout.
  - **Fix**: Adicionar `numberOfLines={1}` e `ellipsizeMode="tail"`.

- [ ] **[M-49] Attachments perdidos ao falhar envio de mensagem** — `chat-screen.tsx:771`
  - Input limpa attachment paths mesmo quando send falha; usuario deve re-adicionar.
  - **Fix**: So limpar input no callback de sucesso.
  - **Status**: Current `submit()` flow clears the composer only when `sendMessage()` returns success. Local tests: `mobile/src/features/chat/ui/chat-screen-ux-v2.test.ts`. Pending mobile E2E before completion.

- [ ] **[M-50] Terminal scroll position nao atualiza ao keyboard show/hide** — `chat-screen.tsx:741`
  - Se teclado aparece durante terminal output, scroll pode ficar no meio.
  - **Fix**: Re-scroll ao bottom apos evento de keyboard.

---

## CROSS-PLATFORM V2

- [ ] **[X-06] Consistencia de transition timing** — Desktop usa 200ms/300ms misto; Mobile usa LayoutAnimation defaults.
  - **Fix**: Padronizar duracoes: 150ms para micro-transitions, 250ms para modais, 400ms para page transitions.

---

## Resumo V2

| Prioridade | Desktop | Mobile | Cross | Total |
|------------|---------|--------|-------|-------|
| P1 High | 5 | 6 | -- | **11** |
| P2 Medium | 8 | 6 | -- | **14** |
| P3 Low | 8 | 3 | 1 | **12** |
| **Total** | **21** | **15** | **1** | **37** |

---

## Ordem de Ataque V2

### Sprint 7 — Critical Fixes
1. `[D-37]` Scroll race fix
2. `[D-39]` Timer cleanup no unmount
3. `[D-57]` WS handler memoization
4. `[M-38]` Terminal scroll race
5. `[M-39]` Keyboard listener cleanup
6. `[M-40]` zIndex conflicts

### Sprint 8 — Animation Polish
7. `[D-40]` + `[D-41]` Fade transitions para badges/buttons
8. `[D-42]` Skeleton sync
9. `[M-36]` Scroll animado
10. `[M-42]` Drawer animation guard
11. `[M-43]` Splash skip

### Sprint 9 — Edge Cases
12. `[D-38]` Terminal debounce
13. `[D-45]` CopyButton cleanup
14. `[D-51]` Error auto-dismiss
15. `[M-41]` Provider model preserve
16. `[M-44]` Scroll debounce
17. `[M-45]` Health check overlay

### Sprint 10 — Polish
18. Remaining P2/P3 items
