/* First Mate Home — design reference (locked 2026-10-03).
   Seamless window, centred tab bar (Home · PR Review · Watchers · Chats), Spotlight home with My First Mate on the left,
   the "Open First Mate" button under the face, and the slim "Ask First Mate…" bar that pulls up into a chat.
   Prototype only: synthetic data, no network. The moment switch (?m=) resets everything. */
(() => {
  'use strict';
  const { STEPS, DOING, TONE, INSTRUMENTS, CHAT_COLORS, scenarios, byId } = window.DASH;
  const { MOMENTS } = window.HOME;
  const ASSETS = 'assets/watchers/';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const store = {
    get(k) { try { return localStorage.getItem('herdr-home-' + k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem('herdr-home-' + k, v); } catch { /* storage off: fine */ } },
  };
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

  const P = {
    sidebar: '<rect x="3" y="4.5" width="18" height="15" rx="2.6"/><path d="M9.2 4.5v15"/>',
    chevL: '<path d="m14.5 5.5-6.5 6.5 6.5 6.5"/>',
    chevR: '<path d="m9.5 5.5 6.5 6.5-6.5 6.5"/>',
    chevD: '<path d="m6.5 9.5 5.5 5.5 5.5-5.5"/>',
    search: '<circle cx="10.5" cy="10.5" r="6.2"/><path d="m15.2 15.2 4.8 4.8"/>',
    more: '<circle cx="5.5" cy="12" r="1.1" fill="currentColor"/><circle cx="12" cy="12" r="1.1" fill="currentColor"/><circle cx="18.5" cy="12" r="1.1" fill="currentColor"/>',
    sailboat: '<path d="M12 3.5v13"/><path d="M12.6 4.5c3.4 2.6 5.6 6.6 6 11h-6Z"/><path d="M11 7c-2.3 2.2-3.7 5-4.1 8.5H11"/><path d="M3.5 18.5h17l-2.3 2.5H5.8Z"/>',
    pull: '<circle cx="6.5" cy="5.8" r="2.1"/><circle cx="6.5" cy="18.2" r="2.1"/><circle cx="17.5" cy="18.2" r="2.1"/><path d="M6.5 7.9v8.2M17.5 16.1V9.6a3 3 0 0 0-3-3h-3.7"/><path d="m12.6 4.4-2.2 2.2 2.2 2.2"/>',
    eye: '<path d="M2.5 12s3.6-6.3 9.5-6.3 9.5 6.3 9.5 6.3-3.6 6.3-9.5 6.3S2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="2.9"/>',
    bubble: '<path d="M12 4.5c4.7 0 8.5 3 8.5 6.8s-3.8 6.7-8.5 6.7c-1 0-2-.1-2.9-.4L5 19.5l1-3.4c-1.6-1.2-2.5-2.9-2.5-4.8 0-3.8 3.8-6.8 8.5-6.8Z"/>',
    desktop: '<rect x="2.8" y="4" width="18.4" height="12.4" rx="2"/><path d="M12 16.4v3.6M8 20.2h8"/>',
    laptop: '<rect x="4.5" y="5" width="15" height="10.5" rx="1.6"/><path d="M2.5 18.5h19"/>',
    server: '<rect x="3.5" y="4.5" width="17" height="6.5" rx="1.6"/><rect x="3.5" y="13" width="17" height="6.5" rx="1.6"/><path d="M7 7.8h.01M7 16.2h.01"/>',
    phone: '<rect x="7" y="2.8" width="10" height="18.4" rx="2.6"/><path d="M11 18.2h2"/>',
    install: '<path d="M12 4v10.5m-4.2-4.2L12 14.5l4.2-4.2"/><path d="M5 17.5v1.6c0 .8.6 1.4 1.4 1.4h11.2c.8 0 1.4-.6 1.4-1.4v-1.6"/>',
    play: '<path d="M8.2 5.6v12.8L18.5 12Z" fill="currentColor" stroke="none"/>',
    clock: '<circle cx="12" cy="12" r="8.6"/><path d="M12 7.2V12l3.2 2"/>',
    check: '<path d="m5.5 12.5 4 4 9-9.5"/>',
    checkCircle: '<circle cx="12" cy="12" r="8.6"/><path d="m8.2 12.3 2.7 2.7 5-5.4"/>',
    alert: '<path d="M10.4 4.6 2.9 17.8a1.8 1.8 0 0 0 1.6 2.7h15a1.8 1.8 0 0 0 1.6-2.7L13.6 4.6a1.8 1.8 0 0 0-3.2 0Z"/><path d="M12 9.5v4.4M12 17.1v.01"/>',
    bang: '<circle cx="12" cy="12" r="8.6"/><path d="M12 7.6v5.2M12 16.2v.01"/>',
    diamond: '<path d="M12 3.5 20.5 12 12 20.5 3.5 12Z" fill="currentColor" stroke="none"/>',
    half: '<circle cx="12" cy="12" r="7.6"/><path d="M12 4.4a7.6 7.6 0 0 1 0 15.2Z" fill="currentColor" stroke="none"/>',
    ring: '<circle cx="12" cy="12" r="7.6"/>',
    turn: '<path d="M18.5 5.5v5.2a4 4 0 0 1-4 4h-9"/><path d="m9 11-3.5 3.7L9 18.4"/>',
    split: '<rect x="3" y="5" width="18" height="14" rx="2.2"/><path d="M9 5v14M15 5v14"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    close: '<path d="m6.5 6.5 11 11M17.5 6.5l-11 11"/>',
    mic: '<rect x="9" y="3.5" width="6" height="10.5" rx="3"/><path d="M5.8 11.2a6.2 6.2 0 0 0 12.4 0M12 17.4v3.1"/>',
    send: '<path d="M12 18.5v-13m-5.5 5.5L12 5.5l5.5 5.5"/>',
    tray: '<path d="M3.5 13.2 5.8 5.5h12.4l2.3 7.7v5.3H3.5Z"/><path d="M3.5 13.2h4.8l1.4 2.5h4.6l1.4-2.5h4.8"/>',
    disk: '<rect x="3" y="7" width="18" height="10" rx="2.2"/><path d="M7 12h.01M10.5 12h6.5"/>',
    sparkles: '<path d="m11 3.5 1.9 5.1 5.1 1.9-5.1 1.9L11 17.5l-1.9-5.1L4 10.5l5.1-1.9Z"/><path d="M18.5 15v4.5M16.3 17.3h4.5"/>',
    branch: '<circle cx="6.5" cy="5.5" r="2"/><circle cx="6.5" cy="18.5" r="2"/><circle cx="17.5" cy="7.5" r="2"/><path d="M6.5 7.5v9M17.5 9.5c0 4.5-11 2.5-11 7"/>',
    box: '<path d="M3.8 7.6 12 3.4l8.2 4.2v8.8L12 20.6l-8.2-4.2Z"/><path d="M3.8 7.6 12 11.8l8.2-4.2M12 11.8v8.8"/>',
    grid: '<rect x="3.5" y="3.5" width="7" height="7" rx="1.6"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.6"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.6"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.6"/>',
    wave: '<path d="M3 12h3.2l2.3-5.5 4 11 2.6-7.5 1.6 2H21"/>',
    link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2.8v2.6M12 18.6v2.6M21.2 12h-2.6M5.4 12H2.8M18.5 5.5l-1.8 1.8M7.3 16.7l-1.8 1.8M18.5 18.5l-1.8-1.8M7.3 7.3 5.5 5.5"/>',
    sun: '<circle cx="12" cy="12" r="3.8"/><path d="M12 2.8v2.4M12 18.8v2.4M2.8 12h2.4M18.8 12h2.4M5.5 5.5l1.7 1.7M16.8 16.8l1.7 1.7M5.5 18.5l1.7-1.7M16.8 7.2l1.7-1.7"/>',
    keyboard: '<rect x="2.8" y="6" width="18.4" height="12" rx="2"/><path d="M6.5 10h.01M10 10h.01M13.5 10h.01M17 10h.01M7.5 14h9"/>',
    power: '<path d="M12 3.5v8"/><path d="M7.2 6.6a7 7 0 1 0 9.6 0"/>',
  };
  const icon = (name, cls = '') => `<svg class="ic ${cls}" viewBox="0 0 24 24" aria-hidden="true">${P[name] || ''}</svg>`;
  Object.assign(P, {
    popout: '<path d="M13.5 4.5h6v6"/><path d="m19.5 4.5-8 8"/><path d="M18 14v4.2c0 .7-.6 1.3-1.3 1.3H5.8c-.7 0-1.3-.6-1.3-1.3V7.3c0-.7.6-1.3 1.3-1.3H10"/>',
    compose: '<path d="M11 4.5H6.3c-1 0-1.8.8-1.8 1.8v11.4c0 1 .8 1.8 1.8 1.8h11.4c1 0 1.8-.8 1.8-1.8V13"/><path d="m17.8 3.8 2.4 2.4-8 8-3.1.7.7-3.1Z"/>',
    home: '<path d="M4 10.5 12 4l8 6.5V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1Z"/>',
    minimize: '<path d="M6 12h12"/>',
  });

  // ---------- State ----------
  const params = new URLSearchParams(location.search);
  const pick = k => (MOMENTS[k] ? k : null);
  const fresh = () => ({ done: new Set(), snoozed: new Set(), log: [], sent: {}, more: false, recap: false, spot: 0, fm: null, thinking: false,
    place: 'home', focusId: null, chatOpen: false, chatsTab: 'inbox', pop: null, searchOpen: false });
  const state = Object.assign(fresh(), { moment: pick(params.get('m')) || pick(store.get('moment')) || 'morning' });
  if (params.get('fm')) state.fm = params.get('fm');
  if (params.get('chat') === '1') state.chatOpen = true;
  if (params.get('place')) state.place = params.get('place');
  const M = () => MOMENTS[state.moment];
  let W = build(M());

  function build(m) {
    const w = scenarios.busy.build();
    for (const [kind, map] of Object.entries(m.overrides || {})) {
      for (const [id, o] of Object.entries(map)) {
        const target = byId(w[kind], id);
        if (!target) continue;
        for (const [k, v] of Object.entries(o)) { if (v === null) delete target[k]; else target[k] = v; }
      }
    }
    return w;
  }

  // ---------- Vocabulary ----------
  const FM_STATUS = {
    blocked: { label: 'Blocked', c: 'var(--alert)' },
    turn: { label: 'Your turn', c: 'var(--attention)' },
    ready: { label: 'Ready for review', c: 'var(--signal)' },
    working: { label: 'Working', c: 'var(--working)' },
    idle: { label: 'Ready to plan', c: 'var(--idle)' },
    done: { label: 'Complete', c: 'var(--signal)' },
  };
  const TONES = { alert: 'var(--alert)', attention: 'var(--attention)', signal: 'var(--signal)', accent: 'var(--accent)', info: 'var(--brand-blue)', good: 'var(--signal)' };
  const fmWord = f => (f.hud === 'working' && f.step != null ? DOING[f.step] : FM_STATUS[f.hud].label);
  const plural = (n, one, many = one + 's') => `${n} ${n === 1 ? one : many}`;
  const age = m => (m == null ? '' : m < 1 ? 'now' : m < 60 ? `${Math.round(m)}m` : m < 1440 ? `${Math.round(m / 60)}h` : `${Math.round(m / 1440)}d`);
  const feature = id => byId(W.features, id);
  const machine = id => byId(W.machines, id);

  // ---------- Atoms ----------
  const disc = (f, size = 32) => `<span class="disc" style="--s:${size}px" aria-hidden="true">${f.emoji}</span>`;
  const tile = (name, c, size = 32) => `<span class="tile" style="--c:${c};--s:${size}px" aria-hidden="true">${icon(name)}</span>`;
  function critter(w, size = 40) {
    const inst = INSTRUMENTS.includes(w.avatar);
    const resting = w.state === 'paused';
    const flags = [resting ? 'resting' : '', w.attention ? 'flagged' : '', inst ? 'inst' : '', w.offline ? 'offline' : '', w.live ? 'live' : ''].join(' ');
    return `<span class="critter ${flags}" style="--s:${size}px;--tone:${TONE[w.avatar] || '#ABA5F2'}" aria-hidden="true"><img src="${ASSETS}Watcher-${w.avatar}-${resting ? 'resting' : 'idle'}.svg" alt="">${resting ? '<i class="zz">z</i>' : ''}${w.attention ? '<i class="fl">!</i>' : ''}</span>`;
  }
  const deviceIcon = m => (m.device === 'server' ? 'server' : m.device === 'laptop' ? 'laptop' : 'desktop');
  const chatColor = c => (c.color ? CHAT_COLORS[c.color] : 'var(--ink-2)');

  function chip(kind, id, label) {
    const capHTML = (open, lead, name, c, title) => `<button class="cap" data-open="${open}" style="--c:${c}" title="${esc(title)}"><span class="cap-lead">${lead}</span><span class="nm">${esc(name)}</span></button>`;
    if (kind === 'fm') {
      const f = feature(id); if (!f) return esc(label || id);
      return capHTML(`fm:${id}`, `<span class="disc" style="--s:17px">${f.emoji}</span>`, label || f.name, f.offline ? 'var(--idle)' : FM_STATUS[f.hud].c, `${f.name} · ${fmWord(f)} · ${f.now}`);
    }
    if (kind === 'w') {
      const w = byId(W.watchers, id); if (!w) return esc(label || id);
      return capHTML(`route:watchers:${id}`, `<span class="cap-critter">${critter(w, 17)}</span>`, label || w.name, w.attention ? 'var(--alert)' : (TONE[w.avatar] || 'var(--accent)'), `${w.name} · ${w.story}`);
    }
    if (kind === 'm') {
      const m = machine(id); if (!m) return esc(label || id);
      const bad = m.state === 'offline' || m.health === 'storage_full';
      const c = bad ? 'var(--alert)' : m.health === 'storage_low' ? 'var(--attention)' : 'var(--ink-2)';
      const t = m.state === 'offline' ? 'Offline' : m.health === 'storage_full' ? 'Disk full' : m.health === 'storage_low' ? 'Low on disk' : 'Online';
      return capHTML(`route:machines:${id}`, `<span class="cap-ic">${icon(deviceIcon(m))}</span>`, label || m.name, c, `${m.name} · ${t}`);
    }
    if (kind === 'c') {
      const c = byId(W.chats, id); if (!c) return esc(label || id);
      return capHTML(`route:chats:${id}`, `<span class="cap-ic chatdot" style="--cc:${chatColor(c)}"></span>`, label || c.title, chatColor(c), `${c.title} · ${c.ws}`);
    }
    if (kind === 'r') {
      const r = byId(W.reviews, id); if (!r) return esc(label || id);
      return capHTML(`route:reviews:${id}`, `<span class="cap-ic">${icon('pull')}</span>`, label || `#${r.number}`, state.moment === 'trouble' && id === 'r311' ? 'var(--alert)' : 'var(--brand-blue)', `${r.repo} #${r.number} · ${r.title}`);
    }
    if (kind === 'pr') return capHTML(`route:reviews:${id}`, `<span class="cap-ic">${icon('pull')}</span>`, label || `#${id}`, 'var(--brand-blue)', `Pull request #${id}`);
    return esc(label || id);
  }
  const TOKEN = /\{(fm|w|m|c|r|pr):([^}|]+)(?:\|([^}]+))?\}/g;
  function rich(text) {
    let out = '', last = 0;
    String(text).replace(TOKEN, (match, kind, id, label, at) => { out += esc(text.slice(last, at)) + chip(kind, id, label); last = at + match.length; return match; });
    return out + esc(String(text).slice(last));
  }

  // ---------- My First Mate's face ----------
  const MOUTH = {
    calm: 'M-5.5 9.5q5.5 4 11 0', happy: 'M-7 8q7 7.5 14 0', attentive: 'M-4.5 10q4.5 2.6 9 0',
    concerned: 'M-5 11.6q5 -1.8 10 0', thinking: 'M-3.5 10.5h7',
  };
  const TICKS = Array.from({ length: 60 }, (_, i) => {
    const a = i / 60 * Math.PI * 2, r1 = i % 5 ? 51.5 : 50, r2 = 54;
    return `<line x1="${(Math.cos(a) * r1).toFixed(2)}" y1="${(Math.sin(a) * r1).toFixed(2)}" x2="${(Math.cos(a) * r2).toFixed(2)}" y2="${(Math.sin(a) * r2).toFixed(2)}"/>`;
  }).join('');
  function mood() {
    if (state.thinking) return 'thinking';
    if (!liveTop().length && !M().suggestions) return 'happy';
    if (state.moment === 'trouble' && !liveTop().some(t => t.kind === 'machine')) return 'attentive';
    return M().mood;
  }
  function avatar(size, cls = '', act = '') {
    const md = mood();
    return `<button class="fm-av mood-${md} ${cls}" style="--s:${size}px" data-av ${act} title="Talk to My First Mate">
      <svg class="fm-av-ring" viewBox="-60 -60 120 120" aria-hidden="true">
        <circle class="r-glow" r="44"/><g class="r-ticks">${TICKS}</g><circle class="r-outer" r="46"/>
        <g class="r-think"><circle class="a1" r="57"/><circle class="a2" r="59"/></g>
      </svg>
      <span class="fm-av-disc"><svg class="face" viewBox="-24 -24 48 48" aria-hidden="true"><g class="f-look"><g class="f-blink"><rect x="-12.5" y="-10" width="8" height="12" rx="4"/><rect x="4.5" y="-10" width="8" height="12" rx="4"/></g><path class="f-mouth" d="${MOUTH[md]}"/></g></svg></span>
    </button>`;
  }
  const miniFace = (size = 22, md = 'calm') => `<span class="face-orb mini" style="--s:${size}px" aria-hidden="true"><svg class="face" viewBox="-24 -24 48 48"><g class="f-blink"><rect x="-12.5" y="-10" width="8" height="12" rx="4"/><rect x="4.5" y="-10" width="8" height="12" rx="4"/></g><path class="f-mouth" d="${MOUTH[md] || MOUTH.calm}"/></svg></span>`;
  function statusLine() {
    const active = W.features.filter(f => f.hud !== 'done').length;
    return `Keeping an eye on ${plural(active, 'First Mate')}, ${plural(W.watchers.length, 'watcher')} and ${plural(W.machines.length, 'machine')}.`;
  }

  // ---------- What's still on the list ----------
  const live = list => (list || []).filter(x => !state.done.has(x.id) && !state.snoozed.has(x.id));
  const liveTop = () => live(M().top);
  const liveChats = () => live(M().chats);
  const liveNotes = () => live(M().notes);
  const findItem = id => [...(M().top || []), ...(M().chats || []), ...(M().notes || [])].find(x => x.id === id);
  const waitingChat = id => liveChats().some(c => c.ref === id && c.replies);

  function itemOpen(it) {
    if (it.kind === 'fm' || it.kind === 'suggest') return `fm:${it.ref}`;
    if (it.kind === 'pr' || it.kind === 'request') return `route:reviews:${it.pr}`;
    if (it.kind === 'review') return `route:reviews:${it.ref}`;
    if (it.kind === 'machine') return `route:machines:${it.ref}`;
    if (it.kind === 'watcher') return `route:watchers:${it.ref}`;
    return `route:chats:${it.ref}`;
  }
  function itemTitle(it) {
    if (it.title) return it.title;
    if (it.kind === 'fm') return feature(it.ref).name;
    if (it.kind === 'review') { const r = byId(W.reviews, it.ref); return `#${r.number} ${r.title}`; }
    return it.ref;
  }
  function itemAvatar(it, size = 34) {
    if (it.kind === 'fm' || it.kind === 'suggest') return disc(feature(it.ref), size);
    if (it.kind === 'pr') return tile('pull', 'var(--signal)', size);
    if (it.kind === 'review' || it.kind === 'request') return tile('pull', 'var(--brand-blue)', size);
    if (it.kind === 'machine') { const m = machine(it.ref); return tile(m.state === 'offline' ? deviceIcon(m) : 'disk', 'var(--alert)', size); }
    if (it.kind === 'watcher') return critter(byId(W.watchers, it.ref), size);
    return tile('bubble', 'var(--ink-2)', size);
  }
  const why = it => `<span class="why" style="--c:${TONES[it.tone] || 'var(--ink-2)'}">${esc(it.why)}</span>`;
  function acts(it, { compact = false } = {}) {
    const replies = (it.replies || []).map(r => `<button class="reply-chip" data-act="reply" data-item="${it.id}" data-text="${esc(r)}">${esc(r)}</button>`);
    if (it.replies?.length && !compact) replies.push(`<button class="reply-chip ghost" data-open="${it.kind === 'fm' ? `fm:${it.ref}` : `route:chats:${it.ref}`}">Something else…</button>`);
    const buttons = (it.actions || []).map((a, i) => `<button class="btn ${a.primary ? 'primary' : ''}" data-act="action" data-item="${it.id}" data-i="${i}">${esc(a.label)}</button>`);
    const all = [...replies, ...buttons];
    return all.length ? `<div class="acts">${all.join('')}</div>` : '';
  }

  // ---------- Spotlight pieces ----------
  const greet = () => `<h1 class="h-greet">${esc(M().greeting)}</h1>`;
  const when = () => `<div class="h-when">${esc(M().when)}<span class="sep">·</span>${esc(M().away)}</div>`;
  const leadHTML = () => `<p class="b-lead">${M().lead.map((s, i) => `<span class="rv ln" style="--i:${1 + i}">${rich(s)}</span>`).join(' ')}</p>`;
  function bigCard(it) {
    return `<article class="task big nonum first" data-item="${it.id}" style="--tc:${TONES[it.tone] || 'var(--accent)'}">
      <span class="task-av">${itemAvatar(it, 40)}</span>
      <div class="task-main">
        <div class="task-top"><button class="task-title" data-open="${itemOpen(it)}">${esc(itemTitle(it))}</button>${why(it)}<span class="grow"></span>
          <button class="ask-about" data-act="ask-about" data-item="${it.id}" title="Ask First Mate about this">${icon('sparkles')}<span>Ask about this</span></button></div>
        <p class="task-text">${rich(it.text)}</p>
        ${acts(it)}
      </div>
    </article>`;
  }
  function doneCard() {
    const idle = W.features.find(f => f.hud === 'idle');
    const text = M().suggestions ? 'That’s all my ideas for now. Have a good weekend.' : `That’s everything on your list.${idle ? ` When you’re ready, ${rich(`{fm:${idle.id}}`)} is waiting for a plan.` : ''}`;
    return `<div class="done-card">${icon('checkCircle')}<div><b>${M().suggestions ? 'All set.' : 'Nice. You’re clear.'}</b><span>${text}</span></div></div>`;
  }
  function chatCard(it) {
    const c = byId(W.chats, it.ref);
    return `<article class="chat-card" data-item="${it.id}">
      <div class="cc-top"><span class="cc-dot" style="--c:${chatColor(c)}"></span><button class="cc-title" data-open="route:chats:${c.id}">${esc(c.title)}</button></div>
      <div class="cc-meta"><span class="cc-why ${it.replies ? 'wait' : ''}">${esc(it.why)}</span><span class="sep">·</span>${esc(c.ws)} on ${esc(machine(c.machine).name)}</div>
      <p class="cc-quote">“${esc(it.quote)}”</p>
      ${acts(it, { compact: true })}
    </article>`;
  }
  function noteCard(it) {
    const mark = it.who ? critter(byId(W.watchers, it.who), 26) : `<span class="note-ic" style="--c:${TONES[it.tone]}">${icon(it.tone === 'good' ? 'sparkles' : it.tone === 'info' ? 'eye' : 'alert')}</span>`;
    const links = (it.actions || []).map((a, i) => `<button class="note-act ${a.primary ? 'primary' : ''}" data-act="action" data-item="${it.id}" data-i="${i}">${esc(a.label)}</button>`).join('');
    return `<div class="note" data-item="${it.id}" style="--tc:${TONES[it.tone]}"><span class="note-mark">${mark}</span>
      <div class="note-body"><p>${rich(it.text)}</p>${links ? `<div class="note-acts">${links}</div>` : ''}</div></div>`;
  }
  const movingLine = () => `<p class="moving">${icon('sailboat')}<span>${rich(M().moving)}</span></p>`;
  function recapBlock() {
    const r = M().recap;
    return `<details class="recap" ${state.recap ? 'open' : ''} data-recap>
      <summary>${icon('clock')}<span>${esc(M().recapTitle)}</span><span class="recap-n">${plural(r.length, 'update')}</span>${icon('chevD', 'chev')}</summary>
      <ol>${r.map(x => `<li><span class="t">${esc(x.t)}</span><span class="ri" style="--c:${TONES[x.tone] || 'var(--icon)'}">${icon(x.ic)}</span><span>${rich(x.text)}</span></li>`).join('')}</ol>
    </details>`;
  }
  const h2 = (title, n) => `<h2 class="h-sec small">${esc(title)}${n ? `<span class="h-n">${n}</span>` : ''}</h2>`;

  // What First Mate just said, shown beside its face for a few seconds when the chat isn't open.
  const popHTML = () => (state.pop ? `<div class="say-pop" role="status">${state.pop}</div>` : '');

  function spotlight() {
    const top = liveTop();
    const idx = top.length ? state.spot % top.length : 0;
    const cur = top[idx];
    const after = top.slice(idx + 1).concat(top.slice(0, idx)).slice(0, 2);
    const stack = cur ? `<div class="stack" data-depth="${after.length}">
        ${after.map((_, k) => `<div class="stack-ghost g${k + 1}" aria-hidden="true"></div>`).reverse().join('')}
        ${bigCard(cur)}
      </div>
      <div class="stack-nav">
        <span class="stack-count">${top.length === 1 ? 'Just this one' : `${M().suggestions ? 'Idea' : 'Up next'} ${idx + 1} of ${top.length}`}</span>
        ${after.length ? `<span class="stack-then">Then ${after.map(a => `<button class="then" data-act="spot-go" data-item="${a.id}">${esc(itemTitle(a))}</button>`).join(', ')}</span>` : ''}
        <span class="grow"></span>
        ${top.length > 1 ? `<button class="btn ghost" data-act="spot-next">Skip for now ${icon('chevR')}</button>` : ''}
      </div>` : doneCard();
    const chats = liveChats();
    const radar = liveNotes().length ? `<div class="whispers">${liveNotes().map(n => `<div class="whisper">${noteCard(n)}</div>`).join('')}</div>` : '';
    return `<div class="spot"><div class="spot-scroll">
      <div class="spot-stage">
        <div class="spot-left">
          <div class="face-wrap">${avatar(168, '', 'data-act="chat-open"')}${popHTML()}</div>
          <div class="fm-name">My First Mate</div><div class="fm-status">${statusLine()}</div>
          ${fmOpenCard()}
          ${radar}
        </div>
        <div class="spot-right">
          <div class="balloon rv" style="--i:0">${greet()}${when()}${leadHTML()}${movingLine()}</div>
          <div class="rv" style="--i:3">${stack}</div>
          ${chats.length ? `<div class="spot-chats rv" style="--i:4">${h2(M().chatsTitle, chats.length)}<div class="chats">${chats.map(chatCard).join('')}</div></div>` : ''}
          <div class="rv" style="--i:6">${recapBlock()}</div>
        </div>
      </div></div>
      ${state.chatOpen ? '' : askBar()}
    </div>`;
  }

  // ---------- The conversation with My First Mate ----------
  function logHTML() {
    return state.log.map(m => (m.who === 'you'
      ? `<div class="lg you"><span>${esc(m.text)}</span></div>`
      : `<div class="lg fm">${miniFace(24)}<span>${m.html}</span></div>`)).join('')
      + (state.thinking ? `<div class="lg fm">${miniFace(24)}<span class="typing"><span></span><span></span><span></span></span></div>` : '');
  }
  function opener() {
    const n = liveTop().length;
    const ctx = n ? `${plural(n, 'thing needs', 'things need')} you on Home` : M().suggestions ? 'Nothing needs you; I have a few ideas' : 'You’re clear';
    return `<div class="chat-ctx">${icon('home')}<span>${esc(ctx)}</span><span class="sep">·</span><span>${esc(M().when.split('·')[1].trim())}</span></div>
      <div class="lg fm">${miniFace(24)}<span>I can see everything on Home. Ask me about any of it, or tell me what to do: answer a First Mate, prepare a review, clean up a machine.</span></div>`;
  }
  function chatSurface() {
    return `<section class="chat chat-sheet" aria-label="Chat with My First Mate">
      <header class="chat-head">
        ${miniFace(30)}
        <div class="chat-who"><b>My First Mate</b><span>${mood() === 'thinking' ? 'Thinking…' : 'Sees every machine · runs on Work'}</span></div>
        <span class="grow"></span>
        <button class="open-full" data-act="popout" title="Continue in the First Mate window">Open in First Mate${icon('popout')}</button>
        <button class="icon-btn" data-act="chat-close" title="Minimize (esc)">${icon('chevD')}</button>
      </header>
      <div class="chat-body" id="chat-body">${opener()}${logHTML()}</div>
      <div class="chat-suggest">${M().suggest.map(s => `<button class="sg" data-act="suggest" data-text="${esc(s)}">${esc(s)}</button>`).join('')}</div>
      <form class="chat-composer" data-ask>
        <button type="button" class="fw-plus" title="Attach">${icon('plus')}</button>
        <span class="fw-input"><input name="q" autocomplete="off" placeholder="Message My First Mate…" aria-label="Message My First Mate"><button type="button" class="icon-btn" title="Hold to talk">${icon('mic')}</button><button class="send" title="Send">${icon('send')}</button></span>
      </form>
    </section>`;
  }

  // ---------- Places Home links to (existing screens, sketched) ----------
  const VIEWER = { pending: 'Your review', re_review_requested: 'Re-review requested', approved: 'Approved', changes_requested: 'Changes requested', commented: 'Commented', not_reviewed: 'Not reviewed yet' };
  function reviewRows() {
    const failed = id => state.moment === 'trouble' && id === 'r311';
    const rows = W.reviews.map(r => ({ id: r.id, n: r.number, title: r.title, repo: r.repo, who: r.author,
      word: failed(r.id) ? 'Couldn’t prepare' : r.status === 'preparing' ? r.prep : VIEWER[r.viewer],
      c: failed(r.id) ? 'var(--alert)' : r.viewer === 'pending' ? 'var(--attention)' : r.status === 'preparing' ? 'var(--working)' : 'var(--ink-2)',
      sub: failed(r.id) ? 'Not enough space on Dev' : r.walkthrough ? `Walkthrough · ${r.walkthrough.chapters} chapters${r.drafts ? ` · ${plural(r.drafts, 'draft')}` : ''}` : `+${r.add} −${r.del} · ${r.files} files`,
      btn: failed(r.id) ? 'Retry' : r.status === 'preparing' ? null : 'Open', needs: r.viewer === 'pending' || failed(r.id), age: r.age }));
    W.requests.forEach(q => rows.unshift({ id: `q${q.number}`, n: q.number, title: q.title, repo: q.repo, who: q.author, word: 'Requested on GitHub', c: 'var(--attention)', sub: 'No walkthrough yet', btn: 'Prepare', needs: true, age: q.age }));
    return rows;
  }
  function reviewsScreen() {
    const rows = reviewRows();
    const row = r => `<div class="srow ${state.focusId && (state.focusId === r.id || state.focusId === String(r.n)) ? 'focus' : ''}">${tile('pull', 'var(--brand-blue)', 32)}
      <div class="srow-main"><div class="srow-top"><b>${esc(r.title)}</b><span class="st" style="--c:${r.c}">${esc(r.word)}</span></div><div class="srow-sub">${esc(r.repo)} #${r.n} · ${esc(r.who)} · ${esc(r.sub)}</div></div>
      <span class="srow-age">${age(r.age)}</span>${r.btn ? `<button class="btn ${r.needs ? 'primary' : ''}" data-act="toast" data-text="Opens the review for #${r.n}">${r.btn}</button>` : ''}</div>`;
    return screen('pull', 'PR Review', `Review host: Dev · ${plural(rows.length, 'pull request')}`,
      `<div class="sgroup">Waiting on you</div>${rows.filter(r => r.needs).map(row).join('') || '<div class="snone">Nothing waiting on you.</div>'}
       <div class="sgroup">Everything else</div>${rows.filter(r => !r.needs).map(row).join('')}`);
  }
  function watchersScreen() {
    const card = w => `<div class="wcard ${state.focusId === w.id ? 'focus' : ''} ${w.attention ? 'att' : ''}">${critter(w, 44)}
      <div class="wcard-main"><b>${esc(w.name)}</b><p>${esc(w.story)}</p>
      <div class="wcard-last"><span class="udot" style="--c:${w.attention ? 'var(--alert)' : w.live ? 'var(--signal)' : w.state === 'paused' ? 'var(--idle)' : 'var(--ink-2)'}"></span>${esc(w.attention || (w.live ? w.live.label : w.last.text))}</div>
      <div class="wcard-next">${w.state === 'paused' ? 'Paused' : w.live ? 'Running now' : `Next ${esc(w.next)}`} · ${esc(machine(w.machine).name)}</div></div></div>`;
    const order = [...W.watchers].sort((a, b) => (b.attention ? 1 : 0) - (a.attention ? 1 : 0));
    return screen('eye', 'Watchers', `${plural(W.watchers.filter(w => w.state === 'active').length, 'watcher')} on · ${plural(W.machines.length, 'machine')}`, `<div class="wgrid">${order.map(card).join('')}</div>`);
  }
  function chatScreen(id) {
    if (!id) {
      const list = chatList(state.chatsTab);
      return screen('bubble', 'Chats', `${plural(W.chats.length, 'chat')} on ${plural(W.machines.length, 'machine')}`,
        `<div class="ctabs">${chatTabs()}</div><div class="clist big">${list.map(chatRow).join('')}</div>`);
    }
    const c = byId(W.chats, id);
    const waiting = waitingChat(id) ? liveChats().find(x => x.ref === id) : null;
    return `<div class="scr chat-scr"><div class="scr-head"><span class="cc-dot" style="--c:${chatColor(c)}"></span><h1>${esc(c.title)}</h1><span class="scr-sub">${esc(machine(c.machine).name)} · ${esc(c.ws)}</span><span class="scr-note">Existing chat screen, sketched</span></div>
      <div class="chat-skel"><div class="msg you">Can you take a pass at “${esc(c.title)}”? Keep the change small and add a test.</div>
        ${[92, 76, 84, 40, 0, 88, 70].map(w => (w ? `<i style="width:${w}%"></i>` : '<br>')).join('')}
        ${waiting ? `<div class="msg fm"><div class="skim">${esc(waiting.quote)}</div></div>${acts(waiting, { compact: true })}` : ''}</div></div>`;
  }
  const screen = (ic, title, sub, body) => `<div class="scr"><div class="scr-head">${tile(ic, 'var(--accent)', 30)}<h1>${esc(title)}</h1><span class="scr-sub">${esc(sub)}</span><span class="scr-note">Existing screen, sketched</span></div><div class="scr-body">${body}</div></div>`;

  // ---------- Chats list (sidebar, chats column, Chats tab) ----------
  function chatList(tab) {
    const rank = c => (waitingChat(c.id) ? 0 : c.status === 'working' ? 1 : 2);
    const all = [...W.chats];
    if (tab === 'inbox') return all.filter(c => waitingChat(c.id) || c.status === 'working' || c.age < 70).sort((a, b) => rank(a) - rank(b) || a.age - b.age);
    return all.sort((a, b) => a.age - b.age);
  }
  const inboxCount = () => W.chats.filter(c => waitingChat(c.id)).length;
  const chatTabs = () => `<button class="${state.chatsTab === 'inbox' ? 'on' : ''}" data-act="chats-tab" data-tab="inbox">Inbox${inboxCount() ? `<span class="n">${inboxCount()}</span>` : ''}</button><button class="${state.chatsTab === 'recent' ? 'on' : ''}" data-act="chats-tab" data-tab="recent">Recent</button>`;
  function chatRow(c) {
    const wait = waitingChat(c.id);
    const glyph = wait ? `<span class="cg wait">${icon('diamond')}</span>` : c.status === 'working' ? `<span class="cg work">${icon('half')}</span>` : '<span class="cg"></span>';
    return `<button class="crow2 ${state.place === `chat:${c.id}` ? 'on' : ''}" data-place="chat:${c.id}">${glyph}<span class="clabel2" style="--c:${c.color ? CHAT_COLORS[c.color] : 'transparent'}"></span>
      <span class="crow2-main"><b>${esc(c.title)}</b><span>${wait ? '<em>Waiting on you</em> · ' : ''}${esc(machine(c.machine).name)} · ${esc(c.ws)}</span></span><span class="cage">${age(c.age)}</span></button>`;
  }

  // ---------- Status lines for the places ----------
  function placeInfo() {
    const top = liveTop();
    const needsReview = reviewRows().filter(r => r.needs);
    const att = W.watchers.find(w => w.attention);
    const next = W.watchers.filter(w => w.state === 'active' && !w.live && w.nextMin != null && !w.offline).sort((a, b) => a.nextMin - b.nextMin)[0];
    const featuresNeeding = W.features.filter(f => ['blocked', 'turn', 'ready'].includes(f.hud)).length;
    const working = W.features.filter(f => f.hud === 'working').length;
    return {
      home: { sub: top.length ? `${plural(top.length, 'thing needs', 'things need')} you` : M().suggestions ? 'A few ideas for you' : 'You’re clear', badge: top.length && !M().suggestions ? top.length : 0, c: 'var(--attention)' },
      fm: { sub: `${working} working${featuresNeeding ? ` · ${featuresNeeding} need you` : ''}`, badge: 0 },
      reviews: { sub: needsReview.length ? `${needsReview.map(r => `#${r.n}`).slice(0, 2).join(', ')} ${needsReview.some(r => r.word === 'Couldn’t prepare') ? 'need a look' : 'waiting on you'}` : 'Nothing waiting on you', badge: needsReview.length, c: needsReview.some(r => r.word === 'Couldn’t prepare') ? 'var(--alert)' : 'var(--brand-blue)' },
      watchers: { sub: att ? `${att.name} needs a look` : next ? `${next.name} runs ${next.next.startsWith('in') ? next.next : 'later'}` : 'All quiet', badge: att ? '!' : 0, c: 'var(--alert)', att },
      chats: { sub: inboxCount() ? `${plural(inboxCount(), 'chat is', 'chats are')} waiting` : 'Nothing waiting', badge: inboxCount(), c: 'var(--attention)' },
    };
  }
  const badge = (n, c) => (n ? `<span class="pbadge" style="--c:${c}">${n}</span>` : '');

  // ---------- Tab bar: centred where a toolbar would be, with no band or divider ----------
  function tabBar() {
    const I = placeInfo();
    const items = [['home', miniFace(18, mood() === 'thinking' ? 'calm' : mood()), 'Home', I.home, '⌘1'], ['reviews', icon('pull'), 'PR Review', I.reviews, '⌘2'],
      ['watchers', icon('eye'), 'Watchers', I.watchers, '⌘3'], ['chats', icon('bubble'), 'Chats', I.chats, '⌘4']];
    const tabsHTML = items.map(([p, ic, label, info, key]) => {
      const on = state.place === p || (p === 'chats' && state.place.startsWith('chat'));
      return `<button class="tab ${on ? 'on' : ''}" data-place="${p}" title="${esc(info.sub)} · ${key}"><span class="tab-ic">${ic}</span><span class="tab-label">${label}</span>${info.badge ? `<span class="tab-count" style="--c:${info.c}">${info.badge}</span>` : ''}</button>`;
    }).join('');
    return `<nav class="tabbar" aria-label="Places">${tabsHTML}</nav>`;
  }
  // ---------- The First Mate button, under the face ----------
  function fmOpenCard() {
    const I = placeInfo();
    return `<button class="fm-open" data-open="fm:lead" title="Open the First Mate window">${icon('sailboat')}<span class="fm-open-main"><b>Open First Mate</b><span>${esc(I.fm.sub)}</span></span>${icon('popout', 'fm-arrow')}</button>`;
  }
  // ---------- "Ask First Mate…" bar, floating at the bottom of Home ----------
  function askBar() {
    return `<button class="ask-bar" data-act="chat-open">${miniFace(26, mood() === 'thinking' ? 'calm' : mood())}<span>Ask First Mate…</span><kbd>⌘J</kbd></button>`;
  }

  // ---------- The First Mate window (simplified; the real one is a separate window) ----------
  function fmWindow() {
    if (!state.fm) return '';
    const order = ['blocked', 'turn', 'ready', 'working', 'idle', 'done'];
    const list = [...W.features].sort((a, b) => order.indexOf(a.hud) - order.indexOf(b.hud) || a.age - b.age);
    const sel = state.fm === 'lead' ? null : feature(state.fm);
    const rows = list.map(f => `<button class="fw-row ${state.fm === f.id ? 'on' : ''}" data-open="fm:${f.id}"><span class="frow-dot"></span>${disc(f, 34)}
        <span class="fw-row-main"><span class="fw-row-top"><b>${esc(f.name)}</b></span><span class="fw-row-sub"><span class="st" style="--c:${FM_STATUS[f.hud].c}">${esc(fmWord(f))}</span><span>${esc(f.now)}</span></span></span></button>`).join('');
    let head, body, name, extra = '';
    if (!sel) {
      head = `${miniFace(28)}<div class="fw-title"><b>My First Mate</b><span>Work · sees every machine</span></div>`;
      body = `<div class="fw-summary"><div class="fw-summary-label">${icon('home')}From Home</div><p>${esc(M().greeting)} ${M().lead.map(rich).join(' ')}</p></div>${logHTML()}`;
      name = 'My First Mate';
      extra = `<div class="fw-replies">${M().suggest.map(s => `<button class="sg" data-act="suggest" data-text="${esc(s)}">${esc(s)}</button>`).join('')}</div>`;
    } else {
      head = `${disc(sel, 28)}<div class="fw-title"><b>${esc(sel.name)}</b><span><span class="st" style="--c:${FM_STATUS[sel.hud].c}">${esc(fmWord(sel))}</span>${sel.step != null && sel.hud !== 'done' ? `<span class="pill">${STEPS[sel.step]} · step ${sel.step + 1} of 6</span>` : ''}<span class="fw-where">${esc(sel.project)} · ${esc(machine(sel.machine).name)}</span></span></div>`;
      const thread = sel.thread || [{ who: 'fm', text: `${sel.say} ${sel.now}.` }];
      body = thread.map(m => (m.who === 'you' ? `<div class="msg you">${esc(m.text)}</div>` : `<div class="msg fm"><div class="skim">${esc(m.text)}</div></div>`)).join('')
        + (state.sent[sel.id] ? `<div class="msg you">${esc(state.sent[sel.id])}</div><div class="msg fm"><div class="skim">Got it. Back to work.</div></div>` : '');
      name = sel.name;
      const topItem = liveTop().find(t => t.kind === 'fm' && t.ref === sel.id && t.replies);
      if (topItem) extra = `<div class="fw-replies">${topItem.replies.map(r => `<button class="reply-chip" data-act="reply" data-item="${topItem.id}" data-text="${esc(r)}">${esc(r)}</button>`).join('')}</div>`;
    }
    return `<section class="fmwin" role="dialog" aria-label="First Mate window">
      <div class="fw-bar"><div class="lights"><button class="light close" data-act="close-fm" title="Close"></button><i></i><i></i></div><span class="fw-bar-title">First Mate</span><span class="grow"></span><span class="fw-bar-hint">A separate window in the app · <kbd>esc</kbd></span></div>
      <div class="fw-body"><div class="fw-rail"><div class="fw-search">${icon('search')}<span>Search</span></div>
        <button class="fw-row lead ${!sel ? 'on' : ''}" data-open="fm:lead"><span class="frow-dot"></span>${miniFace(34)}<span class="fw-row-main"><span class="fw-row-top"><b>My First Mate</b></span><span class="fw-row-sub"><span>Your assistant</span></span></span></button>
        <div class="fw-label">Conversations</div>${rows}</div>
        <div class="fw-chat"><div class="fw-chat-head">${head}</div><div class="fw-transcript">${body}</div>${extra}
          <form class="fw-composer" data-fw-send><button type="button" class="fw-plus" title="Attach">${icon('plus')}</button><span class="fw-input"><input name="m" autocomplete="off" placeholder="Message ${esc(name)}…" aria-label="Message ${esc(name)}"><button type="button" class="icon-btn" title="Hold to talk">${icon('mic')}</button><button class="send" title="Send">${icon('send')}</button></span></form>
        </div></div>
    </section>`;
  }

  // ---------- Render ----------
  function pane() {
    if (state.place === 'reviews') return reviewsScreen();
    if (state.place === 'watchers') return watchersScreen();
    if (state.place === 'chats') return chatScreen(null);
    if (state.place.startsWith('chat:')) return chatScreen(state.place.slice(5));
    return spotlight();
  }
  function titlebar() {
    return `<div class="lights"><i></i><i></i><i></i></div>${tabBar()}<span class="grow"></span>
      ${state.searchOpen ? `<label class="tb-search">${icon('search')}<input placeholder="Search" aria-label="Search" data-search></label>` : `<button class="icon-btn search-btn" data-act="search" title="Search (⌘F)">${icon('search')}</button>`}`;
  }
  function shell() {
    const sheet = state.chatOpen ? `<div class="scrim" data-act="chat-close"></div><div class="sheet">${chatSurface()}</div>` : '';
    return `<div class="home-shell"><main class="pane">${pane()}${sheet}</main></div>`;
  }
  function render({ keepScroll = true } = {}) {
    const sc = $('.spot-scroll, .scr');
    const scroll = keepScroll && sc ? sc.scrollTop : 0;
    const active = document.activeElement;
    const focused = active?.closest?.('[data-ask]') ? '[data-ask] input' : active?.closest?.('[data-fw-send]') ? '[data-fw-send] input' : null;
    $('#titlebar').innerHTML = titlebar();
    $('#home').innerHTML = shell();
    $('#fm-layer').innerHTML = fmWindow();
    $$('[data-moment]').forEach(b => b.classList.toggle('on', b.dataset.moment === state.moment));
    const s = $('.spot-scroll, .scr'); $('#titlebar').classList.toggle('scrolled', !!s && s.scrollTop > 6);
    if (state.searchOpen) $('[data-search]')?.focus();
    $('#moment-note').textContent = M().note;
    const sc2 = $('.spot-scroll, .scr'); if (sc2) sc2.scrollTop = scroll;
    $$('#chat-body, .fw-transcript').forEach(l => { l.scrollTop = l.scrollHeight; });
    if (focused) $(focused)?.focus();
    $('.srow.focus, .wcard.focus')?.scrollIntoView({ block: 'center' });
  }

  // ---------- Behaviour ----------
  function settle() { document.body.classList.add('revealed'); }
  function speak() {
    if (reduced) return;
    $$('[data-av]').forEach(a => { a.classList.add('speaking'); setTimeout(() => a.classList.remove('speaking'), 1300); });
  }
  let toastTimer, popTimer;
  function toast(text) {
    const t = $('#toast'); t.innerHTML = text; t.hidden = false;
    clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, 2600);
  }
  const chatVisible = () => state.chatOpen || state.fm === 'lead';
  function say(text) {
    const html = rich(text);
    state.log.push({ who: 'fm', html });
    if (!chatVisible() && state.place === 'home') {
      state.pop = html;
      clearTimeout(popTimer); popTimer = setTimeout(() => { state.pop = null; render(); }, 4200);
    }
    render(); speak();
  }
  function leave(id, then) {
    settle();
    const els = $$(`[data-item="${id}"]`);
    if (!els.length || reduced) { then(); return; }
    els.forEach(el => el.classList.add('leaving'));
    setTimeout(then, 240);
  }
  function openChat() {
    settle();
    state.chatOpen = true;
    state.pop = null;
  }
  function ask(text, answer) {
    openChat();
    state.log.push({ who: 'you', text });
    state.thinking = true;
    render();
    setTimeout(() => {
      const hit = answer ? { a: answer } : M().answers.find(a => a.k.test(text));
      state.thinking = false;
      (hit?.resolves || []).forEach(id => state.done.add(id));
      say(hit ? hit.a : 'I’d look into that and answer here. If it needs a longer back-and-forth with a First Mate, I’ll open its conversation.');
    }, reduced ? 200 : 950);
  }
  function reply(it, text) {
    const target = it.kind === 'fm' ? `{fm:${it.ref}}` : `{c:${it.ref}}`;
    if (it.kind === 'fm') state.sent[it.ref] = text;
    leave(it.id, () => { state.done.add(it.id); say(it.ack || `Sent “${text}” to ${target}.`); });
  }
  function action(it, a) {
    switch (a.act) {
      case 'open':
        if (it.kind === 'fm' || it.kind === 'suggest') { state.fm = it.ref; render(); } else navigate(itemOpen(it).slice(6));
        return;
      case 'ask': ask(a.q); return;
      case 'route': navigate(a.route); return;
      case 'snooze': leave(it.id, () => { state.snoozed.add(it.id); say(a.ack || 'Okay, I’ll bring it back later.'); }); return;
      case 'dismiss': leave(it.id, () => { state.done.add(it.id); if (a.ack) say(a.ack); else render(); }); return;
      default: leave(it.id, () => { state.done.add(it.id); say(a.ack || 'Done.'); });
    }
  }
  function navigate(route) {
    settle();
    const [place, id] = route.split(':');
    if (place === 'machines') { toast(`Opens <b>Settings › Machines</b>${id ? ` → ${esc(machine(id)?.name || id)}` : ''}`); return; }
    if (place === 'chats') { state.place = id ? `chat:${id}` : 'chats'; }
    else { state.place = place; state.focusId = id || null; }
    state.chatOpen = false;
    render({ keepScroll: false });
  }
  function setMoment(m) {
    Object.assign(state, fresh(), { moment: m });
    store.set('moment', m);
    const u = new URL(location.href); u.searchParams.set('m', m); history.replaceState(null, '', u);
    W = build(M());
    document.body.classList.remove('revealed');
    render({ keepScroll: false });
    setTimeout(settle, 2600);
  }

  // ---------- Events ----------
  document.addEventListener('click', e => {
    const mo = e.target.closest('[data-moment]');
    if (mo) { setMoment(mo.dataset.moment); return; }
    const pl = e.target.closest('[data-place]');
    if (pl) { settle(); state.place = pl.dataset.place; state.focusId = null; state.chatOpen = false; render({ keepScroll: false }); return; }
    const el = e.target.closest('[data-act], [data-open]');
    if (!el) return;
    if (el.dataset.open) {
      e.preventDefault(); settle();
      const [kind, ...rest] = el.dataset.open.split(':');
      if (kind === 'fm') { state.fm = rest[0]; render(); return; }
      if (kind === 'route') { navigate(rest.join(':')); return; }
      return;
    }
    const it = el.dataset.item ? findItem(el.dataset.item) : null;
    switch (el.dataset.act) {
      case 'reply': reply(it, el.dataset.text); break;
      case 'action': action(it, it.actions[+el.dataset.i]); break;
      case 'suggest': ask(el.dataset.text); break;
      case 'ask-about': ask(`Tell me more about ${itemTitle(it)}.`, `${itemTitle(it)}: ${it.text} I can open its full conversation if you want the details.`); break;
      case 'chat-open': openChat(); render(); setTimeout(() => $('[data-ask] input, [data-fw-send] input')?.focus(), 30); break;
      case 'chat-close': state.chatOpen = false; render(); break;
      case 'popout': state.chatOpen = false; state.fm = 'lead'; render(); toast('Moved to the First Mate window. The conversation comes with you.'); break;
      case 'close-fm': state.fm = null; render(); break;
      case 'spot-next': settle(); state.spot++; render(); break;
      case 'spot-go': { settle(); state.spot = Math.max(0, liveTop().findIndex(t => t.id === it.id)); render(); break; }
      case 'chats-tab': state.chatsTab = el.dataset.tab; render(); break;
      case 'toast': toast(esc(el.dataset.text)); break;
      case 'search': state.searchOpen = true; render(); break;
      default: break;
    }
  });
  // The top strip only gets a soft backdrop once content scrolls under it.
  document.addEventListener('scroll', e => {
    if (e.target.matches?.('.spot-scroll, .scr')) $('#titlebar').classList.toggle('scrolled', e.target.scrollTop > 6);
  }, true);
  document.addEventListener('focusout', e => { if (e.target.matches?.('[data-search]') && !e.target.value) setTimeout(() => { if (!state.searchOpen || document.activeElement?.matches('[data-search]')) return; state.searchOpen = false; render(); }, 120); });
  document.addEventListener('toggle', e => { if (e.target.matches?.('[data-recap]')) state.recap = e.target.open; }, true);
  document.addEventListener('submit', e => {
    e.preventDefault();
    const input = e.target.querySelector('input');
    const text = input.value.trim();
    if (!text) return;
    input.value = '';
    if (e.target.matches('[data-ask]')) { ask(text); return; }
    if (e.target.matches('[data-fw-send]')) {
      if (state.fm === 'lead') { ask(text); return; }
      state.sent[state.fm] = text;
      const t = liveTop().find(x => x.kind === 'fm' && x.ref === state.fm);
      if (t) { state.done.add(t.id); state.log.push({ who: 'fm', html: rich(`You answered {fm:${state.fm}}. It’s back to work.`) }); }
      render();
    }
  });
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && state.searchOpen) { state.searchOpen = false; render(); return; }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); state.searchOpen = true; render(); return; }
    if (e.key === 'Escape') {
      if (state.fm) { state.fm = null; render(); return; }
      if (state.chatOpen) { state.chatOpen = false; render(); return; }
    }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'j') { e.preventDefault(); if (state.chatOpen) state.chatOpen = false; else openChat(); render(); setTimeout(() => $('[data-ask] input, [data-fw-send] input')?.focus(), 30); return; }
    if ((e.metaKey || e.ctrlKey) && ['1', '2', '3', '4'].includes(e.key)) {
      e.preventDefault();
      const p = ['home', 'reviews', 'watchers', 'chats'][+e.key - 1];
      state.place = p;
      state.focusId = null; render({ keepScroll: false });
    }
  });
  document.addEventListener('pointermove', e => {
    if (reduced) return;
    $$('[data-av]').forEach(a => {
      const r = a.getBoundingClientRect();
      const dx = e.clientX - (r.left + r.width / 2), dy = e.clientY - (r.top + r.height / 2);
      const d = Math.hypot(dx, dy) || 1, k = Math.min(1, d / 420);
      a.style.setProperty('--lx', `${(dx / d * 2.6 * k).toFixed(2)}px`);
      a.style.setProperty('--ly', `${(dy / d * 2 * k).toFixed(2)}px`);
    });
  });

  render({ keepScroll: false });
  setTimeout(settle, 2600);
  window.FIRST_MATE_HOME = { state, render, setMoment };
})();
