const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../Sources/BeautyRegistration/Resources/bridge.js'), 'utf8');

function fixture(host, {compatibility = false, overrides} = {}) {
  const events = [], clicked = [];
  const requests = [];
  let fetchResponse = {status: 200, body: {success: true}, retryAfter: null};
  let elapsed = 0;
  class FixtureDate extends Date { static now() { return 1800000000000 + elapsed; } }
  class Input {
    constructor() {this.offsetWidth = 100; this.textContent = ''; this._value = '';}
    get value() {return this._value;}
    set value(v) {this._value = v;}
    dispatchEvent() {}
  }
  class XHR {
    constructor() {this.listeners = []; this.status = 200; this.responseType = ''; this.headers = {};}
    open() {}
    setRequestHeader(name, value) { this.headers[name.toLowerCase()] = value; }
    getResponseHeader(name) { return name.toLowerCase() === 'retry-after' ? this.retryAfter : null; }
    send() {}
    addEventListener(type, fn) {this.listeners.push(fn);}
    removeEventListener(type, fn) {this.listeners=this.listeners.filter(item=>item!==fn);}
    respond(url, body, status = 200, method = 'GET', retryAfter = null) {
      this.retryAfter = retryAfter;
      this.open(method, url); this.status = status; this.responseText = typeof body === 'string' ? body : JSON.stringify(body);
      this.listeners.forEach(fn => fn());
    }
  }
  const fields = Object.fromEntries(['#username','input[name="username"]','input[name="password"]','input[name="confirmPassword"]','input[name="email"]'].map(k=>[k,new Input()]));
  const buttons = ['Get Email', '发送验证码', '创建账户'].map(text=>({textContent: text,offsetWidth: 100, disabled: false,getAttribute:()=>null,click:()=>clicked.push(text)}));
  let rows = [];
  const document = {
    querySelector(selector) {
      if(selector.includes('headlessui'))return {textContent:'fviainboxes.com'};
      if(selector === 'form button[type="submit"]')return buttons[2];
      return fields[selector] || null;
    },
    querySelectorAll(selector) {
      if(selector === 'button')return buttons;
      if(selector === 'main ul li')return rows;
      return [];
    }
  };
  const context = {
    window: {webkit: {messageHandlers: {beauty:{postMessage: e => events.push(e)}}},fetch: async(input,init)=>{requests.push({input,init});return {status:fetchResponse.status,headers:{get:name=>name.toLowerCase()==='retry-after'?fetchResponse.retryAfter:null,forEach:()=>{}},clone:()=>({text:async()=>JSON.stringify(fetchResponse.body)})};}},
    document,location:{hostname:host,origin:`https://${host}`,href:`https://${host}/sign-up`,pathname:'/sign-up'},
    URL,Headers,Date:FixtureDate,performance:{now:()=>elapsed},HTMLInputElement:Input,XMLHttpRequest:XHR,Event:class {},beautyDocumentID:'test-document',beautyCompatibilityHeaders:compatibility,
    navigator:{userAgent:'Fixture WebKit'},
    getComputedStyle:()=>({visibility:'visible',display:'block'}),
    DOMParser:class {parseFromString(html){return {body:{textContent:html.replace(/<[^>]*>/g,' ')},querySelectorAll:()=>[]};}}
  };
  if (overrides !== undefined) context.beautyHeaderOverrides = overrides;
  vm.createContext(context); vm.runInContext(source, context);
  // Expose a respond helper that runs inside the vm so bridge's XHR patches apply.
  const respondInVm = vm.runInContext(`(function(url, body, status, method, retryAfter) {
    var xhr = new XMLHttpRequest();
    xhr.open(method || 'GET', url);
    xhr.send();
    xhr.status = status || 200;
    xhr.retryAfter = retryAfter || null;
    xhr.responseText = typeof body === 'string' ? body : JSON.stringify(body);
    // getAllResponseHeaders stub for the response listener
    xhr.getAllResponseHeaders = function() { return ''; };
    xhr.listeners.forEach(function(fn) { fn(); });
  })`, context);
  return {bridge:context.window.beautyBridge,events,clicked,buttons,fields,advance:ms=>{elapsed+=ms;},
    fetch:context.window.fetch,requests,newXHR:()=>new XHR(),setFetchResponse:value=>{fetchResponse=value;},
    requestHeaders:(url,headers)=>{const xhr=new XHR();xhr.open('POST',url);for(const [k,v] of Object.entries(headers))xhr.setRequestHeader(k,v);xhr.send();return xhr.headers;},
    respond:(url,body,status,method,retryAfter)=>respondInVm(url,body,status,method,retryAfter),
    rows:values=>{rows=values.map(text=>({textContent:text,click:()=>clicked.push(text)}));},
    // Filtered views so tests are insulated from networkRecord events.
    get apiEvents() { return events.filter(e=>e.kind==='registration'||e.kind==='verification'); },
    get networkEvents() { return events.filter(e=>e.kind==='networkRecord'); }};
}

