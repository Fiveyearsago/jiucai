'use strict';
const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { parseProxy } = require('./core');
const { Engine } = require('./engine');
let win, engine, testingProxies=false, refreshing=null, cancelRefresh=false, nextRefresh=0;
const defaults = {config:{prefix:'xiaorange',startIndex:176,count:1,digits:3,invitation:'WAI1',intervalSeconds:60}, password:'', proxy:{enabled:false,switchEvery:1,timeout:10,entries:[],autoSource:false,sourceMinutes:60,testLimit:3000,sources:['https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/socks5.txt','https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks5.txt','https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt']},headers:{userAgent:'',accept:'application/json',language:'',custom:{}},records:[]};
class Store {
  constructor() {
    this.file=path.join(app.getPath('userData'),'records.json'); this.data=structuredClone(defaults);
    if(fs.existsSync(this.file)) { let raw=JSON.parse(fs.readFileSync(this.file,'utf8')); this.data={...this.data,...raw,config:{...this.data.config,...raw.config},proxy:{...this.data.proxy,...raw.proxy},headers:{...this.data.headers,...raw.headers}}; }
    for(const r of this.data.records) if(r.status==='submitting') { r.status='uncertain'; r.note='应用关闭时提交结果未知，请先在官网核对。'; }
    this.save();
  }
  save() { const dir=path.dirname(this.file); fs.mkdirSync(dir,{recursive:true,mode:0o700}); const tmp=this.file+'.tmp'; fs.writeFileSync(tmp,JSON.stringify(this.data,null,2),{mode:0o600}); fs.renameSync(tmp,this.file); }
}
function ensureSender(e) { if(!win||e.sender!==win.webContents||e.senderFrame.url!==pathToFileURL(path.join(__dirname,'index.html')).href) throw Error('非法调用'); }
function create() {
  const store=new Store();
  win=new BrowserWindow({width:1360,height:900,minWidth:1000,minHeight:720,title:'Beauty 注册助手',webPreferences:{preload:path.join(__dirname,'preload.js'),contextIsolation:true,nodeIntegration:false,sandbox:true}});
  engine=new Engine(store, state=>{ if(!win.isDestroyed()) win.webContents.send('state',state); });
  win.webContents.setWindowOpenHandler(()=>({action:'deny'}));
  win.webContents.on('will-navigate',(e)=>e.preventDefault()); win.loadFile(path.join(__dirname,'index.html'));
  win.on('close',()=>{engine.stopped=true;cancelRefresh=true;});
  setInterval(()=>{if(!win || win.isDestroyed() || engine.running || testingProxies || refreshing) return; const p=engine.store.data.proxy; if(p.autoSource && Date.now()>=nextRefresh) startRefresh();},15000).unref();
}

