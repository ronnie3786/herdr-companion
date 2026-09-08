const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '../herdr_harness/static/board.html'), 'utf8');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1].split('      // Boot\n')[0];
function board({ demo = true, elements = {} } = {}) {
  const context = vm.createContext({
    URLSearchParams, URL, console,
    window: {}, location: { search: demo ? '?demo=1' : '', origin: 'https://example.test' },
    document: { addEventListener() {}, getElementById(id) { return elements[id] || (['runs','graph','minimap'].includes(id) ? {addEventListener(){}} : null); }, documentElement: { dataset: { theme: 'dark' } } },
    localStorage: { getItem() { return null; }, setItem() {} },
    setTimeout() {}, clearTimeout() {},
  });
  vm.runInContext(script, context);
  return { run: (source) => vm.runInContext(source, context), context };
}
const synthetic = `({id:'item-example',key:'TASK-101',title:'Example feature',revision:7,current_stage_key:'build',lifecycle:'active',stages:{build:{stage_key:'build',title:'Build',phase_key:'work',sequence:0,next:['review'],state:'active'},review:{stage_key:'review',title:'Review',phase_key:'work',sequence:1,next:['build','done'],state:'pending',checkpoint_kind:'human'},done:{stage_key:'done',title:'Done',phase_key:'work',sequence:2,next:[],state:'pending'}},path:{mode:'dynamic',visits:[]}})`;

test('demo steps infer successor edges and do not offer completion at implementation', () => {
  const { run } = board();
  assert.equal(run(`ticketStages(itemByKey('DEMO-101')).find(stage => stage.stage_key === 'implement').next[0]`), 'architect-code-review');
  assert.match(run(`pathTicketHtml(itemByKey('DEMO-101'))`), /Move to Agent review/);
  assert.doesNotMatch(run(`pathTicketHtml(itemByKey('DEMO-101'))`), />Complete ticket</);
});

test('ticket definitions preserve explicit terminal edges independently of the template', () => {
  const { run } = board();
  run(`globalThis.item = ${synthetic}`);
  assert.equal(run(`ticketStages(item).length`), 3);
  assert.equal(run(`ticketStages(item)[2].next.length`), 0);
  assert.equal(run(`ticketStages(item)[0].title`), 'Build');
  assert.match(run('pathTicketHtml(item)'), /Return to Build/);
});

test('inserting a step preserves outgoing branches and does not change the original ticket', () => {
  const { run } = board();
  run(`globalThis.item = ${synthetic}; globalThis.draft = draftStages(item); insertPathStep(draft,1);`);
  assert.equal(run(`draft[1].next.join(',')`), 'step-1');
  assert.equal(run(`draft[2].next.join(',')`), 'build,done');
  assert.equal(run(`item.stages.review.next.join(',')`), 'build,done');
});

test('removing an unused detour reconnects its predecessors and leaves no dangling edges', () => {
  const { run } = board();
  run(`globalThis.item = ${synthetic}; globalThis.draft = draftStages(item); insertPathStep(draft,1); removePathStep(draft,'step-1');`);
  assert.equal(run(`draft.map(stage => stage.key).join(',')`), 'build,review,done');
  assert.equal(run(`draft[1].next.join(',')`), 'build,done');
});

test('current steps, visited steps, and evidence cannot be removed in the editor', () => {
  const { run } = board();
  run(`globalThis.item = ${synthetic}; item.path.visits = [{stage_key:'review'}];`);
  assert.equal(run(`pathStepCanRemove(item,'build')`), false);
  assert.equal(run(`pathStepCanRemove(item,'review')`), false);
  assert.equal(run(`pathStepCanRemove(item,'done')`), true);
  run(`item.stages.done.documents = [{id:'proof',title:'Synthetic proof'}]`);
  assert.equal(run(`pathStepCanRemove(item,'done')`), false);
});

test('human checkpoints keep forward actions disabled while exposing explicit rework', () => {
  const { run } = board();
  run(`globalThis.item = ${synthetic}; item.current_stage_key='review'; item.stages.review.checkpoint_state='pending'; item.path.visits=[{stage_key:'build'}];`);
  const rendered = run('pathTicketHtml(item)');
  assert.match(rendered, /data-path-action="approve"/);
  assert.match(rendered, /data-stage="done" disabled/);
  assert.match(rendered, /data-stage="build">Return to Build/);
});