test('compatibility headers affect only registration API requests and preserve authentication and payload headers',async()=>{
  const f=fixture('api.jiucaihezi.studio',{compatibility:true});
  const original={'Accept':'application/json, text/plain, */*','Accept-Language':'zh-CN','Authorization':'fixture-token','Content-Type':'application/json'};
  const changed=f.requestHeaders('/api/user/register',original);
  assert.equal(changed.accept,'application/json');
  assert.equal(changed['accept-language'],'en-US,en;q=0.9');
  assert.equal(changed.authorization,'fixture-token');
  assert.equal(changed['content-type'],'application/json');
  assert.equal(f.requestHeaders('/api/user/login',original).accept,original.Accept);
  assert.equal(f.requestHeaders('https://other.invalid/api/user/register',original).accept,original.Accept);
  assert.equal(fixture('fviainboxes.com',{compatibility:true}).requestHeaders('/api/user/register',original).accept,original.Accept);
  assert.equal(fixture('api.jiucaihezi.studio').requestHeaders('/api/user/register',original).accept,original.Accept);
  await f.fetch('/api/verification?email=fixture@example.test',{headers:original});
  const headers=f.requests[0].init.headers;
  assert.equal(headers.get('Accept'),'application/json');
  assert.equal(headers.get('Accept-Language'),'en-US,en;q=0.9');
  assert.equal(headers.get('Authorization'),'fixture-token');
  assert.equal(f.bridge.snapshot().requestProfile,'Safari 兼容');
});

test('language and Accept choices work independently of user agent and automatic values preserve website headers',async()=>{
  const f=fixture('api.jiucaihezi.studio',{overrides:{'Accept-Language':'zh-CN,zh;q=0.9,en;q=0.8','Accept':'application/json, text/plain, */*'}});
  const original={'Accept':'text/plain','Accept-Language':'de','Authorization':'fixture-token','Content-Type':'application/json'};
  const actual=f.requestHeaders('/api/user/register',original);
  assert.equal(actual['accept-language'],'zh-CN,zh;q=0.9,en;q=0.8');
  assert.equal(actual.accept,'application/json, text/plain, */*');
  assert.equal(actual.authorization,'fixture-token');
  assert.equal(actual['content-type'],'application/json');
  await f.fetch(new URL('https://api.jiucaihezi.studio/api/verification?email=fixture@example.test'),{headers:original});
  assert.equal(f.requests[0].init.headers.get('Accept-Language'),actual['accept-language']);
  const automatic=fixture('api.jiucaihezi.studio',{compatibility:true,overrides:{}});
  assert.deepEqual(automatic.requestHeaders('/api/user/register',original),Object.fromEntries(Object.entries(original).map(([key,value])=>[key.toLowerCase(),value])));
  assert.equal(f.requestHeaders('/api/status',original).accept,'text/plain');
});

