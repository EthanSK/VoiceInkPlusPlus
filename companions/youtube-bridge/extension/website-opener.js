/* global chrome */

// Keep the native bridge allow-listed: Agentic Mouse sends only one identifier, and this extension
// is the single source of truth for the URL that opens beside Chrome's current tab.
globalThis.createChromeWebsiteOpener = ({
  chromeApi = chrome,
  websiteURLs = {
    youtube: 'https://www.youtube.com/',
    x: 'https://x.com/',
    facebook: 'https://www.facebook.com/',
    github: 'https://github.com/EthanSK',
    linkedin: 'https://www.linkedin.com/feed/',
    gemini: 'https://gemini.google.com/app',
    grok: 'https://grok.com/',
  },
  log = () => {},
} = {}) => ({
  open: async (website) => {
    if (
      typeof website !== 'string'
      || !Object.prototype.hasOwnProperty.call(websiteURLs, website)
    ) {
      return { opened: false, reason: 'invalid-website' };
    }

    let lastFocusedWindow;
    try {
      lastFocusedWindow = await chromeApi.windows.getLastFocused({
        populate: false,
        windowTypes: ['normal'],
      });
    } catch (error) {
      return { opened: false, reason: `window-unavailable:${String(error)}` };
    }
    const windowId = lastFocusedWindow?.id;
    if (!Number.isInteger(windowId)) {
      return { opened: false, reason: 'no-focused-window' };
    }

    let activeTabs;
    try {
      activeTabs = await chromeApi.tabs.query({ active: true, windowId });
    } catch (error) {
      return { opened: false, reason: `tab-query-failed:${String(error)}` };
    }
    const activeTab = activeTabs.find(
      (tab) => Number.isInteger(tab.id) && Number.isInteger(tab.index),
    );
    if (!activeTab) {
      return { opened: false, reason: 'no-active-tab' };
    }

    try {
      const created = await chromeApi.tabs.create({
        active: true,
        index: activeTab.index + 1,
        url: websiteURLs[website],
        windowId,
      });
      log(`opened website=${website} window=${windowId} tab=${created.id ?? 'nil'}`);
      return {
        opened: true,
        reason: 'opened',
        tabId: Number.isInteger(created.id) ? created.id : undefined,
      };
    } catch (error) {
      return { opened: false, reason: `create-failed:${String(error)}` };
    }
  },
});