test('revision conflicts preserve the path draft, disable save, and never retry the mutation', async () => {
  const elements = { 'path-editor-save': {}, 'path-editor-error': {}, 'path-editor-reload': { hidden: true } };
  const { run } = board({ demo: false, elements });
  run(`globalThis.item = ${synthetic}; WORK_ITEMS=[item]; pathDraft={itemKey:item.key,revision:7,note:'Add a regression check',stages:draftStages(item)}; globalThis.requests=0; globalThis.reloads=0; apiFetch=async()=>{requests++;throw Object.assign(new Error('stale'),{status:409,body:{error:{code:'active_work_revision_conflict'}}});}; loadBoard=async()=>{reloads++;};`);
  await run(`saveTicketPath({preventDefault(){}})`);
  assert.equal(run('requests'), 1);
  assert.equal(run('reloads'), 1);
  assert.equal(run('pathDraft.note'), 'Add a regression check');
  assert.equal(run('pathDraft.revision'), 7);
  assert.equal(run('pathDraft.conflict'), true);
  assert.equal(elements['path-editor-save'].disabled, true);
  assert.equal(elements['path-editor-reload'].hidden, false);
  assert.match(elements['path-editor-error'].textContent, /draft is still here/);
  await run(`saveTicketPath({preventDefault(){}})`);
  assert.equal(run('requests'), 1);
});

test('validation failures preserve editable draft and display the actual error', async () => {
  const elements = { 'path-editor-save': {}, 'path-editor-error': {} };
  const { run } = board({ demo: false, elements });
  run(`globalThis.item = ${synthetic}; WORK_ITEMS=[item]; pathDraft={itemKey:item.key,revision:7,note:'Review detour',stages:draftStages(item)}; apiFetch=async()=>{throw Object.assign(new Error('A visited step must remain in the path'),{status:409,body:{error:{code:'active_work_path_history_conflict'}}});};`);
  await run(`saveTicketPath({preventDefault(){}})`);
  assert.equal(elements['path-editor-save'].disabled, false);
  assert.equal(elements['path-editor-error'].textContent, 'A visited step must remain in the path');
  assert.equal(run('pathDraft.stages.length'), 3);
});

test('visit history keeps the stage evidence summary separate from the route decision', () => {
  const { run } = board();
  run(`globalThis.item = ${synthetic}; item.path.visits = [{stage_key:'build',entered_at:'2026-01-01T12:00:00Z',outcome:'rework',summary:'Synthetic validation failed',transition_note:'Return to planning for a revised approach'}];`);
  const rendered = run('pathTicketHtml(item)');
  assert.match(rendered, /Synthetic validation failed/);
  assert.match(rendered, /Decision: Return to planning for a revised approach/);
});

test('display order does not bypass human approval for an unvisited earlier step', () => {
  const { run } = board();
  run(`globalThis.item = ${synthetic}; item.current_stage_key='review'; item.stages.review.checkpoint_state='pending';`);
  assert.match(run('pathTicketHtml(item)'), /data-stage="build" disabled/);
});

test('empty board renders without a previously mounted ticket view', () => {
  const elements = { graph: { addEventListener() {}, querySelector() { return null; }, querySelectorAll() { return []; } } };
  const { run } = board({ demo: false, elements });
  run('renderTicketPaths()');
  assert.match(elements.graph.innerHTML, /Ticket paths/);
  assert.match(elements.graph.innerHTML, /No tickets in this view/);
});

test('a second checkpoint pass requires approval before proceeding to a previously visited onward step', () => {
  const { run } = board();
  run(`globalThis.item = ${synthetic}; item.current_stage_key='review'; item.stages.review.checkpoint_state='pending'; item.path.visits=['build','review','done','build','review'].map(stage_key=>({stage_key}));`);
  assert.equal(run(`ticketRouteIsReturn(item,'build')`), true);
  assert.equal(run(`ticketRouteIsReturn(item,'done')`), false);
  const rendered = run('pathTicketHtml(item)');
  assert.match(rendered, /data-stage="done" disabled/);
  assert.match(rendered, /data-stage="build">Return to Build/);
  run(`item.stages.review.checkpoint_state='approved'`);
  assert.match(run('pathTicketHtml(item)'), /data-stage="done">Move to Done/);
});

test('server next options keep blocked routes visible and do not mistake zero allowed routes for completion', () => {
  const { run } = board();
  run(`globalThis.item = ${synthetic}; item.path.available_next=[]; item.path.next_options=[{stage_key:'review',returning:false,allowed:false,reason:'Approve the current checkpoint before continuing'}];`);
  const rendered = run('pathTicketHtml(item)');
  assert.match(rendered, /data-stage="review" disabled/);
  assert.doesNotMatch(rendered, />Complete ticket</);
});

test('server ancestry and return targets take priority over all historical visits and display order', () => {
  const { run } = board();
  run(`globalThis.item = ${synthetic}; item.current_stage_key='review'; item.path.visits=['build','review','done','build','review'].map(stage_key=>({stage_key})); item.path.ancestry=['build','review']; item.path.return_targets=['build'];`);
  assert.equal(run(`ticketRouteIsReturn(item,'done')`), false);
  assert.equal(run(`ticketRouteIsReturn(item,'build')`), true);
  run(`item.path.next_options=[{stage_key:'build',returning:false,allowed:false,reason:'Route needs approval'}]`);
  assert.equal(run(`ticketRouteIsReturn(item,'build')`), false);
});