test('request observations whitelist headers, strip URL secrets and do not change actual request contents',async()=>{
  const f=fixture('api.jiucaihezi.studio');
  f.bridge.fillRegistration({username:'fixture',email:'fixture@example.test',password:'fixture-password'});
  const headers={'Accept':'application/json','Content-Type':'application/json','Cache-Control':'no-cache','X-Requested-With':'XMLHttpRequest',
    'Referer':'https://api.jiucaihezi.studio/sign-up?token=referer-secret#fragment',
    'Authorization':'Bearer private-token','Cookie':'session=private-cookie','X-API-Key':'private-key'};
  const body='fixture-password body-must-not-be-recorded';
  await f.fetch('/api/user/register?email=fixture@example.test&token=query-secret',{method:'POST',headers,body});
  await new Promise(resolve=>setImmediate(resolve));
  const event=f.events.find(e=>e.kind==='requestHeaders');
  assert.equal(event.path,'/api/user/register');
  assert.equal(event.method,'POST');
  assert.equal(event.transport,'fetch');
  const shown=Object.fromEntries(event.headers.map(h=>[h.name,h.value]));
  assert.equal(shown['Content-Type'],'application/json');
  assert.equal(shown['Cache-Control'],'no-cache');
  assert.equal(shown.Referer,'https://api.jiucaihezi.studio/sign-up');
  for (const secret of ['fixture-password','fixture@example.test','private-token','private-cookie','private-key','referer-secret','query-secret','body-must-not-be-recorded']) {
    assert.ok(!JSON.stringify(event).includes(secret));
  }
  assert.equal(f.requests[0].init.body,body);
  assert.equal(f.requests[0].init.headers.Authorization,headers.Authorization);
  const before=f.events.filter(e=>e.kind==='requestHeaders').length;
  await f.fetch('https://other.invalid/api/user/register',{headers});
  await f.fetch('/api/private/token-secret',{headers});
  assert.equal(f.events.filter(e=>e.kind==='requestHeaders').length,before);
});

test('XHR observations reflect combined safe headers and clear state on reuse',()=>{
  const f=fixture('api.jiucaihezi.studio',{compatibility:true});
  const xhr=f.newXHR();
  xhr.open('POST','/api/user/register?token=private-query');
  xhr.setRequestHeader('Accept','website-value');
  xhr.setRequestHeader('Content-Type','application/json');
  xhr.setRequestHeader('Cache-Control','no-cache');
  xhr.setRequestHeader('cache-control','no-store');
  xhr.setRequestHeader('Authorization','private-token');
  xhr.send('private-body');
  const event=f.events.find(e=>e.kind==='requestHeaders');
  const shown=Object.fromEntries(event.headers.map(h=>[h.name,h]));
  assert.equal(shown.Accept.value,'application/json');
  assert.equal(shown.Accept.source,'客户端配置');
  assert.equal(shown['Cache-Control'].value,'no-cache, no-store');
  assert.equal(shown['Content-Type'].source,'网页设置');
  assert.ok(!JSON.stringify(event).includes('private'));
  xhr.open('GET','/api/status'); xhr.send();
  const next=f.events.at(-1);
  assert.equal(next.path,'/api/status');
  assert.equal(next.headers.length,1); // Only the browser identifier; no stale request headers.
});

