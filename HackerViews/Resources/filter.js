/* Runs in a WKContentWorld isolated from Hacker News's own JavaScript. */
(() => {
  'use strict';
  if (location.hostname !== 'news.ycombinator.com' || window.HackerViews) return;
  const bridge = window.webkit.messageHandlers.hackerViews;
  let blocked = new Set(window.__hackerViewsBlocked || []);
  let accountFiltersActive = !!window.__hackerViewsAccountFiltersActive;
  let preferred = new Set(window.__hackerViewsPreferred || []);
  let highlightActive = !!window.__hackerViewsHighlightActive;
  let ordered = !!window.__hackerViewsOrdered;
  if (ordered) { blocked = new Set(); preferred = new Set(); highlightActive = false; accountFiltersActive = !!window.__hackerViewsOrderedActive; }
  let revealedID = null;
  let revealAll = false;
  let scrollReportPending = false;
  window.addEventListener('scroll', () => {
    if (!ready || scrollReportPending) return;
    scrollReportPending = true;
    setTimeout(() => {
      scrollReportPending = false;
      reportReadingPosition();
    }, 150);
  }, {passive: true});
  function reportReadingPosition() {
    // Do not overwrite the saved destination with an intermediate load position.
    if(!ready || lazyRestoreAnchor || lazyRestoreY)return;
    const anchor=readingPosition();
    post({kind:'scrollPosition',y:Math.max(0,window.scrollY),anchor});
  }
  window.addEventListener('pagehide',reportReadingPosition);
  document.addEventListener('click',event=>{
    if(!lazyThread && event.target.closest?.('.togg'))queueMicrotask(()=>{
      post({kind:'collapsedState',ids:[...document.querySelectorAll('tr.comtr.coll')].map(row=>Number(row.id)).filter(id=>Number.isSafeInteger(id)&&id>0)});
    });
  });
  document.addEventListener('visibilitychange',()=>{if(document.hidden)reportReadingPosition();});
  // Opening a discussion from a temporarily revealed contribution should not ask
  // the reader to reveal it again. The intent travels with the navigation.
  function carryReveal(event) {
    if (event.button === 2) return;
    const link = event.target.closest?.('a[href]');
    if (!link || !link.closest('[data-qhn-revealed]')) return;
    let target; try { target = new URL(link.href, location.href); } catch (_) { return; }
    if (target.hostname !== 'news.ycombinator.com' || target.pathname !== '/item') return;
    const id = Number(target.searchParams.get('id'));
    if (Number.isSafeInteger(id) && id > 0) post({kind: 'revealIntent', id});
  }
  document.addEventListener('click', carryReveal, true);
  document.addEventListener('auxclick', carryReveal, true);
  let editedRow = null;
  let filterAnchor = null;
  function captureFilterAnchor() {
    const rows = [...document.querySelectorAll('tr.athing')].filter(row => row.getClientRects().length && !row.hasAttribute('data-qhn-hidden'));
    const edited = rows.find(row => row.id === editedRow && row.getBoundingClientRect().bottom > 0 && row.getBoundingClientRect().top < innerHeight);
    const first = edited || rows.find(row => row.getBoundingClientRect().bottom > 0);
    if (!first) return;
    const index = rows.indexOf(first);
    filterAnchor = {ids: [...rows.slice(index), ...rows.slice(0, index).reverse()].map(row => row.id),
      top: first.getBoundingClientRect().top, y: scrollY};
    editedRow = null;
  }
  function restoreFilterAnchor() {
    if (!filterAnchor) return;
    const target = filterAnchor.ids.map(id => document.getElementById(id)).find(row => row && !row.hasAttribute('data-qhn-hidden') && row.getClientRects().length);
    window.scrollTo(0, target ? window.scrollY + target.getBoundingClientRect().top - (target.id === filterAnchor.ids[0] ? filterAnchor.top : Math.max(0, filterAnchor.top)) : filterAnchor.y);
    filterAnchor = null;
  }
  function readingPosition() {
    const started=scrollDiagnostics?performance.now():0;
    const rows=[...document.querySelectorAll('tr.athing')];
    const selected=scrollDiagnostics?performance.now():0;
    let checked=0;
    const row=rows.find(r=>{checked++;return r.getClientRects().length && r.getBoundingClientRect().bottom>0;});
    if(scrollDiagnostics) {
      const ms=performance.now()-started;
      metric('anchorCalls');metric('anchorTotal',ms);maximum('anchorMax',ms);
      metric('anchorSelectTotal',selected-started);maximum('anchorRowsMax',rows.length);
      metric('anchorChecked',checked);maximum('anchorCheckedMax',checked);
    }
    const node=row && lazyNodes.get(Number(row.id));
    return {y:window.scrollY,id:row?Number(row.id):0,top:row?.getBoundingClientRect().top||0,
      ancestors:node?[...node.ancestors]:[]};
  }
  function refreshState() {
    const collapsed = lazyThread ? [...lazyCollapsed] : [...document.querySelectorAll('tr.comtr.coll')].map(row=>Number(row.id));
    return {...readingPosition(), collapsed};
  }
  function restoreReadingPosition(anchor,y) {
    if (!lazyThread) for (const id of anchor.collapsed || []) {
      const row=document.getElementById(String(id));
      if(row && !row.classList.contains('coll'))row.querySelector('.togg')?.click();
    }
    const row=document.getElementById(String(anchor.id));
    if(row?.getClientRects().length)window.scrollTo(0,window.scrollY+row.getBoundingClientRect().top-(anchor.top||0));
    else window.scrollTo(0,y);
  }
  // Cache the reading anchor before reflow. A resize event arrives after the
  // width has changed, so selecting the top row in that event is already too late.
  let viewportAnchor=null, viewportWidth=window.innerWidth, resizeFramePending=false;
  let anchorFramePending=false;
  function rememberViewportAnchor() {
    if(!ready || resizeFramePending || window.innerWidth!==viewportWidth)return;
    viewportAnchor=readingPosition();
  }
  window.addEventListener('scroll',()=>{
    if(anchorFramePending || resizeFramePending || window.innerWidth!==viewportWidth)return;
    anchorFramePending=true;
    const queuedAt=scrollDiagnostics?performance.now():0;
    const capture=()=>{
      anchorFramePending=false;
      if(scrollDiagnostics){metric('anchorScrollCalls');maximum('anchorWaitMax',performance.now()-queuedAt);}
      rememberViewportAnchor();
    };
    if(typeof requestAnimationFrame==='function')requestAnimationFrame(capture);else setTimeout(capture,0);
  },{passive:true});
  window.addEventListener('resize',()=>{
    if(window.innerWidth===viewportWidth || resizeFramePending)return;
    resizeFramePending=true;
    const restore=()=>{
      const saved=viewportAnchor;
      if(saved && ready) {
        const row=document.getElementById(String(saved.id));
        if(row?.getClientRects().length) {
          const rect=row.getBoundingClientRect();
          // Keep the same contribution visible even if reflow makes it shorter
          // than the amount that was previously above the viewport.
          const top=Math.max(saved.top,Math.min(0,24-rect.height));
          restoreReadingPosition({...saved,top},saved.y);
        } else window.scrollTo(0,saved.y);
      }
      viewportWidth=window.innerWidth;resizeFramePending=false;
      rememberViewportAnchor();
    };
    if(typeof requestAnimationFrame==='function')requestAnimationFrame(restore);else setTimeout(restore,0);
  },{passive:true});
  let originalPoster = null;
  let signedInUser = null;
  let requestedOP = false;
  function readSignedInUser(doc) {
    // HN identifies the authenticated account in its header. Never infer it
    // from contribution authors or a visited profile.
    const me=doc.querySelector('a#me[href]');
    let name=null;
    if(me) {
      try {
        const url=new URL(me.getAttribute('href'),location.href);
        if(url.origin===location.origin && url.pathname==='/user')name=url.searchParams.get('id');
      } catch (_) {}
    }
    signedInUser=name;
  }
  function paintOP() {
    if(!document.body?.dataset.hvTopic)readSignedInUser(document);
    document.querySelectorAll('.hnuser').forEach(link => {
      if(link.closest('.pagetop, .hv-header') || link.id==='me')return;
      const author=link.textContent.trim();
      const own=!!signedInUser && author===signedInUser;
      const op=!!originalPoster && author===originalPoster && !!link.closest('tr.comtr');
      const existing = link.nextElementSibling?.matches('.qhn-op') ? link.nextElementSibling : null;
      if (!own && !op) { existing?.remove(); return; }
      const badge = existing || document.createElement('span');
      badge.className = 'qhn-op';
      let label=badge.querySelector('.qhn-op-badge');
      if(!label){label=document.createElement('span');label.className='qhn-op-badge';badge.append(label);}
      label.textContent=own?(op?'You · OP':'You'):'OP';
      label.title=own?(op?'Your comment · Original poster':'Your post'):'Original poster';
      label.setAttribute('aria-label',label.title);
      if(!existing)link.after(badge);
      badge.dataset.qhnFilterLabel = link.dataset.qhnFilterLabel || '';
    });
  }
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
    .qhn-loading { display: flex; align-items: center; gap: 10px; min-height: 44px;
      padding: 8px 14px; color: var(--qhn-muted); font-size: 12px; overflow-anchor: none; }
    .qhn-loading button { font: inherit; min-height: 32px; padding: 4px 10px; cursor: pointer;
      color: var(--qhn-text); background: var(--qhn-hover); border: 1px solid var(--qhn-line); border-radius: 5px; }
    .qhn-loading button:hover { border-color: var(--qhn-accent); }
    .qhn-spinner { width: 12px; height: 12px; border: 2px solid var(--qhn-line);
      border-top-color: var(--qhn-accent); border-radius: 50%; animation: qhn-spin 0.8s linear infinite; }
    @keyframes qhn-spin { to { transform: rotate(360deg); } }
    @media (prefers-reduced-motion: reduce) { .qhn-spinner { animation: none; } }
    #hv-topic { padding: 12px 16px; }
    /* Retain real layout heights offscreen; estimated subtree heights change
       the scroll geometry as WebKit skips and reactivates nested comments. */
    body[data-hv-topic] { overflow-anchor: none; }
    .hv-own > button { cursor: pointer; color: var(--qhn-text); background: var(--qhn-hover); border: 1px solid var(--qhn-line); border-radius: 5px; min-height: 32px; }
    .hv-own .hv-vote.hv-voted { color: var(--qhn-accent); }
    .hv-own .hv-vote.hv-vacant, .hv-own .hv-vote.hv-vacant:hover { color: transparent; background: var(--qhn-bg); pointer-events: none; }
    .hv-own .hv-vote.hv-voted:hover, .hv-own .hv-vote.hv-voted:focus-visible { color: var(--qhn-text); }
    .hv-own .fatitem td.votelinks { width: 34px; min-width: 34px; text-align: center; padding-top: 8px; }
    .fatitem .hv-vote { margin: 0 auto; }
    .hv-score { display: block; font-size: 12px; font-weight: 600; color: var(--qhn-muted); margin-top: 2px; }
    .fatitem td.votelinks:has(.hv-voted) .hv-score { color: var(--qhn-accent); }
    .hv-reader-actions button, .qhn-record-text { display: inline; min-width: 0; min-height: 0; width: auto; height: auto; padding: 0; margin: 0; border: 0; border-radius: 0;
      background: none; font: inherit; color: inherit; line-height: inherit; vertical-align: baseline; cursor: pointer; }
    .hv-reader-actions button:hover, .qhn-record-text:hover, .hv-reader-actions button.hv-open { color: var(--qhn-accent); text-decoration: underline; }
    .hv-visit { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 14px; margin: 8px 0 2px; font-size: 12px; color: var(--qhn-muted); }
    .hv-visit-new { color: var(--qhn-accent); font-weight: 600; }
    .hv-visit-loading { color: var(--qhn-muted); }
    .hv-visit button { font: inherit; font-size: 12px; min-height: 28px; padding: 3px 10px; cursor: pointer;
      color: var(--qhn-text); background: transparent; border: 1px solid var(--qhn-line); border-radius: 6px; }
    .hv-visit button:hover { border-color: var(--qhn-accent); color: var(--qhn-accent); }
    .hv-new-dot { display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: var(--qhn-accent); margin-right: 6px; vertical-align: middle; box-sizing: border-box; }
    .hv-new-read .hv-new-dot { background: transparent; border: 1.5px solid var(--qhn-accent); opacity: .7; }
    .hv-flash { animation: hv-flash 1.2s ease-out; }
    @keyframes hv-flash { from { background: color-mix(in srgb, var(--qhn-accent) 22%, transparent); } to { background: transparent; } }
    .hv-new-count { color: var(--qhn-accent); font-weight: 600; }
    .hv-own .hv-collapse { position: relative; font: inherit; color: var(--qhn-muted); background: transparent; border: 0; min-height: 0; padding: 0 3px; }
    .hv-collapse::before { content: ''; position: absolute; inset: -7px -3px; border-radius: 4px; }
    .hv-own .hv-collapse:hover, .hv-own .hv-collapse:focus-visible { color: var(--qhn-text); background: var(--qhn-hover); outline: 1px solid var(--qhn-line); }
    .hv-comment-tail, .hv-age { white-space: nowrap; }
    .hv-comment-nav a { text-decoration: none; }
    .comtr.hv-tombstone td.default { padding: 2px 0 2px 6px; }
    .hv-tombstone-label { color: var(--qhn-muted); font-size: 12px; font-style: italic; }
    .hv-own .hv-vote { appearance: none; -webkit-appearance: none; display: block; box-sizing: border-box;
      width: 20px; height: 16px; min-height: 0; padding: 0; margin: 0; border: 0; border-radius: 2px;
      background: var(--qhn-bg); color: var(--qhn-muted); }
    .hv-vote .votearrow { display: block; width: 0; height: 0; margin: auto; border-left: 4px solid transparent;
      border-right: 4px solid transparent; border-bottom: 8px solid currentColor; }
    .hv-vote .rotate180 { transform: rotate(180deg); }
    .hv-own .hv-vote:hover, .hv-own .hv-vote:focus-visible { color: var(--qhn-text); background: var(--qhn-hover); }
    .hv-own .hv-vote:disabled { opacity: .45; }
    .hv-own td.votelinks { vertical-align: top; padding-top: 1px; width: 20px; min-width: 20px; }
    .hv-own .hv-vote:has(> .rotate180):not(.hv-voted):not(:hover):not(:focus-visible) > .votearrow { opacity: .45; }
    /* One column per comment: its arrows, then its own marker when it has one
       (highlighted author, revealed, moderated), then the rail of its replies.
       The arrows paint the page colour so the marker runs behind them. */
    .hv-own td.votelinks { position: relative; }
    .comtr td.votelinks::after { content: ''; position: absolute; left: 10px; top: 0; bottom: 0; width: 2px; box-sizing: border-box; background: transparent; }
    .comtr.qhn-preferred td.votelinks::after { background: var(--qhn-highlight, #27a99a); }
    .comtr.qhn-revealed td.votelinks::after { background: transparent; border-left: 2px dashed var(--qhn-accent); }
    .comtr.hv-tombstone td.votelinks::after { background: transparent; border-left: 2px dashed var(--qhn-line); }
    /* A branch draws one rail in that same column, from just under its parent's
       text to its last reply. It is the collapse control for the branch; [-] stays for keys. */
    .hv-children { position: relative; }
    .hv-rail { position: absolute; top: -12px; bottom: 12px; width: 12px; z-index: 1; margin: 0; padding: 0; border: 0; min-height: 0; appearance: none; -webkit-appearance: none;
      cursor: pointer; background: linear-gradient(to right, transparent 5px, var(--qhn-line) 5px, var(--qhn-line) 6px, transparent 6px); }
    .hv-rail:hover, .hv-rail:focus-visible { outline: 0; background: linear-gradient(to right, transparent 4px, var(--qhn-accent) 4px, var(--qhn-accent) 6px, transparent 6px); }
    .hv-node:has(> .hv-children > .hv-rail:hover) > .hv-own .comhead .hnuser { color: var(--qhn-accent) !important; }
    .hv-reader-actions a, .hv-reader-actions .qhn-record-text { color: var(--qhn-muted); text-decoration: none; }
    .hv-reader-actions a:hover, .hv-reader-actions .qhn-record-text:hover { color: var(--qhn-accent); text-decoration: underline; }
    [hidden] { display: none !important; }
    html, body { margin: 0; padding: 0; background: var(--qhn-bg); color: var(--qhn-text); }
    body, td, .title, .comment, .comhead, .subtext, .pagetop {
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    }
    /* Avoid horizontal rubber-banding on the document. Real overflow (such as
       code blocks) remains scrollable in both directions. */
    html { overscroll-behavior-x: none; }
    body { font-size: 14px; }
    #hnmain { width: 100% !important; min-width: 0 !important; background: var(--qhn-bg); padding: 0 16px 16px; }
    #hnmain > tbody > tr:first-child > td { background: var(--qhn-bg) !important; padding: 0; }
    #hnmain > tbody > tr:first-child table { padding: 0 !important; }
    #hnmain > tbody > tr:first-child > td > table > tbody > tr > td:first-child:has(> a > img[src="y18.svg"]), .hnname { display: none; }
    /* One header for feed pages and the topic shell. Every item carries a leading
       tick and a trailing gap; the negative item margin puts the tick inside the
       previous gap and the list's overflow clips the first tick of every line. */
    .hv-header { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap;
      gap: 6px 16px; padding: 6px 0; margin: 0 0 10px; border-bottom: 1px solid var(--qhn-line);
      font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 12px; line-height: 24px; color: var(--qhn-muted); }
    #hnmain .hv-header { margin-bottom: 0; }
    body.hv-plain { padding: 0 16px 16px; }
    .hv-header ul { display: flex; align-items: center; flex-wrap: wrap; list-style: none; overflow: hidden; margin: 0; padding: 0; }
    .hv-header .hv-nav { margin-left: -7px; }
    .hv-header .hv-side { margin-left: auto; margin-right: -7px; }
    .hv-header li { display: flex; align-items: center; margin-left: -7px; }
    .hv-header li::before { content: ''; display: block; flex: none; width: 1px; height: 12px; background: var(--qhn-line); margin: 0 3px; }
    .hv-header li > :last-child { margin-right: 7px; }
    .hv-header a { color: var(--qhn-muted); text-decoration: none; padding: 0 7px; border-radius: 5px; }
    .hv-header a:hover { color: var(--qhn-text); background: var(--qhn-hover); }
    .hv-header a:focus-visible { outline: 2px solid var(--qhn-accent); outline-offset: -2px; }
    .hv-header a[aria-current="page"] { color: var(--qhn-accent); font-weight: 600; }
    .hv-header .hv-me { color: var(--qhn-text); font-weight: 600; padding-right: 4px; }
    .hv-header .hv-karma { font-variant-numeric: tabular-nums; padding-right: 7px; }
    .hv-chip { display: inline-flex; align-items: center; gap: 5px; height: 20px; padding: 0 8px 0 6px; box-sizing: border-box;
      font: inherit; font-size: 11px; line-height: 20px; cursor: default; white-space: nowrap;
      border: 1px solid var(--qhn-line); border-radius: 999px; background: var(--qhn-panel); color: var(--qhn-muted); }
    .hv-header li > .hv-chip:last-child { margin-right: 11px; }
    .hv-chip svg { width: 12px; height: 12px; stroke: currentColor; fill: none; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
    button.hv-chip { cursor: pointer; }
    button.hv-chip:hover { background: var(--qhn-hover); color: var(--qhn-text); }
    button.hv-chip:focus-visible { outline: 2px solid var(--qhn-accent); outline-offset: 1px; }
    .hv-chip-alert, .hv-chip[aria-pressed="true"] { color: var(--qhn-accent); border-color: color-mix(in srgb, var(--qhn-accent) 45%, var(--qhn-line)); }
    .hv-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
    .qhn-revealed .commtext, .qhn-revealed .titleline, .qhn-revealed .toptext { opacity: .6; }

    .qhn-reveal-label { display: inline-block; margin-left: 6px; padding: 1px 5px; font-size: 10px; line-height: 1.3; font-weight: 600;
      color: var(--qhn-accent); border: 1px solid currentColor; border-radius: 4px; vertical-align: baseline; white-space: nowrap; }
    .hv-skeleton { display: inline-block; width: 92px; height: 12px; border-radius: 6px; background: var(--qhn-line); vertical-align: middle; margin-left: 4px; }
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
    .comtr > td { padding: 0 0 12px; }
    .comtr.qhn-root > td { border-top: 1px solid var(--qhn-line); padding-top: 12px; }
    .comtr table { width: 100%; }
    /* Give spare table width to the content, never the indentation/vote gutters.
       Hiding the body on collapse must not redistribute column widths. */
    .comtr td.ind { width: 0; }
    .comtr td.votelinks { width: 20px; min-width: 20px; }
    .comtr td.default { width: 100%; }
    /* A comment is its header and its text. Depth is the indent, the branch
       rail belongs to the branch (.hv-rail), and the left edge carries a
       marker only when there is something to mark. */
    .comtr td.default { border-left: 0; background: transparent; padding: 0 0 0 6px; }
    .comtr td.default > div:first-child { margin: 0 0 2px !important; }
    .comtr td.default > br { display: none; }
    .comhead a.hnuser { color: var(--qhn-text); font-size: 12px; font-weight: 600; }
    .reply a, .reply a:any-link { display: inline-block; font: inherit; font-size: 12px; padding: 2px 0; margin-top: 2px;
      background: transparent; border: 0; text-decoration: none; color: var(--qhn-muted); }
    .reply a:hover { color: var(--qhn-accent); text-decoration: underline; }
    .hv-comment .qhn-composer { margin: 10px 0 4px; }
    .hv-comment .qhn-composer p { display: flex; gap: 10px; align-items: center; }
    .hv-comment .hv-comment-cancel, .hv-comment .qhn-loading button { font: inherit; font-size: 12px; min-height: 32px; padding: 4px 10px; cursor: pointer;
      color: var(--qhn-text); background: var(--qhn-hover); border: 1px solid var(--qhn-line); border-radius: 5px; }
    .hv-comment .qhn-loading { padding-left: 0; }
    .comment, .commtext, .toptext { color: var(--qhn-text); font-size: 14px; line-height: 1.6; }
    .comment, .commtext, .toptext { max-width: 90ch; overflow-wrap: anywhere; }
    /* HN's score classes (.c00 a:link, .c5a a:visited, etc.) otherwise
       override the reader palette and paint links black in dark mode. */
    .commtext a:any-link, .toptext a:any-link {
      color: var(--qhn-accent) !important;
      text-decoration: underline; text-underline-offset: 2px;
    }
    .commtext a:any-link:hover, .toptext a:any-link:hover {
      color: var(--qhn-text) !important;
    }
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

    .qhn-preferred-author { color: var(--qhn-highlight, #27a99a) !important; font-weight: 600; }
    .qhn-faded-author[data-qhn-filter-label]::after { content: ' ◐ ' attr(data-qhn-filter-label); font-size: 10px; font-weight: 600; color: var(--qhn-muted); }
    .qhn-preferred-author::after { content: ' ★'; font-size: 10px; font-weight: 600; }
    .qhn-preferred-author[data-qhn-filter-label]::after { content: ' ★ ' attr(data-qhn-filter-label); }
    .qhn-op-badge { display: inline-block; margin-left: 5px; padding: 1px 4px;
      font-size: 10px; line-height: 1.3; font-weight: 700; border: 1px solid currentColor;
      border-radius: 4px; color: var(--qhn-text); vertical-align: baseline; }
    .hnuser:has(+ .qhn-op)::after { content: none; }
    .qhn-preferred-author + .qhn-op::after { content: ' ★ ' attr(data-qhn-filter-label);
      color: var(--qhn-highlight, #27a99a); font-size: 10px; font-weight: 600; }
    .qhn-faded-author + .qhn-op::after { content: ' ◐ ' attr(data-qhn-filter-label);
      color: var(--qhn-muted); font-size: 10px; font-weight: 600; }
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
    .qhn-record { margin: 0 2px; border: 0; background: transparent; color: var(--qhn-muted);
      font: 15px/15px -apple-system, sans-serif; padding: 3px 6px; min-width: 28px; min-height: 26px; box-sizing: border-box;
      vertical-align: middle; cursor: pointer; border-radius: 4px; }
    .qhn-record:hover, .qhn-record:focus-visible { background: var(--qhn-hover); color: var(--qhn-accent); }
    #qhn-profile-record button, .qhn-profile-effect button, .qhn-note summary, .reply a {
      min-height: 32px; min-width: 32px; box-sizing: border-box;
    }
    .qhn-note summary { padding: 6px 8px; border-radius: 5px; cursor: pointer; }
    #qhn-profile-record button:hover, .qhn-profile-effect button:hover, .qhn-note summary:hover {
      background: var(--qhn-hover); color: var(--qhn-accent); border-color: var(--qhn-accent);
    }
    .qhn-record:focus-visible { outline: 2px solid var(--qhn-accent); outline-offset: 1px; }
    .qhn-record:active, #qhn-profile-record button:active, .qhn-profile-effect button:active,
    .qhn-note summary:active, .reply a:active {
      background: color-mix(in srgb, var(--qhn-accent) 22%, var(--qhn-bg));
    }
    .qhn-note summary:focus-visible { outline: 2px solid var(--qhn-accent); outline-offset: 2px; }
    @media (pointer: coarse) {
      .qhn-record:not(.qhn-record-text), #qhn-profile-record button, .qhn-profile-effect button, .qhn-note summary, .reply a {
        min-width: 44px !important; min-height: 44px !important;
      }
    }
    @media (max-width: 600px) {
      #hnmain { padding: 0 8px 12px; }
      .hv-header a { padding: 0 5px; }
      .hv-header li { margin-left: -5px; }
      .hv-header li::before { margin: 0 2px; }
      .hv-header li > :last-child { margin-right: 5px; }
      .hv-header .hv-nav { margin-left: -5px; }
      .hv-header .hv-side { margin-right: -5px; }
      .title { font-size: 15px; }
      .comtr td.default { padding: 0 0 0 6px; }
      /* A deep comment's header is wider than the screen if its tail cannot
         wrap. Let it break between its groups, never inside one. */
      .hv-comment-tail { white-space: normal; }
      .hv-comment-nav, .hv-reader-actions, .hv-hn-actions { white-space: nowrap; }
      .qhn-composer { padding: 10px; }
      .qhn-record { min-height: 32px; min-width: 32px; }
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

  function trace(event, fields={}) {
    bridge.postMessage({kind:'performance',event,timeOrigin:performance.timeOrigin,at:performance.now(),...fields});
  }
  // Debug-only, aggregated once per second; no per-frame bridge traffic or
  // geometry reads. This observes the existing loader without changing scheduling.
  const scrollDiagnostics = !!window.__hackerViewsScrollDiagnostics;
  let lastScrollActivity = -Infinity, lastWheelAt = -Infinity;
  let scrollMetrics = {};
  const metric = (key,value=1) => { scrollMetrics[key]=(scrollMetrics[key]||0)+value; };
  const maximum = (key,value) => { scrollMetrics[key]=Math.max(scrollMetrics[key]||0,value); };
  if(scrollDiagnostics) {
    let framePending=false,lastFrame=0;
    function frame(at) {
      if(document.hidden || at-lastScrollActivity>300) {framePending=false;lastFrame=0;return;}
      if(lastFrame) {
        const gap=at-lastFrame;
        metric('frames');metric('frameTotal',gap);maximum('frameMax',gap);
        scrollMetrics.frameMin=Math.min(scrollMetrics.frameMin||Infinity,gap);
        if(gap>20)metric('framesOver20');
        if(gap>34)metric('framesOver34');
      }
      lastFrame=at;requestAnimationFrame(frame);
    }
    function activity() {
      lastScrollActivity=performance.now();
      if(!framePending && typeof requestAnimationFrame==='function') {framePending=true;requestAnimationFrame(frame);}
    }
    window.addEventListener('wheel',()=>{
      lastWheelAt=performance.now();metric('wheels');activity();
    },{passive:true});
    window.addEventListener('scroll',()=>{metric('scrollEvents');activity();},{passive:true});
    document.addEventListener('contentvisibilityautostatechange',event=>{
      if(event.target.matches?.('.hv-node'))metric(event.skipped?'skipped':'unskipped');
    },true);
    document.addEventListener('DOMContentLoaded',()=>{
      if(typeof ResizeObserver==='undefined')return;
      let previous=null;
      const observer=new ResizeObserver(entries=>{
        const height=entries[0]?.contentRect.height;
        if(previous!==null && height!==previous) {
          metric('heightChanges');metric('heightDelta',Math.abs(height-previous));
          maximum('heightMax',Math.abs(height-previous));
        }
        previous=height;
      });
      observer.observe(document.body);
    },{once:true});
    const supported=typeof PerformanceObserver!=='undefined'?PerformanceObserver.supportedEntryTypes||[]:[];
    for(const type of ['longtask','layout-shift'])if(supported.includes(type)) {
      new PerformanceObserver(list=>{
        for(const entry of list.getEntries()) {
          if(type==='longtask') {metric('longTasks');maximum('longTaskMax',entry.duration);}
          else {metric('layoutShifts');metric('layoutShiftScore',entry.value||0);}
        }
      }).observe({type,buffered:false});
    }
    trace('scroll.instrumented',{version:2,longTaskSupported:supported.includes('longtask')?1:0,
      layoutShiftSupported:supported.includes('layout-shift')?1:0});
    setInterval(()=>{
      if(!Object.keys(scrollMetrics).length)return;
      trace('scroll.sample',scrollMetrics);scrollMetrics={};
    },1000);
  }
  function post(message) {
    if(message.kind==='lazyItems')trace('batch.request',{token:message.token,count:message.ids.length,
      reason:lazyRefreshQueue?'refresh':lazyJump?'navigation':lazyRestoreY?'restore':'viewport',groups:lazyGroups.size});
    bridge.postMessage(message);
  }
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
  // ---- One header for feed pages and the topic shell. Links come from HN's
  // own header so per-user URLs and the logout token stay correct. ----
  const headerPaths = new Set(['/', '/news', '/newest', '/front', '/newcomments', '/ask', '/show', '/jobs', '/submit',
    '/threads', '/best', '/active', '/lists', '/login', '/logout', '/user']);
  const defaultSections = [['new', '/newest'], ['threads', '/threads'], ['past', '/front'], ['comments', '/newcomments'],
    ['ask', '/ask'], ['show', '/show'], ['jobs', '/jobs'], ['submit', '/submit']];
  const headerModel = {links: null, identity: {state: 'pending'}, hidden: 0, unresolved: 0, retry: null};
  let headerSignature = '';
  function readHeader(root, base) {
    const spans = [...root.querySelectorAll('.pagetop')];
    if (!spans.length) return null;
    const links = [];
    const identity = {state: 'out', loginURL: new URL('/login?goto=news', base).href};
    for (const span of spans) for (const a of span.querySelectorAll('a[href]')) {
      let url; try { url = new URL(a.getAttribute('href'), base); } catch (_) { continue; }
      if (url.origin !== location.origin || !headerPaths.has(url.pathname)) continue;
      const label = a.textContent.trim();
      if (a.id === 'me' && url.pathname === '/user') {
        identity.state = 'in'; identity.name = label; identity.profileURL = url.href;
        identity.karma = (/\((\d[\d,]*)\)/.exec(span.textContent) || [])[1] || '';
        continue;
      }
      if (url.pathname === '/logout') { identity.logoutURL = url.href; continue; }
      if (url.pathname === '/login') { identity.loginURL = url.href; continue; }
      if (a.closest('.hnname') || ['/', '/news', '/user'].includes(url.pathname)) continue;
      if (!label || links.some(entry => entry.url === url.href)) continue;
      links.push({label, url: url.href, current: !!a.closest('.topsel')});
    }
    if (identity.state === 'in' && !identity.logoutURL) identity.logoutURL = new URL('/logout?goto=news', base).href;
    return {links, identity};
  }
  function headerElement() {
    const shell = document.getElementById('hv-header');
    if (shell) return shell;
    if (document.body?.dataset.hvTopic) {
      const header = document.createElement('header'); header.id = 'hv-header'; header.className = 'hv-header';
      (document.getElementById('hv-topic') || document.body).prepend(header);
      return header;
    }
    const cell = document.querySelector('#hnmain > tbody > tr:first-child > td');
    if (!cell) {
      if (!document.body || document.getElementById('hnmain')) return null;
      const header = document.createElement('header'); header.id = 'hv-header'; header.className = 'hv-header';
      document.body.classList.add('hv-plain'); document.body.prepend(header);
      const me = document.querySelector('a#me[href]');
      headerModel.identity = me ? readHeader(document.body, location.href)?.identity || {state: 'unknown'} : (location.pathname === '/login' ? {state: 'unknown'} : {state: 'out'});
      return header;
    }
    let header = cell.querySelector(':scope > header.hv-header');
    if (!header) {
      const parsed = readHeader(cell, location.href);
      if (!parsed) return null;
      headerModel.links = parsed.links; headerModel.identity = parsed.identity;
      header = document.createElement('header'); header.className = 'hv-header';
      cell.replaceChildren(header);
    }
    return header;
  }
  function chipIcon(kind) {
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg'); svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS(ns, 'path');
    path.setAttribute('d', kind === 'retry' ? 'M21 12a9 9 0 1 1-2.6-6.4M21 4v5h-5'
      : kind === 'shown' ? 'M2 12c1-3 5-7 10-7s9 4 10 7c-1 3-5 7-10 7S3 15 2 12zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z'
      : 'M3 3l18 18M10.6 10.6a2 2 0 0 0 2.8 2.8M9.9 5.1A10.4 10.4 0 0 1 12 5c5 0 9 4 10 7-.4 1.1-1.2 2.4-2.4 3.6M6.3 6.3C4.3 7.7 2.7 9.7 2 12c1 3 5 7 10 7 1.7 0 3.2-.4 4.5-1');
    svg.append(path); return svg;
  }
  function renderHeader() {
    const host = headerElement();
    if (!host) return;
    const model = headerModel;
    const signature = JSON.stringify([location.pathname, model.links, model.identity, model.hidden, model.unresolved, revealAll]);
    if (signature === headerSignature && host.childElementCount) return;
    headerSignature = signature;
    const item = (label, url, options = {}) => {
      const li = document.createElement('li'); const a = hnLink(label, url);
      if (options.current) a.setAttribute('aria-current', 'page');
      if (options.id) a.id = options.id;
      if (options.className) a.className = options.className;
      li.append(a); return li;
    };
    const nav = document.createElement('ul'); nav.className = 'hv-nav';
    const links = model.links || defaultSections.map(([label, path]) => ({label, url: new URL(path, 'https://news.ycombinator.com/').href}));
    const topic = !!document.body?.dataset.hvTopic;
    const onFeedHome = !topic && !links.some(link => link.current) && ['/', '/news'].includes(location.pathname);
    nav.append(item('home', 'https://news.ycombinator.com/', {current: onFeedHome}));
    for (const link of links) nav.append(item(link.label, link.url, {current: !topic && !!link.current}));
    const side = document.createElement('ul'); side.className = 'hv-side';
    const plural = (n, noun) => n + ' ' + noun + (n === 1 ? '' : 's');
    if (model.hidden > 0) {
      const li = document.createElement('li'); const chip = document.createElement('button'); chip.type = 'button'; chip.className = 'hv-chip';
      chip.setAttribute('aria-pressed', String(revealAll));
      chip.append(chipIcon(revealAll ? 'shown' : 'hidden'), document.createTextNode((revealAll ? 'Showing ' : '') + model.hidden + ' hidden'));
      chip.title = revealAll ? 'Hide the ' + plural(model.hidden, 'revealed contribution') + ' again'
        : 'Temporarily show the ' + plural(model.hidden, 'contribution') + ' hidden by your filters';
      chip.onclick = toggleRevealAll; li.append(chip); side.append(li);
      const status = document.createElement('span'); status.className = 'hv-sr'; status.setAttribute('role', 'status');
      status.textContent = revealAll ? 'Showing ' + plural(model.hidden, 'hidden contribution') + ' temporarily' : ''; li.append(status);
    }
    if (model.unresolved > 0) {
      const li = document.createElement('li'); const chip = document.createElement('button'); chip.type = 'button'; chip.className = 'hv-chip hv-chip-alert';
      chip.append(chipIcon('retry'), document.createTextNode(model.unresolved + ' unchecked · retry'));
      chip.title = plural(model.unresolved, 'contribution') + ' couldn’t be checked. Retry.';
      chip.onclick = () => model.retry?.(); li.append(chip); side.append(li);
    }
    const identity = model.identity || {state: 'unknown'};
    if (identity.state === 'pending') {
      const li = document.createElement('li'); li.className = 'hv-account';
      const skeleton = document.createElement('span'); skeleton.className = 'hv-skeleton'; skeleton.setAttribute('aria-label', 'Loading account');
      li.append(skeleton); side.append(li);
    } else if (identity.state === 'in') {
      const li = document.createElement('li'); li.className = 'hv-account';
      const me = hnLink(identity.name, identity.profileURL); me.id = 'me'; me.className = 'hv-me'; li.append(me);
      if (identity.karma) { const karma = document.createElement('span'); karma.className = 'hv-karma'; karma.textContent = identity.karma; karma.title = 'Karma'; li.append(karma); }
      side.append(li);
      side.append(item('logout', identity.logoutURL, {id: 'logout'}));
    } else if (identity.state === 'out') {
      side.append(item('login', identity.loginURL || 'https://news.ycombinator.com/login?goto=news'));
    }
    host.replaceChildren(nav, side);
  }
  // A filtered row keeps the reason it was hidden so a temporary reveal can label it.
  function markFiltered(row, reason) { row.classList.add('qhn-filtered'); row.dataset.qhnReason = reason || ''; }
  function revealTargets(row) {
    if (row.matches('.comtr') || !row.querySelector('.titleline')) return [row];
    const metadata = row.nextElementSibling;
    return [row, metadata, metadata?.nextElementSibling?.matches('.spacer') ? metadata.nextElementSibling : null].filter(Boolean);
  }
  function revealLabel(head, reason) {
    if (!head) return;
    let label = head.querySelector(':scope > .qhn-reveal-label');
    if (!label) { label = document.createElement('span'); label.className = 'qhn-reveal-label'; head.append(label); }
    label.textContent = 'Hidden by ' + (reason || 'your filters');
    label.title = 'Temporarily revealed. Reload or use the header control to hide it again.';
  }
  function setRevealed(row, revealed) {
    const targets = revealTargets(row);
    for (const element of targets) {
      element.classList.toggle('qhn-revealed', revealed);
      element.toggleAttribute('data-qhn-revealed', revealed);
      if (revealed) { element.removeAttribute('data-qhn-hidden'); hidden.delete(element); } else hide(element);
    }
    const author = (targets[1] || row).querySelector('.hnuser') || row.querySelector('.hnuser');
    const head = author?.closest('.comhead, .subtext') || author?.parentElement;
    if (revealed) revealLabel(head, row.dataset.qhnReason);
    else head?.querySelector(':scope > .qhn-reveal-label')?.remove();
  }
  function toggleRevealAll() {
    revealAll = !revealAll;
    if (lazyThread) {
      for (const node of lazyNodes.values()) if (filteredEffect(node.entry?.effect)) lazyRender(node, node.entry);
      lazyHeaderStatus(); lazyPump();
    } else {
      for (const row of document.querySelectorAll('tr.athing.qhn-filtered')) setRevealed(row, revealAll);
      renderHeader();
    }
  }
  function setHeaderStatus(hidden, unresolved, retry) {
    headerModel.hidden = hidden; headerModel.unresolved = unresolved; headerModel.retry = retry;
    renderHeader();
  }
  function addControls() {
    renderHeader();
    if (!requestedOP && location.pathname === '/item') {
      const id = Number(new URL(location.href).searchParams.get('id'));
      if (id > 0) { requestedOP = true; post({kind: 'originalPoster', id}); }
    }
    paintOP();
    document.querySelectorAll('tr.athing').forEach(row => {
      if (!row.querySelector('.titleline') || row.closest('.fatitem')) return;
      row.classList.add('qhn-story');
      row.nextElementSibling?.classList.add('qhn-story-meta');
      row.closest('table')?.classList.add('qhn-feed');
    });
    document.querySelectorAll('tr.athing:not(.comtr)').forEach(row => {
      if (row.querySelector(':scope > td.default') && !row.querySelector('.titleline')) row.classList.add('comtr', 'qhn-flat');
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
      if (location.pathname === '/user' && !link.closest('.pagetop, .hv-header') &&
          link.textContent.trim() === new URL(location.href).searchParams.get('id')) return;
      if (link.dataset.qhnControl) return;
      link.dataset.qhnControl = '1';
      const author = link.textContent.trim();
      let row = link.closest('tr.comtr, tr.athing');
      if (!row) {
        const metadata = link.closest('tr');
        if (metadata?.previousElementSibling?.matches('.athing')) row = metadata.previousElementSibling;
      }
      (link.nextElementSibling?.matches('.qhn-op') ? link.nextElementSibling : link).after(recordButton(author, row, link));
    });
  }
  function recordButton(author, row, link, label = '⋯') {
    const button = document.createElement('button');
    button.className = 'qhn-record' + (label === '⋯' ? '' : ' qhn-record-text');
    button.textContent = label;
    button.title = `Flag this user or save a note about this comment`;
    button.setAttribute('aria-label', `Block, highlight, or annotate ${author}`);
    button.addEventListener('click', event => {
      event.preventDefault(); event.stopPropagation();
      editedRow = row?.id || null;
      post(capture(author, row, link));
    });
    return button;
  }

  function collect() {
    document.querySelectorAll('tr.athing:not(.comtr)').forEach(row => {
      if (row.querySelector(':scope > td.default') && !row.querySelector('.titleline')) row.classList.add('comtr', 'qhn-flat');
    });
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
    const link = [...document.querySelectorAll('.hnuser')].find(link => link.textContent.trim() === username && !link.closest('.pagetop, .hv-header'));
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
    function change() { dirty = true; clearTimeout(timer); timer = setTimeout(save, 5000); profileSaveStatus(null); }
    input.oninput = change; source.oninput = change;
    input.onblur = save; source.onblur = save;
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
      const link = document.createElement('a'); link.href = url.href; if (url.hostname === 'news.ycombinator.com') link.target = '_blank'; link.textContent = entry.title || url.href; source.append(link); row.append(source);
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
    const userLink = [...document.querySelectorAll('.hnuser')].find(link => link.textContent.trim() === username && !link.closest('.pagetop, .hv-header'));
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
    detail.textContent = result.effect === 'varies'
      ? 'Post/comment scope, content patterns, and direct assignments are evaluated for each contribution.'
      : result.effect === 'unresolved'
      ? `Could not verify filter ${result.priority}: ${result.ruleName}. Retry when connected.`
      : result.label === 'Shown without unverified styling'
      ? 'Some filter conditions could not be verified. Contributions remain visible without filter styling.'
      : matched ? `Filter ${result.priority}: ${result.ruleName}. ${result.effect === 'blocked' ? 'Contributions are blocked. The filter’s Hide replies too setting controls descendants.' : 'First matching filter for this account.'}`
      : 'No enabled filter matches this account. Contributions are shown normally.';
    if (result.effect?.startsWith('highlight:') && /^#[0-9a-f]{6}$/i.test(result.effect.slice(10))) {
      panel.style.setProperty('--qhn-profile-color', result.effect.slice(10));
    } else if (result.effect === 'blocked') panel.style.setProperty('--qhn-profile-color', 'var(--qhn-accent)');
    const copy = document.createElement('div'); copy.className = 'qhn-profile-copy';
    copy.append(heading, detail);
    if(result.contributionCaveat){const caveat=document.createElement('p');caveat.textContent='Content, scope, and per-item rules may change the effect on individual contributions.';copy.append(caveat);}
    panel.appendChild(copy);
    if (result.effect === 'unresolved') {
      const retry = document.createElement('button'); retry.textContent = 'Retry'; retry.onclick = () => process(); copy.appendChild(retry);
    }
    panel.appendChild(profileAction());
  }
  let matchedHighlights = new Set();
  let pending = null;
  let progressTimer;
  let progressBoundary;
  function showProgress(boundary, complete) {
    let progress = document.getElementById('qhn-progress');
    if (!boundary) {
      progress?.remove(); clearTimeout(progressTimer); progressBoundary = null; return;
    }
    if (!progress) {
      progress = document.createElement('tr'); progress.id = 'qhn-progress';
      const cell = document.createElement('td'); cell.colSpan = 100;
      const status = document.createElement('div'); status.className = 'qhn-loading'; status.setAttribute('role', 'status');
      cell.append(status); progress.append(cell);
    }
    boundary.before(progress);
    if (progressBoundary === boundary && !complete) return;
    progressBoundary = boundary;
    clearTimeout(progressTimer);
    const status = progress.firstElementChild.firstElementChild;
    const stalled = () => {
      status.replaceChildren();
      const text = document.createElement('span');
      text.textContent = complete ? 'Some contributions couldn’t be checked.' : 'Still checking…';
      const retry = document.createElement('button'); retry.textContent = 'Retry'; retry.onclick = () => process();
      status.append(text, retry);
    };
    if (complete) { stalled(); return; }
    const spinner = document.createElement('span'); spinner.className = 'qhn-spinner'; spinner.setAttribute('aria-hidden', 'true');
    status.replaceChildren(spinner, document.createTextNode('Loading more…'));
    progressTimer = setTimeout(stalled, 8000);
  }
  // Discussion documents contain only a shell. Children are requested in bounded
  // batches when their placeholder approaches the viewport; no full-thread HTML.
  let lazyThread = false;
  let lazyThreadRootID = null;
  let lazyToken = 0;
  const lazyPending = new Map();
  const lazyActive = () => [...lazyPending.values()].reduce((n,r)=>n+r.ids.size,0);
  let localPaused = false;
  let localToken = 0;
  let localApplying = false;
  let lazyRestoreAnchor = null;
  let lazyRefreshQueue = null;
  let lazyRestoreY = 0;
  let lazyJump = null;
  // The reader's previous visit to this discussion. Comments posted after it
  // are new; its reading anchor is where the reader left off.
  let visitBaseline = null;
  const pluralize = (n, noun) => n + ' ' + noun + (n === 1 ? '' : 's');
  const lazyNodes = new Map();
  const lazyCollapsed = new Set();
  const lazyGroups = new Map();
  let lazyObserver;
  function safeBody(html) {
    const parsed = new DOMParser().parseFromString(html || '', 'text/html');
    const output = document.createDocumentFragment();
    const allowed = new Set(['P','A','I','EM','B','STRONG','PRE','CODE','BR','BLOCKQUOTE','UL','OL','LI']);
    function copy(source, target) {
      for (const child of source.childNodes) {
        if (child.nodeType === 3) { target.append(document.createTextNode(child.textContent)); continue; }
        if (child.nodeType !== 1 || ['SCRIPT','STYLE','IFRAME','OBJECT'].includes(child.tagName)) continue;
        if (!allowed.has(child.tagName)) { copy(child, target); continue; }
        const element = document.createElement(child.tagName.toLowerCase());
        if (child.tagName === 'A') {
          try { const url = new URL(child.getAttribute('href'), 'https://news.ycombinator.com/');
            if (['https:','http:','mailto:'].includes(url.protocol)) element.href = url.href;
          } catch (_) {}
          element.rel = 'noreferrer';
        }
        copy(child, element); target.append(element);
      }
    }
    copy(parsed.body, output); return output;
  }
  function hnLink(text, path) {
    const link = document.createElement('a'); link.textContent = text;
    link.href = new URL(path, 'https://news.ycombinator.com/').href;
    return link;
  }
  function lazyStatus(host, text, retry) {
    host.replaceChildren();
    const status = document.createElement('div'); status.className = 'qhn-loading'; status.setAttribute('role','status');
    if (!retry) { const spinner = document.createElement('span'); spinner.className = 'qhn-spinner'; status.append(spinner); }
    status.append(document.createTextNode(text));
    if (retry) { const button = document.createElement('button'); button.textContent = 'Retry'; button.onclick = retry; status.append(button); }
    host.append(status);
  }
  function lazyGroup(host, ids, depth, ancestors) {
    const sentinel = document.createElement('div'); sentinel.className = 'hv-more';
    host.append(sentinel);
    const group = {host, ids: ids.filter(id => Number.isSafeInteger(id) && id > 0 && !ancestors.has(id)), offset: 0, depth, ancestors, sentinel, queuedAt: performance.now()};
    lazyGroups.set(sentinel, group);
    trace('group.queued',{id:group.ids[0]||0,parent:[...ancestors].at(-1)||0,count:group.ids.length,depth});
    lazyStatus(sentinel, 'Loading comments…');
    lazyObserver?.observe(sentinel);
    return group;
  }
  const filteredEffect = effect => effect === 'blocked' || effect === 'hidden-item';
  // The nearest loaded ancestor hidden for the same reason as this node: the
  // contribution whose branch block it inherits, or another reply under it.
  function inheritanceAnchor(node, entry = node.entry) {
    if (entry?.effect !== 'blocked' || !entry.inheritedFrom) return null;
    for (const id of [...node.ancestors].reverse()) {
      const ancestor = lazyNodes.get(id);
      if (ancestor?.entry && (ancestor.id === entry.inheritedFrom || ancestor.entry.inheritedFrom === entry.inheritedFrom)) return ancestor;
    }
    return null;
  }
  // Hidden on its own account. Replies hidden only because of a loaded
  // ancestor are neither counted nor labelled: revealing that ancestor lifts them.
  function lazyFiltered(node, entry = node.entry) {
    return filteredEffect(entry?.effect) && node.id !== revealedID && !inheritanceAnchor(node, entry);
  }
  function lazyShown(node, entry = node.entry) {
    if (!filteredEffect(entry?.effect)) return true;
    if (node.id === revealedID || revealAll) return true;
    const anchor = inheritanceAnchor(node, entry);
    return !!anchor && lazyShown(anchor);
  }
  function lazyHeaderStatus() {
    const nodes = [...lazyNodes.values()];
    const hiddenNodes = nodes.filter(n => lazyFiltered(n)).length;
    const unresolvedNodes = nodes.filter(n => n.entry?.effect === 'unresolved');
    const unresolved = lazyActive() ? 0 : unresolvedNodes.length;
    setHeaderStatus(hiddenNodes, unresolved, () => { localPaused = false; lazyRefreshQueue = unresolvedNodes; lazyPump(); });
    return {hidden: hiddenNodes, unresolved};
  }
  // The discussion root's own reveal control. Its replies follow it.
  function setRootRevealed(revealed) {
    const id = Number(document.body.dataset.hvTopic);
    revealedID = revealed ? id : null;
    // Hiding the destination again ends the chip's reveal too; otherwise the
    // root would stay on screen and the control would appear to do nothing.
    if (!revealed && revealAll) { toggleRevealAll(); return; }
    const root = lazyNodes.get(id);
    if (root?.entry) lazyRender(root, root.entry);
    lazyHeaderStatus(); lazyPump();
  }
  function lazyAnnounce() {
    if (lazyRefreshQueue) return;
    if(lazyRestoreAnchor) {
      const anchor=lazyRestoreAnchor;
      const node=lazyNodes.get(anchor.id);
      if(node?.entry && !lazyActive()) {
        if(node.entry.effect==='blocked' || node.entry.effect==='hidden-item')lazyRestoreAnchor=null;
        else {
          node.host.style.contentVisibility='visible';
          restoreReadingPosition(anchor,lazyRestoreY);
          lazyRestoreAnchor=null;lazyRestoreY=0;
        }
      } else if(anchor.ancestors.some(id=>{
        const n=lazyNodes.get(id);
        return n?.entry && (n.entry.effect==='blocked' || n.entry.effect==='unresolved' ||
          !n.entry.item?.kids?.includes([...anchor.ancestors,anchor.id][anchor.ancestors.indexOf(id)+1]));
      }))lazyRestoreAnchor=null;
    }
    if (!lazyRestoreAnchor && lazyRestoreY > 0 && !lazyActive()) {
      if (document.documentElement.scrollHeight >= lazyRestoreY + innerHeight || (!lazyGroups.size && !lazyActive())) {
        window.scrollTo(0,lazyRestoreY); lazyRestoreY=0;
      }
    }
    ready = true; document.documentElement.removeAttribute('data-qhn-pending');
    renderVisitLine();if(visitBaseline)refreshNewNavigation();
    const {hidden:hiddenNodes, unresolved}=lazyHeaderStatus();
    post({kind:'ready', complete:true, hidden:hiddenNodes, unresolved, title:document.title, destinationHidden:false});
    rememberViewportAnchor();
  }
  function lazySchedule(group, count) {
    const ids=group.ids.slice(group.offset,group.offset+count);
    group.offset+=ids.length;
    const nodes=ids.map(id=>{
      if(lazyNodes.has(id))return lazyNodes.get(id);
      const host=document.createElement('div');host.className='hv-node';group.sentinel.before(host);
      const own=document.createElement('div');own.className='hv-own';host.append(own);lazyStatus(own,'Loading comments…');
      const node={id,host,group,depth:group.depth,ancestors:group.ancestors,collapsed:lazyCollapsed.has(id)};lazyNodes.set(id,node);return node;
    });
    if(group.offset===group.ids.length) {lazyObserver?.unobserve(group.sentinel);group.sentinel.remove();lazyGroups.delete(group.sentinel);}
    lazyRequestNodes(nodes);
  }
  function lazyRequestNodes(nodes) {
    if(!nodes.length)return;
    const token=++lazyToken;
    lazyPending.set(token,{ids:new Set(nodes.map(n=>n.id)),nodes});
    post({kind:'lazyItems',ids:nodes.map(n=>n.id),token,visible:nodes.some(n=>{const r=n.host.getBoundingClientRect();return r.bottom>0 && r.top<innerHeight;})});
  }
  function lazyPump() {
    if(!scrollDiagnostics)return lazyPumpWork();
    const start=performance.now();
    try {return lazyPumpWork();}
    finally {const ms=performance.now()-start;metric('pumpCalls');metric('pumpTotal',ms);maximum('pumpMax',ms);}
  }
  function lazyPumpWork() {
    if(!lazyThread || localPaused)return;
    if(lazyRefreshQueue) {
      while(lazyRefreshQueue.length && lazyActive()<32)lazyRequestNodes(lazyRefreshQueue.splice(0,Math.min(8,32-lazyActive())));
      if(!lazyRefreshQueue.length && !lazyActive()){lazyRefreshQueue=null;restoreFilterAnchor();lazyAnnounce();}
      else return;
    }
    if(lazyJump) {
      const {group,candidates,link}=lazyJump;
      while(candidates.length) {
        const node=lazyNodes.get(candidates[0]);
        if(!node || !node.entry) {
          if(!node && lazyActive()<32)lazySchedule(group,Math.min(8,32-lazyActive()));
          break;
        }
        if(['blocked','hidden-item'].includes(node.entry.effect) || (node.entry.item?.deleted && !node.entry.item.kids?.length)){candidates.shift();continue;}
        node.host.style.contentVisibility='visible';node.host.scrollIntoView({block:'start'});
        link.removeAttribute('aria-busy');link.textContent=lazyJump.label;lazyJump=null;break;
      }
      if(lazyJump && !candidates.length){link.removeAttribute('aria-busy');link.textContent=lazyJump.label;link.title='No more visible comments';lazyJump=null;}
    }
    if(lazyRestoreAnchor) {
      const path=[...lazyRestoreAnchor.ancestors,lazyRestoreAnchor.id];
      for(const id of path) {
        if(lazyNodes.has(id))continue;
        const group=[...lazyGroups.values()].find(g=>g.ids.includes(id));
        if(group && lazyActive()<32) {
          // Preserve sibling ordering while advancing the branch containing the anchor.
          while(group.offset<=group.ids.indexOf(id) && lazyActive()<32)
            lazySchedule(group,Math.min(8,32-lazyActive()));
        }
        break;
      }
    }
    while(lazyActive()<32) {
      // Keep filling slots until the entire allowed tree is loaded. Geometry
      // controls priority only; distant and collapsed branches still make progress.
      const restoring=!!(lazyRestoreAnchor || lazyRestoreY);
      const needsRestoreContent=lazyRestoreY && document.documentElement.scrollHeight<lazyRestoreY+innerHeight;
      const groups=[...lazyGroups.values()].filter(g=>!restoring ||
        (g.sentinel.getClientRects().length && (needsRestoreContent || g.sentinel.getBoundingClientRect().top<innerHeight+500)));
      const distance=g=>{
        if(!g.sentinel.getClientRects().length)return Infinity;
        const r=g.sentinel.getBoundingClientRect();
        if(r.top>=0 && r.top<innerHeight)return 0;
        return Math.min(Math.abs(r.top),Math.abs(r.top-innerHeight));
      };
      const priorities=new Map(groups.map(g=>[g,distance(g)]));
      groups.sort((a,b)=>priorities.get(a)-priorities.get(b));
      const group=groups[0];if(!group)break;
      trace('group.start',{id:group.ids[group.offset],queueMs:performance.now()-group.queuedAt,visible:!!group.visibleAt,ms:group.visibleAt?performance.now()-group.visibleAt:0});
      lazySchedule(group,Math.min(8,32-lazyActive()));
    }
    lazyAnnounce();
  }
  let networkToken=0;
  const networkWaiters=new Map();
  async function pooledFetch(url,options) {
    if(!window.__hackerViewsNetworkPool)return fetch(url,options);
    const token=++networkToken;
    await new Promise(resolve=>{networkWaiters.set(token,resolve);post({kind:'networkAcquire',token});});
    try {
      const response=await fetch(url,options);
      // Keep the lease until the response body has finished downloading.
      const body=await response.arrayBuffer();
      return new Response(body,{status:response.status,statusText:response.statusText,headers:response.headers});
    } finally {post({kind:'networkRelease',token});}
  }
  const canonicalItems = new Map();
  // HN's own comment form for this discussion, taken from its authenticated
  // HTML: the hidden fields carry the token HN requires, so the reader can
  // offer the box inline and post through HN like the real page does.
  let canonicalCommentForm = null, canonicalCommentState = 'pending', commentControl = null;
  function rememberCommentForm(doc, target) {
    if (canonicalCommentState !== 'pending' || new URL(target).searchParams.get('id') !== document.body.dataset.hvTopic) return;
    const topic = document.body.dataset.hvTopic;
    const form = [...doc.querySelectorAll('form[action]')].find(candidate => {
      let action; try { action = new URL(candidate.getAttribute('action'), target); } catch (_) { return false; }
      return action.origin === location.origin && action.pathname === '/comment' && candidate.querySelector('input[type="hidden"][name="parent"]')?.value === topic;
    });
    const fields = form ? [...form.querySelectorAll('input[type="hidden"][name]')].map(input => ({name: input.name, value: input.value})) : [];
    canonicalCommentForm = form ? {fields} : null;
    canonicalCommentState = form ? 'ready' : 'none';
    renderCommentBox();
  }
  function commentToggle() {
    const toggle = document.createElement('button'); toggle.type = 'button'; toggle.className = 'hv-comment-toggle';
    toggle.textContent = 'comment'; toggle.title = 'Add a comment'; toggle.setAttribute('aria-expanded', 'false');
    toggle.onclick = () => setCommentBoxOpen(commentControl?.host?.hidden !== false);
    commentControl = {...(commentControl || {}), toggle}; return toggle;
  }
  function commentHost() {
    const host = document.createElement('div'); host.className = 'hv-comment-host hv-comment'; host.hidden = true;
    commentControl = {...(commentControl || {}), host}; return host;
  }
  function setCommentBoxOpen(open) {
    const {toggle, host} = commentControl || {};
    if (!host) return;
    host.hidden = !open; toggle?.setAttribute('aria-expanded', String(open)); toggle?.classList.toggle('hv-open', open);
    if (open) { renderCommentBox(); host.querySelector('textarea')?.focus(); } else toggle?.focus();
  }
  // What changed since the reader's last visit, and where they left off.
  let visitLineHost = null, visitLineText = '';
  // New and not yet read. Jumping on from a new comment reads it; the marks
  // never change under a reader who is only scrolling.
  function newComments() { return [...lazyNodes.values()].filter(n => n.isNew && !n.readNew); }
  function newBelow(node) { return [...lazyNodes.values()].filter(n => n.isNew && !n.readNew && n.ancestors.has(node.id)).length; }
  let currentNew = null;
  function markRead(row) {
    const node = lazyNodes.get(Number(row?.id));
    if (!node?.isNew || node.readNew) return;
    node.readNew = true; row.classList.remove('hv-new'); row.classList.add('hv-new-read');
    for (const id of node.ancestors) lazyNodes.get(id)?.updateToggle?.();
  }
  function visitLine() {
    const line = document.createElement('div'); line.className = 'hv-visit'; line.hidden = !visitBaseline;
    visitLineHost = line; visitLineText = ''; renderVisitLine(); return line;
  }
  // Every comment is loaded and rendered, so the new-comment count is final.
  function threadComplete() {
    return lazyGroups.size === 0 && lazyPending.size === 0 && queuedResults.size === 0 && [...lazyNodes.values()].every(n => n.entry);
  }
  let pendingNextNew = false, pendingLink = null;
  function goToRow(target) {
    if (currentNew && currentNew !== target) markRead(currentNew);
    currentNew = target;
    const node = lazyNodes.get(Number(target.id));
    for (const id of node ? node.ancestors : []) { const ancestor = lazyNodes.get(id); if (ancestor?.collapsed) ancestor.expand?.(); }
    target.closest('.hv-node')?.style.setProperty('content-visibility', 'visible');
    target.scrollIntoView({block: 'start'}); target.classList.add('hv-flash'); setTimeout(() => target.classList.remove('hv-flash'), 1200);
    pendingNextNew = false; pendingLink = null;
    const control = visitLineHost?.querySelector('.hv-next-new'); if (control) { control.textContent = 'Next new'; control.disabled = false; }
    renderVisitLine(); refreshNewNavigation();
  }
  const follows = (row, other) => !!(row.compareDocumentPosition(other) & Node.DOCUMENT_POSITION_FOLLOWING);
  function jumpFromNew(node, link) {
    const row = document.getElementById(String(node.id));
    const unread = [...document.querySelectorAll('tr.comtr.hv-new')];
    const after = unread.filter(other => follows(row, other)), others = unread.filter(other => other !== row);
    const target = after[0] || (threadComplete() && others.length ? others[0] : null);
    if (target) { markRead(row); goToRow(target); return; }
    if (threadComplete()) return;
    pendingNextNew = true; pendingLink = link; link.textContent = 'loading…'; localPaused = false; lazyPump();
  }
  function refreshNewNavigation() {
    const unread = [...document.querySelectorAll('tr.comtr.hv-new')], complete = threadComplete();
    for (const wrap of document.querySelectorAll('tr.comtr .hv-new-nav')) {
      const row = wrap.closest('tr.comtr'), link = wrap.querySelector('a');
      const after = unread.some(other => follows(row, other)), others = unread.some(other => other !== row);
      const label = after ? 'next new' : !complete ? 'next new' : others ? 'first new' : '';
      wrap.hidden = !label;
      if (label) link.textContent = pendingNextNew && link === pendingLink ? 'loading…' : label;
    }
  }
  function renderVisitLine() {
    const line = visitLineHost;
    if (!line || !visitBaseline) return;
    const topic = Number(document.body.dataset.hvTopic);
    // Counted from the comments themselves, the same test that marks them, so
    // the line never promises a comment the marks cannot find.
    const count = newComments().length, complete = threadComplete();
    const text = count ? pluralize(count, 'new comment') + ' since your last visit'
      : complete ? 'Nothing new since your last visit' : 'Looking for new comments since your last visit';
    const key = text + (complete ? '' : '…');
    if (key === visitLineText) return;
    visitLineText = key; line.replaceChildren();
    const label = document.createElement('span'); label.className = 'hv-visit-text' + (count ? ' hv-visit-new' : ''); label.textContent = text;
    const when = document.createElement('span'); when.className = 'hv-visit-when'; when.textContent = '(' + relativeTime(visitBaseline.viewedAt) + ')';
    line.append(label, when);
    if (!complete && count) { const loading = document.createElement('span'); loading.className = 'hv-visit-loading'; loading.textContent = '· still loading'; line.append(loading); }
    if (count || !complete) {
      const next = document.createElement('button'); next.type = 'button'; next.className = 'hv-next-new';
      next.textContent = pendingNextNew ? 'Loading…' : 'Next new'; next.disabled = pendingNextNew;
      next.title = 'Jump to the next new comment (N)'; next.onclick = () => jumpToNextNew(next); line.append(next);
    }
    const anchor = visitBaseline.anchor;
    if (anchor && !visitBaseline.reload && Number.isSafeInteger(anchor.id) && anchor.id > 0 && anchor.id !== topic) {
      const jump = document.createElement('button'); jump.type = 'button'; jump.className = 'hv-resume'; jump.textContent = 'Jump to where you left off';
      jump.onclick = () => resumeReading(anchor); line.append(jump);
    }
  }
  function resumeReading(anchor) {
    const node = lazyNodes.get(anchor.id);
    if (node?.entry && node.host.getClientRects().length) { node.host.style.contentVisibility = 'visible'; restoreReadingPosition(anchor, anchor.y || 0); return; }
    lazyRestoreAnchor = {id: anchor.id, top: anchor.top || 0, ancestors: Array.isArray(anchor.ancestors) ? anchor.ancestors : []};
    lazyRestoreY = anchor.y || 0; localPaused = false; lazyPump();
  }
  function jumpToNextNew(button) {
    // Thread order, including comments inside collapsed branches, which sit
    // where their collapsed ancestor sits on screen.
    const rowTop = row => {
      if (row.getClientRects().length) return row.getBoundingClientRect().top;
      let host = row.closest('.hv-node');
      while (host && !host.getClientRects().length) host = host.parentElement?.closest('.hv-node');
      return host ? host.getBoundingClientRect().top : Infinity;
    };
    const rows = [...document.querySelectorAll('tr.comtr.hv-new')];
    const target = rows.find(row => rowTop(row) > 60) || rows[0];
    if (target) { goToRow(target); return; }
    if (threadComplete()) return;
    // Nothing new is loaded yet: keep loading and jump when one arrives.
    pendingNextNew = true; pendingLink = null;
    if (button) { button.textContent = 'Loading…'; button.disabled = true; }
    localPaused = false; lazyPump();
  }
  document.addEventListener('keydown', event => {
    if (!lazyThread || event.key !== 'n' || event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.target.closest?.('input, textarea, select, [contenteditable]')) return;
    if (document.querySelector('tr.comtr.hv-new')) { event.preventDefault(); jumpToNextNew(null); }
  });
  function renderCommentBox() {
    const host = commentControl?.host;
    if (!host || host.hidden) return;
    host.replaceChildren();
    if (canonicalCommentState === 'ready') {
      const form = document.createElement('form'); form.className = 'qhn-composer hv-comment-form'; form.method = 'post';
      form.action = new URL('/comment', 'https://news.ycombinator.com/').href;
      for (const field of canonicalCommentForm.fields) {
        const input = document.createElement('input'); input.type = 'hidden'; input.name = field.name; input.value = field.value; form.append(input);
      }
      const text = document.createElement('textarea'); text.name = 'text'; text.rows = 6; text.required = true; text.setAttribute('aria-label', 'Comment');
      const actions = document.createElement('p');
      const submit = document.createElement('input'); submit.type = 'submit'; submit.value = 'add comment';
      const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'hv-comment-cancel'; cancel.textContent = 'Cancel';
      cancel.onclick = () => setCommentBoxOpen(false);
      actions.append(submit, cancel); form.append(text, actions); host.append(form);
      return;
    }
    const note = document.createElement('div'); note.className = 'qhn-loading';
    if (canonicalCommentState === 'pending') { note.textContent = 'Loading the comment form…'; host.append(note); return; }
    note.append(canonicalCommentState === 'none' ? 'Hacker News isn’t offering a comment form for this story.' : 'The comment form couldn’t be loaded.');
    const open = document.createElement('button'); open.type = 'button'; open.textContent = 'Open on Hacker News';
    open.onclick = () => post({kind: 'canonical', url: new URL('/item?id=' + document.body.dataset.hvTopic, 'https://news.ycombinator.com/').href});
    const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'hv-comment-cancel'; cancel.textContent = 'Cancel';
    cancel.onclick = () => setCommentBoxOpen(false);
    note.append(open, cancel); host.append(note);
  }
  function relativeTime(seconds) {
    const age=Math.max(0,Math.floor(Date.now()/1000-seconds));
    for(const [unit,size] of [['year',31536000],['month',2592000],['day',86400],['hour',3600],['minute',60]]) {
      if(age>=size){const n=Math.floor(age/size);return n+' '+unit+(n===1?'':'s')+' ago';}
    }
    return 'just now';
  }
  function applyCanonicalMetadata(node) {
    const data=canonicalItems.get(node.id),own=node.host.querySelector(':scope > .hv-own');
    if(!data || !own)return;
    const heading=own.querySelector('.subtext .comhead, .comtr .comhead');
    let actions=own.querySelector('.hv-hn-actions');
    if(heading && data.actions.length && !actions?.childNodes.length) {
      if(!actions) {
        actions=document.createElement('span');actions.className='hv-hn-actions';
        if(heading.closest('.subtext'))heading.after(actions);
        else {const ours=heading.querySelector('.hv-reader-actions'),toggle=heading.querySelector('.hv-collapse');if(ours)ours.before(actions);else if(toggle)toggle.before(actions,'\u00a0');else heading.append(actions);}
      }
      for(const action of data.actions)actions.append(' | ',hnLink(action.label,action.url));
    }
    const count=own.querySelector('.hv-comment-count');
    if(count && Number.isFinite(data.comments))count.textContent=pluralize(data.comments,'comment');
    const text=own.querySelector('.commtext');
    if(text && data.fade)text.style.opacity=String(data.fade);
  }
  function rememberCanonicalItems(doc,target) {
    const allowed=new Set(['edit','delete','flag','unflag','hide','unhide','favorite','unfavorite','past']);
    for(const row of doc.querySelectorAll('tr.athing[id]')) {
      const id=Number(row.id);if(!Number.isSafeInteger(id)||id<=0)continue;
      const sources=[...row.querySelectorAll('.comhead')];
      if(!row.matches('.comtr') && row.nextElementSibling?.querySelector('.subtext'))sources.push(row.nextElementSibling);
      const actions=[];
      for(const source of sources)for(const a of source.querySelectorAll('a[href]')) {
        const label=a.textContent.trim().toLowerCase();
        if(!allowed.has(label))continue;
        let url;try{url=new URL(a.getAttribute('href'),target);}catch(_){continue;}
        if(url.origin!==location.origin || !['/edit','/delete-confirm','/delete','/flag','/hide','/fave','/front'].includes(url.pathname))continue;
        if(label!=='past' && url.searchParams.get('id')!==String(id))continue;
        if(!actions.some(action=>action.label===label))actions.push({label,url:url.href});
      }
      const text=row.querySelector('.commtext,.titleline');
      const shade=[...(text?.classList||[])].find(name=>/^c[0-9a-f]{2}$/.test(name));
      const countText=row.matches('.comtr')?null:[...(row.nextElementSibling?.querySelectorAll('a[href]')||[])].map(a=>a.textContent).find(t=>/^\s*\d+\s*comments?\s*$/.test(t));
      // HN's live count is what the visit record should remember, not the API's cached total.
      if(countText && id===Number(document.body.dataset.hvTopic))post({kind:'visitCount',id,count:Number(/\d+/.exec(countText)[0])});
      canonicalItems.set(id,{actions,showDead:!!text && !/^\s*\[(dead|deleted)\]\s*$/.test(text.textContent),
        fade:shade?Math.max(.35,1-parseInt(shade.slice(1),16)/255):null,comments:countText?Number(/\d+/.exec(countText)[0]):null});
      const node=lazyNodes.get(id);
      if(node?.entry?.item?.dead)lazyRender(node,node.entry);
      else if(node)applyCanonicalMetadata(node);
    }
  }
  const voteActions = new Map();
  const pendingVotes = new Set();
  const voteControls = new Map();
  const votePages = new Set();
  let votePage = location.href, voteFetching = false;
  let voteObserver;
  function updateVoteControls(id) {
    const actions=voteActions.get(id);
    // State lives on the arrow: a cast vote keeps its arrow, in accent, and
    // clicking it again undoes. Nothing else in the row changes.
    for(const {button,direction} of voteControls.get(id)||[]) {
      const cast=actions?.voted===direction;
      // While a vote stands the other arrow keeps its place, unseen, so the
      // cast arrow does not slide into its slot.
      const vacant=!!actions?.voted && !cast;
      button.hidden=actions?.voted ? false : !actions?.[direction];
      button.classList.toggle('hv-voted',cast);
      button.classList.toggle('hv-vacant',vacant);
      button.setAttribute('aria-pressed',String(cast));
      button.setAttribute('aria-hidden',String(vacant));
      button.tabIndex=vacant?-1:0;
      const verb=direction==='up'?'Upvote':'Downvote', state=direction==='up'?'Upvoted':'Downvoted';
      const label=cast ? (!actions.undo ? state : actions.undoFailed ? 'Undo failed. Click to retry' : state+'. Click to undo')
        : (button.dataset.hvRetry ? 'Retry vote' : verb);
      button.title=label;button.setAttribute('aria-label',label);
      button.disabled=pendingVotes.has(id) || vacant || (cast && !actions.undo);
    }
  }
  function voteLinkHidden(link) {
    for(let node=link;node && node.nodeType===1;node=node.parentElement) {
      if(node.hidden || node.classList.contains('nosee') || node.classList.contains('noshow') ||
         node.style.display==='none' || node.style.visibility==='hidden')return true;
    }
    return false;
  }
  function readVoteActions(doc,row,target) {
    const id=Number(row.id);
    const actions={};
    for(const a of row.querySelectorAll('.votelinks a[href]')) {
      if(a.closest('tr.athing')!==row || voteLinkHidden(a))continue;
      const url=new URL(a.getAttribute('href'),target),direction=url.searchParams.get('how');
      if(url.origin===location.origin && url.pathname==='/vote' && url.searchParams.get('id')===String(id) && url.searchParams.get('auth') && ['up','down'].includes(direction))actions[direction]=url.href;
    }
    const undo=doc.getElementById('un_'+id);
    if(undo && !voteLinkHidden(undo)) {
      const url=new URL(undo.getAttribute('href')||'',target);
      const label=undo.textContent.trim().toLowerCase();
      if(url.origin===location.origin && url.pathname==='/vote' && url.searchParams.get('id')===String(id) && url.searchParams.get('how')==='un' && url.searchParams.get('auth')) {
        if(label==='unvote')actions.voted='up';
        else if(label==='undown')actions.voted='down';
        if(actions.voted)actions.undo=url.href;
      }
    }
    return actions;
  }
  async function undoVote(id) {
    const previous=voteActions.get(id);
    if(!previous?.undo || pendingVotes.has(id))return;
    pendingVotes.add(id);updateVoteControls(id);
    try {
      const url=new URL(previous.undo);url.searchParams.set('js','t');
      const response=await pooledFetch(url.href,{credentials:'same-origin',cache:'no-store'});
      if(!response.ok)throw new Error();
      voteActions.set(id,{});updateVoteControls(id);
      // Ask HN which actions are now eligible; never infer downvote eligibility.
      const target=new URL('/item?id='+id,location.origin).href;
      const page=await pooledFetch(target,{credentials:'same-origin',cache:'no-store'});
      if(page.ok) {
        const doc=new DOMParser().parseFromString(await page.text(),'text/html');
        const row=doc.querySelector('tr.athing[id="'+id+'"]');
        if(row)voteActions.set(id,readVoteActions(doc,row,target));
      }
    } catch (_) {
      if(voteActions.get(id)===previous)previous.undoFailed=true;
      // If the undo request failed, retain the voted state and allow retry.
      // If only the subsequent eligibility fetch failed, leave unknown actions hidden.
    } finally {pendingVotes.delete(id);updateVoteControls(id);}
  }
  async function loadVoteActions() {
    if(localPaused || voteFetching || !votePage || typeof fetch!=='function')return;
    const needed=[...voteControls].some(([id,controls])=>!voteActions.has(id) && controls.some(c=>c.visible && c.button.isConnected));
    if(!needed && votePages.size)return;
    const target=votePage;if(votePages.has(target))return;
    voteFetching=true;
    const voteStarted=performance.now();trace('votes.start');
    try {
      // HN's read-only item API has no per-account voting permissions. Inspect
      // authenticated action links in the background; never gate comment loading.
      const response=await pooledFetch(target,{credentials:'same-origin',cache:'no-store',signal:AbortSignal.timeout(10000)});
      if(!response.ok)throw new Error();
      const html=await response.text();trace('votes.response',{ms:performance.now()-voteStarted,bytes:new TextEncoder().encode(html).length});
      const doc=new DOMParser().parseFromString(html,'text/html');
      readSignedInUser(doc);paintOP();
      if(document.getElementById('hv-header')) {
        const parsed=readHeader(doc,target);
        if(parsed){if(parsed.links.length)headerModel.links=parsed.links;headerModel.identity=parsed.identity;renderHeader();}
      }
      rememberCanonicalItems(doc,target);rememberCommentForm(doc,target);
      for(const row of doc.querySelectorAll('tr.athing[id]')) {
        const id=Number(row.id);if(!Number.isSafeInteger(id))continue;
        const actions=readVoteActions(doc,row,target);
        voteActions.set(id,actions);updateVoteControls(id);
      }
      votePages.add(target);
      const more=doc.querySelector('a.morelink[href]');
      const next=more?new URL(more.getAttribute('href'),target):null;
      votePage=next && next.origin===location.origin && next.pathname==='/item' && next.searchParams.get('id')===new URL(location.href).searchParams.get('id')?next.href:null;
    } catch (_) {
      // Unknown eligibility stays hidden. A later viewport entry can retry.
      if(headerModel.identity.state==='pending'){headerModel.identity={state:'unknown'};renderHeader();}
      if(canonicalCommentState==='pending'){canonicalCommentState='failed';renderCommentBox();}
      return;
    } finally {voteFetching=false;trace('votes.end',{ms:performance.now()-voteStarted});}
    void loadVoteActions();
  }
  function lazyVoteControl(item, direction) {
    const button=document.createElement('button');button.type='button';button.className='hv-vote';button.hidden=true;
    button.title=direction==='up'?'Upvote':'Downvote';button.setAttribute('aria-label',button.title);
    const arrow=document.createElement('span');arrow.className='votearrow'+(direction==='down'?' rotate180':'');arrow.setAttribute('aria-hidden','true');button.append(arrow);
    const control={button,direction,visible:false};
    const controls=voteControls.get(item.id)||[];controls.push(control);voteControls.set(item.id,controls);
    button.onclick=()=>lazyVote(item,button,direction);updateVoteControls(item.id);
    // Observe the row host, since an ineligible/unknown button itself is hidden.
    setTimeout(()=>{
      const host=button.closest('.hv-own');if(!host)return;
      updateVoteControls(item.id);
      if(typeof IntersectionObserver==='undefined')return;
      voteObserver ??= new IntersectionObserver(entries=>{
        for(const entry of entries)if(entry.isIntersecting) {
          for(const controls of voteControls.values())for(const c of controls)if(entry.target.contains(c.button))c.visible=true;
        }
        void loadVoteActions();
      },{rootMargin:'200px'});
      voteObserver.observe(host);
    },0);
    return button;
  }
  async function lazyVote(item, button, direction) {
    if(voteActions.get(item.id)?.voted===direction)return undoVote(item.id);
    const action=voteActions.get(item.id)?.[direction];if(!action || pendingVotes.has(item.id))return;
    pendingVotes.add(item.id);updateVoteControls(item.id);
    try {
      const url=new URL(action);url.searchParams.set('js','t');
      const voted=await pooledFetch(url.href,{credentials:'same-origin',cache:'no-store'});
      if(!voted.ok)throw new Error();
      url.searchParams.set('how','un');
      delete button.dataset.hvRetry;
      voteActions.set(item.id,{voted:direction,undo:url.href});updateVoteControls(item.id);
    } catch (_) {button.dataset.hvRetry='1';}
    finally {pendingVotes.delete(item.id);updateVoteControls(item.id);}
  }
  function lazyNavigation(node, item, heading) {
    const nav=document.createElement('span');nav.className='hv-comment-nav';
    const link=(label,id)=> {
      if(!id)return;
      if(nav.childNodes.length)nav.append(' | ');
      const a=hnLink(label,'/item?id='+id);
      a.onclick=event=>{
        if(event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)return;
        if(label==='next' || label==='prev') {
          event.preventDefault();
          if(lazyJump){lazyJump.link.textContent=lazyJump.label;lazyJump.link.removeAttribute('aria-busy');}
          const index=node.group.ids.indexOf(node.id);
          const candidates=label==='next'?node.group.ids.slice(index+1):node.group.ids.slice(0,index).reverse();
          localPaused=false;lazyJump={group:node.group,candidates,link:a,label};a.textContent='Loading…';a.setAttribute('aria-busy','true');lazyPump();return;
        }
        const target=lazyNodes.get(id)?.host;
        if(target && target.getClientRects().length) {event.preventDefault();target.style.contentVisibility='visible';target.scrollIntoView({block:'start'});}
      };
      nav.append(a);
    };
    const threadRoot=lazyThreadRootID || [...node.ancestors].find(id=>lazyNodes.get(id)?.entry?.item?.type==='comment');
    if(threadRoot!==node.id)link('root',threadRoot);
    link('parent',item.parent);
    const siblings=node.group?.ids || [], index=siblings.indexOf(node.id);
    const available=id=>{const entry=lazyNodes.get(id)?.entry;return !['blocked','hidden-item','unresolved'].includes(entry?.effect) && !(entry?.item?.deleted && !entry.item.kids?.length);};
    link('prev',siblings.slice(0,index).reverse().find(available));
    link('next',siblings.slice(index+1).find(available));
    if(node.isNew) {
      // A new comment carries the way to the next one, so after a jump the
      // control is where the reader is looking. Labels follow the loaded set.
      const wrap=document.createElement('span');wrap.className='hv-new-nav';
      const a=document.createElement('a');a.href='#';a.className='hv-new-link';a.textContent='next new';a.title='Jump to the next new comment (N)';
      a.onclick=event=>{event.preventDefault();jumpFromNew(node,a);};
      if(nav.childNodes.length)wrap.append(' | ');wrap.append(a);nav.append(wrap);
    }
    let tail=heading.querySelector(':scope > .hv-comment-tail');
    if(!tail){tail=document.createElement('span');tail.className='hv-comment-tail';heading.append(tail);}
    if(nav.childNodes.length){nav.prepend(' | ');tail.append(nav,' ');}
  }
  function headingTail(heading) { return heading.querySelector(':scope > .hv-comment-tail') || heading; }
  const replyWord=n=>n+' '+(n===1?'reply':'replies');
  // Replies under a comment: those loaded and shown, or at least the direct ones HN reports.
  function repliesBelow(node) {
    let loaded=0;
    for(const other of lazyNodes.values())if(other.entry && other.ancestors.has(node.id) && !filteredEffect(other.entry.effect))loaded++;
    return Math.max(loaded,node.entry?.item?.kids?.length||0);
  }
  function branchRail(node) {
    const rail=document.createElement('button');rail.type='button';rail.className='hv-rail';rail.tabIndex=-1;rail.setAttribute('aria-hidden','true');
    rail.style.left=(Math.min(node.depth*28,280)+13)+'px';
    rail.onmouseenter=()=>{rail.title='Collapse '+replyWord(repliesBelow(node));};
    rail.onclick=()=>node.toggleButton?.click();
    node.rail=rail;return rail;
  }
  function collapseToggle(node, onToggle) {
    const toggle=document.createElement('button');toggle.type='button';toggle.className='hv-collapse';
    const update=()=>{
      const fresh=node.collapsed?newBelow(node):0, replies=node.collapsed?repliesBelow(node):0;
      toggle.textContent=node.collapsed?'[+]'+(replies?' '+replyWord(replies):'')+(fresh?' · '+fresh+' new':''):'[-]';
      toggle.setAttribute('aria-expanded',String(!node.collapsed));
      const label=node.collapsed?'Expand thread'+(replies?', '+replyWord(replies):'')+(fresh?', '+pluralize(fresh,'new comment'):''):'Collapse thread';
      toggle.setAttribute('aria-label',label);toggle.title=label;
    };
    node.toggleButton=toggle;node.updateToggle=update;node.expand=()=>{if(node.collapsed)toggle.click();};update();
    toggle.onclick=()=>{
      node.collapsed=!node.collapsed;
      if(node.collapsed)lazyCollapsed.add(node.id);else lazyCollapsed.delete(node.id);
      if(node.children)node.children.host.hidden=node.collapsed;
      onToggle?.(node.collapsed);update();
      post({kind:'collapsedState',ids:[...lazyCollapsed]});lazyPump();
    };
    return toggle;
  }
  function lazyRender(node, entry) {
    const started=performance.now();
    lazyRenderContent(node,entry);
    trace('comment.dom',{id:node.id,ms:performance.now()-started});
  }
  function lazyRenderContent(node, entry) {
    node.entry=entry;
    voteControls.delete(node.id);
    const item=entry.item;
    let own=node.host.querySelector(':scope > .hv-own');
    if (!own) { own=document.createElement('div'); own.className='hv-own'; node.host.prepend(own); }
    own.style.visibility=''; own.replaceChildren();
    let effect=entry.effect, revealed=false, shown=false;
    if (filteredEffect(effect) && lazyShown(node, entry)) {
      // Only what the header chip revealed carries a label; a revealed
      // destination has its notice and a lifted reply follows its ancestor.
      shown=true; revealed=revealAll && node.id!==revealedID && !inheritanceAnchor(node, entry); effect='visible';
    }
    const root=node.id===Number(document.body.dataset.hvTopic);
    if (!item || effect==='unresolved') {
      lazyStatus(own,entry.reason || 'This contribution’s filter check could not finish.',()=>{ lazyStatus(own,'Retrying…'); localPaused=false; lazyRefreshQueue=[node]; lazyPump(); });
      if (node.children) node.children.host.hidden=true;
      return;
    }
    if (effect==='blocked') {
      if (root) {
        const text=document.createElement('p'); text.textContent='Hidden by '+(entry.label || 'your filters');
        const reveal=document.createElement('button'); reveal.textContent='Reveal this contribution';
        reveal.onclick=()=>setRootRevealed(true); own.append(text,reveal);
      }
      if (node.children) node.children.host.hidden=true;
      return;
    }
    if(item.deleted===true || (item.dead===true && !canonicalItems.get(item.id)?.showDead)) {
      const marker=item.dead?'[moderated]':'[deleted]';
      if(root)document.title=(item.dead?'Moderated':'Deleted')+' comment | Hacker News';
      if(item.type==='comment' && (root || item.kids?.length)) {
        // Same scaffold as a live comment, so the tombstone keeps its place in
        // the tree and its replies can be collapsed like any other branch.
        const table=document.createElement('table');table.className='comment-tree';
        const tbody=document.createElement('tbody');table.append(tbody);
        const row=document.createElement('tr');row.id=String(item.id);row.className='athing comtr hv-tombstone';
        const outer=document.createElement('td');const inner=document.createElement('table');const innerRow=document.createElement('tr');
        inner.innerHTML='<tbody></tbody>';inner.firstChild.append(innerRow);outer.append(inner);row.append(outer);
        const ind=document.createElement('td');ind.className='ind';ind.setAttribute('indent',String(node.depth*40));
        const spacer=document.createElement('span');spacer.style.cssText='display:block;width:'+Math.min(node.depth*28,280)+'px';ind.append(spacer);
        const votes=document.createElement('td');votes.className='votelinks';
        const cell=document.createElement('td');cell.className='default';
        const heading=document.createElement('span');heading.className='comhead';
        const label=hnLink(marker,'/item?id='+item.id);label.className='hv-tombstone-label';heading.append(label);
        if(item.time){const age=hnLink(relativeTime(item.time),'/item?id='+item.id);age.title=new Date(item.time*1000).toLocaleString();const stamp=document.createElement('span');stamp.className='hv-age';stamp.append(' · ',age);heading.append(stamp);}
        lazyNavigation(node,item,heading);
        headingTail(heading).append(collapseToggle(node));
        const head=document.createElement('div');head.append(heading);
        cell.append(head);innerRow.append(ind,votes,cell);tbody.append(row);
        own.append(table);
      } else if(root || item.kids?.length) {
        const placeholder=document.createElement('p');placeholder.className='hv-deleted';
        placeholder.append(hnLink(marker,'/item?id='+item.id));
        if(root && item.parent)placeholder.append(' · ',hnLink('parent','/item?id='+item.parent));
        own.append(placeholder);
      }
      if(!node.children && item.kids?.length) {
        const host=document.createElement('div');host.className='hv-children';node.host.append(host);
        if(item.type==='comment' && node.depth*28<280)host.append(branchRail(node));
        node.children=lazyGroup(host,item.kids,item.type==='comment'?node.depth+1:0,new Set([...node.ancestors,node.id]));
      }
      if(node.children)node.children.host.hidden=!!node.collapsed;
      if(item.dead)void loadVoteActions();
      return;
    }
    if (root) document.title=(item.type==='comment' ? 'Comment by '+(item.by || '[deleted]') : item.title || 'Discussion')+' | Hacker News';
    const table=document.createElement('table');
    table.className=item.type==='comment'?'comment-tree':'fatitem';
    const tbody=document.createElement('tbody'); table.append(tbody);
    const row=document.createElement('tr'); row.id=String(item.id);
    const user=hnLink(item.by || '[deleted]','/user?id='+encodeURIComponent(item.by || ''));
    user.className='hnuser';
    const heading=document.createElement('span');heading.className='comhead'; heading.append(user);
    if(item.time) { const age=hnLink(relativeTime(item.time),'/item?id='+item.id);age.title=new Date(item.time*1000).toLocaleString();const stamp=document.createElement('span');stamp.className='hv-age';stamp.append(' ',age);heading.append(stamp); }
    // A comment posted after the reader's last view of this discussion.
    const fresh=!!(visitBaseline && item.type==='comment' && Number.isFinite(item.time) && item.time>visitBaseline.viewedAt && !filteredEffect(entry.effect) && !item.deleted);
    node.isNew=fresh;

    if(item.type==='comment') {
      row.className='athing comtr';
      const outer=document.createElement('td');const inner=document.createElement('table');const innerRow=document.createElement('tr');
      inner.innerHTML='<tbody></tbody>';inner.firstChild.append(innerRow);outer.append(inner);row.append(outer);
      const ind=document.createElement('td');ind.className='ind';ind.setAttribute('indent',String(node.depth*40));
      const spacer=document.createElement('span');spacer.style.cssText='display:block;width:'+Math.min(node.depth*28,280)+'px';ind.append(spacer);
      const votes=document.createElement('td'); votes.className='votelinks';
      votes.append(lazyVoteControl(item,'up'),lazyVoteControl(item,'down'));
      votes.style.visibility=node.collapsed?'hidden':'';
      const cell=document.createElement('td');cell.className='default';
      const head=document.createElement('div');head.append(heading);
      if(fresh){row.classList.add('hv-new');const dot=document.createElement('span');dot.className='hv-new-dot';dot.title='New since your last visit';dot.setAttribute('aria-label','New since your last visit');heading.prepend(dot);}
      lazyNavigation(node,item,heading);
      // HN's line, one separator: navigation, then HN's own actions when its
      // HTML arrives, then ours (reply, note), then the toggle.
      user.dataset.qhnControl='1';
      const ours=document.createElement('span');ours.className='hv-reader-actions';
      const reply=hnLink('reply','/reply?id='+item.id+'&goto='+encodeURIComponent('item?id='+document.body.dataset.hvTopic+'#'+item.id));reply.className='hv-reply';
      ours.append(' | ',reply);if(item.by)ours.append(' | ',recordButton(item.by,row,user,'note'));
      headingTail(heading).append(ours,' ');
      const body=document.createElement('div');body.className='comment';body.hidden=!!node.collapsed;
      headingTail(heading).append(collapseToggle(node,collapsed=>{body.hidden=collapsed;votes.style.visibility=collapsed?'hidden':'';}));
      const text=document.createElement('span');text.className='commtext';text.append(safeBody(item.deleted?'[deleted]':item.text || ''));body.append(text);
      cell.append(head,body);innerRow.append(ind,votes,cell);tbody.append(row);
    } else {
      row.className='athing submission';const cell=document.createElement('td');const title=document.createElement('span');title.className='titleline';
      let target;try{target=new URL(item.url || '/item?id='+item.id,'https://news.ycombinator.com/');}catch(_){target=new URL('/item?id='+item.id,'https://news.ycombinator.com/');}
      if(!['https:','http:'].includes(target.protocol))target=new URL('/item?id='+item.id,'https://news.ycombinator.com/');
      const link=hnLink('',target.href);link.append(safeBody(item.title || 'Discussion'));title.append(link);if(target.hostname!=='news.ycombinator.com'){const domain=document.createElement('span');domain.className='sitebit comhead';domain.append(' (',hnLink(target.hostname.replace(/^www\./,''),'/from?site='+encodeURIComponent(target.hostname)),')');title.append(domain);}cell.append(title);row.append(cell);tbody.append(row);
      const meta=document.createElement('tr');const md=document.createElement('td');md.className='subtext';
      const canComment=item.type!=='job' && root && effect!=='hidden-item';
      if(item.by) {
        // HN's line with HN's separator: author, age, HN's actions, the
        // reader's own, the count. The score sits in the gutter with its arrow.
        user.dataset.qhnControl='1';
        const hnActions=document.createElement('span');hnActions.className='hv-hn-actions';
        const ours=document.createElement('span');ours.className='hv-reader-actions';
        if(root){ours.append(' | ',recordButton(item.by,row,user,'note'));if(canComment)ours.append(' | ',commentToggle());}
        const count=document.createElement('span');count.className='hv-comment-count';count.textContent=pluralize(item.descendants ?? 0,'comment');
        md.append('by ',heading,hnActions,ours,' | ',count);
      } else if(item.time)md.append(relativeTime(item.time));
      meta.append(md);tbody.append(meta);
      if(item.text){const textRow=document.createElement('tr');const text=document.createElement('td');text.className='toptext';text.append(safeBody(item.text));textRow.append(text);tbody.append(textRow);}
      const votes=document.createElement('td');votes.className='votelinks';
      if(item.type!=='job'){votes.append(lazyVoteControl(item,'up'));const score=document.createElement('span');score.className='hv-score';score.textContent=String(item.score ?? 0);score.title=pluralize(item.score ?? 0,'point');votes.append(score);}
      row.prepend(votes);md.colSpan=2;
      const textCell=tbody.querySelector('.toptext');if(textCell)textCell.colSpan=2;
      if(root && item.by){own.append(visitLine());if(canComment)own.append(commentHost());}
    }
    if(effect!=='hidden-item') {
      own.prepend(table);paintOrdered(row,effect,item.type==='comment'?null:row.nextElementSibling,entry.label);
      if(shown)table.setAttribute('data-qhn-revealed','');
      if(revealed){row.classList.add('qhn-revealed');revealLabel(heading,entry.label);}
    } else if(root) { const reveal=document.createElement('button');reveal.textContent='Reveal this contribution';reveal.onclick=()=>setRootRevealed(true);own.prepend(reveal); }
    if(!node.children && item.kids?.length) {
      const host=document.createElement('div');host.className='hv-children';node.host.append(host);
      if(item.type==='comment' && node.depth*28<280)host.append(branchRail(node));
      node.children=lazyGroup(host,item.kids,item.type==='comment'?node.depth+1:0,new Set([...node.ancestors,node.id]));
    }
    if(node.children) node.children.host.hidden=!!node.collapsed;
    if(item.type==='comment')for(const id of node.ancestors){const ancestor=lazyNodes.get(id);if(ancestor?.collapsed)ancestor.updateToggle?.();}
    if(item.type==='comment' && visitBaseline){
      for(const id of node.ancestors)lazyNodes.get(id)?.updateToggle?.();
      renderVisitLine();if(fresh)refreshNewNavigation();
      if(fresh && pendingNextNew)setTimeout(()=>{
        if(!pendingNextNew)return;
        const from=pendingLink && lazyNodes.get(Number(pendingLink.closest('tr.comtr')?.id));
        if(from)jumpFromNew(from,pendingLink);else jumpToNextNew(visitLineHost?.querySelector('.hv-next-new'));
      },0);
    }
    if(root && revealedID===node.id && filteredEffect(entry.effect)) { const notice=document.createElement('div');notice.className='qhn-loading';
      notice.append('Temporarily revealed · Hidden by '+(entry.label || 'your filters')+' · '); const hide=document.createElement('button');hide.textContent='Hide again';hide.onclick=()=>setRootRevealed(false);notice.append(hide);own.prepend(notice); }
    addControls();paintOP();applyCanonicalMetadata(node);
  }
  const queuedResults = new Map();
  let resultFramePending = false;
  let scrollingUntil = 0, settleTimer = null;
  function scrollingNow() { return performance.now() < scrollingUntil; }
  function noteReadingScroll() {
    scrollingUntil=performance.now()+200;
    clearTimeout(settleTimer);
    settleTimer=setTimeout(()=>{scheduleResults();lazyPump();},210);
  }
  window.addEventListener('wheel',noteReadingScroll,{passive:true});
  window.addEventListener('touchmove',noteReadingScroll,{passive:true});
  // Momentum continues emitting scroll events after fingers leave the trackpad.
  window.addEventListener('scroll',noteReadingScroll,{passive:true});

  function scheduleResults() {
    if(resultFramePending || !queuedResults.size)return;
    if(typeof requestAnimationFrame!=='function'){flushResults();return;}
    resultFramePending=true;
    requestAnimationFrame(()=>{resultFramePending=false;flushResults();});
  }
  function lazyResult(token, entries) {
    const request=lazyPending.get(token);if(!request)return;
    trace('batch.received',{token,count:entries.length});
    for(const entry of entries)if(request.ids.has(entry.id))
      queuedResults.set(entry.id,{token,entry,request});
    scheduleResults();
  }
  function flushResults() {
    let anchor=null, anchorTop=0;
    const explicit=!!(lazyRestoreY || lazyRestoreAnchor || lazyRefreshQueue || lazyJump);
    if(window.scrollY>0 && !explicit) {
      anchor=[...document.querySelectorAll('.hv-own .athing')].find(row=>{const r=row.getBoundingClientRect();return row.getClientRects().length && r.bottom>0 && r.top<innerHeight;});
      if(anchor)anchorTop=anchor.getBoundingClientRect().top;
    }
    const renderStart=performance.now();
    const applicable=[];
    // Read geometry before any writes, once for the entire frame's results.
    for(const [id,result] of queuedResults) {
      const {token,request,entry}=result;
      if(lazyPending.get(token)!==request || !request.ids.has(id)){queuedResults.delete(id);continue;}
      const node=request.nodes.find(n=>n.id===id);
      if(!node){queuedResults.delete(id);continue;}
      const own=node.host.querySelector(':scope > .hv-own');
      if(!explicit && scrollingNow() && own?.getClientRects().length &&
         own.getBoundingClientRect().top<Math.max(0,anchorTop))continue;
      applicable.push({...result,node});queuedResults.delete(id);
    }
    if(!applicable.length)return;
    for(const {token,request,entry,node} of applicable) {
      request.ids.delete(entry.id);
      lazyRender(node,entry);
      if(!request.ids.size)lazyPending.delete(token);
    }
    if(anchor?.isConnected) {
      const delta=anchor.getBoundingClientRect().top-anchorTop;
      if(Math.abs(delta)>.5) {
        if(scrollDiagnostics)trace('scroll.correction',{delta,wheelAge:Number.isFinite(lastWheelAt)?performance.now()-lastWheelAt:-1,
          scrolling:scrollingNow()?1:0});
        window.scrollTo(0,window.scrollY+delta);
      }
    }
    const ms=performance.now()-renderStart;
    if(scrollDiagnostics) {metric('renderCalls');metric('renderTotal',ms);maximum('renderMax',ms);}
    lazyAnnounce();trace('batch.dom',{count:applicable.length,ms});
    if(typeof requestAnimationFrame==='function')requestAnimationFrame(()=>trace('batch.frame',{count:applicable.length,ms:performance.now()-renderStart}));
    setTimeout(lazyPump,0);
  }
  function lazyRefresh() {
    localPaused=false;
    lazyToken++;lazyPending.clear();queuedResults.clear();post({kind:'cancelLazy'});
    lazyRefreshQueue=[...lazyNodes.values()];
    for(const node of lazyRefreshQueue){const own=node.host.querySelector(':scope > .hv-own');if(own)own.style.visibility='hidden';}
    lazyPump();
  }
  function showPausedComments() {
    const hosts=[...[...lazyNodes.values()].filter(n=>!n.entry).map(n=>n.host.querySelector(':scope > .hv-own')),
      ...[...lazyGroups.values()].map(g=>g.sentinel)].filter(Boolean);
    for(const host of hosts) {
      host.replaceChildren();
      const status=document.createElement('div');status.className='qhn-loading';status.dataset.hvPaused='';
      status.append('More comments are available. ');
      const button=document.createElement('button');button.textContent='Load comments';button.onclick=resumeLocalLoading;
      button.disabled=localApplying;
      status.append(button);host.append(status);
    }
  }
  function localRecheck() {
    captureFilterAnchor();
    const token=++localToken;
    if(lazyThread) {
      localPaused=true;localApplying=true;
      lazyToken++;lazyPending.clear();queuedResults.clear();post({kind:'cancelLazy'});
      lazyRefreshQueue=null;showPausedComments();
      post({kind:'localRecheck',token,ids:[...lazyNodes.values()].filter(n=>n.entry).map(n=>n.id)});
    } else {
      const tree=collect();
      const pageID=['item','reply'].includes(location.pathname.replace(/^\//,'')) ? Number(new URL(location.href).searchParams.get('id')) : null;
      pending={token:++generation,tree,pageID};
      post({kind:'localRecheck',token,ids:[...new Set([pageID,...tree.rows.map(idOf),...tree.stories.map(idOf)].filter(Boolean))]});
    }
  }
  function localResult(token,effects,labels,inherited={}) {
    if(token!==localToken)return;
    if(!lazyThread) {
      for(const element of hidden)element.removeAttribute('data-qhn-hidden');
      hidden.clear();
      if(!accountFiltersActive)for(const story of pending?.tree.stories||[])paintOrdered(story,'visible',story.nextElementSibling,'');
      finish(pending?.token,effects,false,labels,false,inherited);return;
    }
    localApplying=true;
    for(const node of lazyNodes.values()) {
      if(!node.entry || !effects[node.id])continue;
      const effect=effects[node.id],label=labels[node.id]||'',inheritedFrom=inherited[node.id]||undefined;
      if(node.entry.effect===effect && (node.entry.label||'')===label && node.entry.inheritedFrom===inheritedFrom)continue;
      lazyRender(node,{...node.entry,effect,label,inheritedFrom,reason:effect==='unresolved'?label:undefined});
    }
    localApplying=false;
    showPausedComments();
    restoreFilterAnchor();lazyAnnounce();
  }
  // Layout changes and programmatic anchor restoration must not restart loading.
  // Resume unfinished work only when the reader deliberately continues reading.
  function resumeLocalLoading() {
    if(!localPaused || localApplying)return;
    localPaused=false;
    for(const status of document.querySelectorAll('[data-hv-paused]'))lazyStatus(status.parentElement,'Loading comments…');
    const unfinished=[...lazyNodes.values()].filter(n=>!n.entry);
    lazyRefreshQueue=unfinished.length?unfinished:null;
    lazyPump();void loadVoteActions();
  }
  window.addEventListener('wheel',resumeLocalLoading,{passive:true});
  window.addEventListener('touchmove',resumeLocalLoading,{passive:true});
  window.addEventListener('pointerdown',event=>{
    if(event.clientX>=document.documentElement.clientWidth-16)resumeLocalLoading();
  },{passive:true});
  window.addEventListener('keydown',event=>{
    if(['ArrowDown','ArrowUp','PageDown','PageUp','Home','End',' '].includes(event.key))resumeLocalLoading();
  });

  function startLazyThread() {
    if(lazyThread) { lazyRefresh();return; }
    lazyThread=true;lazyRestoreY=Number(document.body.dataset.hvScroll)||0;
    if(document.body.dataset.hvReveal)revealedID=Number(document.body.dataset.hvTopic);
    try { const visit=JSON.parse(atob(document.body.dataset.hvVisit||'')); if(Number.isFinite(visit?.viewedAt) && visit.viewedAt>0)visitBaseline=visit; } catch(_) {}
    // A discussion opened again by a new navigation takes the threads the
    // reader had collapsed last time. History state, when present, wins.
    let seededCollapse=false;
    try {
      const anchor=JSON.parse(atob(document.body.dataset.hvAnchor||''));
      if(!Array.isArray(anchor?.collapsed) && Array.isArray(visitBaseline?.collapsed)) {
        for(const id of visitBaseline.collapsed)if(Number.isSafeInteger(id) && id>0)lazyCollapsed.add(id);
        seededCollapse=lazyCollapsed.size>0;
      }
    } catch(_) { if(Array.isArray(visitBaseline?.collapsed)){for(const id of visitBaseline.collapsed)if(Number.isSafeInteger(id) && id>0)lazyCollapsed.add(id);seededCollapse=lazyCollapsed.size>0;} }
    if(seededCollapse)post({kind:'collapsedState',ids:[...lazyCollapsed]});
    try {
      const anchor=JSON.parse(atob(document.body.dataset.hvAnchor||''));
      for(const id of anchor.collapsed || [])if(Number.isSafeInteger(id) && id>0)lazyCollapsed.add(id);
      if(Number.isSafeInteger(anchor.id) && anchor.id>0 && Array.isArray(anchor.ancestors))lazyRestoreAnchor=anchor;
    } catch(_) {}
    if(typeof IntersectionObserver!=='undefined')lazyObserver=new IntersectionObserver(entries=>{
      for(const entry of entries)if(entry.isIntersecting){
        const group=lazyGroups.get(entry.target);
        if(group && !group.visibleAt){group.visibleAt=performance.now();trace('group.nearViewport',{id:group.ids[group.offset]||0,queueMs:group.visibleAt-group.queuedAt});}
      }
      lazyPump();
    },{rootMargin:'500px'});
    window.addEventListener('scroll',lazyPump,{passive:true});
    renderHeader();
    lazyGroup(document.getElementById('hv-topic-root'),[Number(document.body.dataset.hvTopic)],0,new Set());
    lazyAnnounce();lazyPump();void loadVoteActions();
  }

  function process() {
    if (document.body?.dataset.hvTopic) { startLazyThread(); return; }
    if (!started) return;
    showProgress(null, false);
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
    const items=[...tree.rows,...tree.stories].map(row=>{
      const comment=row.matches('tr.comtr') || !!row.querySelector('.commtext');
      return {id:idOf(row),by:authorOf(comment?row:row.nextElementSibling),type:comment?'comment':'story'};
    }).filter(item=>item.id && item.by);
    post({kind: 'ancestors', ids, token, items});
    // List pages can show their chrome and in-place progress immediately.
    // Unchecked contributions stay hidden until their decisions arrive.
    if(!pageID && ordered)finish(token, {}, false, {}, true);
  }

  // Feed rows the reader has opened before get a count of comments added since.
  let visitsRequested = false;
  function requestVisits(stories) {
    if (visitsRequested) return;
    const ids = [...new Set(stories.map(idOf).filter(id => Number.isSafeInteger(id) && id > 0))];
    if (!ids.length) return;
    visitsRequested = true; post({kind: 'visits', ids: ids.slice(0, 500)});
  }
  function paintVisits(results) {
    for (const [key, record] of Object.entries(results || {})) {
      const row = document.getElementById(String(key));
      if (!row || !Number.isFinite(record?.descendants)) continue;
      const subtext = row.nextElementSibling?.querySelector('.subtext') || row.nextElementSibling;
      const link = [...(subtext?.querySelectorAll('a[href]') || [])].find(a => /^\s*\d+\s*comments?\s*$/.test(a.textContent));
      if (!link || subtext.querySelector('.hv-new-count')) continue;
      const fresh = Number(/\d+/.exec(link.textContent)[0]) - record.descendants;
      if (fresh <= 0) continue;
      const badge = document.createElement('span'); badge.className = 'hv-new-count'; badge.textContent = ' · +' + fresh + ' new';
      badge.title = pluralize(fresh, 'comment') + ' since your last visit'; link.after(badge);
    }
  }
  function finish(token, decisions, blockPage = false, labels = {}, partial = false, inherited = {}) {
    if (!pending || pending.token !== token) return;
    if (partial) {
      pending.decisions = Object.assign(pending.decisions || {}, decisions);
      pending.labels = Object.assign(pending.labels || {}, labels);
      pending.inherited = Object.assign(pending.inherited || {}, inherited);
      decisions = pending.decisions; labels = pending.labels; inherited = pending.inherited;
    }
    if (partial && filterAnchor) return;
    const {tree, pageID} = pending;
    if (partial && ordered) {
      // Reveal a checked prefix so late results cannot insert rows above content
      // the reader has already started reading.
      decisions = {...decisions};
      let gap = false;
      for (const row of [...tree.stories, ...tree.rows]) {
        const id = idOf(row);
        if (!id) continue;
        if (!decisions[id]) gap = true;
        if (gap) decisions[id] = 'unresolved';
      }
    }
    // Revealing the destination also lifts the replies hidden only because of
    // it. Contributions hidden by their own rules keep their decisions.
    if (revealedID && revealedID === pageID && ['blocked', 'hidden-item'].includes(decisions[pageID])) {
      const source = decisions[pageID] === 'blocked' ? (inherited[pageID] || pageID) : null;
      decisions = {...decisions, [pageID]: 'visible'};
      if (source) for (const id of Object.keys(inherited)) if (inherited[id] === source && decisions[id] === 'blocked') decisions[id] = 'visible';
    }
    if (pageID && decisions[pageID] === 'blocked') blockPage = true;
    for (const row of tree.rows) {
      const state = decisions[accountFiltersActive ? idOf(row) : tree.rootFor.get(row)] || (accountFiltersActive ? 'unresolved' : undefined);
      const filtered = state === 'blocked' || state === 'hidden-item';
      row.classList.remove('qhn-filtered', 'qhn-revealed');
      if (filtered) { markFiltered(row, labels[idOf(row)]); setRevealed(row, revealAll); }
      else if (state === 'unresolved') hide(row);
      else if (ordered) { row.removeAttribute('data-qhn-hidden'); hidden.delete(row); setRevealed(row, false); row.removeAttribute('data-qhn-hidden'); hidden.delete(row); }
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
        story.classList.remove('qhn-filtered', 'qhn-revealed');
        if (state === 'blocked' || state === 'hidden-item') { markFiltered(story, labels[idOf(story)]); setRevealed(story, revealAll); }
        else { hide(story); hide(metadata); if (metadata?.nextElementSibling?.matches('.spacer')) hide(metadata.nextElementSibling); }
        if (story.closest('.fatitem') && state === 'blocked') blockPage = true;
      }
    }
    paintOP();
    const unresolvedCount = Object.values(decisions).filter(value => value === 'unresolved').length;
    const hiddenContributions = [...tree.stories, ...tree.rows].filter(row => row.classList.contains('qhn-filtered')).length;
    if (partial && pageID && !decisions[pageID]) return;
    checking = partial;
    if (!partial) pending = null;
    if (blockPage || (pageID && decisions[pageID] === 'unresolved')) {
      // Never reveal unchecked content as a network-error fallback.
      post({kind: 'held', reason: blockPage ? 'blocked' : 'unresolved', label: labels[pageID] || ''});
      return;
    }
    const boundary = [...tree.stories, ...tree.rows].find(row =>
      partial ? !pending?.decisions?.[idOf(row)] : decisions[idOf(row)] === 'unresolved');
    showProgress(boundary, !partial);
    setHeaderStatus(hiddenContributions, partial ? 0 : unresolvedCount, () => process());
    if (!partial) requestVisits(tree.stories);
    restoreFilterAnchor();
    ready = true;
    document.documentElement.removeAttribute('data-qhn-pending');
    post({kind: 'ready', complete: !partial, hidden: hiddenContributions, unresolved: unresolvedCount, title: document.title, destinationHidden: !!pageID && decisions[pageID] === 'hidden-item'});
    rememberViewportAnchor();
  }

  window.HackerViews = {
    lazyResult, localResult, readingPosition, refreshState, restoreReadingPosition,
    networkGranted(token) { const resolve=networkWaiters.get(token);networkWaiters.delete(token);resolve?.(); },
    originalPoster(name, threadRootID) {
      originalPoster = name; paintOP();
      if(Number.isSafeInteger(threadRootID) && threadRootID>0) {
        lazyThreadRootID=threadRootID;
        if(lazyThread)for(const node of lazyNodes.values()) {
          const nav=node.host.querySelector(':scope > .hv-own .hv-comment-nav');
          if(nav && node.entry?.item) {
            const holder=document.createElement('span');lazyNavigation(node,node.entry.item,holder);
            nav.replaceWith(holder.querySelector('.hv-comment-nav'));
          }
        }
        if(lazyThread && visitBaseline)refreshNewNavigation();
      }
    },
    profileRecord, profileSaveStatus,
    resolveProfile,
    setOrdered(active, local = false) {
      ordered = true; blocked = new Set(); preferred = new Set(); highlightActive = false; revealAll = false;
      accountFiltersActive = !!active;
      if(local)localRecheck();else {captureFilterAnchor();process();}
    },
    configure(names, active, favorites, highlightRules) {
      blocked = new Set(names); accountFiltersActive = !!active;
      preferred = new Set(favorites); highlightActive = !!highlightRules; process();
    },
    resolveHighlights(token, names) {
      if (token !== generation) return;
      names.forEach(name => matchedHighlights.add(name));
      paintHighlights(matchedHighlights); paintOP();
    },
    revealDestination() {
      if (lazyThread) { setRootRevealed(true); return; }
      revealedID = Number(new URL(location.href).searchParams.get('id'));
      process();
    },
    setFilters(names, active) { blocked = new Set(names); accountFiltersActive = !!active; process(); },
    setBlocked(names) { blocked = new Set(names); process(); },
    resolvePartial(token, decisions, labels = {}, inherited = {}) { finish(token, decisions, false, labels, true, inherited); },
    resolve(token, decisions, labels = {}, inherited = {}) { finish(token, decisions, false, labels, false, inherited); },
    visitResults(results) { paintVisits(results); },
    retry() { process(); }
  };
  const observer = new MutationObserver(mutations => {
    install();
    if (lazyThread) return;
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
