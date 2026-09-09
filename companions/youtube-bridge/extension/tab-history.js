/* global chrome */

// Chrome exposes spatial previous/next-tab shortcuts, but not activation history. Keep a
// browser-like back/forward stack per window so a mouse wheel can revisit the tabs the user
// actually used without focusing Chrome or moving to another Chrome window.
globalThis.createChromeTabHistoryController = ({
  chromeApi = chrome,
  storageKey = 'chromeTabActivationHistory',
  historyLimit = 100,
  log = () => {},
} = {}) => {
  /** @type {Map<number, { entries: number[], cursor: number }>} */
  const histories = new Map();
  /** @type {Map<number, number>} */
  const expectedActivations = new Map();
  let isHydrated = false;
  let operationChain = Promise.resolve();

  const enqueue = (operation) => {
    operationChain = operationChain.then(operation, operation);
    return operationChain;
  };

  const hydrate = async () => {
    if (isHydrated) {
      return;
    }
    isHydrated = true;
    try {
      const stored = await chromeApi.storage.local.get(storageKey);
      const windows = stored?.[storageKey]?.windows;
      if (!windows || typeof windows !== 'object') {
        return;
      }
      for (const [rawWindowId, rawHistory] of Object.entries(windows)) {
        const windowId = Number(rawWindowId);
        const allEntries = Array.isArray(rawHistory?.entries)
          ? rawHistory.entries.filter(Number.isInteger)
          : [];
        if (!Number.isInteger(windowId) || allEntries.length === 0) {
          continue;
        }
        const rawCursor = Number.isInteger(rawHistory.cursor)
          ? rawHistory.cursor
          : allEntries.length - 1;
        const firstRetainedIndex = Math.max(0, allEntries.length - historyLimit);
        const entries = allEntries.slice(firstRetainedIndex);
        histories.set(windowId, {
          entries,
          cursor: Math.min(
            Math.max(0, rawCursor - firstRetainedIndex),
            entries.length - 1,
          ),
        });
      }
    } catch (error) {
      log(`tab history storage read failed: ${String(error)}`);
    }
  };

  const persist = async () => {
    const windows = {};
    for (const [windowId, history] of histories) {
      if (history.entries.length > 0) {
        windows[String(windowId)] = history;
      }
    }
    try {
      await chromeApi.storage.local.set({
        [storageKey]: { version: 1, windows },
      });
    } catch (error) {
      log(`tab history storage write failed: ${String(error)}`);
    }
  };

  const recordActivation = (tabId, windowId) => {
    if (!Number.isInteger(tabId) || !Number.isInteger(windowId)) {
      return false;
    }
    const expectedTabId = expectedActivations.get(windowId);
    if (expectedTabId === tabId) {
      expectedActivations.delete(windowId);
      return false;
    }
    if (expectedTabId !== undefined) {
      expectedActivations.delete(windowId);
    }

    const history = histories.get(windowId) ?? { entries: [], cursor: -1 };
    if (history.entries[history.cursor] === tabId) {
      histories.set(windowId, history);
      return false;
    }

    // Selecting a tab after going back creates a new branch, just like browser-page history.
    history.entries = history.entries.slice(0, history.cursor + 1);
    history.entries.push(tabId);
    if (history.entries.length > historyLimit) {
      history.entries.splice(0, history.entries.length - historyLimit);
    }
    history.cursor = history.entries.length - 1;
    histories.set(windowId, history);
    return true;
  };

  const collapseAdjacentEntries = (entries, cursor) => {
    const collapsed = [];
    let collapsedCursor = -1;
    entries.forEach((tabId, index) => {
      if (collapsed[collapsed.length - 1] !== tabId) {
        collapsed.push(tabId);
      }
      if (index <= cursor) {
        collapsedCursor = collapsed.length - 1;
      }
    });
    return {
      entries: collapsed,
      cursor: Math.min(Math.max(0, collapsedCursor), collapsed.length - 1),
    };
  };

  const removeTab = (tabId) => {
    let changed = false;
    for (const [windowId, history] of histories) {
      const oldEntries = history.entries;
      const retainedBeforeCursor = oldEntries
        .slice(0, history.cursor + 1)
        .filter((entry) => entry !== tabId).length;
      const entries = oldEntries.filter((entry) => entry !== tabId);
      if (entries.length === oldEntries.length) {
        continue;
      }
      changed = true;
      if (entries.length === 0) {
        histories.delete(windowId);
        expectedActivations.delete(windowId);
      } else {
        histories.set(
          windowId,
          collapseAdjacentEntries(entries, retainedBeforeCursor - 1),
        );
      }
    }
    return changed;
  };

  const getTab = async (tabId) => {
    try {
      return await chromeApi.tabs.get(tabId);
    } catch {
      return null;
    }
  };

  const navigate = async (direction) => {
    if (direction !== 'back' && direction !== 'forward') {
      return { moved: false, reason: 'invalid-direction' };
    }
    let lastFocusedWindow;
    try {
      lastFocusedWindow = await chromeApi.windows.getLastFocused({
        populate: false,
        windowTypes: ['normal'],
      });
    } catch (error) {
      return { moved: false, reason: `window-unavailable:${String(error)}` };
    }
    const windowId = lastFocusedWindow?.id;
    if (!Number.isInteger(windowId)) {
      return { moved: false, reason: 'no-focused-window' };
    }

    const activeTabs = await chromeApi.tabs.query({ active: true, windowId });
    const activeTabId = activeTabs.find((tab) => Number.isInteger(tab.id))?.id;
    if (!Number.isInteger(activeTabId)) {
      return { moved: false, reason: 'no-active-tab' };
    }
    recordActivation(activeTabId, windowId);

    const history = histories.get(windowId);
    if (!history) {
      await persist();
      return { moved: false, reason: 'no-history' };
    }
    const increment = direction === 'back' ? -1 : 1;
    let candidateIndex = history.cursor + increment;
    while (candidateIndex >= 0 && candidateIndex < history.entries.length) {
      const candidateTabId = history.entries[candidateIndex];
      const candidateTab = await getTab(candidateTabId);
      if (!candidateTab || candidateTab.windowId !== windowId) {
        history.entries.splice(candidateIndex, 1);
        if (candidateIndex <= history.cursor) {
          history.cursor -= 1;
        }
        candidateIndex = history.cursor + increment;
        continue;
      }

      const previousCursor = history.cursor;
      history.cursor = candidateIndex;
      expectedActivations.set(windowId, candidateTabId);
      await persist();
      try {
        await chromeApi.tabs.update(candidateTabId, { active: true });
        log(`tab history ${direction} window=${windowId} tab=${candidateTabId}`);
        return { moved: true, reason: direction, tabId: candidateTabId, windowId };
      } catch (error) {
        history.cursor = previousCursor;
        expectedActivations.delete(windowId);
        await persist();
        return { moved: false, reason: `activation-failed:${String(error)}` };
      }
    }

    await persist();
    return { moved: false, reason: direction === 'back' ? 'start-of-history' : 'end-of-history' };
  };

  return {
    initialize: () => enqueue(async () => {
      await hydrate();
      try {
        const windows = await chromeApi.windows.getAll({
          populate: false,
          windowTypes: ['normal'],
        });
        for (const window of windows) {
          if (!Number.isInteger(window.id)) {
            continue;
          }
          const activeTabs = await chromeApi.tabs.query({ active: true, windowId: window.id });
          const activeTabId = activeTabs.find((tab) => Number.isInteger(tab.id))?.id;
          recordActivation(activeTabId, window.id);
        }
        await persist();
      } catch (error) {
        log(`tab history initialization failed: ${String(error)}`);
      }
    }),
    activated: ({ tabId, windowId }) => enqueue(async () => {
      await hydrate();
      if (recordActivation(tabId, windowId)) {
        await persist();
      }
    }),
    removed: (tabId) => enqueue(async () => {
      await hydrate();
      if (removeTab(tabId)) {
        await persist();
      }
    }),
    windowRemoved: (windowId) => enqueue(async () => {
      await hydrate();
      if (histories.delete(windowId)) {
        expectedActivations.delete(windowId);
        await persist();
      }
    }),
    replaced: (addedTabId, removedTabId) => enqueue(async () => {
      await hydrate();
      let changed = false;
      for (const [windowId, history] of histories) {
        const entries = history.entries.map((tabId) => {
          if (tabId === removedTabId) {
            changed = true;
            return addedTabId;
          }
          return tabId;
        });
        histories.set(windowId, collapseAdjacentEntries(entries, history.cursor));
      }
      if (changed) {
        await persist();
      }
    }),
    navigate: (direction) => enqueue(async () => {
      await hydrate();
      return navigate(direction);
    }),
  };
};