test('only registration POST success with an explicit business success is accepted',()=>{
  const f=fixture('api.jiucaihezi.studio');
  f.respond('/api/user/register',{success:true},200,'POST');
  assert.equal(f.apiEvents[0].success,true);
  assert.equal(f.apiEvents[0].documentID,'test-document');
  f.respond('/api/user/register',{success:false,password:'never forward'},200,'POST');
  assert.equal(f.apiEvents[1].success,false);
  assert.ok(!JSON.stringify(f.apiEvents).includes('never forward'));
  f.respond('/api/user/register','<html>502</html>',502,'POST');
  assert.equal(f.apiEvents[2].success,false);
  f.respond('/api/user/register',{success:true},200,'GET');
  f.respond('https://other.invalid/api/user/register',{success:true},200,'POST');
  assert.equal(f.apiEvents.length,3);
});
test('rate limiting is reported without retrying or clicking',()=>{
  const f=fixture('api.jiucaihezi.studio');
  f.respond('/api/verification',{success:false},429);
  assert.equal(f.apiEvents[0].success,false);
  assert.match(f.bridge.snapshot().problem,/限流/);
  assert.equal(f.clicked.length,0);
});
test('Retry-After is forwarded as seconds from both XHR and fetch, only for 429',async()=>{
  const f=fixture('api.jiucaihezi.studio');
  f.respond('/api/verification',{success:false},429,'GET','120');
  assert.equal(f.events.at(-1).retryAfterSeconds,120);
  f.respond('/api/verification',{success:false},429,'GET',new Date(1800000045000).toUTCString());
  assert.equal(f.events.at(-1).retryAfterSeconds,45);
  for(const invalid of [null,'','-1','1.5','not-a-date']) {
    f.respond('/api/verification',{success:false},429,'GET',invalid);
    assert.equal(f.events.at(-1).retryAfterSeconds,undefined);
  }
  f.respond('/api/verification',{success:true},200,'GET','120');
  assert.equal(f.events.at(-1).retryAfterSeconds,undefined);
  f.setFetchResponse({status:429,body:{success:false,message:'请等待 1 秒后再试'},retryAfter:'30'});
  await f.fetch('/api/verification');
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(f.events.at(-1).retryAfterSeconds,30);
  assert.equal(f.clicked.length,0,'Only the native task controls retry timing');
});
test('failure diagnostics retain the server explanation but redact credentials and discard other response data',()=>{
  const f=fixture('api.jiucaihezi.studio');
  f.bridge.fillRegistration({username:'fixture210',email:'fixture210@example.test',password:'fixture-only-password'});
  // The parser records the supplied code before looking up the fixture's absent input.
  assert.throws(()=>f.bridge.fillCode({code:'a7F91c'}),/未找到/);
  f.respond('/api/user/register',{success:false,message:'验证码错误或已过期',debug:{password:'unrelated-response-secret'}},200,'POST');
  assert.equal(f.apiEvents[0].message,'验证码错误或已过期');
  assert.equal(f.apiEvents[0].status,200);
  f.respond('/api/user/register',{success:false,message:'密码 fixture-only-password，验证码 a7F91c，邮箱 fixture210@example.test'},200,'POST');
  assert.ok(f.apiEvents[1].message.includes('[已隐藏]'));
  const output=JSON.stringify(f.apiEvents);
  for(const secret of ['fixture-only-password','a7F91c','fixture210@example.test','unrelated-response-secret']) assert.ok(!output.includes(secret));
  f.respond('/api/user/register',{success:false,error:{message:'同一 IP 注册次数已达上限'}},403,'POST');
  assert.equal(f.apiEvents[2].message,'同一 IP 注册次数已达上限');
  f.respond('/api/user/register','<html>Internal error with sensitive content</html>',502,'POST');
  assert.equal(f.apiEvents[3].message,'');
});
test('mailbox identity, baseline and subject filtering exclude stale or unrelated OTPs',()=>{
  const f=fixture('fviainboxes.com');
  f.bridge.prepareMailbox({username:'sample176'});
  const route='/messages?username=sample176&domain=fviainboxes.com';
  const old={id:'old',subject:'韭菜盒子 注册验证码',from:'noreply@jiucaihezi.studio'};
  f.respond(route,{result:[old]});
  assert.equal(f.bridge.snapshot().ready,true);
  f.bridge.armMailbox();
  f.rows([old.subject]); f.bridge.scanMailbox();
  assert.equal(f.clicked.length,0);
  f.respond('/message?username=sample176&domain=fviainboxes.com&id=old','验证码 111111');
  assert.equal(f.bridge.snapshot().code,'');
  f.respond('/messages?username=another&domain=fviainboxes.com',{result:[]});
  assert.equal(f.bridge.snapshot().messages.length,1);
  const fresh={...old,id:'fresh',createdAt:f.bridge.snapshot().requestedAt};
  f.respond(route,{result:[fresh,old]}); f.rows([fresh.subject,old.subject]); f.bridge.scanMailbox();
  f.respond('/message?username=another&domain=fviainboxes.com&id=fresh','验证码 222222');
  assert.equal(f.bridge.snapshot().code,'');
  f.respond('/message?username=sample176&domain=fviainboxes.com&id=fresh','<p>您的验证码是：<b>384721</b></p>');
  assert.equal(f.bridge.snapshot().code,'384721');
});
test('disabled controls and unknown hosts cannot trigger submissions',()=>{
  const f=fixture('api.jiucaihezi.studio'); f.buttons[2].disabled=true;
  assert.equal(f.bridge.submit(),'disabled'); assert.equal(f.clicked.length,0);
  assert.equal(fixture('untrusted.invalid').bridge,undefined);
});
test('the live Chinese email-verification subject is recognized',()=>{
  const f=fixture('fviainboxes.com');
  f.bridge.prepareMailbox({username:'sample200'});
  const route='/messages?username=sample200&domain=fviainboxes.com';
  f.respond(route,{result:[]}); f.bridge.armMailbox();
  const message={id:'live-title',subject:'韭菜盒子邮箱验证邮件',from:'jiucaihezi',createdAt:f.bridge.snapshot().requestedAt};
  f.respond(route,{result:[message]}); f.rows([message.subject]); f.bridge.scanMailbox();
  assert.ok(f.clicked.includes(message.subject));
  f.respond('/message?username=sample200&domain=fviainboxes.com&id=live-title','您的验证码为：<b>284619</b>');
  assert.equal(f.bridge.snapshot().code,'284619');
});
test('manual OTP validation prevents malformed form input',()=>{
  const f=fixture('api.jiucaihezi.studio');
  assert.throws(()=>f.bridge.fillCode({code:'12345'}),/6 位/);
});
test('registration email codes can contain letters and retain their case',()=>{
  for (const [html, expected] of [
    ['您的验证码为: <b>a7F91c</b>。验证码 10 分钟内有效。', 'a7F91c'],
    ['Your verification code is: <b>B4d902</b>', 'B4d902'],
    ['验证码：<strong>1234567</strong>', ''],
    ['验证码：<strong>abcdef0</strong>', '']
  ]) {
    const f=fixture('fviainboxes.com'); f.bridge.prepareMailbox({username:'sample201'});
    f.respond('/messages?username=sample201&domain=fviainboxes.com',{result:[]}); f.bridge.armMailbox();
    const message={id:'mixed',subject:'韭菜盒子邮箱验证邮件',from:'jiucaihezi',createdAt:f.bridge.snapshot().requestedAt};
    f.respond('/messages?username=sample201&domain=fviainboxes.com',{result:[message]});
    f.rows([message.subject]); f.bridge.scanMailbox();
    f.respond('/message?username=sample201&domain=fviainboxes.com&id=mixed',html);
    assert.equal(f.bridge.snapshot().code,expected);
  }
});

