'use strict';
(() => {
  const $ = selector => document.querySelector(selector);
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const label = value => String(value || 'ready').replaceAll('_', ' ');
  const date = value => { const d = new Date(value || 0); return Number.isNaN(+d) ? '' : d.toLocaleTimeString([], {hour:'numeric',minute:'2-digit'}); };
  const base = new URL('../api/v1/first-mate/', location.href).pathname;
  const state = {features:[],selected:new URLSearchParams(location.search).get('feature'),detail:null,tab:'Overview',graph:false,token:'',drafts:new Map(),pending:new Map(),generation:0,resourceGeneration:0,sessionView:null,refreshSequence:0,appliedRefresh:0,sending:new Set(),lastSignature:'',error:null};
  let noticeTimer;
  function notice(text) { clearTimeout(noticeTimer); $('#notice').textContent = text; $('#notice').hidden = false; noticeTimer = setTimeout(() => $('#notice').hidden = true, 7000); }
  function status(value) { return `<span class="status ${escape(value)}">${escape(label(value))}</span>`; }
  function modal(title, html) { state.resourceGeneration++; $('#dialog-title').textContent=title; $('#dialog-body').innerHTML=html; if (!$('#dialog').open) $('#dialog').showModal(); }
  async function api(path, body) {
    const headers = {}; if (state.token) headers.Authorization = `Bearer ${state.token}`;
    if (body) headers['Content-Type']='application/json';
    const response = await fetch(base+path, {method:body?'POST':'GET',headers,body:body?JSON.stringify(body):undefined,cache:'no-store'});
    const value = await response.json().catch(() => ({}));
    if (!response.ok || value.ok === false) throw Error(value.error?.message || (response.status===401?'Connect with your companion API token.':`Companion returned ${response.status}`));
    return value;
  }
  function idFor(key, text) { const pending = state.pending.get(key); if (pending?.text===text) return pending.id; const id=crypto.randomUUID(); state.pending.set(key,{id,text}); return id; }
  function empty(title,text) { return `<div class="empty"><h2>${escape(title)}</h2><p>${escape(text)}</p></div>`; }
  function updateComposer() {
    const feature = state.detail?.feature;
    const closed = ['completed','cancelled'].includes(feature?.status);
    $('#send').disabled = !feature || feature.id !== state.selected || !!state.error || closed || state.sending.has(state.selected);
    $('#prompt').disabled = closed;
  }
  function selectFeature(id) {
    if (state.selected) state.drafts.set(state.selected, $('#prompt').value);
    state.selected = id;
    state.generation++;
    state.resourceGeneration++;
    state.detail = null;
    state.sessionView = null;
    state.lastSignature = '';
    state.error = null;
    $('#prompt').value = state.drafts.get(id) || '';
    if ($('#dialog').open) $('#dialog').close();
    renderFeatures();
    renderDetail();
    updateComposer();
  }
  async function refresh() {
    const generation=state.generation, sequence=++state.refreshSequence;
    const current=()=>generation===state.generation && sequence>=state.appliedRefresh;
    try {
      const list=await api('features'); if(!current())return;
      state.features=list.features||[];
      if(!state.selected && state.features.length) state.selected=state.features[0].id;
      renderFeatures();
      if(state.selected) {
        const selected=state.selected; const detail=await api(`features/${encodeURIComponent(selected)}`);
        if(!current() || selected!==state.selected)return;
        if(detail.feature?.id!==selected)throw Error('Companion returned a different feature.');
        state.detail={visits:[],assignments:[],documents:[],messages:[],events:[],sessions:[],...detail};
        const signature=JSON.stringify(detail);
        if(signature!==state.lastSignature){state.lastSignature=signature;renderDetail();}
      } else renderDetail();
      state.appliedRefresh=sequence;
      state.error=null;$('#connection').textContent='Connected';$('#connection').title=`Updated ${new Date().toLocaleTimeString()}`;
    } catch(error) {
      if(!current())return;
      state.error=error.message;$('#connection').textContent=state.detail?'Offline · saved view':'Connection needed';$('#connection').title=error.message;
      if(!state.detail){$('#workspace').innerHTML=empty('Connect to your companion',error.message);$('#chat-status').textContent=error.message;}
    }
    updateComposer();
  }
  function renderFeatures(){
    $('#features').innerHTML=state.features.map(f=>`<button class="feature ${f.id===state.selected?'selected':''}" data-feature="${escape(f.id)}" aria-pressed="${f.id===state.selected}"><strong>${escape(f.title)}</strong><small>${escape(label(f.status))}</small></button>`).join('')||empty('Start a feature','Your ideas and tickets will appear here.');
  }
  function renderDetail(){
    const d=state.detail;if(!d){$('#feature-header').innerHTML=empty(state.selected?'Loading feature':'Your First Mate','Select a feature or start something new.');$('#messages').innerHTML=empty('A clear place to begin','Create a feature. Your First Mate will help shape the plan and delegate each step.');$('#workspace').innerHTML=empty('Your feature workspace','Goals, agents, documents, and the workflow live here.');renderTabs();return;}
    const f=d.feature;
    $('#feature-header').innerHTML=`<h1>${escape(f.title)}</h1><p>Your First Mate · one conversation for this feature</p>${status(f.status)}`;
    const log=$('#messages'), nearBottom=log.scrollHeight-log.scrollTop-log.clientHeight<90;
    log.innerHTML=d.messages.map(m=>`<article class="message ${m.role==='user'?'user':''}"><span class="avatar" aria-hidden="true">${m.role==='user'?'You':'FM'}</span><div class="message-main"><div class="message-meta"><strong>${m.role==='user'?'You':m.role==='system'?'Workflow':'First Mate'}</strong><time>${escape(date(m.created_at))}</time>${m.status==='queued'?'<small>Queued</small>':''}</div><div class="prose">${escape(m.text||m.content)}</div></div></article>`).join('')||empty('Ready for your direction','Tell First Mate what this feature should achieve.');
    if(nearBottom)log.scrollTop=log.scrollHeight;
    $('#chat-status').textContent=['completed','cancelled'].includes(f.status)?'This feature is closed. Its history remains available.':f.status==='awaiting_direction'?'Your move. Describe what should happen next.':f.status==='coordinating'?'First Mate is responding. You can queue your next message.':'Work continues independently. Your First Mate is available.';
    renderTabs();renderWorkspace();
  }
  function renderTabs(){ $('#tabs').innerHTML=['Overview','Agents','Documents','Workflow'].map(tab=>`<button data-tab="${tab}" class="${state.tab===tab?'selected':''}" aria-current="${state.tab===tab?'page':'false'}">${tab}</button>`).join(''); }
  function documentsForVisit(visitId){const d=state.detail,ids=new Set(d.assignments.filter(a=>(a.visit_ids||[a.visit_id]).includes(visitId)).map(a=>a.id));return d.documents.filter(doc=>doc.visit_id===visitId||ids.has(doc.assignment_id));}
  function resources(visit){const d=state.detail,agents=d.assignments.filter(a=>(a.visit_ids||[a.visit_id]).includes(visit.id)),docs=documentsForVisit(visit.id);return `<div class="resources"><button data-resource="agents" data-visit="${escape(visit.id)}" ${agents.length?'':'disabled'}>${agents.length} agents</button><button data-resource="documents" data-visit="${escape(visit.id)}" ${docs.length?'':'disabled'}>${docs.length} documents</button></div>`;}
  function agentRows(agents){return agents.map(a=>`<button class="row" data-agent="${escape(a.id)}"><span><strong>${escape(a.title||a.role)}</strong><small>${escape(a.role)} · Attempt ${escape(a.generation||1)}</small></span>${status(a.status||a.verdict)}</button>`).join('')||empty('No agents yet','Delegated assignments appear here when First Mate starts a stage.');}
  function docRows(docs){return docs.map(d=>`<button class="row" data-document="${escape(d.id)}"><span><strong>${escape(d.title)}</strong><small>${escape(d.media_type||'Document')} · ${escape(date(d.created_at))}</small></span><span aria-hidden="true">↗</span></button>`).join('')||empty('No documents yet','Plans, evidence, and review reports stay attached to the work that produced them.');}
  function visitCard(v,graph=false){return `<article class="${graph?'node':'visit'} ${escape(v.status)}"><h3>${escape(v.title||label(v.stage_key))}</h3>${status(v.status)}${resources(v)}</article>`;}
  function renderWorkspace(){
    const d=state.detail;if(!d)return;let html='';
    if(state.tab==='Overview'){
      html=`<p class="eyebrow">The goal</p><p class="goal">${escape(d.feature.goal)}</p>`;
      if(d.feature.status==='awaiting_direction')html+='<section class="checkpoint"><h3>Ready for your next direction</h3><p>Work is waiting at a human checkpoint. Review the latest request, then tell First Mate how you want to continue.</p></section>';
      html+=`<div class="section-title"><h2>Working on this feature</h2><small>${d.assignments.length} assignments</small></div>${agentRows([...d.assignments.filter(a=>['running','queued','dispatching','handoff_pending'].includes(a.status)),...d.assignments.filter(a=>!['running','queued','dispatching','handoff_pending'].includes(a.status)).slice(-4)].slice(0,4))}`;
      html+='<div class="section-title"><h2>Feature journal</h2></div>'+d.events.slice(-12).reverse().map(e=>`<article class="event"><time>${escape(date(e.created_at))}</time>${escape(e.summary||label(e.type))}</article>`).join('');
      html+=`<div class="controls"><button data-action-feature="${escape(d.feature.id)}" data-action="${d.feature.status==='paused'?'resume':'pause'}" ${['completed','cancelled'].includes(d.feature.status)?'disabled':''}>${d.feature.status==='paused'?'Resume authorized work':'Pause work'}</button><button data-action-feature="${escape(d.feature.id)}" data-action="cancel" ${['completed','cancelled'].includes(d.feature.status)?'disabled':''}>Cancel feature</button></div>`;
    } else if(state.tab==='Agents')html='<h2>The crew</h2><p class="eyebrow">Independent sessions, grouped by the work they own.</p>'+d.visits.map(v=>`<div class="section-title"><h3>${escape(v.title||label(v.stage_key))}</h3></div>${agentRows(d.assignments.filter(a=>(a.visit_ids||[a.visit_id]).includes(v.id)))}`).join('');
    else if(state.tab==='Documents')html='<h2>Feature documents</h2><p class="eyebrow">Every result keeps its producing assignment and session.</p>'+docRows(d.documents);
    else html=`<div class="view-switch"><button data-view="timeline" class="${state.graph?'':'selected'}">Timeline</button><button data-view="graph" class="${state.graph?'selected':''}">Graph</button></div><p class="eyebrow">Recorded stage visits, including returns and revisions.</p><div class="${state.graph?'graph':'timeline'}">${d.visits.map(v=>visitCard(v,state.graph)).join('')||empty('Your route starts here','First Mate will propose a stage after your first message.')}</div>`;
    $('#workspace').innerHTML=html;
  }
  function picker(kind,visitId){const d=state.detail,v=d.visits.find(v=>v.id===visitId);modal(`${v?.title||'Stage'} · ${kind}`,kind==='agents'?agentRows(d.assignments.filter(a=>(a.visit_ids||[a.visit_id]).includes(visitId))):docRows(documentsForVisit(visitId)));}
  async function openDocument(id) {
    const generation=state.generation, resource=++state.resourceGeneration, feature=state.selected;
    try {
      const result=await api(`documents/${encodeURIComponent(id)}`),d=result.document;
      if(generation!==state.generation || resource!==state.resourceGeneration)return;
      if(d?.id!==id || d.feature_id!==feature)throw Error('Document ownership did not match this feature.');
      modal(d.title,`<div class="document-meta">Produced by ${escape(d.assignment_id||'First Mate')}<br>Session ${escape(d.native_session_id||'Unassigned')}</div><pre>${escape(d.content)}</pre>${d.native_session_id?`<button data-session="${escape(d.native_session_id)}">Open producing session</button>`:''}`);
    }catch(e){if(generation===state.generation && resource===state.resourceGeneration)notice(e.message);}
  }
  async function openSession(id, before=null){
    const generation=state.generation, resource=++state.resourceGeneration;
    const previous=before!==null && state.sessionView?.id===id ? state.sessionView.messages : [];
    try {
      const query=before===null?'':`?before=${encodeURIComponent(before)}&limit=100`;
      const d=await api(`sessions/${encodeURIComponent(id)}${query}`);
      if(generation!==state.generation || resource!==state.resourceGeneration)return;
      if(d.native_session_id!==id)throw Error('Saved session identity did not match.');
      if(before!==null && d.next_before!=null && (d.next_before<0 || d.next_before>=before))throw Error('Saved session cursor did not advance.');
      const messages=[...(d.messages||[]),...previous];
      state.sessionView={id,messages};
      const paging=d.total_messages!=null?`<div class="document-meta">${messages.length} of ${escape(d.total_messages)} saved messages</div>`:'';
      const earlier=d.next_before!=null?`<button data-session="${escape(id)}" data-before="${escape(d.next_before)}">Load earlier messages</button>`:'';
      modal('Saved agent session',`<p class="document-meta">${escape(id)}</p>${paging}${earlier}${messages.map(m=>`<article class="event"><strong>${escape(m.role)}</strong><div class="prose">${escape(m.text||m.content)}</div></article>`).join('')||empty('No saved messages yet','The exact session is registered, but it has not written a transcript yet.')}`);
    }catch(e){if(generation===state.generation && resource===state.resourceGeneration)notice(e.message);}
  }
  async function openAgent(id){const a=state.detail.assignments.find(a=>a.id===id);const sessions=(state.detail.sessions||[]).filter(s=>s.assignment_id===id);if(!sessions.length&&a?.native_session_id)return openSession(a.native_session_id);modal(a?.title||'Assignment',`<p>${escape(label(a?.status))}</p>${sessions.length?sessions.map(s=>`<button class="row" data-session="${escape(s.native_session_id)}"><span><strong>${s.native_session_id===a.native_session_id?'Latest session':'Earlier session'}</strong><small>${escape(s.native_session_id)}</small></span>${status(s.status)}</button>`).join(''):'<p class="document-meta">A saved session will appear after this assignment starts.</p>'}${state.detail.sessions_truncated?'<p>Showing recent session history. Older sessions remain retained on the companion host.</p>':''}`);}
  document.addEventListener('click',async e=>{
    const b=e.target.closest('button');if(!b)return;
    if(b.dataset.feature){selectFeature(b.dataset.feature);await refresh();}
    if(b.dataset.tab){state.tab=b.dataset.tab;renderTabs();renderWorkspace();}
    if(b.dataset.view){state.graph=b.dataset.view==='graph';renderWorkspace();}
    if(b.dataset.resource)picker(b.dataset.resource,b.dataset.visit);
    if(b.dataset.agent)await openAgent(b.dataset.agent);
    if(b.dataset.document)await openDocument(b.dataset.document);
    if(b.dataset.session){b.disabled=true;try{await openSession(b.dataset.session,b.dataset.before===undefined?null:Number(b.dataset.before));}finally{b.disabled=false;}}
    if(b.dataset.action){
      const action=b.dataset.action, feature=b.dataset.actionFeature;
      if(!feature || state.selected!==feature || state.detail?.feature.id!==feature)return;
      if(action==='cancel'&&!confirm('Cancel this feature’s active work? Its history will be retained.'))return;
      try{await api(`features/${encodeURIComponent(feature)}/actions`,{action,request_id:idFor(`action:${feature}`,action)});state.pending.delete(`action:${feature}`);await refresh();}catch(err){notice(err.message);}
    }
  });
  $('#composer').addEventListener('submit',async e=>{
    e.preventDefault();const text=$('#prompt').value.trim(),feature=state.selected;
    if(!text||!feature||$('#send').disabled)return;
    state.sending.add(feature);updateComposer();
    try{
      await api(`features/${encodeURIComponent(feature)}/messages`,{text,request_id:idFor(`message:${feature}`,text)});
      state.pending.delete(`message:${feature}`);
      if(state.drafts.get(feature)?.trim()===text)state.drafts.delete(feature);
      if(state.selected===feature && $('#prompt').value.trim()===text)$('#prompt').value='';
      await refresh();
    }catch(error){notice(`${error.message} Your message is retained. Retry sends the same request.`);}
    finally{state.sending.delete(feature);updateComposer();}
  });
  $('#prompt').addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();if(!$('#send').disabled)$('#composer').requestSubmit();}});
  $('#new').onclick=()=>{modal('Start a feature','<form id="new-feature"><label for="feature-title">Feature name</label><input id="feature-title" required placeholder="A small improvement worth shipping"><label for="feature-goal">What should it achieve?</label><textarea id="feature-goal" required placeholder="Describe the outcome in your own words."></textarea><label for="feature-cwd">Project folder on this companion host</label><input id="feature-cwd" required placeholder="/path/to/project"><button class="primary" type="submit">Create feature</button></form>');$('#new-feature').onsubmit=async e=>{e.preventDefault();const payload={title:$('#feature-title').value.trim(),goal:$('#feature-goal').value.trim(),cwd:$('#feature-cwd').value.trim()};payload.request_id=idFor('create',JSON.stringify(payload));try{const d=await api('features',payload);state.pending.delete('create');selectFeature(d.feature.id);await refresh();$('#prompt').focus();}catch(err){notice(err.message);}};};
  $('#connect').onclick=()=>{modal('Connect to Herdr','<form id="connection-form"><p>Your companion API token stays in memory for this page only.</p><label for="api-token">API token</label><input id="api-token" type="password" autocomplete="off"><button class="primary">Connect</button></form>');$('#connection-form').onsubmit=e=>{e.preventDefault();state.token=$('#api-token').value;selectFeature(state.selected);$('#dialog').close();refresh();};};
  $('#dialog').addEventListener('close',()=>{state.resourceGeneration++;});
  function theme(value){document.documentElement.dataset.theme=value;$('#theme').textContent=value==='dark'?'Light mode':'Dark mode';try{localStorage.setItem('herdr-first-mate-theme',value);}catch{}}
  $('#theme').onclick=()=>theme(document.documentElement.dataset.theme==='dark'?'light':'dark');
  let saved;try{saved=localStorage.getItem('herdr-first-mate-theme');}catch{}theme(new URLSearchParams(location.search).get('theme')||saved||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light'));
  renderTabs();updateComposer();refresh();let polling=false;setInterval(async()=>{if(document.hidden||polling)return;polling=true;try{await refresh();}finally{polling=false;}},2500);
})();
