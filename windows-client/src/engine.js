'use strict';
const https = require('node:https');
const { SocksProxyAgent } = require('socks-proxy-agent');
const { parseProxy, proxyUrl, retryAfter, candidates, codeFromHTML, username, validate } = require('./core');

class Engine {
  constructor(store, emit) { this.store=store; this.emit=emit; this.running=false; this.paused=false; this.stopped=false; this.manualCode=''; this.manualSubmit=false; this.cooldownUntil=Number(store.data.cooldownUntil)||0; this.network=[]; this.current=null; this.phase='准备开始'; this.completed=0; this.total=0; }
  notify() { this.emit(this.snapshot()); }
  snapshot() { return { state:this.store.data, running:this.running, paused:this.paused, phase:this.phase, current:this.current, completed:this.completed, total:this.total, network:this.network, cooldownUntil:this.cooldownUntil, waitingCode:this.waitingCode, verificationSent:this.verificationSent, verificationCode:this.manualCode }; }
  setPhase(text) { this.phase=text; this.notify(); }
  async sleep(ms) { const end=Date.now()+ms; while(Date.now()<end) { if(this.stopped) throw Error('任务已停止'); await new Promise(r=>setTimeout(r,Math.min(250,end-Date.now()))); } }
  async gate() { if(this.stopped) throw Error('任务已停止'); while(this.paused) await this.sleep(250); }
  async waitRateLimit() { while(Date.now()<this.cooldownUntil) { await this.gate(); this.setPhase(`服务限流，等待 ${Math.ceil((this.cooldownUntil-Date.now())/1000)} 秒`); await this.sleep(Math.min(1000,this.cooldownUntil-Date.now())); } }
  async http(origin, path, {query, method='GET', body, proxy, headers={}, timeout=10000, beforeRequest}={}) {
    await this.gate(); await this.waitRateLimit(); await this.gate();
    const url=new URL(path,origin); if(query) for(const [k,v] of Object.entries(query)) url.searchParams.set(k,v);
    const safeHeaders={Accept:'application/json',...headers};
    if(body!==undefined) safeHeaders['Content-Type']='application/json';
    const agent=proxy ? new SocksProxyAgent(proxyUrl(proxy), { timeout }) : undefined;
    const started=Date.now(); if(beforeRequest) beforeRequest(started); let result;
    try {
      result=await new Promise((resolve,reject)=> {
        const req=https.request(url,{method,headers:safeHeaders,agent,timeout},res=>{
          const chunks=[]; let size=0;
          res.on('data',chunk=>{size+=chunk.length; if(size>5*1024*1024) req.destroy(Error('响应过大')); else chunks.push(chunk)});
          res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,text:Buffer.concat(chunks).toString('utf8')}));
        }); req.on('timeout',()=>req.destroy(Error('请求超时'))); req.on('error',reject);
        if(body!==undefined) req.write(JSON.stringify(body)); req.end();
      });
      let json; try { json=JSON.parse(result.text); } catch {}
      const message=typeof json?.message==='string'?json.message:(typeof json?.error==='string'?json.error:'');
      let clean=message.replace(/[\w.+-]+@[\w.-]+\.[a-z]{2,}/ig,'[邮箱已隐藏]').replace(/(?:password|token|secret|密码)\s*[:=：]\s*\S+/ig,'[凭据已隐藏]'); for(const secret of [this.store.data.password,this.manualCode,proxy?.password,...Object.values(query||{}),...Object.values(body||{})]) if(typeof secret==='string'&&secret.length>=4) clean=clean.split(secret).join('[已隐藏]'); clean=clean.slice(0,300);
      this.network.unshift({method,path,status:result.status,time:new Date().toISOString(),duration:Date.now()-started,message:clean}); this.network=this.network.slice(0,500); this.notify();
      if(result.status===429) {
        const seconds=retryAfter(result.headers,clean); this.cooldownUntil=Math.max(this.cooldownUntil,Date.now()+seconds*1000); this.store.data.cooldownUntil=this.cooldownUntil; this.store.save();
        const e=Error(`HTTP 429：${clean || '请求过于频繁'}，等待 ${seconds} 秒。`); e.status=429; throw e;
      }
      if(result.headers['cf-mitigated']==='challenge') throw Error('服务要求人机验证，请在官网完成。');
      return {...result,json, message:clean};
    } catch(e) { if(!e.status) { this.network.unshift({method,path,status:0,time:new Date().toISOString(),duration:Date.now()-started,message:'连接失败'}); this.notify(); } throw e; } finally { agent?.destroy(); }
  }
  async request(origin,path,options) { while(true) { try { return await this.http(origin,path,options); } catch(e) { if(e.status!==429) throw e; await this.waitRateLimit(); } } }
  headers() { let h={}; const cfg=this.store.data.headers; if(cfg.userAgent) h['User-Agent']=cfg.userAgent; if(cfg.accept) h.Accept=cfg.accept; if(cfg.language) h['Accept-Language']=cfg.language; for (const [k,v] of Object.entries(cfg.custom||{})) { if(!/^[!#$%&'*+.^_`|~\w-]+$/.test(k)||/[\r\n]/.test(String(v))||/^(host|content-length|connection|transfer-encoding|proxy-authorization)$/i.test(k)) throw Error('自定义请求头无效'); h[k]=String(v); } return h; }
  async api(path, proxy, opts={}) { return this.request('https://api.jiucaihezi.studio',path,{proxy,headers:this.headers(),timeout:this.store.data.proxy.timeout*1000,...opts}); }
  async mailbox(path, proxy, query) { return this.request('https://fviainboxes.com',path,{proxy,query,timeout:this.store.data.proxy.timeout*1000}); }
  ensure(reply, op, success=true) { if (reply.status<200 || reply.status>=300 || (success && reply.json?.success!==true)) { const e=Error(`${op}失败（HTTP ${reply.status}）：${reply.message||'服务未确认成功'}`); e.status=reply.status; e.explicit=reply.status>=400&&reply.status<500&&reply.status!==408 || reply.json?.success===false; throw e; } }
  async status(proxy) { const r=await this.api('/api/status',proxy); this.ensure(r,'连接注册接口'); const s=r.json?.data; if(typeof s?.email_verification!=='boolean') throw Error('站点状态响应无法识别'); if(s.turnstile_check) throw Error('网站要求人机验证，请前往官网完成。'); if(s.register_enabled===false||s.password_register_enabled===false) throw Error('网站当前未开放密码注册'); return s; }
  record(r, status, note) { Object.assign(r,{status,note,updatedAt:new Date().toISOString()}); this.store.save(); this.notify(); }
  async begin({single=false,username:singleUser,email:singleEmail,auto=true,consent=false}={}) {
    if(this.running) throw Error('已有任务正在运行'); const {config, password, proxy:pc, records}=this.store.data;
    validate(config,password); if(!consent && auto) throw Error('请先阅读并同意邮箱服务条款');
    if(single && (!/^[A-Za-z0-9_-]{1,20}$/.test(singleUser)||!/^\S+@\S+\.\S+$/.test(singleEmail))) throw Error('用户名或邮箱格式无效');
    if(pc.enabled && !pc.entries.some(p=>p.enabled)) throw Error('代理池为空，请添加代理或关闭代理。');
    this.running=true; this.stopped=false; this.paused=false; this.completed=0; let succeededInRun=0; this.total=single?1:config.count; this.notify();
    try {
      for(let i=0;i<this.total;i++) {
        await this.gate(); const user=single?singleUser:username(config,config.startIndex+i); const email=single?singleEmail:user+'@fviainboxes.com';
        if(records.some(r=>r.username===user&&['succeeded','submitting','uncertain'].includes(r.status))) { this.completed++; this.setPhase(`${user} 已成功或待核对，跳过`); continue; }
        const pool=pc.entries.filter(p=>p.enabled); if(pc.enabled&&!pool.length) throw Error('代理池为空');
        const proxy=pc.enabled?pool[Math.floor(succeededInRun / Math.max(1,pc.switchEvery))%pool.length]:null;
        const r={id:require('node:crypto').randomUUID(),username:user,email,status:'running',note:'开始注册',updatedAt:new Date().toISOString()}; records.unshift(r); this.current=user; this.manualCode=''; this.manualSubmit=false; this.verificationSent=false; this.waitingCode=false; this.store.save(); this.notify();
        try { await this.register(r,proxy,{single,auto}); }
        catch(e) { if(r.status==='submitting') this.record(r,'uncertain','提交结果未知，请先在官网核对。'); else this.record(r,this.stopped?'cancelled':'failed',String(e.message).slice(0,300)); if(this.stopped) throw e; }
        if(r.status==='succeeded') succeededInRun++; this.completed++; this.notify(); if(i+1<this.total) {this.setPhase('等待账号间隔'); await this.sleep(config.intervalSeconds*1000);}
      }
      this.setPhase('任务完成');
    } catch(e) { this.setPhase(this.stopped?'任务已停止':e.message); } finally {this.running=false; this.paused=false; this.current=null; this.waitingCode=false; this.notify();}
  }
  async register(r,proxy,{single,auto}) {
    this.setPhase('连接注册服务'); const status=await this.status(proxy); let baseline=new Set(), requestAt=Date.now(); const [name,domain]=r.email.split('@'); const useMail=status.email_verification&&auto&&domain?.toLowerCase()==='fviainboxes.com';
    if(useMail) { this.setPhase('准备邮箱'); let m=await this.mailbox('/captcha/status',proxy); if(m.status!==200||typeof m.json?.turnstile_enabled!=='boolean'||m.json.turnstile_enabled) throw Error('邮箱服务不可用或要求人机验证'); m=await this.mailbox('/messages',proxy,{username:name,domain}); if(!Array.isArray(m.json?.result)) throw Error('邮箱列表无法识别'); baseline=new Set(m.json.result.map(x=>String(x.id))); }
    if(!status.email_verification) this.verificationSent=true;
    if(status.email_verification) { this.setPhase('请求验证码'); requestAt=Date.now(); const send=await this.api('/api/verification',proxy,{query:{email:r.email},beforeRequest:t=>{requestAt=t;}}); this.ensure(send,'发送验证码'); this.verificationSent=true; this.notify(); }
    this.waitingCode=!!status.email_verification; this.setPhase(status.email_verification?'等待验证码':'等待提交注册'); let nextPoll=Date.now()+2000;
    while((status.email_verification&&!/^[A-Za-z0-9]{6}$/.test(this.manualCode))||(single&&!this.manualSubmit)) {
      await this.gate(); if(useMail&&!/^[A-Za-z0-9]{6}$/.test(this.manualCode)&&Date.now()>=nextPoll) {
        const list=await this.mailbox('/messages',proxy,{username:name,domain}); if(!Array.isArray(list.json?.result)) throw Error('邮箱列表无法识别');
        for(const m of candidates(list.json.result,baseline,requestAt)) { const detail=await this.mailbox('/message',proxy,{username:name,domain,id:String(m.id)}); if(detail.status!==200) throw Error('读取验证邮件失败'); const html=typeof detail.json==='string'?detail.json:detail.text; const code=codeFromHTML(html); if(code&&!this.manualCode) {this.manualCode=code; this.setPhase(single?'已读取验证码，请点击注册用户':'已读取验证码'); break;} }
        nextPoll=Date.now()+2000;
      } await this.sleep(200);
    }
    await this.gate(); this.waitingCode=false; this.setPhase('提交注册'); this.record(r,'submitting','准备提交，等待服务器回执。');
    let reply; try { reply=await this.api('/api/user/register',proxy,{method:'POST',body:{username:r.username,email:r.email,password:this.store.data.password,verification_code:status.email_verification?this.manualCode:'',aff_code:this.store.data.config.invitation}}); } catch(e) { throw e; }
    if(reply.status>=200&&reply.status<300&&reply.json?.success===true) this.record(r,'succeeded','注册接口已明确返回成功。');
    else if(reply.json?.success===false || (reply.status>=400&&reply.status<500&&reply.status!==408)) this.record(r,'failed',`网站拒绝注册（HTTP ${reply.status}）：${reply.message||'未提供原因'}`);
    else this.record(r,'uncertain','提交结果未知，请先在官网核对。');
  }
}
module.exports = {Engine};