test('Get Email waits two seconds after send confirmation and repeats on empty inboxes until the code arrives',()=>{
  const f=fixture('fviainboxes.com');
  assert.equal(f.bridge.prepareMailbox({username:'sample204'}),'prepared');
  f.bridge.armMailbox();
  f.advance(9000);
  assert.equal(f.bridge.pollMailbox(),'waiting');
  assert.deepEqual(f.clicked,[],'Preparation and arming must not click Get Email');
  f.bridge.beginMailboxPolling();
  f.advance(1999);
  assert.equal(f.bridge.pollMailbox(),'waiting');
  f.advance(1);
  assert.equal(f.bridge.pollMailbox(),'clicked');
  const route='/messages?username=sample204&domain=fviainboxes.com';
  for (let i=0;i<2;i++) {
    f.respond(route,{result:[]});
    f.advance(1999);
    assert.equal(f.bridge.pollMailbox(),'waiting');
    f.advance(1);
    assert.equal(f.bridge.pollMailbox(),'clicked');
  }
  assert.equal(f.clicked.filter(x=>x==='Get Email').length,3);
  const message={id:'received',subject:'韭菜盒子邮箱验证邮件',from:'jiucaihezi',createdAt:f.bridge.snapshot().requestedAt+15};
  f.respond(route,{result:[message]}); f.rows([message.subject]);
  assert.equal(f.bridge.pollMailbox(),'reading');
  f.advance(2000);
  assert.equal(f.bridge.pollMailbox(),'reading','Do not reset the mailbox while its message body is loading');
  f.respond('/message?username=sample204&domain=fviainboxes.com&id=received','您的验证码为：<b>a7F91c</b>');
  f.advance(100000);
  assert.equal(f.bridge.pollMailbox(),'complete');
  assert.equal(f.bridge.snapshot().code,'a7F91c');
  assert.equal(f.bridge.snapshot().armed,true);
  assert.equal(f.clicked.filter(x=>x==='Get Email').length,3,'No clicks after receiving a code');
});

