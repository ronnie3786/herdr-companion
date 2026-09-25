const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const script = fs.readFileSync(path.join(__dirname, '../herdr_harness/static/first-mate/app.js'), 'utf8');
const feature = id => ({ id, title: `Synthetic feature ${id}`, goal: 'A synthetic goal', status: 'running', revision: 1 });
const detail = id => ({ ok: true, feature: feature(id), visits: [], assignments: [], documents: [], messages: [], events: [], sessions: [] });
const usage = (overrides = {}) => ({
  currency: 'USD', cost_usd: 1.25, status: 'complete', input_tokens: 100, output_tokens: 20,
  cache_read_tokens: 30, cache_write_tokens: 0, total_tokens: 150, usage_records: 2,
  missing_cost_records: 0, session_count: 1, known_cost_sessions: 1,
  models: [{ provider: 'synthetic', model: 'sample-model', cost_usd: 1.25, status: 'complete',
    input_tokens: 100, output_tokens: 20, cache_read_tokens: 30, cache_write_tokens: 0,
    total_tokens: 150, usage_records: 2, missing_cost_records: 0 }],
  updated_at: '2026-09-21T20:00:00Z', ...overrides,
});
const flush = () => new Promise(resolve => setImmediate(resolve));

// Run the production IIFE unchanged. Tests enter through its actual event
// handlers and resolve network requests in deliberately adversarial orders.
function inspector() {
  const elements = new Map();
  const listeners = new Map();
  const requests = [];
  const intervals = [];
  let nextID = 0;
  function element(selector) {
    if (!elements.has(selector)) {
      const handlers = new Map();
      elements.set(selector, {
        innerHTML: '', textContent: '', value: '', disabled: false, hidden: false,
        open: false, dataset: {}, scrollHeight: 500, scrollTop: 400, clientHeight: 100,
        addEventListener(name, handler) { handlers.set(name, handler); },
        emit(name, event = {}) { return handlers.get(name)?.({ preventDefault() {}, ...event }); },
        showModal() { this.open = true; },
        close() { this.open = false; this.emit('close'); },
        focus() {}, requestSubmit() { return this.emit('submit'); },
      });
    }
    return elements.get(selector);
  }
  const context = vm.createContext({
    URL, URLSearchParams, console,
    location: { href: 'https://example.test/first-mate/', search: '?feature=a' },
    document: {
      querySelector: element, hidden: false, documentElement: { dataset: {} },
      addEventListener(name, handler) { listeners.set(name, handler); },
    },
    fetch(url, options) {
      return new Promise(resolve => requests.push({
        url, options, resolved: false,
        respond(body, status = 200) { this.resolved = true; resolve({ ok: status < 400, status, json: async () => body }); },
      }));
    },
    crypto: { randomUUID: () => `synthetic-request-${++nextID}` },
    localStorage: { getItem() { return null; }, setItem() {} },
    matchMedia: () => ({ matches: false }), confirm: () => true,
    setTimeout() {}, clearTimeout() {}, setInterval(callback) { intervals.push(callback); },
  });
  vm.runInContext(script, context);
  return {
    element, requests,
    click(dataset) { return listeners.get('click')({ target: { closest: () => ({ dataset }) } }); },
    submit() { return element('#composer').emit('submit'); },
    poll() { return intervals[0](); },
    async reply(suffix, body, method = 'GET', status = 200) {
      const request = requests.find(r => !r.resolved && r.url.endsWith(suffix) && r.options.method === method);
      assert.ok(request, `Expected pending ${method} ${suffix}`);
      request.respond(body, status);
      await flush();
      return request;
    },
    async refresh(id, ids = ['a', 'b']) {
      await this.reply('/features', { ok: true, features: ids.map(feature) });
      await this.reply(`/features/${id}`, detail(id));
    },
    async select(id) {
      const selection = this.click({ feature: id });
      await this.refresh(id);
      await selection;
    },
  };
}

test('revised workflow resource menus include carried evidence without rewriting its producer visit', async () => {
  const app = inspector();
  await app.reply('/features', {ok:true,features:[feature('a')]});
  const snapshot = detail('a');
  snapshot.visits = [{id:'revised',title:'Revised implementation',status:'running'}];
  snapshot.assignments = [{id:'carried',visit_id:'original',visit_ids:['original','revised'],title:'Retained review',status:'completed'}];
  snapshot.documents = [{id:'evidence',assignment_id:'carried',visit_id:'original',title:'Original review evidence'}];
  await app.reply('/features/a',snapshot);
  await app.click({tab:'Workflow'});
  assert.match(app.element('#workspace').innerHTML,/1 documents/);
  await app.click({resource:'documents',visit:'revised'});
  assert.match(app.element('#dialog-body').innerHTML,/Original review evidence/);
  assert.equal(snapshot.documents[0].visit_id,'original');
});

