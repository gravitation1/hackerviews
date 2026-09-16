/* Runs in a WKContentWorld isolated from Hacker News's own JavaScript. */
(() => {
  'use strict';
  if (location.hostname !== 'news.ycombinator.com' || window.QuietHN) return;
  const bridge = window.webkit.messageHandlers.quietHN;
  let blocked = new Set(window.__quietHNBlocked || []);
  let accountFiltersActive = !!window.__quietHNAccountFiltersActive;
  let preferred = new Set(window.__quietHNPreferred || []);
  let highlightActive = !!window.__quietHNHighlightActive;
  let ordered = !!window.__quietHNOrdered;
  if (ordered) { blocked = new Set(); preferred = new Set(); highlightActive = false; accountFiltersActive = !!window.__quietHNOrderedActive; }
  let generation = 0;
  let scheduled = false;
  let started = false;
  let ready = false;
  let checking = false;
  const hidden = new Set();

  const style = document.createElement('style');
  style.textContent = `
    :root {
      color-scheme: light dark;
      --qhn-bg: #faf9f6; --qhn-text: #222522; --qhn-muted: #70766f;
      --qhn-line: #e3e5df; --qhn-accent: #aa4b19; --qhn-hover: #eeeae2;
      --qhn-panel: #f1f2ed; --qhn-button-text: #fff;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --qhn-bg: #202526; --qhn-text: #e4e7e4; --qhn-muted: #9ba39d;
        --qhn-line: #363d3d; --qhn-accent: #eea06c; --qhn-hover: #343b3b;
        --qhn-panel: #272d2d; --qhn-button-text: #202526;
      }
    }
    html, body { margin: 0; padding: 0; background: var(--qhn-bg); color: var(--qhn-text); }
    body, td, .title, .comment, .comhead, .subtext, .pagetop {
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    }
    body { font-size: 14px; }
    #hnmain { width: 100% !important; min-width: 0 !important; background: var(--qhn-bg); padding: 0 16px 16px; }
    #hnmain > tbody > tr:first-child > td {
      background: var(--qhn-bg) !important; border-bottom: 1px solid var(--qhn-line); padding: 8px 0;
    }
    #hnmain > tbody > tr:first-child table { padding: 0 !important; }
    #hnmain > tbody > tr:first-child > td > table > tbody > tr > td:first-child:has(> a > img[src="y18.svg"]), .hnname { display: none; }
    .pagetop { font-size: 12px; line-height: 24px; color: var(--qhn-line); }
    .pagetop a { color: var(--qhn-muted); padding: 4px; }
    .pagetop a:hover, .pagetop .topsel a { color: var(--qhn-accent); }
    a:link { color: var(--qhn-text); }
    a:visited { color: var(--qhn-muted); }
    .title { font-size: 14px; line-height: 1.5; }
    .titleline > a { font-weight: 500; }
    .rank { font-size: 11px; color: var(--qhn-muted); padding-right: 4px; }
    .subtext, .comhead, .sitestr, .sitebit { font-size: 11px; color: var(--qhn-muted); }
    .subtext a, .comhead a, .title .sitebit a { color: var(--qhn-muted); }
    .subtext { padding-top: 2px; }
    .spacer { height: 2px !important; }
    .qhn-feed { width: 100%; border-collapse: collapse; }
    .qhn-story > td { padding-top: 5px; }
    .qhn-story-meta > td { padding-bottom: 7px; border-bottom: 1px solid var(--qhn-line); }
    .qhn-story:hover > td, .qhn-story:hover + tr > td,
    .qhn-story:has(+ tr:hover) > td, .qhn-story-meta:hover > td { background: var(--qhn-panel); }
    .fatitem { width: 100%; border-collapse: collapse; border-spacing: 0; }
    .fatitem .titleline > a { font-size: 18px; font-weight: 600; }
    .fatitem > tbody > tr:first-child > td { padding-top: 14px; }
    .comment-tree { width: 100%; }
    .comtr > td { padding: 5px 0; }
    .comtr.qhn-root > td { border-top: 1px solid var(--qhn-line); padding-top: 16px; }
    .comtr table { width: 100%; }
    .comtr .ind { background: repeating-linear-gradient(to right, transparent 0 18px, var(--qhn-line) 18px 19px, transparent 19px 40px); }
    .comtr td.default {
      border-left: 2px solid var(--qhn-line); border-radius: 0 7px 7px 0;
      background: var(--qhn-panel); padding: 10px 14px;
    }
    .comtr.qhn-root td.default { border-left-color: var(--qhn-accent); }
    .comtr td.default > div:first-child { margin: 0 0 6px !important; }
    .comtr td.default > br { display: none; }
    .comhead a.hnuser { color: var(--qhn-text); font-size: 12px; font-weight: 600; }
    .reply a { display: inline-block; font-size: 11px; padding: 2px 9px; margin-top: 4px;
      border: 1px solid var(--qhn-line); border-radius: 5px; text-decoration: none; color: var(--qhn-muted); }
    .reply a:hover { color: var(--qhn-accent); border-color: var(--qhn-accent); }
    .comment, .commtext, .toptext { color: var(--qhn-text); font-size: 14px; line-height: 1.6; }
    .commtext, .toptext { max-width: 88ch; overflow-wrap: anywhere; }
    .commtext a, .toptext a { color: var(--qhn-accent); }
    pre { max-width: 85vw; overflow: auto; }
    textarea, input, select { font: inherit; color: var(--qhn-text); background: var(--qhn-hover); border: 1px solid var(--qhn-line); border-radius: 5px; padding: 6px; }
    textarea { max-width: 100%; box-sizing: border-box; }
    .qhn-composer { max-width: 88ch; padding: 14px; margin: 18px 0; box-sizing: border-box;
      background: var(--qhn-panel); border: 1px solid var(--qhn-line); border-radius: 9px; }
    .qhn-composer::before { content: 'Add a comment'; display: block; margin-bottom: 10px;
      color: var(--qhn-text); font-size: 12px; font-weight: 600; }
    .qhn-composer textarea { display: block; width: 100%; height: 96px; min-height: 80px;
      padding: 10px; background: var(--qhn-bg); resize: vertical; }
    .qhn-composer textarea:focus { outline: 1px solid var(--qhn-accent); }
    .qhn-composer p { margin: 10px 0 0; }
    .qhn-composer a { font-size: 11px; color: var(--qhn-muted); }
    .qhn-composer input[type=submit] { background: var(--qhn-accent); color: var(--qhn-button-text);
      border: 0; font-size: 12px; font-weight: 600; padding: 7px 12px; cursor: pointer; }
    a:focus-visible, button:focus-visible { outline: 2px solid var(--qhn-accent); outline-offset: 2px; }
    html[data-qhn-pending] body { visibility: hidden !important; }
    [data-qhn-hidden] { display: none !important; }
    .qhn-faded .commtext, .qhn-faded .titleline { opacity: var(--qhn-fade-opacity) !important; }
    .qhn-faded .commtext, .qhn-faded .commtext * { color: var(--qhn-text) !important; }
    /* Story title and metadata form one continuous surface; comment gutters stay unpainted. */
    .qhn-preferred:not(.comtr) { background: color-mix(in srgb, var(--qhn-highlight, #27a99a) 12%, var(--qhn-bg)) !important; }
    .qhn-preferred:not(.comtr) > td { background: transparent !important; }
    .qhn-preferred td.default { border-left-color: var(--qhn-highlight, #27a99a) !important;
      background: color-mix(in srgb, var(--qhn-highlight, #27a99a) 12%, var(--qhn-panel)) !important; }
    .qhn-preferred-author { color: var(--qhn-highlight, #27a99a) !important; font-weight: 600; }
    .qhn-faded-author[data-qhn-filter-label]::after { content: ' ◐ ' attr(data-qhn-filter-label); font-size: 10px; font-weight: 600; color: var(--qhn-muted); }
    .qhn-preferred-author::after { content: ' ★'; font-size: 10px; font-weight: 600; }
    .qhn-preferred-author[data-qhn-filter-label]::after { content: ' ★ ' attr(data-qhn-filter-label); }
    .qhn-profile-effect { box-sizing: border-box; width: 100%; min-width: 0; display: flex; align-items: center; gap: 16px; flex-wrap: wrap; margin: 12px 0 18px; padding: 12px 16px;
      border: 1px solid var(--qhn-line); border-left: 3px solid var(--qhn-profile-color, var(--qhn-muted));
      border-radius: 6px; background: var(--qhn-panel); color: var(--qhn-text); }
    .qhn-profile-effect strong { display: block; color: var(--qhn-profile-color, var(--qhn-text)); margin-bottom: 5px; }
    .qhn-profile-effect p { margin: 0; font-size: 12px; color: var(--qhn-muted); }
    #qhn-profile-record { margin: 0 0 20px; padding: 16px; border: 1px solid var(--qhn-line); border-radius: 6px; background: var(--qhn-panel); }
    #qhn-profile-record > header { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
    #qhn-profile-record h3 { margin: 0; color: var(--qhn-text); font-size: 14px; }
    #qhn-profile-record button { flex-shrink: 0; white-space: nowrap; cursor: pointer; font: inherit; font-size: 12px; padding: 5px 9px; border: 1px solid var(--qhn-line); border-radius: 5px; background: var(--qhn-hover); color: var(--qhn-text); }
    #qhn-profile-record textarea { width: 100%; box-sizing: border-box; min-height: 90px; resize: vertical; }
    #qhn-profile-record input { width: 100%; box-sizing: border-box; }
    #qhn-profile-record small { color: var(--qhn-muted); display: block; margin-top: 12px; font-size: 11px; }
    .qhn-note { padding: 16px 0; border-bottom: 1px solid var(--qhn-line); overflow-wrap: anywhere; }
    .qhn-note-text { white-space: pre-wrap; margin: 0 0 10px; font-size: 14px; color: var(--qhn-text); line-height: 1.6; }
    .qhn-note-source, .qhn-note details { font-size: 12px; color: var(--qhn-muted); margin: 8px 0; }
    .qhn-note-excerpt { white-space: pre-wrap; line-height: 1.5; }
    .qhn-note footer { display: flex; align-items: center; gap: 10px; margin-top: 10px; font-size: 11px; color: var(--qhn-muted); }
    .qhn-note-editor > button { margin-top: 8px; }
    .qhn-profile-copy { flex: 1 1 260px; min-width: 0; }
    .qhn-profile-effect button { cursor: pointer; }
    .qhn-profile-edit { flex: 0 0 auto; padding: 7px 10px; font: inherit; font-size: 12px;
      color: var(--qhn-text); background: var(--qhn-hover); border: 1px solid var(--qhn-line); border-radius: 5px; }
    .qhn-profile-edit:hover { border-color: var(--qhn-accent); }
    .qhn-profile-edit:focus-visible { outline: 2px solid var(--qhn-accent); outline-offset: 2px; }
    .qhn-record { margin: 0 3px; border: 0; background: transparent; color: var(--qhn-muted);
      font: 16px/16px -apple-system, sans-serif; padding: 0 4px; min-width: 22px; min-height: 22px;
      vertical-align: middle; cursor: pointer; border-radius: 4px; }
    .qhn-record:hover { background: var(--qhn-hover); color: var(--qhn-accent); }
    @media (max-width: 600px) {
      #hnmain { padding: 0 8px 12px; }
      .pagetop { white-space: normal; }
      .pagetop a { display: inline-block; padding: 2px 3px; }
      .title { font-size: 15px; }
      .comtr td.default { padding: 8px 10px; }
      .qhn-composer { padding: 10px; }
      .qhn-record { min-height: 30px; min-width: 30px; }
      .votearrow { margin: 6px 4px; }
      textarea { max-width: 92vw; box-sizing: border-box; font-size: 16px; }
    }
  `;
  function install() {
    if (!document?.documentElement) return;
    // Keep our presentation rules after HN's stylesheet once parsing finishes.
    if (!style.isConnected || (started && document.documentElement.lastElementChild !== style)) {
      document.documentElement.appendChild(style);
    }
    if (!ready) document.documentElement.setAttribute('data-qhn-pending', '');
  }
  install();

  function post(message) { bridge.postMessage(message); }
  function hide(element) {
    if (!element) return;
    element.setAttribute('data-qhn-hidden', '');
    hidden.add(element);
  }
  function idOf(element) { return Number(element?.id) || null; }
  function depthOf(row) {
    const ind = row.querySelector('.ind');
    return Number(ind?.getAttribute('indent') ?? ind?.querySelector('img')?.getAttribute('width') ?? 0);
  }
  function authorOf(element) { return element?.querySelector('.hnuser')?.textContent.trim() || ''; }
  function capture(author, row, source) {
    const id = idOf(row) || Number(new URL(source.href, location.href).searchParams.get('id'));
    const comment = row?.querySelector('.commtext');
    const title = row?.querySelector('.titleline');
    return {
      kind: 'record', username: author,
      url: id ? `https://news.ycombinator.com/item?id=${id}` : `https://news.ycombinator.com/user?id=${encodeURIComponent(author)}`,
      excerpt: (comment?.innerText || comment?.textContent || title?.innerText || title?.textContent || '').slice(0, 100000),
      context: (document.querySelector('.fatitem .titleline')?.innerText || document.title || 'Hacker News').slice(0, 5000)
    };
  }
  function addControls() {
    const navigation = document.querySelector('.pagetop');
    if (navigation && !navigation.querySelector('.qhn-home')) {
      const home = document.createElement('a');
      home.className = 'qhn-home';
      home.href = 'https://news.ycombinator.com/news';
      home.textContent = 'home';
      home.setAttribute('aria-label', 'Hacker News homepage');
      if (location.pathname === '/' || location.pathname === '/news') {
        home.setAttribute('aria-current', 'page');
        home.style.color = 'var(--qhn-accent)';
      }
      navigation.prepend(home, document.createTextNode(' | '));
    }
    document.querySelectorAll('tr.athing').forEach(row => {
      if (!row.querySelector('.titleline') || row.closest('.fatitem')) return;
      row.classList.add('qhn-story');
      row.nextElementSibling?.classList.add('qhn-story-meta');
      row.closest('table')?.classList.add('qhn-feed');
    });
    document.querySelectorAll('tr.comtr').forEach(row => {
      row.classList.toggle('qhn-root', depthOf(row) === 0);
    });
    document.querySelectorAll('form').forEach(form => {
      const input = form.querySelector('textarea[name="text"]');
      if (!input || new URL(form.action, location.href).pathname !== '/comment') return;
      form.classList.add('qhn-composer');
      if (!input.hasAttribute('aria-label')) input.setAttribute('aria-label', 'Your comment');
      if (!input.placeholder) input.placeholder = 'Add to the discussion…';
    });
    document.querySelectorAll('.hnuser').forEach(link => {
      if (location.pathname === '/user' && !link.closest('.pagetop') &&
          link.textContent.trim() === new URL(location.href).searchParams.get('id')) return;
      if (link.dataset.qhnControl) return;
      link.dataset.qhnControl = '1';
      const author = link.textContent.trim();
      let row = link.closest('tr.comtr, tr.athing');
      if (!row) {
        const metadata = link.closest('tr');
        if (metadata?.previousElementSibling?.matches('.athing')) row = metadata.previousElementSibling;
      }
      const button = document.createElement('button');
      button.className = 'qhn-record';
      button.textContent = '⋯';
      button.title = `Block or highlight ${author}, or save a private note and citation`;
      button.setAttribute('aria-label', `Block, highlight, or annotate ${author}`);
      button.addEventListener('click', event => {
        event.preventDefault(); event.stopPropagation();
        post(capture(author, row, link));
      });
      link.after(button);
    });
  }

  function collect() {
    const rows = [...document.querySelectorAll('tr.comtr')];
    // Some focused comments live in .fatitem instead of the normal comment tree.
    for (const row of document.querySelectorAll('.fatitem tr.athing')) {
      if (row.querySelector('.commtext') && !rows.includes(row)) rows.unshift(row);
    }
    const roots = [];
    const rootFor = new Map();
    let stack = [];
    for (const row of rows) {
      const depth = depthOf(row);
      while (stack.length && stack.at(-1).depth >= depth) stack.pop();
      const inherited = stack.at(-1);
      const root = inherited?.root || idOf(row);
      if (!inherited && root) roots.push(root);
      rootFor.set(row, root);
      const isBlocked = inherited?.blocked || blocked.has(authorOf(row));
      if (isBlocked) hide(row);
      stack.push({depth, root, blocked: isBlocked});
    }
    let blockedStory = false;
    const stories = [...document.querySelectorAll('tr.athing')].filter(row => !rows.includes(row) && row.querySelector('.titleline'));
    for (const story of stories) {
      const metadata = story.nextElementSibling;
      if (!blocked.has(authorOf(metadata))) continue;
      hide(story); hide(metadata);
      if (metadata?.nextElementSibling?.matches('.spacer')) hide(metadata.nextElementSibling);
      if (story.closest('.fatitem')) blockedStory = true;
    }
    return {rows, stories, roots: [...new Set(roots)], rootFor, blockedStory};
  }

  function paintHighlights(names) {
    document.querySelectorAll('.qhn-faded').forEach(row => {
      row.classList.remove('qhn-faded'); row.style.removeProperty('--qhn-fade-opacity');
    });
    document.querySelectorAll('.qhn-preferred').forEach(row => row.classList.remove('qhn-preferred'));
    document.querySelectorAll('.qhn-preferred-author, .qhn-faded-author').forEach(link => {
      link.classList.remove('qhn-preferred-author', 'qhn-faded-author'); link.removeAttribute('title'); link.removeAttribute('data-qhn-filter-label');
    });
    for (const link of document.querySelectorAll('.hnuser')) {
      if (!names.has(link.textContent.trim())) continue;
      let row = link.closest('tr.comtr, tr.athing');
      if (!row) {
        const metadata = link.closest('tr');
        if (metadata?.previousElementSibling?.matches('tr.athing')) {
          row = metadata.previousElementSibling;
          metadata.classList.add('qhn-preferred');
        }
      }
      if (!row) continue;
      row.classList.add('qhn-preferred');
      link.classList.add('qhn-preferred-author');
      link.title = 'Preferred account';
    }
  }
  function requestHighlights(token) {
    paintHighlights(preferred);
    if (!highlightActive) return;
    const names = [...new Set([...document.querySelectorAll('.hnuser')].map(link => link.textContent.trim()))];
    // Chunk large discussion pages without delaying their display.
    for (let i = 0; i < names.length; i += 500) post({kind: 'highlights', names: names.slice(i, i + 500), token});
  }
  function paintOrdered(row, state, metadata = null, label = null) {
    if (/^fade:(25|50|75)$/.test(state)) {
      row.classList.add('qhn-faded');
      row.style.setProperty('--qhn-fade-opacity', String(1 - Number(state.slice(5)) / 100));
      for (const element of [row, metadata].filter(Boolean)) {
        element.querySelectorAll('.hnuser').forEach(link => {
          link.classList.add('qhn-faded-author');
          if (label) link.setAttribute('data-qhn-filter-label', label);
          else link.removeAttribute('data-qhn-filter-label');
          link.title = label ? `Matching filter: ${label}` : 'Faded by your account filter';
        });
      }
      return;
    }
    if (!state?.startsWith('highlight:')) return;
    const color = state.slice(10);
    if (!/^#[0-9a-f]{6}$/i.test(color)) return;
    for (const element of [row, metadata].filter(Boolean)) {
      element.style.setProperty('--qhn-highlight', color);
      element.classList.add('qhn-preferred');
      element.querySelectorAll('.hnuser').forEach(link => {
        link.classList.add('qhn-preferred-author');
        if (label) link.setAttribute('data-qhn-filter-label', label);
        else link.removeAttribute('data-qhn-filter-label');
        link.title = label ? `Matching filter: ${label}` : 'Highlighted by your account filter';
      });
    }
  }
  function profileAction() {
    const username = new URL(location.href).searchParams.get('id');
    const link = [...document.querySelectorAll('.hnuser')].find(link => link.textContent.trim() === username && !link.closest('.pagetop'));
    const button = document.createElement('button');
    button.type = 'button'; button.className = 'qhn-profile-edit'; button.textContent = 'Edit filters…';
    button.setAttribute('aria-label', `Edit filters for ${username}`);
    button.addEventListener('click', event => {
      event.preventDefault(); event.stopPropagation();
      if (link) post({kind: 'record', username});
    });
    return button;
  }
  let profileData = null;
  let editingNote = false;
  let noteAcknowledgement = null;
  function mountProfileRecord(panel) {
    if (document.getElementById('qhn-profile-record')) return;
    const container = document.createElement('section'); container.id = 'qhn-profile-record';
    const header = document.createElement('header');
    const title = document.createElement('h3'); title.textContent = 'Your notes';
    const add = document.createElement('button'); add.type = 'button'; add.textContent = 'Add note';
    add.onclick = () => {
      if (editingNote) return;
      const row = document.createElement('article'); row.className = 'qhn-note';
      document.getElementById('qhn-note-list').prepend(row);
      editProfileNote(row, {id: crypto.randomUUID(), annotation: '', url: location.href, title: 'Profile · ' + new URL(location.href).searchParams.get('id')}, true);
    };
    header.append(title, add);
    const list = document.createElement('div'); list.id = 'qhn-note-list';
    const status = document.createElement('small'); status.id = 'qhn-note-status'; status.textContent = 'Private · Saved automatically';
    container.append(header, list, status); panel.after(container);
  }
  function editProfileNote(row, entry, isNew = false) {
    if (editingNote) return;
    editingNote = true;
    const input = document.createElement('textarea'); input.value = entry.annotation || '';
    input.placeholder = 'Write a note…'; input.setAttribute('aria-label', 'Note');
    const editor = document.createElement('div'); editor.className = 'qhn-note-editor';
    const source = document.createElement('input'); source.type = 'url'; source.value = entry.url;
    source.setAttribute('aria-label', 'Source URL');
    const sourceDetails = document.createElement('details');
    const sourceSummary = document.createElement('summary'); sourceSummary.textContent = 'Source: this profile (change…)';
    if (isNew) { sourceDetails.append(sourceSummary, source); }
    let dirty = false, timer, awaiting = false, doneWanted = false, hasSaved = !isNew;
    function save() {
      clearTimeout(timer);
      if (!dirty) return;
      if (isNew) {
        if (!input.value.trim() && !hasSaved) return;
        try { const url = new URL(source.value); if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw Error(); }
        catch { source.setCustomValidity('Enter an http or https URL.'); sourceDetails.open = true; source.reportValidity(); return; }
        source.setCustomValidity('');
        awaiting = true;
        post({kind: 'profileUpsertNote', id: entry.id, url: source.value, title: source.value === entry.url ? entry.title : '', text: input.value});
      } else { awaiting = true; post(entry.profile ? {kind: 'profileSaveNote', text: input.value} : {kind: 'profileRefNote', id: entry.id, text: input.value}); }
      dirty = false;
    }
    function change() { dirty = true; clearTimeout(timer); timer = setTimeout(save, 500); profileSaveStatus(null); }
    input.oninput = change; source.oninput = change;
    input.onblur = save;
    const done = document.createElement('button'); done.type = 'button'; done.textContent = 'Done';
    function finishEditing() {
      editingNote = false; noteAcknowledgement = null; editor.remove();
      window.removeEventListener('pagehide', save); renderProfileNotes();
    }
    noteAcknowledgement = saved => {
      awaiting = false;
      if (!saved) { dirty = true; doneWanted = false; return; }
      hasSaved = true;
      if (doneWanted && !dirty) finishEditing();
    };
    done.onclick = () => {
      save();
      if (dirty && input.value.trim()) return;
      if (awaiting) doneWanted = true;
      else finishEditing();
    };
    window.addEventListener('pagehide', save);
    editor.append(input); if (isNew) editor.append(sourceDetails); editor.append(done);
    row.replaceChildren(editor); input.focus();
  }
  function profileRecord(username, record) {
    if (location.pathname !== '/user' || new URL(location.href).searchParams.get('id') !== username) return;
    profileData = {username, ...record};
    if (!editingNote) renderProfileNotes();
  }
  function renderProfileNotes() {
    const list = document.getElementById('qhn-note-list');
    if (!list || !profileData) return;
    list.replaceChildren();
    const entries = [...(profileData.note ? [{profile: true, id: 'profile', annotation: profileData.note, url: location.href, title: 'Profile · ' + profileData.username, date: profileData.noteDate || ''}] : []), ...(profileData.references || [])];
    if (!entries.length) { const empty = document.createElement('p'); empty.textContent = 'No notes yet.'; list.append(empty); }
    for (const entry of entries) {
      let url; try { url = new URL(entry.url); if (!['http:', 'https:'].includes(url.protocol)) continue; } catch { continue; }
      const row = document.createElement('article'); row.className = 'qhn-note';
      if (entry.annotation) { const text = document.createElement('p'); text.className = 'qhn-note-text'; text.textContent = entry.annotation; row.append(text); }
      const source = document.createElement('div'); source.className = 'qhn-note-source';
      source.append(document.createTextNode('Source: '));
      const link = document.createElement('a'); link.href = url.href; link.textContent = entry.title || url.href; source.append(link); row.append(source);
      if (entry.excerpt) {
        const details = document.createElement('details');
        const summary = document.createElement('summary'); summary.textContent = 'Saved excerpt';
        const excerpt = document.createElement('p'); excerpt.className = 'qhn-note-excerpt'; excerpt.textContent = entry.excerpt;
        details.append(summary, excerpt); row.append(details);
      }
      const actions = document.createElement('footer');
      const date = document.createElement('span'); date.textContent = entry.date || '';
      const edit = document.createElement('button'); edit.type = 'button'; edit.textContent = entry.annotation ? 'Edit' : 'Add a note…';
      edit.onclick = () => editProfileNote(row, entry);
      const remove = document.createElement('button'); remove.type = 'button'; remove.textContent = 'Remove';
      remove.onclick = () => post(entry.profile ? {kind: 'profileSaveNote', text: ''} : {kind: 'profileRemoveRef', id: entry.id});
      actions.append(date, edit, remove); row.append(actions); list.append(row);
    }
  }
  function profileSaveStatus(saved) {
    if (saved !== null) noteAcknowledgement?.(saved);
    const status = document.getElementById('qhn-note-status');
    if (status) status.textContent = saved === null ? 'Saving…' : saved ? 'Private · Saved automatically' : 'Could not save. Your draft is still here; edit again to retry.';
  }
  function requestProfile(token) {
    if (location.pathname !== '/user') return;
    const username = new URL(location.href).searchParams.get('id');
    if (!username) return;
    const userLink = [...document.querySelectorAll('.hnuser')].find(link => link.textContent.trim() === username && !link.closest('.pagetop'));
    const table = userLink?.closest('table');
    if (!table) return;
    let panel = document.getElementById('qhn-profile-effect');
    if (!panel) {
      panel = document.createElement('section'); panel.id = 'qhn-profile-effect';
      panel.className = 'qhn-profile-effect'; panel.setAttribute('aria-live', 'polite');
      table.before(panel);
    }
    panel.style.removeProperty('--qhn-profile-color');
    const loading = document.createElement('div'); loading.className = 'qhn-profile-copy';
    loading.textContent = 'Checking account effect…';
    panel.replaceChildren(loading, profileAction());
    mountProfileRecord(panel);
    post({kind: 'profile', username, token});
  }
  function resolveProfile(token, result) {
    if (token !== generation) return;
    const panel = document.getElementById('qhn-profile-effect');
    if (!panel) return;
    panel.replaceChildren();
    const heading = document.createElement('strong'); heading.textContent = result.label;
    const detail = document.createElement('p');
    const matched = result.priority > 0;
    detail.textContent = result.effect === 'unresolved'
      ? `Could not verify filter ${result.priority}: ${result.ruleName}. Retry when connected.`
      : matched ? `Filter ${result.priority}: ${result.ruleName}. ${result.effect === 'blocked' ? 'Contributions and their reply branches are hidden. The profile remains available for review.' : 'First matching filter for this account.'}`
      : 'No enabled filter matches this account. Contributions are shown normally.';
    if (result.effect?.startsWith('highlight:') && /^#[0-9a-f]{6}$/i.test(result.effect.slice(10))) {
      panel.style.setProperty('--qhn-profile-color', result.effect.slice(10));
    } else if (result.effect === 'blocked') panel.style.setProperty('--qhn-profile-color', 'var(--qhn-accent)');
    const copy = document.createElement('div'); copy.className = 'qhn-profile-copy';
    copy.append(heading, detail); panel.appendChild(copy);
    if (result.effect === 'unresolved') {
      const retry = document.createElement('button'); retry.textContent = 'Retry'; retry.onclick = () => process(); copy.appendChild(retry);
    }
    panel.appendChild(profileAction());
  }
  let matchedHighlights = new Set();
  let pending = null;
  function process() {
    if (!started) return;
    checking = true;
    ready = false;
    install();
    post({kind: 'pending'});
    for (const element of hidden) element.removeAttribute('data-qhn-hidden');
    hidden.clear();
    addControls();
    const tree = collect();
    const token = ++generation;
    pending = {token, tree};
    matchedHighlights = new Set(preferred);
    requestHighlights(token);
    requestProfile(token);
    if (tree.blockedStory) return finish(token, {}, true);
    if (!blocked.size && !accountFiltersActive) return finish(token, {});
    // Checking a page's item also covers story pages with no visible comments,
    // direct comment links, and reply forms with a blocked parent.
    const pageID = ['item', 'reply'].includes(location.pathname.replace(/^\//, ''))
      ? Number(new URL(location.href).searchParams.get('id')) : null;
    const candidates = accountFiltersActive ? [...tree.rows, ...tree.stories].map(idOf).filter(Boolean) : tree.roots;
    const ids = [...new Set([...(pageID ? [pageID] : []), ...candidates])];
    if (!ids.length) return finish(token, {});
    pending.pageID = pageID;
    post({kind: 'ancestors', ids, token});
  }

  function finish(token, decisions, blockPage = false, labels = {}, partial = false) {
    if (!pending || pending.token !== token) return;
    if (partial) {
      pending.decisions = Object.assign(pending.decisions || {}, decisions);
      pending.labels = Object.assign(pending.labels || {}, labels);
      decisions = pending.decisions; labels = pending.labels;
    }
    const {tree, pageID} = pending;
    if (pageID && decisions[pageID] === 'blocked') blockPage = true;
    for (const row of tree.rows) {
      const state = decisions[accountFiltersActive ? idOf(row) : tree.rootFor.get(row)] || (accountFiltersActive ? 'unresolved' : undefined);
      if (state === 'blocked' || state === 'unresolved') hide(row);
      else if (ordered) { row.removeAttribute('data-qhn-hidden'); hidden.delete(row); }
      if (ordered) paintOrdered(row, state, null, labels[idOf(row)]);
    }
    if (accountFiltersActive) {
      for (const story of tree.stories) {
        const state = decisions[idOf(story)] || 'unresolved';
        if (state === 'visible' || state.startsWith('highlight:') || /^fade:(25|50|75)$/.test(state)) {
          if (ordered) {
            const metadata = story.nextElementSibling;
            for (const element of [story, metadata, metadata?.nextElementSibling?.matches('.spacer') ? metadata.nextElementSibling : null].filter(Boolean)) {
              element.removeAttribute('data-qhn-hidden'); hidden.delete(element);
            }
            paintOrdered(story, state, metadata, labels[idOf(story)]);
          }
          continue;
        }
        const metadata = story.nextElementSibling;
        hide(story); hide(metadata);
        if (metadata?.nextElementSibling?.matches('.spacer')) hide(metadata.nextElementSibling);
        if (story.closest('.fatitem') && state === 'blocked') blockPage = true;
      }
    }
    const unresolvedCount = Object.values(decisions).filter(value => value === 'unresolved').length;
    if (partial && pageID && !decisions[pageID]) return;
    checking = partial;
    if (!partial) pending = null;
    if (blockPage || (pageID && decisions[pageID] === 'unresolved')) {
      // Never reveal unchecked content as a network-error fallback.
      post({kind: 'held', reason: blockPage ? 'blocked' : 'unresolved'});
      return;
    }
    let progress = document.getElementById('qhn-progress');
    if (partial) {
      if (!progress) {
        progress = document.createElement('div'); progress.id = 'qhn-progress';
        progress.style.cssText = 'padding:8px 16px;color:var(--qhn-muted);font-size:12px';
        progress.setAttribute('role', 'status'); document.body.prepend(progress);
      }
      progress.textContent = 'Checking remaining contributions…';
    } else { progress?.remove(); }
    ready = true;
    document.documentElement.removeAttribute('data-qhn-pending');
    post({kind: 'ready', hidden: hidden.size, unresolved: unresolvedCount, title: document.title});
  }

  window.QuietHN = {
    profileRecord, profileSaveStatus,
    resolveProfile,
    setOrdered(active) {
      ordered = true; blocked = new Set(); preferred = new Set(); highlightActive = false;
      accountFiltersActive = !!active; process();
    },
    configure(names, active, favorites, highlightRules) {
      blocked = new Set(names); accountFiltersActive = !!active;
      preferred = new Set(favorites); highlightActive = !!highlightRules; process();
    },
    resolveHighlights(token, names) {
      if (token !== generation) return;
      names.forEach(name => matchedHighlights.add(name));
      paintHighlights(matchedHighlights);
    },
    setFilters(names, active) { blocked = new Set(names); accountFiltersActive = !!active; process(); },
    setBlocked(names) { blocked = new Set(names); process(); },
    resolvePartial(token, decisions, labels = {}) { finish(token, decisions, false, labels, true); },
    resolve(token, decisions, labels = {}) { finish(token, decisions, false, labels); },
    retry() { process(); }
  };
  const observer = new MutationObserver(mutations => {
    install();
    if (!started || scheduled) return;
    const changed = mutations.some(m => [...m.addedNodes].some(n =>
      n.nodeType === 1 && !n.matches?.('.qhn-record, style') &&
      (n.matches?.('tr.comtr, tr.athing, .hnuser') || n.querySelector?.('tr.comtr, tr.athing, .hnuser'))));
    if (!changed) return;
    // Newly added rows are hidden synchronously in this microtask, before paint.
    ready = false; install();
    scheduled = true;
    queueMicrotask(() => { scheduled = false; process(); });
  });
  observer.observe(document, {childList: true, subtree: true});
  document.addEventListener('DOMContentLoaded', () => { started = true; process(); }, {once: true});
  window.addEventListener('pageshow', event => { if (event.persisted) process(); });
})();
