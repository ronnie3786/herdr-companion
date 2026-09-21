const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const script = fs.readFileSync(path.join(__dirname, '../herdr_harness/static/first-mate/app.js'), 'utf8');
const feature = id => ({ id, title: `Synthetic feature ${id}`, goal: 'A synthetic goal', status: 'running', revision: 1 });
const detail = id => ({ ok: true, feature: feature(id), visits: [], assignments: [], documents: [], messages: [], events: [], sessions: [] });
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
    async reply(suffix, body, method = 'GET') {
      const request = requests.find(r => !r.resolved && r.url.endsWith(suffix) && r.options.method === method);
      assert.ok(request, `Expected pending ${method} ${suffix}`);
      request.respond(body);
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
  await app.refresh('c', ['a', 'b', 'c']);
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
