const hostName = 'io.remotecode.computer_use';
const sessions = new Map();
let port;
let requests = Promise.resolve();

// Runs in this extension's isolated world, without changing page attributes
// or exposing references to page scripts. Every action checks visibility again
// inside the tab to close the race with the background service worker.
export function pageOperation(operation, args) {
  if (operation === 'browser_act' && document.visibilityState !== 'hidden') {
    throw new Error('human_activity: the tab is visible; select another tab before continuing.');
  }
  if (operation === 'browser_act') {
    const snapshot = globalThis.__remoteCodeSnapshot;
    const element = snapshot?.get(args.ref);
    if (args.action !== 'scroll' || args.ref) {
      if (!element?.isConnected) throw new Error('stale_reference: take a new browser_snapshot.');
    }
    if (element && (element.disabled || element.getAttribute('aria-disabled') === 'true')) {
      throw new Error('The element is disabled.');
    }
    switch (args.action) {
      case 'click':
        element.click();
        break;
      case 'fill':
      case 'type': {
        const text = String(args.text ?? '');
        element.focus({preventScroll: true});
        if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement || element instanceof HTMLSelectElement) {
          if (element.readOnly) throw new Error('The field is read-only.');
          const prototype = element instanceof HTMLInputElement ? HTMLInputElement.prototype
            : element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLSelectElement.prototype;
          const value = args.action === 'type' ? element.value + text : text;
          Object.getOwnPropertyDescriptor(prototype, 'value').set.call(element, value);
        } else if (element.isContentEditable) {
          element.textContent = (args.action === 'type' ? element.textContent : '') + text;
        } else {
          throw new Error('The element is not an editable field.');
        }
        element.dispatchEvent(new Event('input', {bubbles: true}));
        element.dispatchEvent(new Event('change', {bubbles: true}));
        break;
      }
      case 'scroll':
        (element || window).scrollBy({left: args.delta_x ?? 0, top: args.delta_y ?? 600, behavior: 'instant'});
        break;
      default:
        throw new Error('Unsupported browser action.');
    }
  }
  const token = crypto.randomUUID();
  const refs = new Map();
  const visible = element => {
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
  };
  const elements = Array.from(document.querySelectorAll('a,button,input,textarea,select,[role],[tabindex],[contenteditable]'))
    .filter(visible).slice(0, 200).map((element, index) => {
      const ref = `${token}.${index}`;
      refs.set(ref, element);
      return {
        ref, role: element.getAttribute('role') || element.tagName.toLowerCase(),
        name: (element.getAttribute('aria-label') || element.labels?.[0]?.innerText || element.innerText || element.getAttribute('name') || '').trim().slice(0, 500),
        value: element.type === 'password' ? '' : String(element.value ?? '').slice(0, 1000)
      };
    });
  globalThis.__remoteCodeSnapshot = refs;
  return {url: location.href, title: document.title, ready: document.readyState === 'complete',
    text: (document.body?.innerText || '').slice(0, 16000), elements};
}

async function ownedTab(session, mutate = false) {
  const entry = sessions.get(session);
  if (!entry) throw new Error('No owned tab. Use browser_open first.');
  const tab = await chrome.tabs.get(entry.tabId);
  if (mutate && (entry.takenOver || tab.active)) {
    throw new Error('human_activity: you selected this tab. Use browser_close to release it, then browser_open for a new background tab.');
  }
  return tab;
}

function validURL(raw) {
  const url = new URL(raw);
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Only HTTP and HTTPS URLs are supported.');
  return url.href;
}

