'use strict';
(() => {
  const $ = selector => document.querySelector(selector);
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const safeLink = value => {
    const href=String(value||'').trim();
    if(/^(?:https?:|mailto:)/i.test(href)||/^(?:#|\/|\.\/|\.\.\/)/.test(href))return href;
    return null;
  };
  function markdownInline(value) {
    const source=String(value??'');let html='',cursor=0;
    const token=/(`+)([^`\n]*?)\1|\[([^\]\n]+)\]\(([^\s)]+)\)/g;
    const emphasis=text=>escape(text)
      .replace(/\*\*([^*\n]+)\*\*/g,'<strong>$1</strong>')
      .replace(/__([^_\n]+)__/g,'<strong>$1</strong>')
      .replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g,'$1<em>$2</em>')
      .replace(/(^|[^_])_([^_\n]+)_(?!_)/g,'$1<em>$2</em>');
    for(const match of source.matchAll(token)){
      html+=emphasis(source.slice(cursor,match.index));
      if(match[1])html+=`<code>${escape(match[2])}</code>`;
      else {const href=safeLink(match[4]);html+=href?`<a href="${escape(href)}">${emphasis(match[3])}</a>`:escape(match[0]);}
      cursor=match.index+match[0].length;
    }
    return html+emphasis(source.slice(cursor));
  }
  function markdown(value, quoteDepth=0) {
    const lines=String(value??'').replace(/\r\n?/g,'\n').split('\n');let html='',index=0;
    const tableDivider=line=>/^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);
    const cells=line=>line.trim().replace(/^\||\|$/g,'').split('|').map(cell=>cell.trim());
    const beginsBlock=(line,next)=>/^\s*$/.test(line)||/^\s*(?:`{3,}|~{3,})/.test(line)||/^\s{0,3}#{1,6}\s+/.test(line)||/^\s*>/.test(line)||/^\s*(?:[-+*]|\d+[.)])\s+/.test(line)||(line.includes('|')&&tableDivider(next||''));
    while(index<lines.length){
      const line=lines[index];
      if(/^\s*$/.test(line)){index++;continue;}
      const fence=line.match(/^\s*(`{3,}|~{3,})\s*([^\s`]*)\s*$/);
      if(fence){index++;const code=[],marker=fence[1][0],closing=new RegExp(`^\\s*${marker}{${fence[1].length},}\\s*$`);while(index<lines.length&&!closing.test(lines[index]))code.push(lines[index++]);if(index<lines.length)index++;html+=`<pre${fence[2]?` data-language="${escape(fence[2])}"`:''}><code>${escape(code.join('\n'))}</code></pre>`;continue;}
      const heading=line.match(/^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$/);
      if(heading){const level=heading[1].length;html+=`<h${level}>${markdownInline(heading[2])}</h${level}>`;index++;continue;}
      if(/^\s*>/.test(line)){const quote=[];while(index<lines.length&&/^\s*>/.test(lines[index]))quote.push(lines[index++].replace(/^\s*>\s?/,''));const content=quoteDepth<8?markdown(quote.join('\n'),quoteDepth+1):`<p>${quote.map(markdownInline).join('<br>')}</p>`;html+=`<blockquote>${content}</blockquote>`;continue;}
      const item=line.match(/^\s*(?:([-+*])|(\d+)[.)])\s+(.+)$/);
      if(item){const ordered=!!item[2],items=[];while(index<lines.length){const current=lines[index].match(/^\s*(?:([-+*])|(\d+)[.)])\s+(.+)$/);if(!current||!!current[2]!==ordered)break;items.push(current[3]);index++;}const tag=ordered?'ol':'ul';html+=`<${tag}>${items.map(text=>`<li>${markdownInline(text)}</li>`).join('')}</${tag}>`;continue;}
      if(line.includes('|')&&tableDivider(lines[index+1]||'')){const headers=cells(line);index+=2;const rows=[];while(index<lines.length&&lines[index].includes('|')&&!/^\s*$/.test(lines[index]))rows.push(cells(lines[index++]));html+=`<div class="markdown-table"><table><thead><tr>${headers.map(cell=>`<th>${markdownInline(cell)}</th>`).join('')}</tr></thead><tbody>${rows.map(row=>`<tr>${headers.map((_,column)=>`<td>${markdownInline(row[column]||'')}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;continue;}
      const paragraph=[line];index++;while(index<lines.length&&!beginsBlock(lines[index],lines[index+1]))paragraph.push(lines[index++]);html+=`<p>${paragraph.map(markdownInline).join('<br>')}</p>`;
    }
    return html;
  }
  const literal = value => `<div class="literal-text">${escape(value)}</div>`;
  const messageContent = message => message.role==='assistant' ? `<div class="markdown">${markdown(message.text||message.content)}</div>` : literal(message.text||message.content);
  const humanMessage = message => message.role==='user'||message.role==='human';
  const label = value => String(value || 'ready').replaceAll('_', ' ');
  const date = value => { const d = new Date(value || 0); return Number.isNaN(+d) ? '' : d.toLocaleTimeString([], {hour:'numeric',minute:'2-digit'}); };
  const nonnegative = value => typeof value === 'number' && Number.isFinite(value) && value >= 0;
  const number = value => (Number.isInteger(value) && value >= 0 ? value : 0).toLocaleString('en-US');
  const costAmount = usage => {
    if(!usage || usage.status==='unavailable' || !nonnegative(usage.cost_usd))return 'Unavailable';
    if(usage.cost_usd>0 && usage.cost_usd<0.01)return '<$0.01';
    return new Intl.NumberFormat('en-US',{style:'currency',currency:usage.currency||'USD',minimumFractionDigits:2,maximumFractionDigits:2}).format(usage.cost_usd);
  };
  const coverageLabels = usage => [usage?.status==='partial'?'Partial':'',usage?.stale?'Last reported':''].filter(Boolean);
  const compactCost = usage => {
    const amount=costAmount(usage);
    return amount==='Unavailable'||coverageLabels(usage).length===0?amount:`${amount}*`;
  };
  const modelName = model => [model?.provider,model?.model].filter(value=>typeof value==='string'&&value.trim()).join(' / ')||'Unknown model';
  const modelNames = usage => usage?.models?.length ? usage.models.map(modelName).join(', ') : 'Unknown model';
  const coverage = usage => `${number(usage?.known_cost_sessions)} of ${number(usage?.session_count)} ${usage?.session_count===1?'session':'sessions'} report cost`;
  const usageDescription = usage => {
    if(!usage)return 'Usage unavailable. This companion did not report usage and may need an update.';
    const amount=costAmount(usage);
    const estimate=amount==='Unavailable'?'Estimated USD cost unavailable':`${amount} estimated USD reported by Pi`;
    const qualifiers=coverageLabels(usage).map(value=>` · ${value.toLowerCase()}`).join('');
    return `${estimate} · ${number(usage.total_tokens)} tokens · ${coverage(usage)}${qualifiers}. Not a provider invoice.`;
  };
  const taskUsageDescription = usage => `Task total across all retained managed sessions. ${usageDescription(usage)}`;
  const usageInline = usage => {
    if(!usage)return 'Usage unavailable';
    const cost=compactCost(usage),qualifiers=coverageLabels(usage).map(value=>` · ${escape(value)}`).join('');
    return `${cost==='Unavailable'?'Usage unavailable':`${escape(cost)} estimated`}${qualifiers} · ${escape(number(usage.total_tokens))} tokens · ${escape(modelNames(usage))}`;
  };
  function usagePanel(usage,title='Usage and estimated cost'){
    if(!usage)return `<section class="usage-panel"><h2>${escape(title)}</h2><strong>Usage unavailable</strong><p>This companion did not report usage. Update the companion server to inspect Pi-reported estimates.</p></section>`;
    const models=(usage.models||[]).map(model=>`<div class="usage-model"><span><strong>${escape(modelName(model))}</strong><small>${escape(number(model.total_tokens))} tokens · ${escape(model.usage_records||0)} usage records</small></span><strong class="usage-cost">${escape(compactCost({...usage,cost_usd:model.cost_usd,status:model.status}))}</strong></div>`).join('');
    const warning=usage.status==='partial'||usage.stale?`<p class="usage-warning">⚠ ${usage.stale?'Showing the last reported total; the source is temporarily unreadable.':'Partial coverage: some retained usage or cost records are unavailable.'}</p>`:'';
    const cache=(nonnegative(usage.cache_read_tokens)&&usage.cache_read_tokens>0)||(nonnegative(usage.cache_write_tokens)&&usage.cache_write_tokens>0)?`<p>Cache · ${escape(number(usage.cache_read_tokens))} read · ${escape(number(usage.cache_write_tokens))} write</p>`:'';
    return `<section class="usage-panel" aria-label="${escape(title)}" title="${escape(usageDescription(usage))}"><div class="usage-heading"><h2>${escape(title)}</h2><strong class="usage-total">${escape(compactCost(usage))}</strong></div><p>Pi-reported estimated USD. Not a provider invoice; subscription providers may report $0.00.</p><p><strong>${escape(number(usage.total_tokens))}</strong> total tokens · ${escape(number(usage.input_tokens))} input · ${escape(number(usage.output_tokens))} output</p>${cache}<p>${escape(coverage(usage))}</p>${warning}${models?`<div class="usage-models">${models}</div>`:''}</section>`;
  }
  const sessionKind = session => session?.kind==='advisor'?'Advisor':session?.kind==='coordinator'||(!session?.kind&&session?.role==='first_mate')?'First Mate coordinator':'Worker';
  const selectionText = (selection, full=false) => {
    if(!selection)return '';
    const actual=typeof selection.actual_model==='string'?selection.actual_model.trim():'';
    const requested=typeof selection.requested_model==='string'?selection.requested_model.trim():'';
    const model=value=>{const parts=value.split('/').filter(Boolean);return full?value:(parts[parts.length-1]||value);};
    if(actual){
      const effort=typeof selection.actual_thinking==='string'?selection.actual_thinking.trim():'';
      return `${full?'Actual ':''}${model(actual)}${effort?` · ${effort}`:''}`;
    }
    const effort=typeof selection.requested_thinking==='string'?selection.requested_thinking.trim():'';
    return `Requested ${model(requested||'Pi default')}${effort?` · ${effort}`:''}`;
  };
  const selectionLine = selection => selection ? `<small class="model-selection" title="${escape(selectionText(selection,true))}">◇ ${escape(selectionText(selection))}</small>` : '';
  const base = new URL('../api/v1/first-mate/', location.href).pathname;
  const state = {features:[],selected:new URLSearchParams(location.search).get('feature'),detail:null,tab:'Overview',graph:false,showArchived:false,token:'',drafts:new Map(),pending:new Map(),generation:0,resourceGeneration:0,sessionView:null,refreshSequence:0,appliedRefresh:0,sending:new Set(),lastSignature:'',error:null};
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
      const list=await api(`features${state.showArchived?'?view=all':''}`); if(!current())return;
      state.features=list.features||[];
      if(!state.selected) state.selected=state.features[0]?.id||null;
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
    const row=f=>`<div class="feature-row"><button class="feature ${f.id===state.selected?'selected':''}" data-feature="${escape(f.id)}" aria-pressed="${f.id===state.selected}" aria-label="${escape(`${f.title}, ${f.work_item_id||'Idea'}, status ${label(f.status)}, ${taskUsageDescription(f.usage)}`)}" title="${escape(taskUsageDescription(f.usage))}"><strong>${escape(f.title)}</strong><small class="feature-meta"><span>${escape(f.work_item_id||'Idea')} · ${escape(label(f.status))}</span><span class="compact-cost">${escape(compactCost(f.usage))}</span></small></button><button class="archive-list-action" data-archive-feature="${escape(f.id)}" data-archived="${f.archived_at?'true':'false'}">${f.archived_at?'Unarchive':'Archive'}</button></div>`;
    const active=state.features.filter(f=>!f.archived_at), archived=state.features.filter(f=>f.archived_at);
    $('#features').innerHTML=active.map(row).join('')+(archived.length?`<h3 class="archive-heading">Archived</h3>${archived.map(row).join('')}`:'')||empty('Start a feature','Your ideas and tickets will appear here.');
  }
  function renderDetail(){
    const d=state.detail;if(!d){$('#feature-header').innerHTML=empty(state.selected?'Loading feature':'Your First Mate','Select a feature or start something new.');$('#messages').innerHTML=empty('A clear place to begin','Create a feature. Your First Mate will help shape the plan and delegate each step.');$('#workspace').innerHTML=empty('Your feature workspace','Goals, agents, documents, and the workflow live here.');renderTabs();return;}
    const f=d.feature;
    $('#feature-header').innerHTML=`<h1>${escape(f.title)}</h1><p>Your First Mate · one conversation for this feature${f.archived_at?' · Archived':''}</p>${status(f.status)}`;
    const log=$('#messages'), nearBottom=log.scrollHeight-log.scrollTop-log.clientHeight<90;
    log.innerHTML=d.messages.filter(m=>['user','human','assistant'].includes(m.role)).map(m=>`<article class="message ${humanMessage(m)?'user':''}"><span class="avatar" aria-hidden="true">${humanMessage(m)?'You':'FM'}</span><div class="message-main"><div class="message-meta"><strong>${humanMessage(m)?'You':'First Mate'}</strong><time>${escape(date(m.created_at))}</time>${m.status==='queued'?'<small>Queued</small>':''}</div><div class="prose">${messageContent(m)}</div></div></article>`).join('')||empty('Ready for your direction','Tell First Mate what this feature should achieve.');
    if(nearBottom)log.scrollTop=log.scrollHeight;
    $('#chat-status').textContent=['completed','cancelled'].includes(f.status)?'This feature is closed. Its history remains available.':f.status==='awaiting_direction'?'Your move. Describe what should happen next.':f.status==='coordinating'?'First Mate is responding. You can queue your next message.':'Work continues independently. Your First Mate is available.';
    renderTabs();renderWorkspace();
  }
  function renderTabs(){ $('#tabs').innerHTML=['Overview','Agents','Documents','Workflow'].map(tab=>`<button data-tab="${tab}" class="${state.tab===tab?'selected':''}" aria-current="${state.tab===tab?'page':'false'}">${tab}</button>`).join(''); }
  function documentsForVisit(visitId){const d=state.detail,ids=new Set(d.assignments.filter(a=>(a.visit_ids||[a.visit_id]).includes(visitId)).map(a=>a.id));return d.documents.filter(doc=>doc.visit_id===visitId||ids.has(doc.assignment_id));}
  function resources(visit){const d=state.detail,agents=d.assignments.filter(a=>(a.visit_ids||[a.visit_id]).includes(visit.id)),docs=documentsForVisit(visit.id);return `<div class="resources"><button data-resource="agents" data-visit="${escape(visit.id)}" ${agents.length?'':'disabled'}>${agents.length} agents</button><button data-resource="documents" data-visit="${escape(visit.id)}" ${docs.length?'':'disabled'}>${docs.length} documents</button></div>`;}
  function agentRows(agents){return agents.map(a=>{const distinctSubtree=a.subtree_usage&&JSON.stringify(a.subtree_usage)!==JSON.stringify(a.usage);const own=distinctSubtree?`<small>Own · ${usageInline(a.usage)}</small>`:`<small>${usageInline(a.usage)}</small>`;const subtree=distinctSubtree?`<small>With descendants · ${usageInline(a.subtree_usage)}</small>`:'';return `<button class="row" data-agent="${escape(a.id)}"><span><strong>${escape(a.title||a.role)}</strong><small>${escape(a.role)} · Attempt ${escape(a.attempt||1)}</small>${selectionLine(a.model_selection)}${own}${subtree}</span>${status(a.status||a.verdict)}</button>`;}).join('')||empty('No agents yet','Delegated assignments appear here when First Mate starts a stage.');}
  function sessionRows(sessions){return sessions.map(s=>`<button class="row" data-session="${escape(s.native_session_id)}"><span><strong>${escape(sessionKind(s))} · generation ${escape(s.generation||1)}</strong><small>${escape(s.ownership_status||label(s.status))}</small>${selectionLine(s.model_selection)}<small>${usageInline(s.usage)}</small></span>${status(s.status)}</button>`).join('');}
  function docRows(docs){return docs.map(d=>`<button class="row" data-document="${escape(d.id)}"><span><strong>${escape(d.title)}</strong><small>${escape(d.media_type||'Document')} · ${escape(date(d.created_at))}</small></span><span aria-hidden="true">↗</span></button>`).join('')||empty('No documents yet','Plans, evidence, and review reports stay attached to the work that produced them.');}
  function visitCard(v,graph=false){return `<article class="${graph?'node':'visit'} ${escape(v.status)}"><h3>${escape(v.title||label(v.stage_key))}</h3>${status(v.status)}${resources(v)}</article>`;}
  function renderWorkspace(){
    const d=state.detail;if(!d)return;let html='';
    if(state.tab==='Overview'){
      html=`<p class="eyebrow">The goal</p><p class="goal">${escape(d.feature.goal)}</p>${usagePanel(d.feature.usage,'Full task usage')}`;
      if(d.feature.status==='awaiting_direction')html+='<section class="checkpoint"><h3>Ready for your next direction</h3><p>Work is waiting at a human checkpoint. Review the latest request, then tell First Mate how you want to continue.</p></section>';
      html+=`<div class="section-title"><h2>Working on this feature</h2><small>${d.assignments.length} assignments</small></div>${agentRows([...d.assignments.filter(a=>['running','queued','dispatching','handoff_pending'].includes(a.status)),...d.assignments.filter(a=>!['running','queued','dispatching','handoff_pending'].includes(a.status)).slice(-4)].slice(0,4))}`;
      html+='<div class="section-title"><h2>Feature journal</h2></div>'+d.events.slice(-12).reverse().map(e=>`<article class="event"><time>${escape(date(e.created_at))}</time>${escape(e.summary||label(e.type))}</article>`).join('');
      html+=`<div class="controls"><button data-action-feature="${escape(d.feature.id)}" data-action="${d.feature.status==='paused'?'resume':'pause'}" ${['completed','cancelled'].includes(d.feature.status)?'disabled':''}>${d.feature.status==='paused'?'Resume authorized work':'Pause work'}</button><button data-action-feature="${escape(d.feature.id)}" data-action="cancel" ${['completed','cancelled'].includes(d.feature.status)?'disabled':''}>Cancel feature</button><button data-archive-feature="${escape(d.feature.id)}" data-archived="${d.feature.archived_at?'true':'false'}">${d.feature.archived_at?'Unarchive':'Archive…'}</button></div>`;
    } else if(state.tab==='Agents'){
      const coordinators=d.sessions.filter(s=>s.kind==='coordinator'||(!s.kind&&s.role==='first_mate'));
      const advisors=d.sessions.filter(s=>s.kind==='advisor');
      html='<h2>The crew</h2><p class="eyebrow">Independent sessions, grouped by the work they own.</p>';
      if(coordinators.length)html+=`<div class="section-title"><h3>First Mate coordinator</h3><small>${coordinators.length} saved sessions</small></div>${sessionRows(coordinators)}`;
      if(advisors.length)html+=`<div class="section-title"><h3>Advisors</h3><small>${advisors.length} saved sessions</small></div>${sessionRows(advisors)}`;
      html+=d.visits.map(v=>`<div class="section-title"><h3>${escape(v.title||label(v.stage_key))}</h3></div>${agentRows(d.assignments.filter(a=>(a.visit_ids||[a.visit_id]).includes(v.id)))}`).join('');
      if(d.sessions_truncated)html+='<p class="eyebrow">Showing recent saved sessions. Earlier sessions remain retained on the companion host.</p>';
    }
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
      const content=/^text\/markdown(?:\s*;|$)/i.test(d.media_type||'')?`<div class="markdown document-content">${markdown(d.content)}</div>`:`<div class="literal-text document-content">${escape(d.content)}</div>`;
      modal(d.title,`<div class="document-meta">Produced by ${escape(d.assignment_id||'First Mate')}<br>Session ${escape(d.native_session_id||'Unassigned')}</div>${content}${d.native_session_id?`<button data-session="${escape(d.native_session_id)}">Open producing session</button>`:''}`);
    }catch(e){if(generation===state.generation && resource===state.resourceGeneration)notice(e.message);}
  }
  async function openSession(id, before=null){
    const generation=state.generation, resource=++state.resourceGeneration;
    const previousView=before!==null && state.sessionView?.id===id ? state.sessionView : null;
    const previous=previousView?.messages||[];
    try {
      const query=before===null?'':`?before=${encodeURIComponent(before)}&limit=100`;
      const d=await api(`sessions/${encodeURIComponent(id)}${query}`);
      if(generation!==state.generation || resource!==state.resourceGeneration)return;
      if(d.native_session_id!==id)throw Error('Saved session identity did not match.');
      if(before!==null && d.next_before!=null && (d.next_before<0 || d.next_before>=before))throw Error('Saved session cursor did not advance.');
      const retained=(state.detail?.sessions||[]).find(session=>session.native_session_id===id);
      const messages=[...(d.messages||[]),...previous], usage=d.usage||previousView?.usage||retained?.usage;
      const modelSelection=d.model_selection||previousView?.modelSelection||retained?.model_selection;
      state.sessionView={id,messages,usage,modelSelection};
      const paging=d.total_messages!=null?`<div class="document-meta">${messages.length} of ${escape(d.total_messages)} saved messages</div>`:'';
      const earlier=d.next_before!=null?`<button data-session="${escape(id)}" data-before="${escape(d.next_before)}">Load earlier messages</button>`:'';
      modal('Saved agent session',`<p class="document-meta">${escape(id)}${modelSelection?`<br><span title="${escape(selectionText(modelSelection,true))}">${escape(selectionText(modelSelection,true))}</span>`:''}</p>${usagePanel(usage,'Whole-session usage')}${paging}${earlier}${messages.map(m=>`<article class="event"><strong>${escape(m.role)}</strong><div class="prose">${messageContent(m)}</div></article>`).join('')||empty('No saved messages yet','The exact session is registered, but it has not written a transcript yet.')}`);
    }catch(e){if(generation===state.generation && resource===state.resourceGeneration)notice(e.message);}
  }
  async function openAgent(id){const a=state.detail.assignments.find(a=>a.id===id);const sessions=(state.detail.sessions||[]).filter(s=>s.assignment_id===id);if(!sessions.length&&a?.native_session_id)return openSession(a.native_session_id);const own=a?.subtree_usage&&JSON.stringify(a.subtree_usage)!==JSON.stringify(a.usage)?`<p>Own · ${usageInline(a.usage)}<br>With descendants · ${usageInline(a.subtree_usage)}</p>`:`<p>${usageInline(a?.usage)}</p>`;modal(a?.title||'Assignment',`<p>${escape(label(a?.status))}</p>${own}${sessions.length?sessionRows(sessions):'<p class="document-meta">A saved session will appear after this assignment starts.</p>'}${state.detail.sessions_truncated?'<p>Showing recent session history. Older sessions remain retained on the companion host.</p>':''}`);}
  async function setArchived(feature, archived, reason=null){
    const action=archived?'archive':'unarchive', body={action,request_id:idFor(`${action}:${feature}`,reason||action)};
    if(archived&&reason)body.reason=reason;
    try{
      await api(`features/${encodeURIComponent(feature)}/actions`,body);
      state.pending.delete(`${action}:${feature}`);
      if(archived&&!state.showArchived&&state.selected===feature){state.selected=null;state.detail=null;state.lastSignature='';}
      if($('#dialog').open)$('#dialog').close();
      await refresh();
    }catch(error){notice(error.message);}
  }
  function archiveDialog(feature){
    const record=state.features.find(item=>item.id===feature)||state.detail?.feature;
    if(record?.archived_at){setArchived(feature,false);return;}
    const continues=['running','coordinating','recovering'].includes(record?.status);
    modal('Archive feature',`<form id="archive-feature"><p>${continues?'Work continues after archiving. ':''}The feature leaves the active list. Visits, assignments, documents, sessions, events, status, and Active Work linkage are retained.</p><label for="archive-reason">Optional reason</label><select id="archive-reason"><option value="">No reason</option><option value="test/synthetic">Test/synthetic</option><option value="duplicate">Duplicate</option><option value="no longer relevant">No longer relevant</option><option value="superseded">Superseded</option><option value="other">Other</option></select><button class="primary" type="submit">Archive</button></form>`);
    $('#archive-feature').onsubmit=e=>{e.preventDefault();setArchived(feature,true,$('#archive-reason').value||null);};
  }
  document.addEventListener('click',async e=>{
    const b=e.target.closest('button');if(!b)return;
    if(b.dataset.feature){selectFeature(b.dataset.feature);await refresh();}
    if(b.dataset.tab){state.tab=b.dataset.tab;renderTabs();renderWorkspace();}
    if(b.dataset.view){state.graph=b.dataset.view==='graph';renderWorkspace();}
    if(b.dataset.resource)picker(b.dataset.resource,b.dataset.visit);
    if(b.dataset.agent)await openAgent(b.dataset.agent);
    if(b.dataset.document)await openDocument(b.dataset.document);
    if(b.dataset.session){b.disabled=true;try{await openSession(b.dataset.session,b.dataset.before===undefined?null:Number(b.dataset.before));}finally{b.disabled=false;}}
    if(b.dataset.archiveFeature)archiveDialog(b.dataset.archiveFeature);
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
  $('#show-archived').onchange=e=>{state.showArchived=e.target.checked;state.generation++;refresh();};
  $('#dialog').addEventListener('close',()=>{state.resourceGeneration++;});
  function theme(value){document.documentElement.dataset.theme=value;$('#theme').textContent=value==='dark'?'Light mode':'Dark mode';try{localStorage.setItem('herdr-first-mate-theme',value);}catch{}}
  $('#theme').onclick=()=>theme(document.documentElement.dataset.theme==='dark'?'light':'dark');
  let saved;try{saved=localStorage.getItem('herdr-first-mate-theme');}catch{}theme(new URLSearchParams(location.search).get('theme')||saved||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light'));
  renderTabs();updateComposer();refresh();let polling=false;setInterval(async()=>{if(document.hidden||polling)return;polling=true;try{await refresh();}finally{polling=false;}},2500);
})();