function reviewBoard() {
  const result = board({ demo: false });
  result.run(`globalThis.item={id:'review-example',key:'TASK-201',title:'Synthetic PR review',revision:7,current_stage_key:'queued',metadata:{pr:{number:42,url:'https://example.test/pr/42'}},stages:{queued:{stage_key:'queued',sequence:0,phase_key:'queue',title:'Assess PR',checkpoint_kind:'human',checkpoint_state:'pending',next:['ios-review','complete']},'ios-review':{stage_key:'ios-review',sequence:1,phase_key:'review',title:'iOS review',skill_name:'ios-review-remote-pr',checkpoint_kind:'none',next:['complete'],pi_sessions:[]},complete:{stage_key:'complete',sequence:2,phase_key:'outputs',title:'Outputs',checkpoint_kind:'none',next:[]}}}; WORK_ITEMS=[item]; globalThis.requests=[]; globalThis.spawns=[]; globalThis.notices=[]; closeOverlay=()=>{}; loadBoard=async()=>{}; toast=(message)=>notices.push(message); document.querySelectorAll=()=>[{dataset:{stage:'ios-review',skill:'ios-review-remote-pr'}}]; HerdrBridge.send=(type,payload)=>{spawns.push({type,...payload});return true;};`);
  return result;
}

for (const failureAt of [1, 2]) {
  test(`review chooser does not spawn when ${failureAt === 1 ? 'checkpoint approval' : 'choice persistence'} fails`, async () => {
    const { run } = reviewBoard();
    run(`apiFetch=async(path,options)=>{requests.push({path,...JSON.parse(options.body)});if(requests.length===${failureAt})throw new Error('Synthetic write failed');return {item:{...item,revision:8,stages:Object.values(item.stages)}};};`);
    await run(`startChosenReviews(item.key)`);
    assert.equal(run('requests.length'), failureAt);
    assert.equal(run('spawns.length'), 0);
    assert.equal(run('notices.join()'), 'Synthetic write failed');
  });
}

test('review chooser uses returned revisions and raw stage records even when the board remains stale', async () => {
  const { run } = reviewBoard();
  run(`apiFetch=async(path,options)=>{requests.push({path,...JSON.parse(options.body)});return {item:{...item,title:'Returned PR title',revision:7+requests.length,stages:Object.values(item.stages)}};};`);
  await run(`startChosenReviews(item.key)`);
  assert.equal(run('requests.map(request=>request.expected_revision).join()'), '7,8');
  assert.equal(run('WORK_ITEMS[0].revision'), 7);
  assert.equal(run('spawns.length'), 1);
  assert.equal(run('spawns[0].title'), 'Returned PR title');
  assert.equal(run('spawns[0].stageKey'), 'ios-review');
});

test('Mark handled approves the current checkpoint before moving with the returned revision', async () => {
  const { run } = reviewBoard();
  run(`apiFetch=async(path,options)=>{requests.push({path,...JSON.parse(options.body)});return {item:{...item,revision:7+requests.length,stages:Object.values(item.stages)}};};`);
  await run(`markPrHandled(item.key)`);
  assert.equal(run('requests.map(request=>request.to_stage_key).join()'), 'queued,complete');
  assert.equal(run('requests[0].checkpoint_state'), 'approved');
  assert.equal(run('requests.map(request=>request.expected_revision).join()'), '7,8');
  assert.equal(run('notices.join()'), 'Moved to Outputs');
});

for (const failureAt of [1, 2]) {
  test(`Mark handled stops without a success notice when mutation ${failureAt} fails`, async () => {
    const { run } = reviewBoard();
    run(`apiFetch=async(path,options)=>{requests.push({path,...JSON.parse(options.body)});if(requests.length===${failureAt})throw new Error('Synthetic write failed');return {item:{...item,revision:8,stages:Object.values(item.stages)}};};`);
    await run(`markPrHandled(item.key)`);
    assert.equal(run('requests.length'), failureAt);
    assert.equal(run('notices.join()'), 'Synthetic write failed');
  });
}

test('Mark handled keeps an already approved checkpoint and directly moves onward', async () => {
  const { run } = reviewBoard();
  run(`item.stages.queued.checkpoint_state='approved';apiFetch=async(path,options)=>{requests.push({path,...JSON.parse(options.body)});return {item:{...item,revision:8,stages:Object.values(item.stages)}};};`);
  await run(`markPrHandled(item.key)`);
  assert.equal(run('requests.length'), 1);
  assert.equal(run('requests[0].to_stage_key'), 'complete');
  assert.equal(run('requests[0].expected_revision'), 7);
});