test('main chat renders assistant markdown, keeps human text literal, and excludes worker outcomes', async () => {
  const app = inspector();
  await app.reply('/features', {ok:true,features:[feature('a')]});
  const snapshot = detail('a');
  snapshot.messages = [
    {role:'assistant',text:'# Result\n\nUse **care** and `code`.\n\n- One\n- Two\n\n[Safe](https://example.invalid) [Unsafe](javascript:alert(1))\n\n~~~js\nconst safe = true;\n~~~\n\n<script>bad()</script>',status:'delivered'},
    {role:'user',text:'**Keep my markers** <b>literal</b>',status:'queued'},
    {role:'human',text:'_Human alias_ <i>literal</i>',status:'delivered'},
    {role:'system',text:'# Hidden worker outcome'},
    {role:'tool',text:'Hidden raw tool output'},
  ];
  await app.reply('/features/a',snapshot);
  const html = app.element('#messages').innerHTML;
  assert.match(html, /<h1>Result<\/h1>/);
  assert.match(html, /<strong>care<\/strong>/);
  assert.match(html, /<code>code<\/code>/);
  assert.match(html, /<ul><li>One<\/li><li>Two<\/li><\/ul>/);
  assert.match(html, /href="https:\/\/example\.invalid"/);
  assert.match(html, /<pre data-language="js"><code>const safe = true;<\/code><\/pre>/);
  assert.doesNotMatch(html, /href="javascript:/);
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /<div class="literal-text">\*\*Keep my markers\*\* &lt;b&gt;literal&lt;\/b&gt;<\/div>/);
  assert.match(html, /<div class="literal-text">_Human alias_ &lt;i&gt;literal&lt;\/i&gt;<\/div>/);
  assert.equal((html.match(/class="message user"/g)||[]).length, 2);
  assert.equal((html.match(/<strong>You<\/strong>/g)||[]).length, 2);
  assert.doesNotMatch(html, /Hidden worker outcome|Hidden raw tool output/);
  assert.match(html, /<small>Queued<\/small>/);
});

test('retained documents render tables and code without accepting raw HTML', async () => {
  const app = inspector();
  await app.refresh('a');
  const opening = app.click({ document: 'document-a' });
  await app.reply('/documents/document-a', { ok: true, document: {
    id: 'document-a', feature_id: 'a', title: 'Evidence', media_type: 'text/markdown; charset=utf-8',
    content: '| Item | State |\n| --- | --- |\n| Check | **Done** |\n\n```sh\nprintf "safe"\n```\n\n<img src=x onerror=bad()>',
  }});
  await opening;
  const html = app.element('#dialog-body').innerHTML;
  assert.match(html, /class="markdown-table"/);
  assert.match(html, /<th>Item<\/th>/);
  assert.match(html, /<td><strong>Done<\/strong><\/td>/);
  assert.match(html, /<pre data-language="sh"><code>printf &quot;safe&quot;<\/code><\/pre>/);
  assert.doesNotMatch(html, /<img/);
  assert.match(html, /&lt;img src=x onerror=bad\(\)&gt;/);
});

