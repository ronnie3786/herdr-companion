'use strict';
// Every machine, path and session in this prototype is synthetic. No API calls.
const $ = id => document.getElementById(id);
const escapeHTML = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const glyphs = {
  folder:'<path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v10H3Z"/>',
  sail:'<path d="M12 3v13H4L12 3Zm3 4 5 9h-5ZM3 19h18l-3 3H6Z"/>',
  computer:'<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8m-4-4v4"/>',
  plus:'<path d="M12 5v14M5 12h14"/>', x:'<path d="m6 6 12 12M6 18 18 6"/>',
  chevrons:'<path d="m8 9 4-4 4 4m-8 6 4 4 4-4"/>',
  'arrow-up':'<path d="M12 19V5m-6 6 6-6 6 6"/>',
  'arrow-right':'<path d="M5 12h14m-6-6 6 6-6 6"/>',
  right:'<path d="m9 5 7 7-7 7"/>',check:'<path d="m5 12 4 4L19 6"/>',
  home:'<path d="m3 10 9-7 9 7M5 9v12h14V9m-10 12v-8h6v8"/>',
  lock:'<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>'
};
const icon = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${glyphs[name] || glyphs.folder}</svg>`;
const paintIcons = () => document.querySelectorAll('[data-icon]').forEach(el => {el.innerHTML = icon(el.dataset.icon);});
const machines = [
  {id:'studio',name:'Studio Mac',online:true,home:'/Users/developer',roots:['Projects','Documents','Desktop','Private','.config']},
  {id:'laptop',name:'Laptop',online:true,home:'/Users/example',roots:['Projects','Documents','Desktop','Private','.config']},
  {id:'server',name:'Build Server',online:false,home:'/home/developer',roots:['Projects']}
];
const seedProjects = [
  {id:'ios',name:'iOS App',machine:'studio',path:'/Users/developer/Projects/ios-app'},
  {id:'web',name:'Web App',machine:'laptop',path:'/Users/example/Projects/web-app'},
  {id:'api',name:'Service API',machine:'server',path:'/home/developer/Projects/service-api'}
];
const seedSessions = [
  {id:'sample-1',name:'Improve search suggestions',project:'iOS App',machine:'studio',path:seedProjects[0].path,prompt:'Investigate why search suggestions disappear after switching tabs. Propose a plan before making changes.',working:true},
  {id:'sample-2',name:'Simplify the settings page',project:'Web App',machine:'laptop',path:seedProjects[1].path,prompt:'Review the settings page and suggest ways to make it easier to navigate.',working:false}
];
let projects = structuredClone(seedProjects), sessions = structuredClone(seedSessions);
let selectedProject = 'ios', mode = 'project', activeSession = null, editingID = null, projectReturn = 'new';
let browserMachine = null, browserPath = '', browserTarget = 'project', currentFolderValid = false, toastTimer;
const storageKey = 'herdr-project-concept-v1';
try {
  const saved = JSON.parse(localStorage.getItem(storageKey));
  if (saved && Array.isArray(saved.projects) && saved.projects.every(p => p && ['id','name','path','machine'].every(k => typeof p[k] === 'string') && machines.some(m => m.id === p.machine))) projects = saved.projects;
} catch (_) { /* Private browsing can disable storage. In-memory mode still works. */ }
function persist(){try{localStorage.setItem(storageKey,JSON.stringify({projects}));}catch(_){}}
function toast(text){clearTimeout(toastTimer);$('toast').textContent=text;$('toast').hidden=false;toastTimer=setTimeout(()=>$('toast').hidden=true,3200);}
function machine(id){return machines.find(m=>m.id===id);}
function project(){return projects.find(p=>p.id===selectedProject);}
function notice(id,text){$(id).textContent=text;$(id).hidden=!text;}
function setView(view){
  ['new','projects','session'].forEach(v=>$(v+'-view').hidden=v!==view);
  document.querySelectorAll('.nav-row').forEach(b=>b.classList.toggle('selected',b.dataset.view===(view==='projects'?'projects':'new')));
  $('view-title').textContent=view==='new'?'New First Mate session':view==='projects'?'Projects':'First Mate';
  $('view-meta').textContent=view==='session'?machine(sessions.find(s=>s.id===activeSession)?.machine)?.name || 'All machines':'All machines';
  $('project-options').hidden=true;$('project-picker').setAttribute('aria-expanded','false');
  if(view==='new'){activeSession=null;renderSessions();}
  if(view==='projects')renderProjects();
}
function renderSessions(){
  $('session-list').innerHTML=sessions.map(s=>`<button class="session-row ${s.id===activeSession?'active':''}" data-session="${escapeHTML(s.id)}"><span class="status-dot ${s.working?'working':''}"></span><span class="grow"><strong>${escapeHTML(s.name)}</strong><small>${escapeHTML(s.project)} · ${escapeHTML(machine(s.machine).name)}</small></span></button>`).join('');
}
function renderProjects(){
  $('project-count').textContent=projects.length;
  $('projects-list').innerHTML=projects.length?projects.map(p=>{const m=machine(p.machine);return `<div class="project-table-row"><div class="project-title"><span class="project-symbol">${icon('folder')}</span><span><strong>${escapeHTML(p.name)}</strong><small>${escapeHTML(p.path)}</small></span></div><div class="machine-cell">${escapeHTML(m.name)}<small><span class="status-dot ${m.online?'':'offline'}"></span>${m.online?'Connected':'Offline'}</small></div><button class="text-button" data-edit="${escapeHTML(p.id)}" aria-label="Edit ${escapeHTML(p.name)}">Edit</button></div>`;}).join(''):'<p class="empty-folder">No projects yet. Create a project to save a machine and folder for your next session.</p>';
}
function renderSelectedProject(){
  const p=project(),m=p?machine(p.machine):null;
  $('project-selected-label').innerHTML=p?`<strong>${escapeHTML(p.name)}</strong><small>${escapeHTML(m.name)}</small>`:'<strong>Choose a project</strong><small>Save a machine and folder once</small>';
  $('project-context').innerHTML=p?`${icon('folder')}<span>${escapeHTML(p.path)}</span><span class="status-dot ${m.online?'':'offline'}"></span><span>${m.online?'Connected':'Offline'}</span>`:'Your project determines the machine and folder.';
  $('project-options').innerHTML=projects.map(p=>{const m=machine(p.machine);return `<button class="project-option" data-project="${escapeHTML(p.id)}"><span class="project-symbol">${icon('folder')}</span><span><strong>${escapeHTML(p.name)}</strong><small>${escapeHTML(m.name)}</small></span><span class="option-state">${!m.online?'Offline':p.id===selectedProject?icon('check'):''}</span></button>`;}).join('')+`<button class="project-option option-new" id="picker-new-project">${icon('plus')}Create a new project</button>`;
  updateStart();
}
function setMode(next){mode=next;$('project-mode').setAttribute('aria-pressed',next==='project');$('manual-mode').setAttribute('aria-pressed',next==='manual');$('project-setup').hidden=next!=='project';$('manual-setup').hidden=next!=='manual';$('project-options').hidden=true;$('project-picker').setAttribute('aria-expanded','false');updateStart();}
function updateStart(){
  let message='',valid=Boolean($('prompt').value.trim());
  if(mode==='project'){
    const p=project();valid=valid&&Boolean(p);
    if(p&&!machine(p.machine).online){message=`${machine(p.machine).name} is offline. Reconnect that machine or choose another project. Your prompt stays here.`;valid=false;}
  }else{
    const m=machine($('manual-machine').value);
    valid=valid&&Boolean($('manual-title').value.trim())&&Boolean($('manual-path').value.trim());
    if(!m.online){message=`${m.name} is offline. Choose a connected machine to start this session.`;valid=false;}
    $('manual-browse').disabled=!m.online;
  }
  $('start-session').disabled=!valid;notice('start-error',message);
}
function openProject(edit=null,returnTo='new'){
  editingID=edit?.id || null;projectReturn=returnTo;
  $('project-name').value=edit?.name || '';
  $('project-machine').value=edit?.machine || 'studio';
  $('project-machine').disabled=Boolean(edit);
  $('project-folder').value=edit?.path || '';
  $('project-dialog-title').textContent=edit?'Edit project':'New project';
  $('save-project').textContent=edit?'Save changes':'Create project';
  notice('project-error','');updateProjectForm();$('project-dialog').showModal();
}
function updateProjectForm(){
  const m=machine($('project-machine').value);
  $('machine-hint').textContent=m.online?`${m.name} is connected. Browse folders available to Herdr on this machine.`:`${m.name} is offline. Reconnect it before choosing or updating its folder.`;
  $('project-browse').disabled=!m.online;
  $('save-project').disabled=!m.online||!$('project-name').value.trim()||!$('project-folder').value;
}
function folderInfo(m,path){
  if(path===m.home)return {children:m.roots.map(name=>({name,detail:name==='Private'?'Restricted':''}))};
  const relative=path.startsWith(m.home+'/')?path.slice(m.home.length+1):null;
  if(relative==='Private')return {error:'Herdr cannot read this folder.',detail:'Choose a different folder, or allow the companion to access it in this machine’s system settings.'};
  if(relative==='Projects')return {children:(m.id==='studio'?['ios-app','design-system','sample-tools']:['web-app','docs-site','api-client']).map(name=>({name,detail:'Git repository'}))};
  if(relative==='Documents')return {children:[{name:'Notes',detail:''},{name:'Drafts',detail:''}]};
  if(['Desktop','.config','Documents/Notes','Documents/Drafts'].includes(relative))return {children:[]};
  const repoNames=m.id==='studio'?['ios-app','design-system','sample-tools']:['web-app','docs-site','api-client'];
  if(relative?.startsWith('Projects/')){
    const parts=relative.split('/');
    if(repoNames.includes(parts[1]) && parts.length===2)return {repo:true,children:[{name:'.git',detail:'Hidden folder'},{name:'Sources',detail:''},{name:'Tests',detail:''},{name:'docs',detail:''}]};
    if(repoNames.includes(parts[1]) && parts.length===3 && ['.git','Sources','Tests','docs'].includes(parts[2]))return {children:[]};
  }
  return {error:'This folder is unavailable.',detail:'Check the path or choose Home to browse again. This demo contains sample folders only.'};
}
function openBrowser(target){
  browserTarget=target;browserMachine=machine($(target==='project'?'project-machine':'manual-machine').value);
  if(!browserMachine.online)return;
  browserPath=$(target==='project'?'project-folder':'manual-path').value || browserMachine.home+'/Projects';
  $('show-hidden').checked=false;$('folder-dialog').showModal();renderBrowser();
}
function normalizePath(value,m=browserMachine){
  const expanded=value.trim().replace(/^~(?=\/|$)/,m.home);
  if(!expanded.startsWith('/'))return expanded;
  const pieces=[];for(const part of expanded.split('/')){if(!part||part==='.')continue;if(part==='..')pieces.pop();else pieces.push(part);}return '/'+pieces.join('/');
}
function renderBrowser(){
  const m=browserMachine,info=folderInfo(m,browserPath);currentFolderValid=!info.error;
  $('folder-machine-label').innerHTML=`${icon('computer')} ${escapeHTML(m.name)} <span class="status-dot"></span> Connected`;
  $('browse-path').value=browserPath;$('folder-selection-path').textContent=browserPath;
  $('folder-name').textContent=browserPath.split('/').filter(Boolean).pop() || '/';
  $('folder-up').disabled=browserPath===m.home||!browserPath.startsWith(m.home+'/');
  $('home-folder').classList.toggle('active',browserPath===m.home);$('projects-folder').classList.toggle('active',browserPath.startsWith(m.home+'/Projects'));
  const entries=(info.children || []).filter(f=>$('show-hidden').checked || !f.name.startsWith('.'));
  $('folder-rows').innerHTML=entries.map(f=>`<button class="folder-row" data-folder="${escapeHTML(f.name)}"><span class="folder-glyph">${icon('folder')}</span>${escapeHTML(f.name)}<span>${escapeHTML(f.detail)}${icon(f.name==='Private'?'lock':'right')}</span></button>`).join('')+(!info.error&&!entries.length?'<p class="empty-folder">No subfolders. You can use this folder for your project.</p>':'');
  $('folder-error').hidden=!info.error;$('folder-error').innerHTML=info.error?`<strong>${escapeHTML(info.error)}</strong>${escapeHTML(info.detail)}`:'';
  $('choose-folder').disabled=!currentFolderValid;$('folder-item-count').textContent=info.error?'Folder unavailable':`${entries.length} ${entries.length===1?'folder':'folders'}${info.repo?' · Git repository':''}`;
}
function showSession(id){
  const s=sessions.find(s=>s.id===id);if(!s)return;
  activeSession=id;$('session-title').textContent=s.name;$('sent-prompt').textContent=s.prompt;
  $('session-location').innerHTML=`${icon('folder')} ${escapeHTML(s.project)} <span> / </span>${icon('computer')} ${escapeHTML(machine(s.machine).name)}<span> / </span><span>${escapeHTML(s.path)}</span>`;
  setView('session');renderSessions();
}
function startSession(){
  updateStart();if($('start-session').disabled)return;
  const p=mode==='project'?project():null;
  const prompt=$('prompt').value;
  const m=machine(p?.machine || $('manual-machine').value),path=p?.path || normalizePath($('manual-path').value,m);
  if(mode==='manual' && folderInfo(m,path).error){notice('start-error','That folder is unavailable in this demo. Use Browse to choose a sample folder. Your prompt has been kept.');return;}
  const s={id:'session-'+Date.now(),name:mode==='manual'?$('manual-title').value.trim():prompt.trim().split('\n')[0].slice(0,72),project:p?.name || 'Manual session',machine:m.id,path,prompt,working:true};
  sessions.unshift(s);$('prompt').value='';updateStart();showSession(s.id);
}
machines.forEach(m=>{
  for(const id of ['project-machine','manual-machine']){const opt=document.createElement('option');opt.value=m.id;opt.textContent=m.name+(m.online?' · Connected':' · Offline');$(id).append(opt);}
});
document.addEventListener('click',e=>{
  const view=e.target.closest('[data-view]');if(view)setView(view.dataset.view);
  const close=e.target.closest('[data-close]');if(close)$(close.dataset.close).close();
  const prompt=e.target.closest('[data-prompt]');if(prompt){$('prompt').value=prompt.dataset.prompt;updateStart();$('prompt').focus();}
  const choice=e.target.closest('[data-project]');if(choice){selectedProject=choice.dataset.project;renderSelectedProject();$('project-options').hidden=true;$('project-picker').setAttribute('aria-expanded','false');$('prompt').focus();}
  const edit=e.target.closest('[data-edit]');if(edit)openProject(projects.find(p=>p.id===edit.dataset.edit),'projects');
  const folder=e.target.closest('[data-folder]');if(folder){browserPath+='/'+folder.dataset.folder;renderBrowser();$('browse-path').focus();}
  const session=e.target.closest('[data-session]');if(session)showSession(session.dataset.session);
  if(e.target.closest('#picker-new-project')){setView('new');openProject();}
  if(!e.target.closest('.project-picker-wrap')){$('project-options').hidden=true;$('project-picker').setAttribute('aria-expanded','false');}
});
$('project-mode').onclick=()=>setMode('project');$('manual-mode').onclick=()=>setMode('manual');
$('project-picker').onclick=()=>{const open=$('project-options').hidden;$('project-options').hidden=!open;$('project-picker').setAttribute('aria-expanded',String(open));};
$('new-project-inline').onclick=()=>openProject();$('new-project-list').onclick=()=>openProject(null,'projects');
$('project-name').oninput=updateProjectForm;
$('project-machine').onchange=()=>{$('project-folder').value='';notice('project-error','');updateProjectForm();};
$('project-browse').onclick=()=>openBrowser('project');$('manual-browse').onclick=()=>openBrowser('manual');
$('project-form').onsubmit=e=>{
  e.preventDefault();if($('save-project').disabled)return;
  const m=machine($('project-machine').value),path=$('project-folder').value;
  if(folderInfo(m,path).error){notice('project-error','This folder is no longer available. Browse to choose another.');return;}
  const entry={id:editingID || 'project-'+Date.now(),name:$('project-name').value.trim(),machine:m.id,path};
  if(editingID)projects=projects.map(p=>p.id===editingID?entry:p);else projects.push(entry);
  selectedProject=entry.id;persist();renderProjects();renderSelectedProject();$('project-dialog').close();
  if(projectReturn==='new'){setMode('project');setView('new');$('prompt').focus();}else setView('projects');
  toast(editingID?'Project saved. Existing sessions keep their original folder.':'Project created. Ready for a new session.');
};
$('home-folder').onclick=()=>{browserPath=browserMachine.home;renderBrowser();};
$('projects-folder').onclick=()=>{browserPath=browserMachine.home+'/Projects';renderBrowser();};
$('folder-up').onclick=()=>{browserPath=browserPath.slice(0,browserPath.lastIndexOf('/')) || '/';renderBrowser();};
$('path-form').onsubmit=e=>{e.preventDefault();browserPath=normalizePath($('browse-path').value);renderBrowser();};
$('show-hidden').onchange=renderBrowser;
$('choose-folder').onclick=()=>{if(!currentFolderValid)return;$(browserTarget==='project'?'project-folder':'manual-path').value=browserPath;$('folder-dialog').close();if(browserTarget==='project')updateProjectForm();else updateStart();};
for(const id of ['prompt','manual-title','manual-path'])$(id).addEventListener('input',updateStart);
$('manual-machine').onchange=()=>{$('manual-path').value='';updateStart();};
$('start-session').onclick=startSession;
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!document.querySelector('dialog[open]')){$('project-options').hidden=true;$('project-picker').setAttribute('aria-expanded','false');}if((e.metaKey||e.ctrlKey)&&e.key==='Enter'&&!document.querySelector('dialog[open]')&&!$('new-view').hidden){e.preventDefault();startSession();}});
$('theme-toggle').onclick=()=>{const light=document.body.classList.toggle('light');$('theme-toggle').textContent=light?'Dark':'Light';$('theme-toggle').setAttribute('aria-label',light?'Switch to dark appearance':'Switch to light appearance');};
$('reset-demo').onclick=()=>{document.querySelectorAll('dialog[open]').forEach(d=>d.close());projects=structuredClone(seedProjects);sessions=structuredClone(seedSessions);selectedProject='ios';persist();$('prompt').value='';$('manual-title').value='';$('manual-path').value='';$('manual-machine').value='studio';renderProjects();renderSelectedProject();setMode('project');setView('new');toast('Sample projects restored.');};
paintIcons();renderProjects();renderSelectedProject();renderSessions();
if(location.hash==='#projects')setView('projects');
if(location.hash==='#new-project')openProject();
