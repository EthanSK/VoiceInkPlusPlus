import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(
  new URL('../extension/tab-history.js', import.meta.url),
  'utf8',
);

const stored = {};
const tabs = new Map([
  [1, { id: 1, windowId: 10, active: true }],
  [2, { id: 2, windowId: 10, active: false }],
  [3, { id: 3, windowId: 10, active: false }],
  [4, { id: 4, windowId: 10, active: false }],
  [20, { id: 20, windowId: 20, active: true }],
  [21, { id: 21, windowId: 20, active: false }],
]);
let lastFocusedWindowId = 10;
let controller;

const activate = async (tabId, windowId = tabs.get(tabId)?.windowId) => {
  for (const tab of tabs.values()) {
    if (tab.windowId === windowId) {
      tab.active = tab.id === tabId;
    }
  }
  await controller.activated({ tabId, windowId });
};

const chromeApi = {
  storage: {
    local: {
      get: async (key) => ({ [key]: stored[key] }),
      set: async (value) => Object.assign(stored, structuredClone(value)),
    },
  },
  windows: {
    getAll: async () => [{ id: 10 }, { id: 20 }],
    getLastFocused: async () => ({ id: lastFocusedWindowId }),
  },
  tabs: {
    query: async ({ active, windowId }) => [...tabs.values()].filter(
      (tab) => tab.windowId === windowId && (!active || tab.active),
    ),
    get: async (tabId) => {
      const tab = tabs.get(tabId);
      if (!tab) {
        throw new Error('No tab');
      }
      return tab;
    },
    update: async (tabId, { active }) => {
      const tab = tabs.get(tabId);
      if (!tab) {
        throw new Error('No tab');
      }
      if (active) {
        for (const candidate of tabs.values()) {
          if (candidate.windowId === tab.windowId) {
            candidate.active = candidate.id === tabId;
          }
        }
        queueMicrotask(() => { void controller.activated({ tabId, windowId: tab.windowId }); });
      }
      return tab;
    },
  },
};

const context = vm.createContext({ chrome: chromeApi, console, globalThis: {} });
vm.runInContext(source, context, { filename: 'tab-history.js' });
const makeController = () => context.globalThis.createChromeTabHistoryController({ chromeApi });

controller = makeController();
await controller.initialize();
await activate(2);
await activate(3);

assert.deepEqual(JSON.parse(JSON.stringify(await controller.navigate('back'))), {
  moved: true,
  reason: 'back',
  tabId: 2,
  windowId: 10,
});
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal((await controller.navigate('back')).tabId, 1, 'programmatic activation must not create a duplicate history entry');
assert.equal((await controller.navigate('forward')).tabId, 2);

await activate(4);
assert.equal((await controller.navigate('forward')).reason, 'end-of-history', 'manual activation after Back must discard the old forward branch');
assert.equal((await controller.navigate('back')).tabId, 2);
assert.equal((await controller.navigate('forward')).tabId, 4);

lastFocusedWindowId = 20;
await activate(21, 20);
assert.equal((await controller.navigate('back')).tabId, 20, 'each Chrome window must own independent activation history');
lastFocusedWindowId = 10;
assert.equal(tabs.get(4).active, true, 'navigating another Chrome window must not alter this window');

await controller.removed(2);
tabs.delete(2);
assert.equal((await controller.navigate('back')).tabId, 1, 'closed tabs must be removed from every historical occurrence');

controller = makeController();
await controller.initialize();
assert.equal((await controller.navigate('forward')).tabId, 4, 'history must survive an MV3 service-worker restart');

assert.equal((await controller.navigate('sideways')).reason, 'invalid-direction');

await activate(1);
await controller.removed(4);
tabs.delete(4);
assert.equal(
  (await controller.navigate('back')).reason,
  'start-of-history',
  'closing the only tab between two visits to the same tab must not leave a fake navigation step',
);

for (let tabId = 5; tabId <= 14; tabId += 1) {
  tabs.set(tabId, { id: tabId, windowId: 10, active: false });
}
await activate(10);
await activate(12);
await activate(5);
assert.equal(
  [...tabs.values()].filter((tab) => tab.windowId === 10).length,
  12,
  'the fixture must include twelve tabs in the primary window',
);
assert.equal(
  (await controller.navigate('back')).tabId,
  12,
  'history must activate an exact tab beyond Command-1 through Command-9 positional shortcuts',
);

await controller.windowRemoved(20);
assert.equal(
  stored.chromeTabActivationHistory.windows['20'],
  undefined,
  'closed windows must not leave persisted tab history',
);

console.log('Chrome per-window tab activation history: ok');