test('non-markdown documents stay literal and deeply nested quotes are bounded', async () => {
  const app = inspector();
  await app.refresh('a');
  let opening = app.click({ document: 'document-a' });
  await app.reply('/documents/document-a', { ok: true, document: {
    id: 'document-a', feature_id: 'a', title: 'Data', media_type: 'application/json',
    content: '{"heading":"# literal","html":"<b>literal</b>"}',
  }});
  await opening;
  let html = app.element('#dialog-body').innerHTML;
  assert.doesNotMatch(html, /class="markdown document-content"/);
  assert.match(html, /&quot;heading&quot;:&quot;# literal&quot;/);
  assert.match(html, /&lt;b&gt;literal&lt;\/b&gt;/);

  const snapshot = detail('b');
  snapshot.messages = [{role:'assistant',text:`${'> '.repeat(30)}Retained tail`}];
  const selection = app.click({feature:'b'});
  await app.reply('/features', {ok:true,features:[feature('a'),feature('b')]});
  await app.reply('/features/b',snapshot);
  await selection;
  html = app.element('#messages').innerHTML;
  assert.match(html, /Retained tail/);
  assert.equal((html.match(/<blockquote>/g)||[]).length, 9);
});

test('saved sessions render assistant markdown and preserve other roles literally', async () => {
  const app = inspector();
  await app.refresh('a');
  const opening = app.click({ session: 'session-a' });
  await app.reply('/sessions/session-a', { ok: true, native_session_id: 'session-a', messages: [
    { role: 'user', text: '*literal request*' },
    { role: 'assistant', text: '> Reviewed\n\n## Answer' },
    { role: 'system', text: '# Retained worker outcome' },
    { role: 'tool', text: '<tool-result>literal</tool-result>' },
  ] });
  await opening;
  const html = app.element('#dialog-body').innerHTML;
  assert.match(html, /<div class="literal-text">\*literal request\*<\/div>/);
  assert.match(html, /<blockquote><p>Reviewed<\/p><\/blockquote>/);
  assert.match(html, /<h2>Answer<\/h2>/);
  assert.match(html, /<div class="literal-text"># Retained worker outcome<\/div>/);
  assert.match(html, /<div class="literal-text">&lt;tool-result&gt;literal&lt;\/tool-result&gt;<\/div>/);
});

test('selecting a feature removes the previous header and action controls before detail arrives', async () => {
  const app = inspector();
  await app.refresh('a');
  assert.match(app.element('#workspace').innerHTML, /data-action-feature="a"/);
  const selection = app.click({ feature: 'b' });
  assert.match(app.element('#feature-header').innerHTML, /Loading feature/);
  assert.doesNotMatch(app.element('#feature-header').innerHTML, /Synthetic feature a/);
  assert.doesNotMatch(app.element('#workspace').innerHTML, /data-action/);
  assert.equal(app.element('#send').disabled, true);
  await app.refresh('b');
  await selection;
  assert.match(app.element('#feature-header').innerHTML, /Synthetic feature b/);
  assert.equal(app.element('#send').disabled, false);
});

test('a stale action button cannot mutate the newly selected feature', async () => {
  const app = inspector();
  await app.refresh('a');
  const selection = app.click({ feature: 'b' });
  await app.click({ action: 'cancel', actionFeature: 'a' });
  assert.equal(app.requests.filter(r => r.options.method === 'POST').length, 0);
  await app.refresh('b');
  await selection;
  await app.click({ action: 'pause', actionFeature: 'a' });
  assert.equal(app.requests.filter(r => r.options.method === 'POST').length, 0);
});

test('a previous feature action acknowledgement refreshes only the current feature', async () => {
  const app = inspector();
  await app.refresh('a');
  const action = app.click({ action: 'pause', actionFeature: 'a' });
  await app.select('b');
  const acknowledged = await app.reply('/features/a/actions', { ok: true, feature: { ...feature('a'), status: 'paused' } }, 'POST');
  assert.equal(JSON.parse(acknowledged.options.body).action, 'pause');
  await app.refresh('b');
  await action;
  assert.match(app.element('#feature-header').innerHTML, /Synthetic feature b/);
  assert.doesNotMatch(app.element('#feature-header').innerHTML, /paused/);
  assert.equal(app.requests.filter(r => r.options.method === 'POST').length, 1);
});

test('creating a feature starts with its own draft and preserves the previous feature draft', async () => {
  const app = inspector();
  await app.refresh('a');
  app.element('#prompt').value = 'An unsent direction for feature a';
  app.element('#new').onclick();
  app.element('#feature-title').value = 'A new synthetic feature';
  app.element('#feature-goal').value = 'A new goal';
  app.element('#feature-cwd').value = '/tmp/synthetic-project';
  const creation = app.element('#new-feature').onsubmit({ preventDefault() {} });
  await app.reply('/features', { ok: true, feature: feature('c') }, 'POST');
  assert.equal(app.element('#prompt').value, '');
  assert.equal(app.element('#dialog').open, false);
  // The create response can become visible through its detail endpoint before
  // the eventually consistent feature list includes it.
  await app.refresh('c', ['a', 'b']);
  await creation;
  app.element('#prompt').value = 'A separate draft for feature c';
  await app.select('a');
  assert.equal(app.element('#prompt').value, 'An unsent direction for feature a');
  await app.select('c');
  assert.equal(app.element('#prompt').value, 'A separate draft for feature c');
});

test('new edits survive a send acknowledgement and polling never unlocks an in-flight send', async () => {
  const app = inspector();
  await app.refresh('a');
  app.element('#prompt').value = 'The original human direction';
  const send = app.submit();
  assert.equal(app.element('#send').disabled, true);
  app.element('#prompt').value = 'Another thought written during delivery';
  const poll = app.poll();
  await app.refresh('a');
  await poll;
  assert.equal(app.element('#send').disabled, true);
  await app.submit();
  assert.equal(app.requests.filter(r => r.options.method === 'POST').length, 1);
  const message = await app.reply('/features/a/messages', { ok: true, feature: feature('a') }, 'POST');
  assert.equal(JSON.parse(message.options.body).text, 'The original human direction');
  assert.equal(app.element('#prompt').value, 'Another thought written during delivery');
  assert.equal(app.element('#send').disabled, true);
  await app.refresh('a');
  await send;
  assert.equal(app.element('#send').disabled, false);
  assert.equal(app.element('#prompt').value, 'Another thought written during delivery');
});

for (const kind of ['document', 'session']) {
  test(`a delayed ${kind} response cannot open over a different selected feature`, async () => {
    const app = inspector();
    await app.refresh('a');
    const opening = app.click({ [kind]: `${kind}-a` });
    await app.select('b');
    const body = kind === 'document'
      ? { ok: true, document: { id: 'document-a', feature_id: 'a', title: 'Old feature evidence', content: 'Synthetic evidence' } }
      : { ok: true, native_session_id: 'session-a', messages: [{ role: 'assistant', text: 'Old feature session' }] };
    await app.reply(`/${kind}s/${kind}-a`, body);
    await opening;
    assert.equal(app.element('#dialog').open, false);
    assert.match(app.element('#feature-header').innerHTML, /Synthetic feature b/);
  });
}

test('closing a resource sheet fences its still-pending document request', async () => {
  const app = inspector();
  await app.refresh('a');
  app.element('#new').onclick();
  const opening = app.click({ document: 'document-a' });
  app.element('#dialog').close();
  await app.reply('/documents/document-a', { ok: true, document: { id: 'document-a', feature_id: 'a', title: 'Evidence', content: 'Synthetic' } });
  await opening;
  assert.equal(app.element('#dialog').open, false);
});

test('saved-session pagination prepends earlier messages and preserves the full transcript', async () => {
  const app = inspector();
  await app.refresh('a');
  const opening = app.click({ session: 'session-a' });
  await app.reply('/sessions/session-a', { ok: true, native_session_id: 'session-a', messages: [{ role: 'assistant', text: 'Latest result' }], next_before: 2, total_messages: 3 });
  await opening;
  assert.match(app.element('#dialog-body').innerHTML, /1 of 3 saved messages/);
  const earlier = app.click({ session: 'session-a', before: '2' });
  await app.reply('/sessions/session-a?before=2&limit=100', { ok: true, native_session_id: 'session-a', messages: [{ role: 'user', text: 'Original direction' }, { role: 'assistant', text: 'Earlier result' }], next_before: null, total_messages: 3 });
  await earlier;
  const html = app.element('#dialog-body').innerHTML;
  assert.match(html, /3 of 3 saved messages/);
  assert.ok(html.indexOf('Original direction') < html.indexOf('Latest result'));
  assert.doesNotMatch(html, /Load earlier messages/);
});

test('an earlier transcript page cannot reopen a session after switching features', async () => {
  const app = inspector();
  await app.refresh('a');
  const opening = app.click({ session: 'session-a' });
  await app.reply('/sessions/session-a', { ok: true, native_session_id: 'session-a', messages: [{ role: 'assistant', text: 'Latest result' }], next_before: 2, total_messages: 3 });
  await opening;
  const earlier = app.click({ session: 'session-a', before: '2' });
  await app.select('b');
  await app.reply('/sessions/session-a?before=2&limit=100', { ok: true, native_session_id: 'session-a', messages: [{ role: 'user', text: 'Original direction' }], next_before: null, total_messages: 3 });
  await earlier;
  assert.equal(app.element('#dialog').open, false);
  assert.match(app.element('#feature-header').innerHTML, /Synthetic feature b/);
});

test('old payloads show usage unavailable rather than inventing zero cost', async () => {
  const app = inspector();
  await app.refresh('a');
  assert.match(app.element('#features').innerHTML, /Unavailable/);
  assert.match(app.element('#workspace').innerHTML, /Usage unavailable/);
  assert.doesNotMatch(app.element('#features').innerHTML, /\$0\.00/);
});

test('task usage uses the server aggregate instead of summing a truncated session list', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [{ ...feature('a'), work_item_id: 'SYN-7', usage: usage({ cost_usd: 9.99, status: 'partial' }) }] });
  const snapshot = detail('a');
  snapshot.feature = { ...snapshot.feature, work_item_id: 'SYN-7', usage: usage({ cost_usd: 9.99, session_count: 1200, known_cost_sessions: 1199, status: 'partial', cache_write_tokens: 7 }) };
  snapshot.sessions_truncated = true;
  snapshot.sessions = [
    { native_session_id: 'coordinator', role: 'first_mate', kind: 'coordinator', usage: usage({ cost_usd: 90 }) },
    { native_session_id: 'advisor', role: 'watchdog', kind: 'advisor', usage: usage({ cost_usd: 80 }) },
  ];
  await app.reply('/features/a', snapshot);
  const sidebar = app.element('#features').innerHTML;
  const overview = app.element('#workspace').innerHTML;
  assert.match(sidebar, /SYN-7/);
  assert.match(sidebar, /\$9\.99\*/);
  assert.match(sidebar, /Task total across all retained managed sessions/);
  assert.match(sidebar, /status running/);
  assert.match(overview, /\$9\.99\*/);
  assert.match(overview, /1,199 of 1,200 sessions report cost/);
  assert.match(overview, /partial coverage/i);
  assert.match(overview, /Cache · 30 read · 7 write/);
  assert.doesNotMatch(overview, /\$170\.00/);
});

