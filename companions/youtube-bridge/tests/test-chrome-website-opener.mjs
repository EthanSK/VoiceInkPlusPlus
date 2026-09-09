import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(
  new URL('../extension/website-opener.js', import.meta.url),
  'utf8',
);

const createdTabs = [];
let lastFocusedWindow = { id: 10 };
let activeTabs = [{ id: 42, index: 4, windowId: 10, active: true }];
let queryError;
let createError;
const chromeApi = {
  windows: {
    getLastFocused: async () => lastFocusedWindow,
  },
  tabs: {
    query: async () => {
      if (queryError) throw queryError;
      return activeTabs;
    },
    create: async (properties) => {
      if (createError) throw createError;
      createdTabs.push(properties);
      return { id: 99, ...properties };
    },
  },
};

const context = vm.createContext({ chrome: chromeApi, console, globalThis: {} });
vm.runInContext(source, context, { filename: 'website-opener.js' });
const opener = context.globalThis.createChromeWebsiteOpener({ chromeApi });
const expectedURLs = {
  youtube: 'https://www.youtube.com/',
  x: 'https://x.com/',
  facebook: 'https://www.facebook.com/',
  github: 'https://github.com/EthanSK',
  linkedin: 'https://www.linkedin.com/feed/',
  gemini: 'https://gemini.google.com/app',
  grok: 'https://grok.com/',
};

for (const [website, url] of Object.entries(expectedURLs)) {
  assert.deepEqual(
    JSON.parse(JSON.stringify(await opener.open(website))),
    { opened: true, reason: 'opened', tabId: 99 },
  );
  assert.deepEqual(
    JSON.parse(JSON.stringify(createdTabs.at(-1))),
    {
      active: true,
      index: 5,
      url,
      windowId: 10,
    },
  );
}

assert.deepEqual(
  JSON.parse(JSON.stringify(await opener.open('https://example.com/'))),
  { opened: false, reason: 'invalid-website' },
  'arbitrary URLs must never cross the website shortcut boundary',
);
assert.equal(createdTabs.length, 7);

lastFocusedWindow = {};
assert.equal((await opener.open('youtube')).reason, 'no-focused-window');
lastFocusedWindow = { id: 10 };
activeTabs = [];
assert.equal((await opener.open('youtube')).reason, 'no-active-tab');
activeTabs = [{ id: 42, index: 4, windowId: 10, active: true }];
queryError = new Error('window closed');
assert.equal(
  (await opener.open('youtube')).reason,
  'tab-query-failed:Error: window closed',
);
queryError = undefined;
createError = new Error('tab strip changed');
assert.equal(
  (await opener.open('youtube')).reason,
  'create-failed:Error: tab strip changed',
);

console.log('Chrome website opener: ok');
