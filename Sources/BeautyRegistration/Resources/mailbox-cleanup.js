// Cosmetic filtering is scoped to the mailbox's top-level document. Keep Vue's DOM,
// email-body frames, terms and Turnstile intact; CSS also covers ads inserted later.
(() => {
  'use strict';
  if (location.hostname !== 'fviainboxes.com') return;
  const styleID = 'beauty-mailbox-cleanup';
  function install() {
    const root = document.head || document.documentElement;
    if (!root) return false;
    if (document.getElementById(styleID)) return true;
    const style = document.createElement('style');
    style.id = styleID;
    style.textContent = `
      .ad-slot,
      .ad-clip,
      .ad-frame,
      iframe[title="Advertisement"],
      [data-top-strip],
      [data-right-rail],
      .midad-rails,
      aside:has(.ad-slot),
      .fixed:has(button[aria-label="Close ad"]),
      .fixed:has(iframe[title="Advertisement"]),
      div.my-5:has(.ad-slot):not(:has(input, main, iframe[title="Email content"])) {
        display: none !important;
      }
      /* Release the space reserved for the floating ad and the top ad strip. */
      body:has(.fixed iframe[title="Advertisement"]) {
        padding-bottom: 0 !important;
      }
      [class~="max-w-[110rem]"]:has([data-top-strip]) {
        min-height: 0 !important;
      }
    `;
    root.appendChild(style);
    return true;
  }
  if (!install()) {
    const observer = new MutationObserver(() => { if (install()) observer.disconnect(); });
    observer.observe(document, {childList: true, subtree: true});
  }
})();