test('agent and session usage preserve tiny costs, descendants, models, and advisor roles', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  snapshot.feature.usage = usage({ cost_usd: 0.004 });
  snapshot.visits = [{ id: 'work', title: 'Implementation', status: 'running' }];
  snapshot.assignments = [{ id: 'worker', visit_id: 'work', title: 'Worker', role: 'implementation', status: 'running', usage: usage({ cost_usd: 0.004, status: 'partial' }), subtree_usage: usage({ cost_usd: 0.25, session_count: 2, known_cost_sessions: 2, stale: true }) }];
  snapshot.sessions = [
    { native_session_id: 'coordinator', role: 'first_mate', kind: 'coordinator', status: 'retained', generation: 1, usage: usage() },
    { native_session_id: 'advisor', role: 'watchdog', kind: 'advisor', status: 'retained', generation: 1, usage: usage({ models: [{ ...usage().models[0], provider: '<unsafe>', model: 'advisor-model' }] }) },
  ];
  await app.reply('/features/a', snapshot);
  assert.match(app.element('#workspace').innerHTML, /&lt;\$0\.01/);
  await app.click({ tab: 'Agents' });
  const html = app.element('#workspace').innerHTML;
  assert.match(html, /First Mate coordinator/);
  assert.match(html, /Advisors/);
  assert.match(html, /Own · &lt;\$0\.01\* estimated · Partial/);
  assert.match(html, /With descendants · \$0\.25\* estimated · Last reported/);
  assert.match(html, /&lt;unsafe&gt; \/ advisor-model/);
  assert.doesNotMatch(html, /<unsafe>/);
});

