/* First-party page adapter. Never reads cookies, storage tokens or passwords from the page. */
(() => {
  'use strict';
  const registrationHost = 'api.jiucaihezi.studio';
  const mailboxHost = 'fviainboxes.com';
  const compatibilityHeaders = typeof beautyCompatibilityHeaders !== 'undefined' && beautyCompatibilityHeaders;
  const requestProfile = compatibilityHeaders ? 'Safari 兼容' : '默认 WebKit';
  const configuredHeaders = typeof beautyHeaderOverrides !== 'undefined' ? beautyHeaderOverrides
    : compatibilityHeaders ? {'Accept': 'application/json', 'Accept-Language': 'en-US,en;q=0.9'} : {};
  const overrides = Object.entries(configuredHeaders).filter(([name, value]) =>
    ['Accept', 'Accept-Language'].includes(name) && typeof value === 'string' && !/[\r\n]/.test(value));
  if (![registrationHost, mailboxHost].includes(location.hostname)) return;
  const state = {
    mailbox: '', ready: false, messages: [], baseline: [], armed: false,
    selected: null, opened: [], code: '', problem: '', requestedAt: 0, verification: null, registration: null
  };
  let nextMailboxPoll = null;
  let readingUntil = 0;
  let hasPolledMailbox = false;
  let diagnosticSecrets = [];
  const emit = data => { try { window.webkit.messageHandlers.beauty.postMessage({...data, documentID: beautyDocumentID}); } catch (_) {} };
  const visible = el => el && !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length)
    && getComputedStyle(el).visibility !== 'hidden' && getComputedStyle(el).display !== 'none';
  function field(selector, value) {
    const el = document.querySelector(selector);
    if (!el || !visible(el)) throw new Error('字段尚未出现，请等待网页加载。');
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.dispatchEvent(new Event('blur', { bubbles: true }));
    return el;
  }
  function button(pattern) {
    return [...document.querySelectorAll('button')].find(el => visible(el) && pattern.test(el.textContent.trim()));
  }
  function activate(el) {
    if (!el) return 'missing';
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') return 'disabled';
    el.click(); return 'clicked';
  }
  function registrationReadiness() {
    if (location.hostname !== registrationHost || location.pathname !== '/sign-up') return false;
    const fields = ['username', 'password', 'confirmPassword'].map(name => document.querySelector(`input[name="${name}"]`));
    const email = document.querySelector('input[name="email"]');
    if (email) fields.push(email);
    return fields.every(el => visible(el) && !el.disabled);
  }
  function mailboxReadiness() {
    const input = document.querySelector('#username');
    const domain = document.querySelector('[id^="headlessui-listbox-button"]')?.textContent.trim() || '';
    const getEmail = button(/^Get Email$/i);
    let message = '';
    if (!visible(input) || input.disabled) message = '等待邮箱输入框就绪；如出现人机验证，请在邮箱页完成。';
    else if (!domain || domain === 'nodomain') message = '正在等待邮箱域名加载。';
    else if (domain !== mailboxHost) message = '请将邮箱域名切换为 fviainboxes.com。';
    else if (!getEmail || getEmail.disabled || getEmail.getAttribute('aria-disabled') === 'true') message = '正在等待邮箱按钮就绪。';
    return {ready: !message, message};
  }
  function codeFromHTML(html) {
    const doc = new DOMParser().parseFromString(html, 'text/html');
    doc.querySelectorAll('style,script').forEach(el => el.remove());
    const text = (doc.body.textContent || '').replace(/\s+/g, ' ');
    const m = text.match(/(?:验证码|verification\s+code|security\s+code|code\s+is)(?:\s*(?:是|为|is))?\s*[:：]?\s*([a-z0-9]{6})(?![a-z0-9])/i);
    return m ? m[1] : '';
  }
  function failureMessage(body) {
    if (!body || typeof body !== 'object') return '';
    let text = [body.message, body.error?.message, body.error]
      .find(value => typeof value === 'string' && value.trim()) || '';
    for (const secret of diagnosticSecrets) {
      if (secret) text = text.split(secret).join('[已隐藏]');
    }
    // Keep the server's explanation, never a complete response, HTML page or echoed credentials.
    if (/<\/?[a-z][^>]*>/i.test(text)) return '';
    return text.replace(/[\w.+-]+@[\w.-]+\.[a-z]{2,}/gi, '[邮箱已隐藏]')
      .replace(/((?:password|密码|token|secret|api[_ -]?key|authorization)\s*[:=：]\s*)["']?[^\s"',;]+/gi, '$1[已隐藏]')
      .replace(/\b(?:sk-|eyJ)[a-z0-9._-]{12,}\b/gi, '[凭据已隐藏]')
      .replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 500);
  }
  function retryAfterSeconds(raw) {
    if (typeof raw !== 'string' || !raw.trim()) return null;
    const value = raw.trim();
    if (/^\d+$/.test(value)) return Math.min(Number(value), Number.MAX_SAFE_INTEGER);
    // HTTP-date, including the obsolete weekday formats accepted by HTTP recipients.
    if (!/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)/i.test(value)) return null;
    const timestamp = Date.parse(value);
    return Number.isFinite(timestamp) ? Math.max(0, Math.ceil((timestamp - Date.now()) / 1000)) : null;
  }
  function observe(rawURL, status, raw, method, retryAfter, responseHeaders) {
    let url;
    try { url = new URL(rawURL, location.href); } catch (_) { return; }
    if (url.origin !== location.origin) return;
    let body;
    try { body = JSON.parse(raw); } catch (_) { body = raw; }
    // Emit a full network record (req + res) for every same-origin request on the registration host.
    if (location.hostname === registrationHost) {
      const pending = pendingRequests.get(networkKey(rawURL, method));
      pendingRequests.delete(networkKey(rawURL, method));
      const safeBody = typeof raw === 'string' ? failureMessage({message: raw.slice(0, 1000)}) : '';
      emit({
        kind: 'networkRecord',
        method,
        path: url.pathname,
        transport: pending?.transport ?? 'fetch',
        status,
        requestHeaders: pending?.requestHeaders ?? [],
        responseHeaders: Array.isArray(responseHeaders) ? responseHeaders : [],
        responseBody: safeBody,
        retryAfter: retryAfter ?? null,
      });
    }
    if (location.hostname === registrationHost) {
      let kind = null;
      if (url.pathname === '/api/user/register' && method === 'POST') kind = 'registration';
      if (url.pathname === '/api/verification' && method === 'GET') kind = 'verification';
      if (kind) {
        const result = { kind, status, success: status >= 200 && status < 300 && body?.success === true, requestProfile };
        if (kind === 'registration') {
          result.rejected = !result.success &&
            ((status >= 200 && status < 300 && body?.success === false) ||
             (status >= 400 && status < 500 && status !== 408));
        }
        if (!result.success) result.message = failureMessage(body);
        if (status === 429) {
          const seconds = retryAfterSeconds(retryAfter);
          if (seconds !== null) result.retryAfterSeconds = seconds;
          // Preserve the raw body (≤500 chars) so the Swift layer can log the actual limit reason.
          if (raw && typeof raw === 'string') result.rawBody429 = raw.slice(0, 500);
        }
        state[kind] = result;
        if (status === 429) state.problem = '网站限流，请稍后在页面上处理。';
        emit(result);
      }
    }
    if (location.hostname === mailboxHost && url.searchParams.get('username') === state.mailbox && url.searchParams.get('domain') === mailboxHost) {
      if (url.pathname === '/messages') {
        if (status === 429) state.problem = '邮箱服务限流，请稍后继续。';
        else if (status === 403) state.problem = '请在邮箱页面完成人机验证，然后点击继续。';
        else if (status >= 200 && status < 300 && Array.isArray(body?.result)) {
          state.ready = true; state.problem = '';
          state.messages = body.result.map(m => ({id: String(m.id), subject: String(m.subject || ''), from: String(m.from || ''), createdAt: Number(m.createdAt)}));
        }
      }
      if (url.pathname === '/message' && state.armed && url.searchParams.get('id') === state.selected) {
        readingUntil = 0;
        if (status === 200 && typeof body === 'string') state.code = codeFromHTML(body);
        else state.opened = state.opened.filter(id => id !== state.selected);
        if (status === 429) state.problem = '邮箱服务限流，请稍后继续。';
        if (status === 403) state.problem = '请在邮箱页面完成人机验证，然后点击继续。';
      }
    }
  }
  function registrationRequest(rawURL) {
    if (location.hostname !== registrationHost) return false;
    try {
      const url = new URL(rawURL, location.href);
      return url.origin === location.origin && ['/api/user/register', '/api/verification'].includes(url.pathname);
    } catch (_) { return false; }
  }
  const displayedHeaderNames = ['Accept', 'Accept-Language', 'Content-Type', 'Cache-Control', 'Pragma', 'X-Requested-With', 'Origin', 'Referer'];
  const displayedPaths = ['/', '/sign-up', '/sign-in', '/api/status', '/api/verification', '/api/user/register'];
  // Pending request metadata keyed by URL+method, used to join req headers with the response.
  const pendingRequests = new Map();
  function networkKey(url, method) { return method + ' ' + url; }
  const hiddenHeader = /^(cookie|authorization|proxy-authorization)$/i;
  const secretHeader = /token|secret|auth|api[-_]?key|session/i;
  // All page-set headers for the network log; credentials never cross the bridge.
  function loggedHeaders(entries) {
    const result = [];
    if (typeof navigator !== 'undefined') result.push({name: 'User-Agent', value: navigator.userAgent, source: '浏览器标识'});
    for (const [name, value] of entries) {
      if (hiddenHeader.test(name)) continue;
      const overridden = overrides.some(([key]) => key.toLowerCase() === String(name).toLowerCase());
      result.push({name: String(name), value: secretHeader.test(name) ? '[已隐藏]' : failureMessage({message: String(value)}),
        source: overridden ? '客户端配置' : '网页设置'});
    }
    return result;
  }
  function requestDetails(rawURL, method, transport, getHeader, allHeaders) {
    if (location.hostname !== registrationHost) return;
    let url;
    try { url = new URL(rawURL, location.href); } catch (_) { return; }
    if (url.origin !== location.origin) return;
    pendingRequests.set(networkKey(rawURL, method), {requestHeaders: loggedHeaders(allHeaders || []), transport});
    if (!displayedPaths.includes(url.pathname)) return;
    const requestHeaders = [];
    if (typeof navigator !== 'undefined') requestHeaders.push({name: 'User-Agent', value: failureMessage({message: navigator.userAgent}), source: '浏览器标识'});
    for (const name of displayedHeaderNames) {
      let value = getHeader(name);
      if (!value) continue;
      if (name === 'Origin' || name === 'Referer') {
        try {
          const address = new URL(value, location.href);
          value = address.origin + (displayedPaths.includes(address.pathname) ? address.pathname : '/…');
        } catch (_) { continue; }
      }
      requestHeaders.push({name, value: failureMessage({message: String(value)}),
        source: registrationRequest(url.href) && overrides.some(([key]) => key === name) ? '客户端配置' : '网页设置'});
    }
    // No body, query string, cookies, authorization or arbitrary custom headers cross the bridge.
    emit({kind: 'requestHeaders', method, path: url.pathname, transport, headers: requestHeaders});
  }
  const originalFetch = window.fetch;
  window.fetch = async function(input, init) {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    let options = init;
    const headers = new Headers(init?.headers ?? input?.headers);
    if (registrationRequest(url) && overrides.length) {
      for (const [name, value] of overrides) headers.set(name, value);
      options = {...init, headers};
    }
    const method = String(init?.method || input?.method || 'GET').toUpperCase();
    const pending = originalFetch.call(this, input, options);
    requestDetails(url, method, 'fetch', name => headers.get(name), [...headers.entries()]);
    const response = await pending;
    response.clone().text().then(body => {
      const resHeaders = [];
      response.headers.forEach((value, name) => {
        if (!['set-cookie', 'authorization', 'cookie'].includes(name.toLowerCase()))
          resHeaders.push({name, value: String(value).slice(0, 500)});
      });
      observe(url, response.status, body, method, response.headers?.get('Retry-After'), resHeaders);
    }).catch(() => {});
    return response;
  };
  const open = XMLHttpRequest.prototype.open;
  const send = XMLHttpRequest.prototype.send;
  const setRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
  const useCompatibleHeaders = Symbol('beautyCompatibleHeaders');
  const requestMetadata = Symbol('beautyRequestMetadata');
  const responseListener = Symbol('beautyResponseListener');
  XMLHttpRequest.prototype.open = function(method, url) {
    const result = open.apply(this, arguments);
    this[useCompatibleHeaders] = registrationRequest(String(url));
    this[requestMetadata] = {method: String(method).toUpperCase(), url: String(url), headers: {}, all: []};
    if (this[responseListener]) this.removeEventListener('load', this[responseListener]);
    this[responseListener] = () => {
      try {
        const raw = this.responseType === 'json' ? JSON.stringify(this.response) : this.responseText;
        const resHeaders = [];
        (this.getAllResponseHeaders() || '').split('\r\n').forEach(line => {
          const idx = line.indexOf(':');
          if (idx < 0) return;
          const name = line.slice(0, idx).trim().toLowerCase();
          if (['set-cookie', 'authorization', 'cookie'].includes(name)) return;
          resHeaders.push({name: line.slice(0, idx).trim(), value: line.slice(idx + 1).trim().slice(0, 500)});
        });
        observe(String(url), this.status, raw, String(method).toUpperCase(), this.getResponseHeader('Retry-After'), resHeaders);
      } catch (_) {}
    };
    this.addEventListener('load', this[responseListener], {once: true});
    return result;
  };
  XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
    if (this[useCompatibleHeaders] && overrides.some(([key]) => key.toLowerCase() === String(name).toLowerCase())) return;
    const result = setRequestHeader.apply(this, arguments);
    if (this[requestMetadata]) this[requestMetadata].all.push([String(name), String(value)]);
    const key = displayedHeaderNames.find(key => key.toLowerCase() === String(name).toLowerCase());
    if (key && this[requestMetadata]) {
      const headers = this[requestMetadata].headers;
      headers[key] = headers[key] ? headers[key] + ', ' + value : String(value);
    }
    return result;
  };
  XMLHttpRequest.prototype.send = function() {
    if (this[useCompatibleHeaders]) {
      for (const [name, value] of overrides) {
        setRequestHeader.call(this, name, value);
        this[requestMetadata].headers[name] = value;
        this[requestMetadata].all.push([name, value]);
      }
    }
    const result = send.apply(this, arguments);
    const metadata = this[requestMetadata];
    if (metadata) requestDetails(metadata.url, metadata.method, 'XMLHttpRequest', name => metadata.headers[name], metadata.all);
    return result;
  };
  function scanMailbox() {
    if (!state.armed || state.code || readingUntil > performance.now()) return state.code;
    if (readingUntil) {
      // A failed or stalled message request must not permanently exclude its row.
      state.opened = state.opened.filter(id => id !== state.selected);
      readingUntil = 0;
    }
    const next = state.messages.find(m => !state.baseline.includes(m.id) && !state.opened.includes(m.id)
      && Number.isFinite(m.createdAt) && m.createdAt >= state.requestedAt
      && /验证码|邮箱验证|邮件验证|verification|verify|registration/i.test(m.subject)
      && /jiucai|韭菜|new.?api/i.test(m.subject + ' ' + m.from));
    if (!next) return '';
    const index = state.messages.findIndex(m => m.id === next.id);
    const row = [...document.querySelectorAll('main ul li')][index];
    if (row && row.textContent.includes(next.subject)) {
      state.selected = next.id; state.opened.push(next.id);
      readingUntil = performance.now() + 10000;
      row.click();
    }
    return state.code;
  }
  window.beautyBridge = {
    snapshot() {
      const regReady = registrationReadiness();
      const mailbox = mailboxReadiness();
      return {...state, regReady, mailReady: mailbox.ready, mailStatus: mailbox.message, url: location.href, documentID: beautyDocumentID, requestProfile};
    },
    fillRegistration({username, email, password}) {
      if (location.hostname !== registrationHost || location.pathname !== '/sign-up') throw new Error('不在指定注册页。');
      diagnosticSecrets = [password, email];
      field('input[name="username"]', username);
      field('input[name="password"]', password);
      field('input[name="confirmPassword"]', password);
      if (document.querySelector('input[name="email"]')) field('input[name="email"]', email);
      return {requiresEmail: !!document.querySelector('input[name="email"]')};
    },
    prepareMailbox({username}) {
      if (location.hostname !== mailboxHost) throw new Error('邮箱来源不匹配。');
      // Prepare the account without clicking Get Email before the code is sent.
      if (!mailboxReadiness().ready) return 'waiting';
      Object.assign(state, {mailbox: username, ready: false, messages: [], baseline: [], armed: false, selected: null, opened: [], code: '', problem: '', requestedAt: 0});
      nextMailboxPoll = null; readingUntil = 0; hasPolledMailbox = false;
      field('#username', username);
      return 'prepared';
    },
    armMailbox() {
      state.baseline = state.messages.map(m => m.id); state.armed = true; state.code = '';
      state.requestedAt = Math.floor(Date.now() / 1000);
      nextMailboxPoll = null; readingUntil = 0; hasPolledMailbox = false;
      return true;
    },
    beginMailboxPolling() {
      if (location.hostname !== mailboxHost) throw new Error('邮箱来源不匹配。');
      if (!state.armed || state.code) return false;
      state.problem = '';
      nextMailboxPoll = performance.now() + 2000;
      return true;
    },
    pollMailbox() {
      if (location.hostname !== mailboxHost) throw new Error('邮箱来源不匹配。');
      if (state.code) return 'complete';
      if (!state.armed || nextMailboxPoll === null) return 'waiting';
      if (state.problem) return 'blocked';
      const now = performance.now();
      if (hasPolledMailbox) scanMailbox();
      if (state.code) return 'complete';
      if (readingUntil > now) return 'reading';
      if (now < nextMailboxPoll) return 'waiting';
      if (!mailboxReadiness().ready) return 'waiting';
      if (document.querySelector('#username')?.value !== state.mailbox) {
        state.problem = '邮箱账号已变更，请恢复当前任务的邮箱账号后继续。';
        return 'blocked';
      }
      const result = activate(button(/^Get Email$/i));
      if (result === 'clicked') {
        hasPolledMailbox = true;
        nextMailboxPoll = performance.now() + 2000;
      }
      return result;
    },
    sendCode() { return activate(button(/^(发送验证码|发送验证邮件|发送代码|Send code)$/i)); },
    scanMailbox,
    fillCode({code}) {
      if (!/^[a-z0-9]{6}$/i.test(code)) throw new Error('验证码必须是 6 位字母或数字。');
      diagnosticSecrets.push(code);
      const el = [...document.querySelectorAll('input')].find(el => /验证码|Verification code/i.test(el.placeholder || ''));
      if (!el) throw new Error('未找到验证码输入框。');
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, code);
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
      return true;
    },
    submit() { return activate(document.querySelector('form button[type="submit"]')); }
  };

  // The form can be usable before images, fonts or other subresources finish.
  // Report readiness independently of the window load event, including SPA updates.
  let readinessObserver;
  let reportedReady = false;
  function reportPageReady() {
    if (reportedReady) return;
    const page = window.beautyBridge.snapshot();
    const ready = location.hostname === registrationHost ? page.regReady : page.mailReady;
    if (!ready) return;
    reportedReady = true;
    readinessObserver?.disconnect();
    emit({kind: 'pageReady'});
  }
  if (typeof MutationObserver !== 'undefined') {
    readinessObserver = new MutationObserver(reportPageReady);
    readinessObserver.observe(document, {childList: true, subtree: true, characterData: true, attributes: true,
      attributeFilter: ['class', 'style', 'hidden', 'disabled', 'aria-disabled']});
  }
  document.addEventListener?.('DOMContentLoaded', reportPageReady, {once: true});
  window.addEventListener?.('load', reportPageReady, {once: true});
  reportPageReady();
})();