test('post-send polling rejects old mail even when no inbox baseline was fetched',()=>{
  const f=fixture('fviainboxes.com'); f.bridge.prepareMailbox({username:'sample204'}); f.bridge.armMailbox();
  f.bridge.beginMailboxPolling(); f.advance(2000); f.bridge.pollMailbox();
  const subject='韭菜盒子邮箱验证邮件', from='jiucaihezi';
  f.respond('/messages?username=sample204&domain=fviainboxes.com',{result:[
    {id:'old',subject,from,createdAt:f.bridge.snapshot().requestedAt-10},
    {id:'unknown-date',subject,from}
  ]});
  f.rows([subject,subject]); f.bridge.pollMailbox();
  assert.deepEqual(f.clicked,['Get Email']);
  assert.equal(f.bridge.snapshot().selected,null);
});

test('polling respects disabled controls, account changes and rate limits; it has no background clicks',()=>{
  const f=fixture('fviainboxes.com'); f.bridge.prepareMailbox({username:'sample204'}); f.bridge.armMailbox();
  f.bridge.beginMailboxPolling(); f.advance(2000);
  f.buttons[0].disabled=true;
  assert.equal(f.bridge.pollMailbox(),'waiting');
  f.buttons[0].disabled=false;
  f.fields['#username'].value='another';
  assert.equal(f.bridge.pollMailbox(),'blocked');
  assert.deepEqual(f.clicked,[]);
  f.fields['#username'].value='sample204'; f.bridge.beginMailboxPolling(); f.advance(2000);
  assert.equal(f.bridge.pollMailbox(),'clicked');
  f.respond('/messages?username=sample204&domain=fviainboxes.com',{},429);
  f.advance(20000);
  assert.equal(f.bridge.pollMailbox(),'blocked');
  assert.deepEqual(f.clicked,['Get Email']);
  f.bridge.beginMailboxPolling();
  f.advance(30000); // No native polling call while paused/stopped: no browser timer clicks.
  assert.deepEqual(f.clicked,['Get Email']);
});

test('a failed message request can be retried instead of losing the selected email',()=>{
  const f=fixture('fviainboxes.com'); f.bridge.prepareMailbox({username:'sample204'}); f.bridge.armMailbox();
  f.bridge.beginMailboxPolling(); f.advance(2000); f.bridge.pollMailbox();
  const message={id:'retry',subject:'韭菜盒子邮箱验证邮件',from:'jiucaihezi',createdAt:f.bridge.snapshot().requestedAt};
  f.respond('/messages?username=sample204&domain=fviainboxes.com',{result:[message]});f.rows([message.subject]);
  f.bridge.pollMailbox();
  f.respond('/message?username=sample204&domain=fviainboxes.com&id=retry','temporary failure',500);
  f.bridge.pollMailbox();
  assert.equal(f.clicked.filter(x=>x===message.subject).length,2);
  f.respond('/message?username=sample204&domain=fviainboxes.com&id=retry','验证码：B4d902');
  assert.equal(f.bridge.pollMailbox(),'complete');
});