test('agent and saved-session rows distinguish observed routing from requested routing', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  snapshot.visits = [{ id: 'work', title: 'Implementation', status: 'running' }];
  snapshot.assignments = [{
    id: 'worker', visit_id: 'work', title: 'Worker', role: 'implementation', status: 'running',
    model_selection: {
      profile: 'unsafe/<execution>', requested_model: 'synthetic/requested-worker', requested_thinking: 'low',
      actual_model: 'synthetic/observed-worker', actual_thinking: 'high', source: 'host_policy',
    },
  }];
  snapshot.sessions = [{
    native_session_id: 'planner', assignment_id: 'worker', role: 'planner', kind: 'worker', status: 'queued', generation: 1,
    ownership_status: 'queued', model_selection: {
      profile: 'planning', requested_model: 'unsafe/<planner>', requested_thinking: 'xhigh',
      actual_model: null, actual_thinking: 'max', source: 'host_policy',
    },
  }];
  await app.reply('/features/a', snapshot);
  let html = app.element('#workspace').innerHTML;
  assert.match(html, /◇ observed-worker · high/);
  assert.match(html, /title="Profile: unsafe\/&lt;execution&gt; · Requested: synthetic\/requested-worker · low · Actual: synthetic\/observed-worker · high"/);
  assert.doesNotMatch(html, /unsafe\/<execution>/);

  await app.click({ agent: 'worker' });
  html = app.element('#dialog-body').innerHTML;
  assert.match(html, /Profile: unsafe\/&lt;execution&gt; · Requested: synthetic\/requested-worker · low · Actual: synthetic\/observed-worker · high/);
  assert.match(html, /Requested &lt;planner&gt; · xhigh/);
  assert.match(html, /title="Profile: planning · Requested: unsafe\/&lt;planner&gt; · xhigh · Actual: Unavailable — no observed runtime evidence"/);
  assert.doesNotMatch(html, /unsafe\/<planner>/);
});

test('unconfigured architect selections never imply Pi default', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  snapshot.visits = [{ id: 'review', title: 'Architecture review', status: 'running' }];
  snapshot.assignments = [
    {
      id: 'blank-architect', visit_id: 'review', title: 'Blank architect', role: 'architect', status: 'running',
      model_selection: { profile: 'architect', requested_model: '', requested_thinking: 'high', actual_model: null, actual_thinking: null, source: 'host_policy' },
    },
    {
      id: 'whitespace-architect', visit_id: 'review', title: 'Whitespace architect', role: 'architect', status: 'running',
      model_selection: { profile: ' architect ', requested_model: ' \t ', requested_thinking: 'max', actual_model: null, actual_thinking: 'max', source: 'host_policy' },
    },
    {
      id: 'default-planner', visit_id: 'review', title: 'Default planner', role: 'planner', status: 'running',
      model_selection: { profile: 'planning', requested_model: '', requested_thinking: 'xhigh', actual_model: null, actual_thinking: null, source: 'host_policy' },
    },
  ];
  await app.reply('/features/a', snapshot);
  let html = app.element('#workspace').innerHTML;
  assert.equal((html.match(/◇ Not configured/g) || []).length, 2);
  assert.equal((html.match(/Requested Pi default/g) || []).length, 1);
  assert.match(html, /◇ Requested Pi default · xhigh/);
  assert.match(html, /title="Profile: architect · Requested: Not configured · Actual: Unavailable — no observed runtime evidence"/);
  assert.doesNotMatch(html, /Requested Pi default · (?:high|max)/);

  await app.click({ agent: 'whitespace-architect' });
  html = app.element('#dialog-body').innerHTML;
  assert.match(html, /Profile: architect · Requested: Not configured · Actual: Unavailable — no observed runtime evidence/);
  assert.doesNotMatch(html, /Actual: .*max/);
});

test('assignment session detail preserves requested metadata without inventing actual evidence', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  snapshot.visits = [{ id: 'review', title: 'Architecture review', status: 'running' }];
  snapshot.assignments = [{
    id: 'architect', visit_id: 'review', native_session_id: 'architect-session', title: 'Architect', role: 'architect', status: 'running',
    model_selection: { profile: 'architect', requested_model: 'unsafe/<architect>', requested_thinking: 'high', actual_model: null, actual_thinking: 'max', source: 'host_policy' },
  }];
  await app.reply('/features/a', snapshot);
  const opening = app.click({ agent: 'architect' });
  await app.reply('/sessions/architect-session', { ok: true, native_session_id: 'architect-session', messages: [] });
  await opening;
  const html = app.element('#dialog-body').innerHTML;
  assert.match(html, /Profile: architect · Requested: unsafe\/&lt;architect&gt; · high · Actual: Unavailable — no observed runtime evidence/);
  assert.doesNotMatch(html, /Actual: .*max/);
  assert.doesNotMatch(html, /unsafe\/<architect>/);
});