export async function handleRequest(request) {
  const {operation, session, arguments: args = {}} = request;
  if (typeof session !== 'string' || !/^[a-f0-9-]{36}$/i.test(session)) throw new Error('Invalid browser session.');
  if (operation === 'browser_status') return {connected: true, mode: 'current_chrome_profile', hasTab: sessions.has(session)};
  if (operation === 'browser_close') {
    const entry = sessions.get(session);
    if (!entry) return {closed: false};
    const tab = await chrome.tabs.get(entry.tabId).catch(() => null);
    // A selected tab belongs to the user from now on, including on cleanup.
    if (tab && !tab.active && !entry.takenOver) await chrome.tabs.remove(tab.id);
    sessions.delete(session);
    return {closed: !!tab && !tab.active && !entry.takenOver, released: true};
  }
  if (operation === 'browser_open') {
    const url = validURL(args.url);
    if (!sessions.has(session)) {
      if (sessions.size >= 32) throw new Error('Close an existing MacCode browser session first.');
      const window = await chrome.windows.getLastFocused({windowTypes: ['normal']});
      if (window.incognito) throw new Error('Open a regular Chrome window in the profile you want to use.');
      const tab = await chrome.tabs.create({windowId: window.id, url: 'about:blank', active: false});
      sessions.set(session, {tabId: tab.id, takenOver: tab.active});
      await chrome.tabs.update(tab.id, {muted: true});
    }
    const tab = await ownedTab(session, true);
    await chrome.tabs.update(tab.id, {url});
    return {url, loading: true, next: 'Use browser_snapshot to read the page after navigation.'};
  }
  if (!['browser_snapshot', 'browser_act'].includes(operation)) throw new Error('Unknown browser operation.');
  if (operation === 'browser_act') {
    if (!['click', 'fill', 'type', 'scroll'].includes(args.action)) throw new Error('Unsupported browser action.');
    if (args.action !== 'scroll' && typeof args.ref !== 'string') throw new Error('An element ref from browser_snapshot is required.');
    if (['delta_x', 'delta_y'].some(key => args[key] !== undefined && !Number.isFinite(args[key]))) throw new Error('Scroll distances must be finite.');
  }
  const tab = await ownedTab(session, operation === 'browser_act');
  if (tab.status === 'loading') throw new Error('The page is still loading. Take a browser_snapshot again shortly.');
  validURL(tab.url);
  const results = await chrome.scripting.executeScript({
    target: {tabId: tab.id}, world: 'ISOLATED', func: pageOperation, args: [operation, args]
  });
  if (!results[0]?.result) throw new Error('The page did not return a snapshot.');
  return results[0].result;
}

function badge(text, title) {
  chrome.action.setBadgeText({text});
  chrome.action.setTitle({title});
}

function disconnected(connection, error) {
  if (port !== connection) return;
  port = undefined;
  badge('OFF', error || 'MacCode disconnected. Click to reconnect.');
  // Let any running request settle before disposing only tabs we still own.
  requests = requests.then(async () => {
    for (const session of [...sessions.keys()]) {
      await handleRequest({operation: 'browser_close', session}).catch(() => {});
    }
  });
}

function connect() {
  if (port) return;
  const connection = chrome.runtime.connectNative(hostName);
  port = connection;
  badge('ON', 'MacCode connected. Click to disconnect.');
  connection.onMessage.addListener(request => {
    requests = requests.then(async () => {
      if (port !== connection) return;
      let response;
      try { response = {id: request.id, ok: true, ...(await handleRequest(request))}; }
      catch (error) { response = {id: request.id, ok: false, error: String(error.message || error)}; }
      if (port === connection) connection.postMessage(response);
    }).catch(() => {});
  });
  connection.onDisconnect.addListener(() => {
    const error = chrome.runtime.lastError?.message;
    disconnected(connection, error);
  });
}

chrome.tabs.onActivated.addListener(({tabId}) => {
  for (const entry of sessions.values()) if (entry.tabId === tabId) entry.takenOver = true;
});
chrome.tabs.onRemoved.addListener(tabId => {
  for (const [session, entry] of sessions) if (entry.tabId === tabId) sessions.delete(session);
});
chrome.action.onClicked.addListener(() => {
  if (port) {
    const connection = port;
    disconnected(connection);
    connection.disconnect();
  } else connect();
});
chrome.runtime.onInstalled.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
