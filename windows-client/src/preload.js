const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('beauty',{call:(action,payload)=>ipcRenderer.invoke('call',action,payload),onState:callback=>ipcRenderer.on('state',(_event,state)=>callback(state))});