test('saved-session detail prefers response observation and retains it across pagination', async () => {
  const app = inspector();
  const snapshot = detail('a');
  snapshot.sessions = [{
    native_session_id: 'session-a', assignment_id: 'worker', kind: 'worker', status: 'retained', generation: 1,
    model_selection: { profile: 'execution', requested_model: 'synthetic/worker', requested_thinking: 'high', actual_model: null, actual_thinking: null, source: 'host_policy' },
  }];
  await app.reply('/features', { ok: true, features: [feature('a')] });
  await app.reply('/features/a', snapshot);
  const opening = app.click({ session: 'session-a' });
  await app.reply('/sessions/session-a', {
    ok: true, native_session_id: 'session-a', messages: [], next_before: 2, total_messages: 1,
    model_selection: { profile: 'execution', requested_model: 'synthetic/worker', requested_thinking: 'high', actual_model: 'synthetic/clamped-worker', actual_thinking: 'medium', source: 'host_policy' },
  });
  await opening;
  assert.match(app.element('#dialog-body').innerHTML, /Profile: execution · Requested: synthetic\/worker · high · Actual: synthetic\/clamped-worker · medium/);

  const earlier = app.click({ session: 'session-a', before: '2' });
  await app.reply('/sessions/session-a?before=2&limit=100', { ok: true, native_session_id: 'session-a', messages: [], next_before: null, total_messages: 1 });
  await earlier;
  assert.match(app.element('#dialog-body').innerHTML, /Profile: execution · Requested: synthetic\/worker · high · Actual: synthetic\/clamped-worker · medium/);
});

test('old routing payloads omit model labels without affecting usage', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  snapshot.visits = [{ id: 'work', title: 'Implementation', status: 'running' }];
  snapshot.assignments = [{ id: 'worker', visit_id: 'work', title: 'Worker', role: 'implementation', status: 'running', usage: usage({ cost_usd: 0.30 }) }];
  await app.reply('/features/a', snapshot);
  const html = app.element('#workspace').innerHTML;
  assert.doesNotMatch(html, /class="model-selection"/);
  assert.match(html, /\$0\.30 estimated/);
});

test('missing transcript usage falls back only to the exact retained session', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  const currentUsage = usage({ cost_usd: 1, models: [{ ...usage().models[0], cost_usd: 1 }] });
  snapshot.assignments = [{ id: 'worker', native_session_id: 'current', usage: usage({ cost_usd: 9, session_count: 3, known_cost_sessions: 3 }) }];
  snapshot.sessions = [
    { native_session_id: 'current', assignment_id: 'worker', kind: 'worker', usage: currentUsage },
    { native_session_id: 'predecessor', assignment_id: 'worker', kind: 'worker', usage: usage({ cost_usd: 3 }) },
    { native_session_id: 'advisor', assignment_id: 'worker', kind: 'advisor', usage: usage({ cost_usd: 5 }) },
  ];
  await app.reply('/features/a', snapshot);
  const opening = app.click({ session: 'current' });
  await app.reply('/sessions/current', { ok: true, native_session_id: 'current', messages: [] });
  await opening;
  const html = app.element('#dialog-body').innerHTML;
  assert.match(html, /class="usage-total">\$1\.00/);
  assert.doesNotMatch(html, /\$9\.00/);
});

test('additive link fields stay inert for existing document browsing', async () => {
  const app = inspector();
  const snapshot = detail('a');
  snapshot.documents = [{
    id: 'document-a', feature_id: 'a', visit_id: 'visit-a', assignment_id: 'worker',
    title: 'Existing evidence', media_type: 'text/markdown', content_hash: 'synthetic-hash',
    created_at: '2026-09-21T20:00:00Z',
  }];
  snapshot.links = [
    {
      id: 'link-pr', feature_id: 'a', url: 'https://github.com/synthetic-owner/synthetic-repo/pull/4',
      title: 'synthetic-owner/synthetic-repo #4', kind: 'pull_request', source: 'user',
      provenance: {}, title_source: 'user', hidden: false,
      created_at: '2026-09-21T20:00:00Z', updated_at: '2026-09-21T20:00:00Z',
    },
    {
      id: 'link-hidden', feature_id: 'a',
      url: 'http://share.example.test:8443/private/report?token=synthetic#summary',
      title: 'share.example.test', kind: 'link', source: 'discovery',
      provenance: { native_session_id: 'session-a' }, hidden: true,
      created_at: '2026-09-21T20:00:00Z', updated_at: '2026-09-21T20:00:00Z',
    },
  ];
  snapshot.future_additive = { nested: ['values'] };
  snapshot.feature.future_flag = true;
  await app.reply('/features', { ok: true, features: [feature('a')], future_additive: [] });
  await app.reply('/features/a', snapshot);
  await app.click({ tab: 'Documents' });
  const documents = app.element('#workspace').innerHTML;
  assert.match(documents, /Feature documents/);
  assert.match(documents, /data-document="document-a"/);
  assert.doesNotMatch(documents, /github\.com|share\.example\.test/);
  assert.doesNotMatch(documents, /data-link/);
  const opening = app.click({ document: 'document-a' });
  await app.reply('/documents/document-a', {
    ok: true,
    document: { id: 'document-a', feature_id: 'a', title: 'Existing evidence', media_type: 'text/markdown', content: 'Synthetic evidence' },
  });
  await opening;
  assert.match(app.element('#dialog-body').innerHTML, /Synthetic evidence/);
  assert.equal(app.requests.filter(request => request.options.method === 'POST').length, 0);
});

