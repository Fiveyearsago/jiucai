const test = require('node:test');
const assert = require('node:assert/strict');
const c = require('../src/core');
test('SOCKS5 credentials and validation', () => { let p = c.parseProxy('example.com:1080:user:pass:more'); assert.equal(p.password, 'pass:more'); assert.equal(c.proxyUrl(p), 'socks5h://user:pass%3Amore@example.com:1080'); assert.equal(c.parseProxy('host:65536'), null); });
test('429 wait uses server header and message', () => { assert.equal(c.retryAfter({'retry-after':'17'}, '等待 1 秒'),17); assert.equal(c.retryAfter({}, '发送过于频繁，请等待 3 秒后再试'),3); assert.equal(c.retryAfter({}, ''),60); });
test('only fresh related messages, parses split code', () => { const now = Date.now(); const rows = [{id:1, subject:'韭菜盒子邮箱验证码',from:'jiucai',createdAt:now/1000}, {id:2,subject:'验证码',from:'unknown',createdAt:now/1000}]; assert.equal(c.candidates(rows,new Set(),now).length,1); assert.equal(c.candidates(rows,new Set(['1']),now).length,0); assert.equal(c.codeFromHTML('验证码为: <b>a1</b>b2c3'), 'a1b2c3'); });
