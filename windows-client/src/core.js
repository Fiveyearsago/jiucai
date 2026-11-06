'use strict';
const crypto = require('node:crypto');

function parseProxy(line) {
  line = line.trim().replace(/^\uFEFF/, '');
  if (!line) return null;
  try {
    if (/^socks5:\/\//i.test(line)) {
      const u = new URL(line);
      if (!u.hostname || !u.port || u.search || u.hash || !['', '/'].includes(u.pathname)) return null;
      const port = Number(u.port);
      if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
      return { id: crypto.randomUUID(), host: u.hostname.replace(/^\[|\]$/g, ''), port, user: decodeURIComponent(u.username), password: decodeURIComponent(u.password), enabled: true };
    }
    const p = line.split(':');
    const host = p[0]?.trim(), port = Number(p[1]);
    if (p.length < 2 || !/^[A-Za-z0-9._-]+$/.test(host) || !Number.isInteger(port) || port < 1 || port > 65535) return null;
    return { id: crypto.randomUUID(), host, port, user: (p[2] || '').trim(), password: p.slice(3).join(':').trim(), enabled: true };
  } catch { return null; }
}
function proxyUrl(p) {
  const auth = p.user ? `${encodeURIComponent(p.user)}:${encodeURIComponent(p.password)}@` : '';
  const host = p.host.includes(':') ? `[${p.host}]` : p.host;
  return `socks5h://${auth}${host}:${p.port}`;
}
function retryAfter(headers, message = '', now = Date.now()) {
  const value = headers?.['retry-after'];
  if (value != null && /^\d+$/.test(String(value).trim())) return Math.max(1, Number(value));
  if (value) { const date = Date.parse(value); if (Number.isFinite(date)) return Math.max(1, Math.ceil((date - now) / 1000)); }
  const m = String(message).match(/(?:等待|wait(?:\s+for)?)\s*(\d+)\s*(?:秒|seconds?|s\b)/i);
  return m ? Math.max(1, Number(m[1])) : 60;
}
function candidates(rows, baseline, requestedAt) {
  return rows.filter(m => {
    if (m.id == null || baseline.has(String(m.id)) || typeof m.subject !== 'string' || typeof m.from !== 'string') return false;
    let t = typeof m.createdAt === 'number' ? m.createdAt : (/^\d+(?:\.\d+)?$/.test(m.createdAt || '') ? Number(m.createdAt) : Date.parse(m.createdAt) / 1000);
    if (Math.abs(t) >= 1e11) t /= 1000;
    return Number.isFinite(t) && t >= Math.floor(requestedAt / 1000) && /验证码|邮箱验证|邮件验证|verification|verify|registration/i.test(m.subject) && /jiucai|韭菜|new.?api/i.test(m.subject + ' ' + m.from);
  }).sort((a,b) => String(b.createdAt).localeCompare(String(a.createdAt)));
}
function codeFromHTML(html) {
  let text = String(html).replace(/<!--[\s\S]*?(?:-->|$)/g, '').replace(/<(script|style)\b[^>]*>[\s\S]*?(?:<\/\1\s*>|$)/gi, '').replace(/<\/?(?:br|p|div|li|tr|td|th|table|section|h[1-6])\b[^>]*>/gi, ' ').replace(/<[^>]*>/g, '');
  text = text.replace(/&#(?:x([\da-f]+)|(\d+));/gi, (_, h, d) => { try { return String.fromCodePoint(parseInt(h || d, h ? 16 : 10)); } catch { return ''; } }).replace(/&(?:nbsp|ensp|emsp|thinsp);/gi, ' ').replace(/&colon;/gi, ':').replace(/&amp;/gi, '&');
  return text.match(/(?:验证码|verification\s+code|security\s+code|code\s+is)(?:\s*(?:是|为|is))?\s*[:：]?\s*(?<![A-Za-z0-9])([A-Za-z0-9]{6})(?![A-Za-z0-9])/i)?.[1] || null;
}
function username(config, index) { return config.prefix + String(index).padStart(config.digits, '0'); }
function validate(config, password) {
  if (!/^[A-Za-z0-9_-]{1,16}$/.test(config.prefix)) throw Error('用户名前缀需为 1–16 位字母、数字、下划线或短横线。');
  for (const key of ['startIndex','count','digits','intervalSeconds']) if (!Number.isSafeInteger(config[key])) throw Error('编号、数量和间隔必须是整数。');
  if (config.startIndex < 1 || config.count < 1 || !Number.isSafeInteger(config.startIndex + config.count - 1) || config.digits < 1 || config.digits > 6 || username(config, config.startIndex + config.count - 1).length > 20) throw Error('账号编号范围或用户名长度无效。');
  if (config.intervalSeconds < 3 || config.intervalSeconds > 3600) throw Error('账号间隔需为 3–3600 秒。');
  if (password.length < 8 || password.length > 128) throw Error('密码长度需为 8–128 位。');
  if (String(config.invitation).length > 64) throw Error('邀请码过长。');
}
module.exports = { parseProxy, proxyUrl, retryAfter, candidates, codeFromHTML, username, validate };