test('whole-session usage is independent of transcript pagination and survives older pages', async () => {
  const app = inspector();
  await app.refresh('a');
  const opening = app.click({ session: 'session-a' });
  await app.reply('/sessions/session-a', { ok: true, native_session_id: 'session-a', messages: [{ role: 'assistant', text: 'Latest result' }], next_before: 2, total_messages: 3, usage: usage({ cost_usd: 0 }) });
  await opening;
  assert.match(app.element('#dialog-body').innerHTML, /\$0\.00/);
  const earlier = app.click({ session: 'session-a', before: '2' });
  await app.reply('/sessions/session-a?before=2&limit=100', { ok: true, native_session_id: 'session-a', messages: [{ role: 'user', text: 'Original direction' }, { role: 'assistant', text: 'Earlier result' }], next_before: null, total_messages: 3 });
  await earlier;
  const html = app.element('#dialog-body').innerHTML;
  assert.match(html, /\$0\.00/);
  assert.match(html, /3 of 3 saved messages/);
  assert.match(html, /Original direction/);
  assert.match(html, /Earlier result/);
  assert.match(html, /Latest result/);
  assert.ok(html.indexOf('Original direction') < html.indexOf('Earlier result'));
  assert.ok(html.indexOf('Earlier result') < html.indexOf('Latest result'));
});

test('overview verification shows the tested revision, exact gate set, and coverage gaps', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const revision = 'a'.repeat(40);
  const snapshot = detail('a');
  snapshot.feature.verification = {
    status: 'partially_verified', label: 'Partially verified', feature_revision: 3,
    assessed_revisions: { ws_synthetic: revision },
    source_revisions: [revision],
    gate_set: [
      { label: 'packages/sample-core/SampleCoordinatorFeatureTest', package: 'packages/sample-core', suite: 'SampleCoordinatorFeatureTest', configuration: '', outcome: 'passed', tested_revision: revision, run_id: 'fmvr_one', fresh: true },
      { label: 'packages/sample-core/SamplePasteDetectorTests (debug)', package: 'packages/sample-core', suite: 'SamplePasteDetectorTests', configuration: 'debug', outcome: 'passed', tested_revision: revision, run_id: 'fmvr_one', fresh: true },
    ],
    missing_suites: [{ label: 'packages/sample-core/SampleAttachmentTests', package: 'packages/sample-core', suite: 'SampleAttachmentTests', reason: 'never run' }],
    previously_green_missing: [{ label: 'packages/sample-composer/SamplePasteDetectorTests (debug)', package: 'packages/sample-composer', suite: 'SamplePasteDetectorTests', configuration: 'debug' }],
    failing_suites: [],
    stale_evidence: [],
    coverage_reasons: ['2 required suites lack a current passing result'],
    evidence_present: true,
    computed_at: '2026-09-24T12:00:00Z',
  };
  await app.reply('/features/a', snapshot);
  const html = app.element('#workspace').innerHTML;
  assert.match(html, /Verification/);
  assert.match(html, /Partially verified/);
  assert.match(html, /Tested revision/);
  assert.match(html, /aaaaaaaaaaaa…/);
  assert.match(html, /Gate set \(2\)/);
  assert.match(html, /SampleCoordinatorFeatureTest/);
  assert.match(html, /SamplePasteDetectorTests \(debug\)/);
  assert.match(html, /Missing suites \(1\)/);
  assert.match(html, /SampleAttachmentTests/);
  assert.match(html, /Previously passing suites dropped from the gate set \(1\)/);
  assert.match(html, /packages\/sample-composer\/SamplePasteDetectorTests \(debug\)/);
  assert.match(html, /Coverage/);
  assert.match(html, /2 required suites lack a current passing result/);
  assert.match(html, /This evidence is separate from the feature's workflow status/);
  // The workflow badge stays exactly as the companion reported it.
  assert.match(app.element('#feature-header').innerHTML, /status running/);
});

test('overview verification escapes untrusted suite and reason labels', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  snapshot.feature.verification = {
    status: 'partially_verified',
    source_revisions: ['<script>bad()</script>'],
    gate_set: [{ label: '<img src=x onerror=bad()>', outcome: 'passed' }],
    missing_suites: [{ label: 'packages/<script>/Suite', configuration: '<b>' }],
    previously_green_missing: [{ label: 'dropped <i>label</i>' }],
    coverage_reasons: ['<script>alert(1)</script>'],
    evidence_present: true,
  };
  await app.reply('/features/a', snapshot);
  const html = app.element('#workspace').innerHTML;
  assert.doesNotMatch(html, /<script>|<img/);
  assert.match(html, /&lt;script&gt;bad/);
  assert.match(html, /&lt;img src=x onerror=bad\(\)&gt;/);
  assert.match(html, /packages\/&lt;script&gt;\/Suite/);
  assert.match(html, /dropped &lt;i&gt;label&lt;\/i&gt;/);
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
});

