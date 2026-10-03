/* Dashboard redesign — synthetic data only. No real machines, repos, tickets or people.
   "Now" is fixed at Friday, October 2, 8:40 PM so every age reads the same on every load.
   Ages are minutes before now. Field names follow the companion contracts where one exists
   (first-mate-fleet-v1 rows, PR Review summaries, Watchers, Mobile App Hub builds). */
(() => {
  'use strict';

  const STEPS = ['Plan', 'Build', 'Review', 'QA', 'PR', 'Merge'];
  const DOING = ['Planning', 'Building', 'In review', 'In QA', 'PR open', 'Merging'];

  // Watcher avatar tones (WatcherAvatar.toneHex on origin/main).
  const TONE = {
    hoot: '#E3BF7F', lumen: '#E3BF7F', cog: '#E3BF7F',
    mochi: '#E0A4B5', remy: '#E0A4B5', metronome: '#E0A4B5',
    bolt: '#95A9EC', atlas: '#95A9EC',
    echo: '#93CAB4', moss: '#93CAB4', gauge: '#93CAB4',
    rook: '#7FC2C4', tally: '#7FC2C4', terminal: '#7FC2C4',
    clove: '#E4A98F', ziggy: '#E4A98F', hourglass: '#E4A98F',
    juno: '#C9A2DE', kit: '#C9A2DE', valve: '#C9A2DE',
    nimbus: '#97C6E8', orbit: '#97C6E8', beacon: '#97C6E8',
    sprout: '#B0CB94', wren: '#B0CB94',
    pip: '#ABA5F2', quill: '#ABA5F2',
  };
  const INSTRUMENTS = ['gauge', 'cog', 'metronome', 'hourglass', 'beacon', 'relay', 'terminal', 'valve'];

  // Chat tab color labels (ChatTabColor.swift).
  const CHAT_COLORS = {
    lavender: '#B9A7DF', iris: '#969ED4', rose: '#CD9FAB', clay: '#C6AD96', sage: '#9DB9AE', slate: '#95B2C8',
  };

  const base = () => ({
    machines: [
      { id: 'work', name: 'Work', device: 'laptop', state: 'online', companion: '0.82.0b1', health: 'healthy',
        disk: { free: 64, total: 994 }, agents: 4, sims: 2, watchers: 6, watchersOn: true,
        pulse: [2, 3, 3, 4, 3, 4, 5, 4, 4, 5, 4, 4, 4] },
      { id: 'dev', name: 'Dev', device: 'server', state: 'online', companion: '0.82.0b1', health: 'storage_low',
        disk: { free: 9, total: 460 }, agents: 2, sims: 0, watchers: 2, watchersOn: true, reviewHost: true,
        pulse: [1, 2, 2, 3, 3, 2, 2, 3, 2, 2, 3, 2, 2] },
      { id: 'studio', name: 'Studio', device: 'desktop', state: 'online', companion: '0.82.0b1', health: 'healthy',
        disk: { free: 412, total: 1800 }, agents: 1, sims: 0, watchers: 1, watchersOn: true,
        pulse: [0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1] },
    ],

    lead: { machine: 'work', checkedIn: 1 },

    // First Mate features (Second Mates). hud: blocked | turn | ready | working | idle | done
    features: [
      { id: 'f-docs', emoji: '🔍', name: 'Docs search', title: 'Docs search for the help center', project: 'docs-site',
        machine: 'dev', hud: 'blocked', step: 3, now: 'Waiting on the staging admin token', agents: 0, unread: true, age: 14,
        say: 'The staging index rejected the new schema. I need the admin token to retry the migration.',
        thread: [
          { who: 'you', text: 'Ship the new search index to staging when QA passes.', age: 95 },
          { who: 'fm', text: 'QA passed locally. The staging migration failed: the index rejected the new schema with a 401 from the admin API. I need the staging admin token to retry it.', age: 14 },
        ] },
      { id: 'f-passkey', emoji: '🔑', name: 'Passkey sign-in', title: 'Migrate sign-in to passkeys', project: 'relay', ticket: 'RELAY-412',
        machine: 'work', hud: 'turn', step: 1, now: 'Choosing a fallback for older devices', agents: 0, unread: true, age: 6,
        say: 'Older devices can’t use passkeys. Should they get a magic-link fallback, or keep passwords for now?',
        replies: ['Use magic links', 'Keep passwords'],
        thread: [
          { who: 'you', text: 'Plan the passkey migration and start with the API.', age: 180 },
          { who: 'fm', text: 'The API side is in. Before the client work: about 8% of sign-ins come from devices that can’t create passkeys. Should they get a magic-link fallback, or keep passwords for now?', age: 6 },
        ] },
      { id: 'f-csv', emoji: '📄', name: 'Ledger CSV export', title: 'CSV export for statements', project: 'ledger', pr: 88,
        machine: 'dev', hud: 'ready', step: 4, now: 'PR #88 is open and CI passed', agents: 0, unread: true, age: 32,
        say: 'CSV export is done, and PR #88 passed CI. It’s ready for your review.',
        thread: [
          { who: 'you', text: 'Add CSV export to statements. Match the PDF columns.', age: 400 },
          { who: 'fm', text: 'Done. PR #88 adds CSV export with the PDF’s columns, a streaming writer for large statements, and tests. CI passed. It’s ready for your review.', age: 32 },
        ] },
      { id: 'f-retry', emoji: '⏱️', name: 'Retry-After support', title: 'Honor Retry-After on 429 and 503', project: 'relay',
        machine: 'work', hud: 'working', step: 1, stepNote: '3 of 5 tasks', now: 'Wiring the 503 path into the backoff', agents: 2, age: 2,
        say: 'Backoff honors Retry-After on 429s now. The 503 path is next.' },
      { id: 'f-snap', emoji: '🧪', name: 'Snapshot test flakes', title: 'Stabilize snapshot tests on iOS 27', project: 'lumen-ios',
        machine: 'work', hud: 'working', step: 3, now: 'Re-running 40 snapshot tests on iOS 27', agents: 1, age: 5,
        say: 'Three tests flake on font loading. Re-running them with fonts preloaded.' },
      { id: 'f-cache', emoji: '🖼️', name: 'Image cache eviction', title: 'Evict stale image cache entries', project: 'orbit-web',
        machine: 'studio', hud: 'working', step: 2, now: 'A reviewer is checking the LRU change', agents: 1, age: 11,
        say: 'The LRU change is built. A reviewer is checking it.' },
      { id: 'f-deeplink', emoji: '🧭', name: 'Deep link router', title: 'Deep link router', project: 'lumen-ios',
        machine: 'work', hud: 'idle', step: null, now: 'Route universal links to the new tab bar', agents: 0, age: 190,
        say: 'Ready to plan. Say go when you want a plan.' },
      { id: 'f-theme', emoji: '🎨', name: 'Theme tokens', title: 'Theme tokens for Lumen', project: 'lumen-ios',
        machine: 'dev', hud: 'done', step: 5, now: 'Merged and released in 4.12.0', agents: 0, age: 120, say: 'Merged and released in 4.12.0.' },
    ],

    reviewHost: 'dev',
    reviews: [
      { id: 'r1284', repo: 'acme/relay', number: 1284, title: 'Honor Retry-After on 429 and 503 responses', author: 'mk',
        status: 'ready', viewer: 'pending', drafts: 2, walkthrough: { state: 'new', chapters: 5 },
        add: 212, del: 48, files: 9, age: 25,
        skills: [{ t: 'Full review', s: 'done' }, { t: 'Risk scan', s: 'done' }, { t: 'Explainer', s: 'running' }] },
      { id: 'r311', repo: 'acme/lumen', number: 311, title: 'Stabilize snapshot tests on iOS 27', author: 'jt',
        status: 'preparing', viewer: 'not_reviewed', prep: 'Ranking 14 files', add: 388, del: 97, files: 14, age: 4, skills: [] },
      { id: 'r402', repo: 'acme/orbit', number: 402, title: 'Evict stale image cache entries', author: 'rl',
        status: 'ready', viewer: 'commented', walkthrough: { state: 'seen', chapters: 3 }, add: 64, del: 22, files: 4, age: 160,
        skills: [{ t: 'Full review', s: 'done' }] },
    ],
    // GitHub review requests that have no Herdr review yet (Work inbox).
    requests: [
      { repo: 'acme/relay', number: 1291, title: 'Rotate webhook signing keys', author: 'ao', age: 40 },
    ],

    watchers: [
      { id: 'w-ci', name: 'Release branch CI', avatar: 'hoot', kind: 'agent', agent: 'Astra', machine: 'work', state: 'active',
        nextMin: 12, next: 'in 12 min', last: { status: 'finished', text: '2 new failures on lumen-ios', age: 18 },
        story: 'Every 30 minutes, I check the release branch’s CI and post new failures to #lumen-ci.' },
      { id: 'w-crash', name: 'Crash reports', avatar: 'mochi', kind: 'hybrid', agent: 'Sol', machine: 'work', state: 'active',
        attention: 'GitHub token expired at step 2', nextMin: 51, next: 'in 51 min', last: { status: 'failed', text: 'Stopped: the GitHub token expired', age: 9 },
        story: 'Every hour, I pull new crash groups and file the top ones in your Herdr inbox.' },
      { id: 'w-deps', name: 'Dependency updates', avatar: 'sprout', kind: 'script', machine: 'dev', state: 'active',
        live: { step: 2, of: 4, label: 'Checking for something new' }, last: { status: 'finished', text: '3 updates are available', age: 62 },
        story: 'Every 2 hours, a script checks Swift packages and npm for updates and only wakes me if something changed.' },
      { id: 'w-oncall', name: 'On-call digest', avatar: 'echo', kind: 'agent', agent: 'Luna', machine: 'work', state: 'active',
        nextMin: 20, next: 'Today at 9:00 PM', last: { status: 'nothing_new', text: 'Quiet. Nothing new.', age: 130 },
        story: 'Twice a day, I read #oncall and summarize anything that needs a human.' },
      { id: 'w-disk', name: 'Disk check', avatar: 'gauge', kind: 'script', machine: 'studio', state: 'active',
        nextMin: 28, next: 'in 28 min', last: { status: 'finished', text: 'Studio has 412 GB free', age: 32 },
        story: 'Every hour, a script checks free space on Studio and warns below 50 GB.' },
      { id: 'w-brief', name: 'Morning brief', avatar: 'lumen', kind: 'agent', agent: 'Astra', machine: 'work', state: 'active',
        nextMin: 620, next: 'Tomorrow at 7:00 AM', last: { status: 'finished', text: 'Your day: 2 reviews and a 3 PM deploy window', age: 818 },
        story: 'Weekdays at 7:00 AM, I write your morning brief from reviews, tickets and the calendar.' },
      { id: 'w-sims', name: 'Simulator cleanup', avatar: 'hourglass', kind: 'script', machine: 'work', state: 'active',
        nextMin: 320, next: 'Tomorrow at 2:00 AM', last: { status: 'finished', text: 'Deleted 3 idle simulators', age: 1120 },
        story: 'Nightly at 2:00 AM, a script deletes simulators nobody has used for a week.' },
      { id: 'w-notes', name: 'Weekly release notes', avatar: 'quill', kind: 'agent', agent: 'Sol', machine: 'dev', state: 'paused',
        last: { status: 'finished', text: 'Drafted notes for 4.11', age: 7200 },
        story: 'Fridays at 4:00 PM, I draft release notes from merged PRs.' },
    ],
    inbox: [
      { watcher: 'w-crash', text: 'Run stopped at step 2: the GitHub token expired.', age: 9, unread: true },
      { watcher: 'w-ci', text: '2 new failures on lumen-ios: testDarkHeader, testOnboardingCarousel.', age: 18, unread: true },
      { watcher: 'w-deps', text: '3 updates are available: swift-collections 1.3, vite 7.2, eslint 10.1.', age: 62, unread: true },
      { watcher: 'w-brief', text: 'Your day: 2 reviews, 1 ticket in QA, a 3 PM deploy window.', age: 818, unread: false },
    ],

    // Pi chats. status: working | waiting (needs input) | idle | done
    chats: [
      { id: 'c-snap', title: 'Snapshot tests flaking on CI', machine: 'work', ws: 'lumen-ios', status: 'waiting', age: 12, color: 'rose',
        say: 'Quarantine the 3 flaky tests, or keep retrying them?' },
      { id: 'c-hook', title: 'Webhook signature check', machine: 'work', ws: 'relay', status: 'waiting', age: 40, color: 'iris',
        say: 'May I run scripts/rotate-keys.sh against staging?' },
      { id: 'c-side', title: 'Sidebar regroup study', machine: 'dev', ws: 'docs-site', status: 'working', age: 2, color: 'lavender' },
      { id: 'c-retry', title: 'Honor Retry-After on 429s', machine: 'work', ws: 'relay', status: 'working', age: 4, color: 'iris' },
      { id: 'c-index', title: 'Search index rebuild', machine: 'dev', ws: 'ledger', status: 'working', age: 9 },
      { id: 'c-pass', title: 'Migrate sign-in to passkeys', machine: 'work', ws: 'relay', status: 'idle', age: 18, color: 'sage' },
      { id: 'c-csv', title: 'Ledger CSV export', machine: 'dev', ws: 'ledger', status: 'done', age: 64, color: 'lavender' },
      { id: 'c-copy', title: 'Onboarding copy pass', machine: 'work', ws: 'lumen-ios', status: 'idle', age: 190 },
      { id: 'c-img', title: 'Image cache eviction', machine: 'studio', ws: 'orbit-web', status: 'done', age: 300, color: 'clay' },
      { id: 'c-a11y', title: 'Accessibility labels audit', machine: 'work', ws: 'lumen-ios', status: 'done', age: 1300, color: 'rose' },
      { id: 'c-notes', title: 'Release notes 0.99', machine: 'dev', ws: 'docs-site', status: 'idle', age: 1500 },
      { id: 'c-router', title: 'Deep link router spike', machine: 'work', ws: 'lumen-ios', status: 'idle', age: 2900 },
      { id: 'c-perf', title: 'Lighthouse perf sweep', machine: 'studio', ws: 'orbit-web', status: 'idle', age: 4300, color: 'slate' },
      { id: 'c-font', title: 'Font loading jank', machine: 'studio', ws: 'orbit-web', status: 'idle', age: 8700 },
    ],

    buildsApp: 'Lumen',
    builds: [
      { id: 'b2014', version: '4.12.0', build: '20261002-2014', label: 'Passkey sign-in', feature: 'f-passkey', machine: 'work', age: 26 },
      { id: 'b1730', version: '4.12.0', build: '20261002-1730', label: 'Snapshot test fixes', feature: 'f-snap', machine: 'work', age: 190 },
      { id: 'b0912', version: '4.11.2', build: '20261001-0912', label: 'Deep link router spike', machine: 'dev', age: 1408 },
    ],
    sims: [
      { machine: 'work', device: 'iPhone 17 Pro', label: 'Passkey sign-in' },
      { machine: 'work', device: 'iPad Air', label: 'Snapshot test fixes' },
    ],
    simCap: 4,

    shipped: [
      { kind: 'feature', id: 'f-theme', text: 'Theme tokens merged', age: 120 },
      { kind: 'review', text: 'You approved acme/ledger #79', age: 240 },
      { kind: 'build', text: 'Lumen 4.12.0 (1730) published', age: 190 },
      { kind: 'watcher', text: 'Morning brief delivered', age: 818 },
    ],

    configured: { reviews: true, watchers: true, builds: true },
  });

  const clone = value => JSON.parse(JSON.stringify(value));
  const byId = (list, id) => list.find(item => item.id === id);

  const scenarios = {
    busy: {
      label: 'Busy evening',
      note: 'Three First Mates, a review, a watcher, two chats and a disk need you.',
      build: () => base(),
    },
    quiet: {
      label: 'All clear',
      note: 'Nothing needs you. No reviews in progress. Shows the calm and empty states.',
      build: () => {
        const w = base();
        w.features = w.features.filter(f => ['f-retry', 'f-deeplink', 'f-theme', 'f-cache'].includes(f.id));
        byId(w.features, 'f-cache').hud = 'working';
        w.reviews = [];
        w.requests = [];
        w.watchers.forEach(x => { delete x.attention; delete x.live; if (x.last.status === 'failed') x.last = { status: 'finished', text: 'No new crash groups', age: 9 }; });
        byId(w.watchers, 'w-deps').nextMin = 70; byId(w.watchers, 'w-deps').next = 'in 1 hr 10 min';
        w.inbox.forEach(x => { x.unread = false; });
        w.inbox = w.inbox.filter(x => x.watcher !== 'w-crash');
        w.chats.forEach(c => { if (c.status === 'waiting') { c.status = 'done'; delete c.say; } });
        const dev = byId(w.machines, 'dev');
        dev.health = 'healthy'; dev.disk.free = 138; dev.agents = 1;
        byId(w.machines, 'work').agents = 2;
        return w;
      },
    },
    trouble: {
      label: 'Something broke',
      note: 'Studio is offline, Dev’s disk is full, a review failed to prepare and a watcher keeps failing.',
      build: () => {
        const w = base();
        const studio = byId(w.machines, 'studio');
        Object.assign(studio, { state: 'offline', lastSeen: 25, agents: 0 });
        const dev = byId(w.machines, 'dev');
        Object.assign(dev, { health: 'storage_full', agents: 0 });
        dev.disk.free = 1;
        const cache = byId(w.features, 'f-cache');
        cache.offline = true; cache.now = 'Last known: a reviewer was checking the LRU change';
        const csv = byId(w.features, 'f-csv');
        csv.hud = 'blocked'; csv.step = 4; csv.now = 'Can’t save progress: Dev’s disk is full';
        csv.say = 'I can’t save progress because Dev’s disk is full. Free some space and I’ll pick up where I left off.';
        const r311 = byId(w.reviews, 'r311');
        Object.assign(r311, { status: 'failed', error: 'Couldn’t check out the branch: not enough space on Dev' });
        const crash = byId(w.watchers, 'w-crash');
        crash.attention = 'Failed twice: the GitHub token expired';
        crash.last.text = 'Failed twice in a row: the GitHub token expired';
        const disk = byId(w.watchers, 'w-disk');
        disk.offline = true;
        return w;
      },
    },
    setup: {
      label: 'First run',
      note: 'One machine, nothing set up yet. Every section shows how to get started.',
      build: () => {
        const w = base();
        w.machines = [Object.assign(byId(w.machines, 'work'), { agents: 0, sims: 0, watchers: 0, watchersOn: false, pulse: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] })];
        w.features = [];
        w.reviews = []; w.requests = [];
        w.watchers = []; w.inbox = [];
        w.builds = []; w.sims = [];
        w.shipped = [];
        w.chats = [
          { id: 'c-first', title: 'Explain this repository', machine: 'work', ws: 'relay', status: 'done', age: 8 },
          { id: 'c-shell', title: 'Set up the dev environment', machine: 'work', ws: 'relay', status: 'idle', age: 31 },
        ];
        w.configured = { reviews: false, watchers: false, builds: false };
        return w;
      },
    },
  };

  window.DASH = { STEPS, DOING, TONE, INSTRUMENTS, CHAT_COLORS, scenarios, clone, byId };
})();