async function startRefresh() {
  if(refreshing || testingProxies || engine.running) return;
  cancelRefresh=false; engine.stopped=false;
  const work=async()=>{
    const p=engine.store.data.proxy, candidates=[], known=new Set(p.entries.map(x=>[x.host,x.port,x.user,x.password].join('\0'))); let added=0, tested=0, errors=0;
    engine.setPhase('正在更新代理来源');
    for(const source of p.sources||[]) {
      if(cancelRefresh || Date.now()<engine.cooldownUntil) break;
      try { const u=new URL(source); if(u.protocol!=='https:' || u.username || u.password || u.hash) throw Error('只支持 HTTPS 来源');
        const reply=await engine.http(u.origin,u.pathname,{query:Object.fromEntries(u.searchParams),timeout:p.timeout*1000});
        if(reply.status!==200) throw Error('来源不可用');
        for(const line of reply.text.split(/\r?\n/)) { const item=parseProxy(line); if(!item)continue; const key=[item.host,item.port,item.user,item.password].join('\0');if(!known.has(key)){known.add(key); candidates.push(item);} }
      } catch(e) {errors++; if(e.status===429)break;}
    }
    for(const item of candidates) {
      if(cancelRefresh || Date.now()<engine.cooldownUntil) break;
      const started=Date.now(); tested++;
      try { const reply=await engine.http('https://api.jiucaihezi.studio','/api/status',{proxy:item,timeout:Math.min(p.timeout*1000,p.testLimit)});
        if(reply.status===200 && reply.json?.success===true && reply.json?.data && Date.now()-started<=p.testLimit) {p.entries.push(item);engine.store.save();added++;}
      } catch(e) {if(e.status===429)break;}
      engine.setPhase(`代理更新：已测试 ${tested} 个，新增 ${added} 个`);
    }
    nextRefresh=Date.now()+Math.max(1,p.sourceMinutes)*60000;
    engine.setPhase(cancelRefresh?'代理更新已停止':`代理更新完成：测试 ${tested} 个，新增 ${added} 个，来源失败 ${errors} 个`);
  };
  refreshing=work().catch(e=>engine.setPhase(`代理更新失败：${e.message}`)).finally(()=>{refreshing=null;}); await refreshing;
}
ipcMain.handle('call',async(e,action,payload={})=>{
  ensureSender(e); const d=engine.store.data;
  switch(action) {
    case 'state': return engine.snapshot();
    case 'settings':
      if(engine.running) throw Error('任务进行中，请先停止再更改配置。');
      if(refreshing){cancelRefresh=true;await refreshing;}
      d.config={...d.config,...payload.config}; d.password=String(payload.password||'');
      d.proxy={...d.proxy,...payload.proxy,entries:d.proxy.entries};
      d.headers={...d.headers,...payload.headers}; engine.store.save(); engine.notify(); return;
    case 'password': if(engine.running) throw Error('任务运行中不能修改密码'); d.password=String(payload.password||'').slice(0,128); engine.store.save(); return;
    case 'addProxies': {
      if(refreshing) throw Error('请先停止代理更新');
      const lines=String(payload.text||'').split(/\r?\n/); let added=0,invalid=0; const existing=new Set(d.proxy.entries.map(p=>[p.host,p.port,p.user,p.password].join('\0')));
      for(const line of lines) {if(!line.trim())continue; const p=parseProxy(line); if(!p){invalid++;continue;} const key=[p.host,p.port,p.user,p.password].join('\0'); if(!existing.has(key)){existing.add(key); d.proxy.entries.push(p); added++;} }
      engine.store.save();engine.notify();return {added,invalid};
    }
    case 'removeProxy': if(refreshing) throw Error('请先停止代理更新'); if(engine.running) throw Error('任务进行中请勿删除代理'); d.proxy.entries=d.proxy.entries.filter(p=>p.id!==payload.id); engine.store.save();engine.notify();return;
    case 'testProxies': {
      if(engine.running || testingProxies || refreshing) throw Error('请先停止注册任务、代理测试或更新'); engine.stopped=false; const out=[]; testingProxies=true;
      try { for(const p of d.proxy.entries) {
        if(Date.now()<engine.cooldownUntil) {out.push({id:p.id,result:'服务限流，暂停测试'});break;}
        const started=Date.now(); try { const reply=await engine.http('https://api.jiucaihezi.studio','/api/status',{proxy:p,timeout:d.proxy.timeout*1000}); out.push({id:p.id,result:reply.status===200?`${Date.now()-started} ms`:`HTTP ${reply.status}`}); }
        catch(err) {out.push({id:p.id,result:err.status===429?'服务限流，暂停测试':'连接失败'});if(err.status===429)break;}
      } return out; } finally { testingProxies=false; }
    }
    case 'refreshProxies': startRefresh(); return;
    case 'stopRefresh': cancelRefresh=true; return;
    case 'start': if(testingProxies) throw Error('请等待代理测试完成'); if(refreshing){cancelRefresh=true; await refreshing;} engine.begin(payload).catch(err=>{engine.setPhase(err.message);}); return;
    case 'pause': engine.paused=!engine.paused;engine.setPhase(engine.paused?'已暂停':'继续运行');return;
    case 'stop': engine.stopped=true;engine.paused=false;engine.setPhase('正在停止');return;
    case 'code': engine.manualCode=String(payload.code||'').trim();engine.notify();return;
    case 'submit': engine.manualSubmit=true;engine.notify();return;
    case 'resolve': { const r=d.records.find(x=>x.id===payload.id); if(!r||r.status!=='uncertain') throw Error('只能核对待确认记录'); engine.record(r,payload.exists?'succeeded':'failed',payload.exists?'用户核对：注册成功。':'用户核对：未注册，可重试。');return; }
    case 'openData': await shell.openPath(path.dirname(engine.store.file));return;
    case 'terms': await shell.openExternal('https://fviainboxes.com/terms');return;
    case 'export': {
      const {filePath}=await dialog.showSaveDialog(win,{defaultPath:'beauty-registration.csv',filters:[{name:'CSV',extensions:['csv']}]}); if(!filePath)return;
      const esc=s=>{s=String(s??'');if(/^[=+\-@\t\r]/.test(s))s="'"+s;return '"'+s.replace(/"/g,'""')+'"';}; const rows=[['用户名','邮箱','状态','更新时间','备注'],...d.records.map(r=>[r.username,r.email,r.status,r.updatedAt,r.note])]; fs.writeFileSync(filePath,'\ufeff'+rows.map(row=>row.map(esc).join(',')).join('\r\n'));return;
    }
    default: throw Error('未知操作');
  }
});
app.whenReady().then(create); app.on('window-all-closed',()=>app.quit());