test('unknown verification status is never presented as verified', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  snapshot.feature.verification = {
    status: 'future_verdict',
    evidence_present: true,
    gate_set: [{ label: 'packages/a/One', outcome: 'passed' }],
  };
  await app.reply('/features/a', snapshot);
  const html = app.element('#workspace').innerHTML;
  assert.match(html, /Verification unavailable/);
  assert.match(html, /unrecognized verification status/);
  assert.doesNotMatch(html, /<strong>Verified<\/strong>/);
  assert.doesNotMatch(html, /verification-panel verified/);
});

test('absent structured evidence shows verification unavailable rather than green', async () => {
  const absent = inspector();
  await absent.refresh('a');
  const absentHtml = absent.element('#workspace').innerHTML;
  assert.match(absentHtml, /Verification unavailable/);
  assert.match(absentHtml, /No structured suite evidence is reported/);
  assert.doesNotMatch(absentHtml, /verification-panel verified/);

  // The additive empty object a legacy companion returns reads the same way.
  const legacy = inspector();
  await legacy.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  snapshot.feature.verification = {};
  await legacy.reply('/features/a', snapshot);
  const legacyHtml = legacy.element('#workspace').innerHTML;
  assert.match(legacyHtml, /Verification unavailable/);
  assert.match(legacyHtml, /No structured suite evidence is reported/);
  assert.doesNotMatch(legacyHtml, /verification-panel verified/);
});

test('long verification gate sets disclose every entry without dropping any', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  const gateSet = Array.from({ length: 9 }, (_, index) => ({
    label: `packages/sample-core/Suite${index}`,
    package: 'packages/sample-core',
    suite: `Suite${index}`,
    outcome: 'passed',
  }));
  snapshot.feature.verification = {
    status: 'verified',
    source_revisions: ['b'.repeat(40)],
    gate_set: gateSet,
    evidence_present: true,
  };
  await app.reply('/features/a', snapshot);
  const html = app.element('#workspace').innerHTML;
  assert.match(html, /Gate set \(9\)/);
  for (let index = 0; index < 9; index += 1) {
    assert.match(html, new RegExp(`Suite${index}\\b`), `missing Suite${index}`);
  }
  assert.match(html, /Show the remaining 5 of 9/);
  assert.match(html, /verification-panel verified/);
  assert.match(html, /Verified/);
});

test('offline cached verification is labeled last reported and clears on reconnect', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  snapshot.feature.verification = {
    status: 'verified',
    source_revisions: ['c'.repeat(40)],
    gate_set: [{ label: 'packages/sample-core/One', outcome: 'passed' }],
    evidence_present: true,
  };
  await app.reply('/features/a', snapshot);
  assert.doesNotMatch(app.element('#workspace').innerHTML, /Last reported/);

  const outage = app.poll();
  await app.reply('/features', { ok: false, error: { message: 'Synthetic outage' } }, 'GET', 503);
  await outage;
  const offline = app.element('#workspace').innerHTML;
  assert.match(offline, /Last reported/);
  assert.match(offline, /Showing the last reported evidence/);
  assert.match(offline, /Verified/);

  const recovery = app.poll();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  await app.reply('/features/a', snapshot);
  await recovery;
  assert.doesNotMatch(app.element('#workspace').innerHTML, /Last reported/);
});

test('a verified verdict without a reported revision says so instead of implying coverage', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  snapshot.feature.verification = {
    status: 'verified',
    gate_set: [{ label: 'packages/sample-core/One', outcome: 'passed' }],
    evidence_present: true,
  };
  await app.reply('/features/a', snapshot);
  const html = app.element('#workspace').innerHTML;
  assert.match(html, /Verification unavailable/);
  assert.match(html, /without the required gate set and tested revision/);
  assert.match(html, /Gate set \(1\)/);
  assert.doesNotMatch(html, /<strong>Verified<\/strong>/);
  assert.doesNotMatch(html, /verification-panel verified/);
});

test('malformed verification fields cannot break the overview or imply coverage', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  snapshot.feature.verification = {
    status: 'verified',
    gate_set: { not: 'a list' },
    source_revisions: 'not-a-list',
    assessed_revisions: 'nope',
  };
  await app.reply('/features/a', snapshot);
  const html = app.element('#workspace').innerHTML;
  assert.match(html, /Verification unavailable/);
  assert.match(html, /without the required gate set and tested revision/);
  assert.doesNotMatch(html, /<strong>Verified<\/strong>/);
  assert.doesNotMatch(html, /verification-panel verified/);
  assert.doesNotMatch(html, /not-a-list/);
});

test('assessed revisions are never relabeled as tested revisions', async () => {
  const app = inspector();
  await app.reply('/features', { ok: true, features: [feature('a')] });
  const snapshot = detail('a');
  const tested = 'a'.repeat(40);
  const assessed = 'b'.repeat(40);
  snapshot.feature.verification = {
    status: 'partially_verified',
    assessed_revisions: { ws_synthetic: assessed },
    source_revisions: [tested],
    gate_set: [{ label: 'packages/sample-core/One', outcome: 'passed', tested_revision: tested }],
    evidence_present: true,
  };
  await app.reply('/features/a', snapshot);
  const html = app.element('#workspace').innerHTML;
  assert.match(html, /Tested revision/);
  assert.match(html, /aaaaaaaaaaaa…/);
  assert.doesNotMatch(html, /bbbbbbbbbbbb…/);
});
