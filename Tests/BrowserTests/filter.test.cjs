const {test} = require('node:test');
const assert = require('node:assert/strict');
const {JSDOM} = require('jsdom');
const fs = require('node:fs');
const filter = fs.readFileSync('HackerViews/Resources/filter.js', 'utf8');
const row = (id, name, depth = 0) => `<tr class="athing comtr" id="${id}"><td><table><tr><td class="ind" indent="${depth}"></td><td><a class="hnuser" href="user?id=${name}">${name}</a><a href="vote?id=${id}&how=up">up</a><a href="reply?id=${id}">reply</a><div class="commtext">Comment ${id}</div></td></tr></table></td></tr>`;
const story = (id, author) => `<tr class="athing submission" id="${id}"><td><span class="titleline"><a href="https://example.com">Story ${id}</a></span></td></tr><tr><td><a class="hnuser" href="user?id=${author}">${author}</a></td></tr><tr class="spacer"><td></td></tr>`;
async function page(html, {blocked = ['bob'], url = 'https://news.ycombinator.com/news', diagnostics = false} = {}) {
  const messages = [];
  const dom = new JSDOM(`<html><head><title>HN</title></head><body>${html}</body></html>`, {url, runScripts: 'outside-only'});
  dom.window.TextEncoder = TextEncoder;
  dom.window.__hackerViewsBlocked = blocked;
  dom.window.__hackerViewsScrollDiagnostics = diagnostics;
  dom.window.webkit = {messageHandlers: {hackerViews: {postMessage: message => messages.push(message)}}};
  dom.window.eval(filter);
  await new Promise(resolve => setImmediate(resolve));
  return {dom, doc: dom.window.document, messages,
    resolve(decisions) { const request = messages.filter(m => m.kind === 'ancestors').at(-1); dom.window.HackerViews.resolve(request.token, decisions); }};
}
const hidden = (p, id) => p.doc.getElementById(String(id)).hasAttribute('data-qhn-hidden');

test('prunes a blocked branch but preserves ancestors, siblings and HN actions', async () => {
  const p = await page(`<table>${row(1,'alice')}${row(2,'bob',1)}${row(3,'carol',2)}${row(4,'eve',1)}${row(5,'dave')}</table>`);
  p.resolve({'1':'visible','5':'visible'});
  assert.equal(hidden(p,1),false); assert.equal(hidden(p,2),true); assert.equal(hidden(p,3),true);
  assert.equal(hidden(p,4),false); assert.equal(hidden(p,5),false);
  assert.ok(p.doc.getElementById('4').querySelector('a[href="vote?id=4&how=up"]'));
  assert.ok(p.doc.querySelector('a[href="reply?id=4"]'));
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),false);
  p.dom.window.close();
});
test('hides submitted stories with metadata and spacer', async () => {
  const p = await page(`<table>${story(10,'bob')}${story(11,'alice')}</table>`);
  assert.equal(hidden(p,10),true); assert.equal(hidden(p,11),false);
  assert.equal(p.doc.getElementById('10').nextElementSibling.hasAttribute('data-qhn-hidden'),true);
  assert.equal(p.doc.getElementById('10').nextElementSibling.nextElementSibling.hasAttribute('data-qhn-hidden'),true);
  p.dom.window.close();
});
test('direct descendant links and reply forms hold the entire page', async () => {
  for (const path of ['item','reply']) {
    const p = await page(`<table>${row(3,'carol')}</table><form action="comment"><textarea name="text"></textarea></form>`, {url:`https://news.ycombinator.com/${path}?id=3`});
    assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),true);
    p.resolve({'3':'blocked'});
    assert.equal(p.messages.at(-1).reason,'blocked');
    assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),true);
    p.dom.window.close();
  }
});
test('unresolved ancestry is never revealed', async () => {
  const p = await page(`<table>${row(3,'carol')}</table>`,{url:'https://news.ycombinator.com/item?id=3'});
  p.resolve({'3':'unresolved'});
  assert.equal(p.messages.at(-1).reason,'unresolved');
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),true);
  p.dom.window.close();
});
test('unblocking restores branches without modifying original collapse styles', async () => {
  const p = await page(`<table>${row(2,'bob')}${row(3,'carol',1)}</table>`);
  p.doc.getElementById('3').style.display='none';
  p.resolve({'2':'blocked'});
  p.dom.window.HackerViews.setBlocked([]);
  assert.equal(hidden(p,2),false); assert.equal(hidden(p,3),false);
  assert.equal(p.doc.getElementById('3').style.display,'none');
  assert.equal(p.messages.at(-1).kind,'ready');
  p.dom.window.close();
});
test('old ancestry responses cannot override updated filters', async () => {
  const p = await page(`<table>${row(2,'bob')}</table>`);
  const token = p.messages.find(m => m.kind==='ancestors').token;
  p.dom.window.HackerViews.setBlocked([]);
  p.dom.window.HackerViews.resolve(token, {'2':'blocked'});
  assert.equal(hidden(p,2),false); assert.equal(p.messages.at(-1).kind,'ready');
  p.dom.window.close();
});
test('dynamically inserted blocked branches are processed and controls are not duplicated', async () => {
  const p = await page(`<table id="tree">${row(1,'alice')}</table>`);
  p.resolve({'1':'visible'});
  p.doc.getElementById('tree').insertAdjacentHTML('beforeend',row(2,'bob')+row(3,'carol',1));
  await new Promise(resolve => setImmediate(resolve));
  p.resolve({'1':'visible','2':'blocked'});
  assert.equal(hidden(p,2),true); assert.equal(hidden(p,3),true);
  assert.equal(p.doc.querySelectorAll('.qhn-record').length,3);
  p.dom.window.close();
});
test('record actions capture a canonical citation without submitting or voting', async () => {
  const p = await page(`<table>${row(2,'bob')}</table>`,{blocked:[]});
  p.doc.querySelector('.qhn-record').click();
  const record=p.messages.at(-1);
  assert.equal(record.kind,'record'); assert.equal(record.username,'bob');
  assert.equal(record.url,'https://news.ycombinator.com/item?id=2');
  assert.equal(record.excerpt,'Comment 2');
  p.dom.window.close();
});

test('an unresolved branch stays hidden without hiding a verified sibling', async () => {
  const p = await page(`<table>${row(3,'carol')}${row(4,'dave',1)}${row(5,'eve')}</table>`);
  p.resolve({'3':'unresolved','5':'visible'});
  assert.equal(hidden(p,3),true); assert.equal(hidden(p,4),true); assert.equal(hidden(p,5),false);
  assert.equal(p.messages.at(-1).kind,'ready'); assert.equal(p.messages.at(-1).unresolved,1);
  p.dom.window.close();
});

test('account filters check nested comments and submissions with no manual blocks', async () => {
  const p = await page(`<table>${story(10,'submitter')}${row(1,'alice')}${row(2,'newbie',1)}${row(3,'carol',2)}${row(4,'eve',1)}</table>`, {blocked: []});
  p.dom.window.HackerViews.setFilters([], true);
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  assert.deepEqual(Array.from(request.ids).sort((a,b) => a-b), [1,2,3,4,10]);
  p.resolve({'1':'visible','2':'blocked','3':'blocked','4':'visible','10':'blocked'});
  assert.equal(hidden(p,1),false); assert.equal(hidden(p,2),true);
  assert.equal(hidden(p,3),true); assert.equal(hidden(p,4),false);
  assert.equal(hidden(p,10),true);
  assert.equal(p.doc.getElementById('10').nextElementSibling.hasAttribute('data-qhn-hidden'),true);
  p.dom.window.HackerViews.setFilters([], false);
  assert.equal(hidden(p,2),false); assert.equal(hidden(p,10),false);
  p.dom.window.close();
});

test('preferred authors highlight their contributions without highlighting replies or bypassing blocks', async () => {
  const p = await page(`<table>${story(10,'alice')}${row(1,'alice')}${row(2,'bob',1)}${row(3,'carol')}</table>`, {blocked: []});
  p.dom.window.HackerViews.configure(['alice'], false, ['alice'], false);
  p.resolve({'1':'blocked','3':'visible'});
  assert.equal(p.doc.getElementById('1').classList.contains('qhn-preferred'),true);
  assert.equal(p.doc.getElementById('2').classList.contains('qhn-preferred'),false);
  assert.equal(hidden(p,1),true); assert.equal(hidden(p,2),true); assert.equal(hidden(p,10),true);
  p.dom.window.HackerViews.configure([], false, [], true);
  const request = p.messages.filter(m => m.kind === 'highlights').at(-1);
  p.dom.window.HackerViews.resolveHighlights(request.token, ['carol']);
  assert.equal(p.doc.getElementById('3').classList.contains('qhn-preferred'),true);
  assert.equal(p.doc.getElementById('1').classList.contains('qhn-preferred'),false);
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),false);
  p.dom.window.HackerViews.configure([], false, [], false);
  p.dom.window.HackerViews.resolveHighlights(request.token, ['alice']);
  assert.equal(p.doc.querySelectorAll('.qhn-preferred').length,0);
  p.dom.window.close();
});

test('ordered effects apply selected colors and later changes remove stale highlights', async () => {
  const p = await page(`<table>${story(10,'alice')}${row(1,'alice')}${row(2,'bob',1)}</table>`, {blocked: []});
  p.dom.window.HackerViews.setOrdered(true);
  p.resolve({'10':'highlight:#e98caf','1':'highlight:#599bea','2':'visible'});
  assert.equal(hidden(p,10),false);
  assert.equal(p.doc.getElementById('10').style.getPropertyValue('--qhn-highlight'),'#e98caf');
  assert.equal(p.doc.getElementById('1').style.getPropertyValue('--qhn-highlight'),'#599bea');
  assert.equal(p.doc.getElementById('2').classList.contains('qhn-preferred'),false);
  p.dom.window.HackerViews.setOrdered(true);
  p.resolve({'10':'blocked','1':'blocked','2':'blocked'});
  assert.equal(hidden(p,10),true); assert.equal(hidden(p,2),true);
  assert.equal(p.doc.querySelectorAll('.qhn-preferred').length,0);
  p.dom.window.HackerViews.setOrdered(false);
  assert.equal(hidden(p,10),false);
  p.dom.window.close();
});

test('profiles show matching effect and priority while remaining readable when blocked', async () => {
  const p = await page('<table><tr><td>user:</td><td><a class="hnuser" href="user?id=alice">alice</a></td></tr><tr><td>karma:</td><td>1000</td></tr></table>', {blocked: [], url: 'https://news.ycombinator.com/user?id=alice'});
  let request = p.messages.filter(m => m.kind === 'profile').at(-1);
  assert.equal(request.username,'alice');
  const panel = p.doc.getElementById('qhn-profile-effect');
  p.dom.window.HackerViews.resolveProfile(request.token, {effect:'highlight:#599bea', label:'Highlight · Blue', priority:2, ruleName:'Experienced accounts'});
  assert.match(panel.textContent,/Filter 2: Experienced accounts/);
  assert.equal(panel.style.getPropertyValue('--qhn-profile-color'),'#599bea');
  p.dom.window.HackerViews.setOrdered(true);
  const current = p.messages.filter(m => m.kind === 'profile').at(-1);
  p.dom.window.HackerViews.resolveProfile(current.token,{effect:'blocked',label:'Blocked',priority:1,ruleName:'Alice'});
  p.dom.window.HackerViews.resolveProfile(request.token,{effect:'visible',label:'Wrong stale result',priority:0});
  assert.match(panel.textContent,/Blocked/);
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),false);
  p.dom.window.HackerViews.resolveProfile(current.token,{effect:'unresolved',label:'Couldn’t verify effect',priority:1,ruleName:'Karma'});
  assert.equal(panel.querySelector('button').textContent,'Retry');
  p.dom.window.HackerViews.resolveProfile(current.token,{effect:'visible',label:'Shown without unverified styling',priority:0});
  assert.match(panel.textContent,/Some filter conditions could not be verified/);
  assert.doesNotMatch(panel.textContent,/No enabled filter matches/);
  assert.equal(p.doc.querySelectorAll('#qhn-profile-effect').length,1);
  p.dom.window.close();
});

test('general highlights label the matching filter and clear the label for account-specific highlights', async () => {
  const p = await page(`<table>${row(1,'alice')}${story(10,'bob')}</table>`, {blocked: []});
  p.dom.window.HackerViews.setOrdered(true);
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  p.dom.window.HackerViews.resolve(request.token, {'1':'highlight:#599bea','10':'highlight:#27a99a'}, {'1':'High karma <10000>', '10':'Veterans'});
  const author = p.doc.getElementById('1').querySelector('.hnuser');
  assert.equal(author.getAttribute('data-qhn-filter-label'),'High karma <10000>');
  assert.equal(author.textContent,'alice');
  assert.equal(p.doc.getElementById('10').nextElementSibling.querySelector('.hnuser').getAttribute('data-qhn-filter-label'),'Veterans');
  p.dom.window.HackerViews.setOrdered(true);
  p.resolve({'1':'highlight:#599bea','10':'visible'});
  assert.equal(author.hasAttribute('data-qhn-filter-label'),false);
  p.dom.window.close();
});

test('fade levels keep contributions visible, do not fade replies, and clear on effect changes', async () => {
  const p = await page(`<table>${story(10,'alice')}${row(1,'alice')}${row(2,'bob',1)}</table>`, {blocked: []});
  p.dom.window.HackerViews.setOrdered(true);
  p.resolve({'10':'fade:25','1':'fade:75','2':'visible'});
  assert.equal(hidden(p,10),false);
  assert.equal(hidden(p,1),false);
  assert.equal(p.doc.getElementById('10').style.getPropertyValue('--qhn-fade-opacity'),'0.75');
  assert.equal(p.doc.getElementById('1').style.getPropertyValue('--qhn-fade-opacity'),'0.25');
  assert.equal(p.doc.getElementById('2').classList.contains('qhn-faded'),false);
  p.dom.window.HackerViews.setOrdered(true);
  p.resolve({'10':'visible','1':'highlight:#599bea','2':'visible'});
  assert.equal(p.doc.querySelectorAll('.qhn-faded').length,0);
  assert.equal(p.doc.getElementById('1').classList.contains('qhn-preferred'),true);
  p.dom.window.close();
});

test('profile banner opens account notes in every state without a username ellipsis', async () => {
  const p = await page('<table><tr><td>user:</td><td><a class="hnuser" href="user?id=alice">alice</a></td></tr></table>', {blocked: [], url:'https://news.ycombinator.com/user?id=alice'});
  const panel = p.doc.getElementById('qhn-profile-effect');
  const request = p.messages.filter(m => m.kind === 'profile').at(-1);
  assert.equal(p.doc.querySelectorAll('.qhn-record').length,0);
  for (const result of [null, {effect:'visible',label:'No matching filter'}, {effect:'blocked',label:'Blocked',priority:1,ruleName:'Blocked'}, {effect:'unresolved',label:'Couldn’t verify effect',priority:1,ruleName:'New accounts'}]) {
    if (result) p.dom.window.HackerViews.resolveProfile(request.token,result);
    const edit = panel.querySelector('.qhn-profile-edit');
    assert.equal(edit.textContent,'Edit filters…');
    edit.click();
    const capture = p.messages.at(-1);
    assert.equal(capture.username,'alice');
    assert.equal(capture.url,undefined);
    assert.equal(capture.excerpt,undefined);
    assert.equal(panel.querySelectorAll('.qhn-profile-edit').length,1);
  }
  p.dom.window.close();
});

test('profile banner lives outside the content-sized profile table in every filter state', async () => {
  const p = await page('<main><table id="profile"><tr><td>user:</td><td><a class="hnuser" href="user?id=alice">alice</a></td></tr></table></main>', {blocked: [], url:'https://news.ycombinator.com/user?id=alice'});
  const panel = p.doc.getElementById('qhn-profile-effect');
  const table = p.doc.getElementById('profile');
  assert.equal(panel.parentElement,table.parentElement);
  assert.equal(panel.nextElementSibling.id,'qhn-profile-record');
  assert.equal(panel.nextElementSibling.nextElementSibling,table);
  assert.equal(table.rows.length,1);
  const request = p.messages.filter(m => m.kind === 'profile').at(-1);
  for (const result of [{effect:'visible',label:'No matching filter'}, {effect:'highlight:#27a99a',label:'Highlight · Teal',priority:3,ruleName:'Wize Guys'}]) {
    p.dom.window.HackerViews.resolveProfile(request.token,result);
    assert.equal(panel.nextElementSibling.id,'qhn-profile-record');
  assert.equal(panel.nextElementSibling.nextElementSibling,table);
    assert.equal(p.dom.window.getComputedStyle(panel).width,'100%');
    assert.equal(p.dom.window.getComputedStyle(panel).boxSizing,'border-box');
  }
  p.dom.window.close();
});

test('progressive results reveal verified rows while unchecked rows stay hidden', async () => {
  const p = await page(`<table>${story(10,'alice')}${row(1,'alice')}${row(2,'bob',1)}</table>`, {blocked: [], url:'https://news.ycombinator.com/item?id=10'});
  p.dom.window.HackerViews.setOrdered(true);
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  assert.equal(request.ids[0],10);
  p.dom.window.HackerViews.resolvePartial(request.token, {'1':'visible'});
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),true);
  p.dom.window.HackerViews.resolvePartial(request.token, {'10':'visible'});
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),false);
  assert.equal(hidden(p,1),false);
  assert.equal(hidden(p,2),true);
  assert.ok(p.doc.getElementById('qhn-progress'));
  p.dom.window.HackerViews.resolvePartial(request.token, {'2':'fade:50'});
  assert.equal(hidden(p,2),false);
  assert.equal(p.doc.getElementById('2').classList.contains('qhn-faded'),true);
  p.resolve({'10':'visible','1':'visible','2':'fade:50'});
  assert.equal(p.doc.getElementById('qhn-progress'),null);
  p.dom.window.HackerViews.resolvePartial(request.token, {'10':'blocked','1':'blocked','2':'blocked'});
  assert.equal(hidden(p,1),false);
  p.dom.window.close();
});

test('progressive blocked roots never reveal the thread', async () => {
  const p = await page(`<table>${story(10,'alice')}${row(1,'bob')}</table>`, {blocked: [], url:'https://news.ycombinator.com/item?id=10'});
  p.dom.window.HackerViews.setOrdered(true);
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  p.dom.window.HackerViews.resolvePartial(request.token, {'10':'blocked','1':'visible'});
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),true);
  assert.equal(p.messages.at(-1).kind,'held');
  p.dom.window.close();
});

test('faded comments and stories label their matching filter and clear it on changes', async () => {
  const p = await page(`<table>${row(1,'alice')}${story(10,'bob')}</table>`, {blocked: []});
  p.dom.window.HackerViews.setOrdered(true);
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  p.dom.window.HackerViews.resolvePartial(request.token, {'1':'fade:50','10':'fade:75'}, {'1':'Potential bot', '10':'New accounts'});
  const author = p.doc.getElementById('1').querySelector('.hnuser');
  assert.equal(author.getAttribute('data-qhn-filter-label'),'Potential bot');
  assert.equal(author.textContent,'alice');
  assert.ok(author.classList.contains('qhn-faded-author'));
  assert.equal(p.doc.getElementById('10').nextElementSibling.querySelector('.hnuser').getAttribute('data-qhn-filter-label'),'New accounts');
  p.dom.window.HackerViews.setOrdered(true);
  p.resolve({'1':'visible','10':'visible'});
  assert.equal(p.doc.querySelectorAll('.qhn-faded-author').length,0);
  assert.equal(author.hasAttribute('data-qhn-filter-label'),false);
  p.dom.window.close();
});


test('unified notes show profile notes and annotations without expansion and preserve drafts', async () => {
  const p = await page('<table><tr><td><a class="hnuser" href="user?id=alice">alice</a></td></tr></table>', {blocked: [], url:'https://news.ycombinator.com/user?id=alice'});
  const api = p.dom.window.HackerViews;
  const record = {note:'Profile note', references:[{id:'ref1', url:'https://example.com/source', title:'Example <source>', date:'Sep 16', annotation:'Comment note', excerpt:'Saved text'}]};
  api.profileRecord('alice', record);
  assert.deepEqual([...p.doc.querySelectorAll('.qhn-note-text')].map(e=>e.textContent),['Profile note','Comment note']);
  assert.equal(p.doc.querySelectorAll('.qhn-note details').length,1);
  assert.equal(p.doc.querySelector('.qhn-note details summary').textContent,'Saved excerpt');
  assert.equal(p.doc.querySelectorAll('#qhn-profile-record textarea').length,0);
  p.doc.querySelector('.qhn-note footer button').click();
  const input = p.doc.querySelector('.qhn-note textarea');
  input.value='New note'; input.dispatchEvent(new p.dom.window.Event('input'));
  api.profileRecord('alice',record);
  assert.equal(p.doc.querySelector('.qhn-note textarea'),input);
  assert.equal(input.value,'New note');
  p.doc.querySelector('.qhn-note-editor > button').click();
  assert.equal(p.messages.at(-1).kind,'profileSaveNote');
  api.profileSaveStatus(false);
  assert.equal(input.isConnected,true);
  p.doc.querySelector('.qhn-note-editor > button').click();
  api.profileRecord('alice',{...record,note:'New note'});
  api.profileSaveStatus(true);
  assert.equal(p.doc.querySelector('.qhn-note-text').textContent,'New note');
  assert.equal(p.doc.querySelectorAll('#qhn-profile-record textarea').length,0);
  p.dom.window.close();
});

test('new notes default to the profile and reuse one ID across autosaves', async () => {
  const p = await page('<table><tr><td><a class="hnuser" href="user?id=alice">alice</a></td></tr></table>', {blocked: [], url:'https://news.ycombinator.com/user?id=alice'});
  const api = p.dom.window.HackerViews;
  api.profileRecord('alice',{note:'',references:[]});
  p.doc.querySelector('#qhn-profile-record > header button').click();
  const input = p.doc.querySelector('.qhn-note textarea');
  input.value='First'; input.dispatchEvent(new p.dom.window.Event('input')); input.dispatchEvent(new p.dom.window.Event('blur'));
  const first=p.messages.at(-1);
  assert.equal(first.kind,'profileUpsertNote'); assert.equal(first.url,'https://news.ycombinator.com/user?id=alice');
  api.profileSaveStatus(true);
  input.value='Second'; input.dispatchEvent(new p.dom.window.Event('input')); input.dispatchEvent(new p.dom.window.Event('blur'));
  assert.equal(p.messages.at(-1).id,first.id);
  assert.equal(p.messages.at(-1).text,'Second');
  p.dom.window.close();
});

test('item-only blocking leaves a directly opened discussion and replies available', async () => {
  const p = await page(`<table class="fatitem">${story(10,'alice')}</table><table>${row(11,'bob')}</table>`, {blocked: [], url:'https://news.ycombinator.com/item?id=10'});
  p.dom.window.HackerViews.setOrdered(true);
  p.resolve({'10':'hidden-item','11':'visible'});
  assert.equal(hidden(p,10),true);
  assert.equal(hidden(p,11),false);
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),false);
  assert.equal(p.messages.some(m => m.kind === 'held'),false);
  p.dom.window.close();
});

test('temporary reveal exempts only the destination, never blocked replies or unresolved content', async () => {
  const p = await page(`<table>${row(10,'alice')}${row(11,'bob',1)}</table>`, {blocked: [], url:'https://news.ycombinator.com/item?id=10'});
  const api = p.dom.window.HackerViews;
  api.setOrdered(true);
  p.resolve({'10':'blocked','11':'blocked'});
  assert.equal(p.messages.at(-1).reason,'blocked');
  api.revealDestination();
  p.resolve({'10':'blocked','11':'blocked'});
  assert.equal(hidden(p,10),false);
  assert.equal(hidden(p,11),true);
  assert.equal(p.messages.at(-1).kind,'ready');
  api.retry();
  p.resolve({'10':'unresolved','11':'blocked'});
  assert.equal(hidden(p,10),true);
  assert.equal(p.messages.at(-1).reason,'unresolved');
  p.dom.window.close();
});

test('out-of-order checks reveal only a contiguous prefix to prevent insertions above visible rows', async () => {
  const p = await page(`<table>${story(10,'alice')}${story(11,'bob')}${story(12,'carol')}</table>`, {blocked: []});
  const api = p.dom.window.HackerViews;
  api.setOrdered(true);
  const token = p.messages.filter(m => m.kind === 'ancestors').at(-1).token;
  api.resolvePartial(token, {'12':'visible'});
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),false);
  assert.ok(p.doc.getElementById('qhn-progress'));
  assert.equal(hidden(p,10),true);
  assert.equal(hidden(p,12),true);
  api.resolvePartial(token, {'10':'visible'});
  assert.equal(hidden(p,10),false);
  assert.equal(hidden(p,12),true);
  api.resolvePartial(token, {'11':'blocked'});
  assert.equal(hidden(p,11),true);
  assert.equal(hidden(p,12),false);
  p.dom.window.close();
});

test('loading marker moves down at the checked boundary and disappears after completion', async () => {
  const p = await page(`<table>${story(10,'alice')}${story(11,'bob')}${story(12,'carol')}</table>`, {blocked: []});
  assert.equal(p.doc.getElementById('qhn-progress'),null);
  const api = p.dom.window.HackerViews;
  api.setOrdered(true);
  const token = p.messages.filter(m => m.kind === 'ancestors').at(-1).token;
  api.resolvePartial(token, {'10':'visible'});
  const marker = p.doc.getElementById('qhn-progress');
  assert.equal(marker.tagName,'TR');
  assert.equal(marker.nextElementSibling.id,'11');
  assert.match(marker.textContent,/Loading more/);
  api.resolvePartial(token, {'11':'blocked'});
  assert.equal(marker.nextElementSibling.id,'12');
  api.resolve(token, {'10':'visible','11':'blocked','12':'visible'});
  assert.equal(p.doc.getElementById('qhn-progress'),null);
  p.dom.window.close();
});

test('failed verification offers retry at the affected content', async () => {
  const p = await page(`<table>${story(10,'alice')}${story(11,'bob')}</table>`, {blocked: []});
  p.dom.window.HackerViews.setOrdered(true);
  p.resolve({'10':'visible','11':'unresolved'});
  const marker = p.doc.getElementById('qhn-progress');
  assert.equal(marker.nextElementSibling.id,'11');
  assert.equal(marker.querySelector('button').textContent,'Retry');
  p.dom.window.close();
});

test('OP badge marks only the original author and survives filtering and collapse', async () => {
  const p = await page(`<table>${row(10,'alice')}${row(11,'bob',1)}${row(12,'alice',2)}</table>`, {blocked: [], url:'https://news.ycombinator.com/item?id=10'});
  const api = p.dom.window.HackerViews;
  api.originalPoster('alice');
  assert.equal(p.doc.querySelectorAll('.qhn-op-badge').length,2);
  assert.equal(p.doc.getElementById('11').querySelector('.qhn-op'),null);
  assert.equal(p.doc.getElementById('10').querySelector('.hnuser').textContent,'alice');
  api.setOrdered(true);
  const token = p.messages.filter(m => m.kind === 'ancestors').at(-1).token;
  api.resolve(token, {'10':'highlight:#b18be8','11':'visible','12':'visible'}, {'10':'Greybeards'});
  const badge = p.doc.getElementById('10').querySelector('.qhn-op');
  assert.equal(badge.dataset.qhnFilterLabel,'Greybeards');
  p.doc.getElementById('10').classList.add('coll');
  assert.equal(badge.querySelector('.qhn-op-badge').title,'Original poster');
  api.originalPoster('alice');
  assert.equal(p.doc.querySelectorAll('.qhn-op-badge').length,2);
  p.dom.window.close();
});

test('filter changes anchor to the next surviving contribution and skip blocked rows', async () => {
  const p = await page(`<table>${story(10,'alice')}${story(11,'bob')}${story(12,'carol')}</table>`, {blocked: []});
  Object.defineProperty(p.dom.window,'scrollY',{value:100, configurable:true});
  let scrolled;
  p.dom.window.scrollTo = (x,y) => { scrolled=y; };
  for (const [id, top] of [[10,20],[11,120],[12,220]]) {
    const element=p.doc.getElementById(String(id));
    element.getClientRects=()=> element.hasAttribute('data-qhn-hidden') ? [] : [{}];
    element.getBoundingClientRect=()=>({top: id===12 && hidden(p,10) ? 50 : top, bottom:top+80});
  }
  const api=p.dom.window.HackerViews;
  api.setOrdered(true);
  const token=p.messages.filter(m=>m.kind==='ancestors').at(-1).token;
  api.resolvePartial(token,{'10':'blocked'});
  assert.equal(scrolled,undefined);
  api.resolve(token,{'10':'blocked','11':'blocked','12':'visible'});
  assert.equal(scrolled,130);
  assert.equal(hidden(p,12),false);
  p.dom.window.close();
});

test('a discussion over 1000 comments requests every item and renders progressively', async () => {
  const rows = Array.from({length:1056},(_,i)=>row(i+2,'alice')).join('');
  const p = await page(`<table class="fatitem">${story(1,'author')}</table><table>${rows}</table>`, {blocked: [],url:'https://news.ycombinator.com/item?id=1'});
  const api=p.dom.window.HackerViews;
  api.setOrdered(true);
  const request=p.messages.filter(m=>m.kind==='ancestors').at(-1);
  assert.equal(request.ids.length,1057);
  const first=Object.fromEntries(request.ids.slice(0,8).map(id=>[String(id),'visible']));
  api.resolvePartial(request.token,first);
  assert.equal(p.messages.at(-1).kind,'ready');
  assert.ok(p.doc.getElementById('qhn-progress'));
  api.resolve(request.token,Object.fromEntries(request.ids.map(id=>[String(id),'visible'])));
  assert.equal(p.messages.at(-1).complete,true);
  assert.equal(hidden(p,1057),false);
  assert.equal(p.doc.getElementById('qhn-progress'),null);
  p.dom.window.close();
});

async function lazyPage(anchor, {reveal = false, visit = null} = {}) {
  const p=await page('<main id="hv-topic"><header id="hv-header" class="hv-header"></header><div id="hv-topic-root"></div></main>',{blocked:[],url:'https://news.ycombinator.com/item?id=1'});
  p.dom.window.Element.prototype.getClientRects=function(){return this.closest('[hidden]')?[]:[{}];};
  p.dom.window.Element.prototype.getBoundingClientRect=function(){return {top:0,bottom:100};};
  p.doc.body.dataset.hvTopic='1';
  if(reveal)p.doc.body.dataset.hvReveal='1';
  if(visit)p.doc.body.dataset.hvVisit=Buffer.from(JSON.stringify(visit)).toString('base64');
  if(anchor) {p.doc.body.dataset.hvAnchor=Buffer.from(JSON.stringify(anchor)).toString('base64');p.doc.body.dataset.hvScroll=String(anchor.y);}
  p.dom.window.HackerViews.retry();
  return p;
}
test('lazy topic fetches only the root first and prunes blocked branches before fetching children', async()=>{
  const p=await lazyPage(); const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  assert.deepEqual([...request.ids],[1]);
  api.lazyResult(request.token,[{id:1,effect:'blocked',label:'Blocked',item:{id:1,type:'story',by:'author',title:'Hidden title',kids:[2,3]}}]);
  await new Promise(r=>setTimeout(r,5));
  assert.equal(p.messages.filter(m=>m.kind==='lazyItems').length,1);
  assert.equal(p.doc.body.textContent.includes('Hidden title'),false);
  assert.match(p.doc.body.textContent,/Reveal this contribution/);
  p.dom.window.close();
});
test('lazy comments are fetched in bounded batches and unsafe HTML is never injected',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',by:'author',title:'Topic',kids:Array.from({length:10000},(_,i)=>i+2)}}]);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').find(m=>m.ids.includes(2));
  assert.equal(request.ids.length,8);
  api.lazyResult(request.token,request.ids.map(id=>({id,effect:id===2?'blocked':'visible',item:{id,type:'comment',by:'reader',parent:1,text:'<p>Safe <script>bad()</script><a href="javascript:bad()">link</a><img src="https://tracker.test/">',kids:id===2?[20000]:[]}})));
  assert.equal(p.doc.querySelector('.commtext script'),null);
  assert.equal(p.doc.querySelector('.commtext img'),null);
  assert.equal(p.doc.querySelector('.commtext a[href^="javascript:"]'),null);
  assert.equal(p.doc.getElementById('2'),null);
  assert.equal(p.doc.querySelectorAll('.comtr').length,7);
  p.dom.window.close();
});

test('lazy renderer ignores obsolete results and preserves native reply destinations',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  const request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token-1,[{id:1,effect:'visible',item:{id:1,title:'Stale'}}]);
  assert.equal(p.doc.body.textContent.includes('Stale'),false);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'comment',by:'author',parent:99,text:'Target',kids:[]}}]);
  assert.equal(p.doc.querySelector('.comhead a.hv-reply').href,'https://news.ycombinator.com/reply?id=1&goto=item%3Fid%3D1%231');
  assert.equal(p.doc.querySelector('.commtext').textContent,'Target');
  p.dom.window.close();
});

test('lazy comment header restores root, parent, siblings and compact accessible collapse',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',title:'Topic',kids:[2,3,4]}}]);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[2,3,4].map(id=>({id,effect:'visible',item:{id,type:'comment',by:'reader',parent:1,text:'Comment'}})));
  const row=p.doc.getElementById('3');
  assert.deepEqual([...row.querySelectorAll('.hv-comment-nav a')].map(a=>[a.textContent,new URL(a.href).pathname+new URL(a.href).search]),[['parent','/item?id=1'],['prev','/item?id=2'],['next','/item?id=4']]);
  const toggle=row.querySelector('.hv-collapse');
  assert.equal(toggle.textContent,'[-]');assert.equal(toggle.getAttribute('aria-expanded'),'true');
  toggle.click();assert.equal(toggle.textContent,'[+]');assert.equal(toggle.getAttribute('aria-label'),'Expand thread');assert.equal(row.querySelector('.comment').hidden,true);
  toggle.click();assert.equal(toggle.textContent,'[-]');assert.equal(row.querySelector('.comment').hidden,false);
  p.dom.window.close();
});

test('direct comment receives its actual story root when ancestry resolves',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  const request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'comment',by:'reader',parent:42,text:'Comment'}}]);
  api.originalPoster('author',99);
  const root=[...p.doc.querySelectorAll('.hv-comment-nav a')].find(a=>a.textContent==='root');
  assert.equal(root.href,'https://news.ycombinator.com/item?id=99');
  assert.equal(p.doc.querySelector('.commtext').textContent,'Comment');
  p.dom.window.close();
});

test('next loads siblings in the current discussion and skips blocked siblings without navigating',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let scrolled;
  p.dom.window.Element.prototype.scrollIntoView=function(){scrolled=this;};
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',title:'Topic',kids:[2,3,4,5,6,7,8,9,10,11]}}]);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').find(m=>m.ids.includes(9));
  api.lazyResult(request.token,request.ids.map(id=>({id,effect:'visible',item:{id,type:'comment',by:'reader',parent:1,text:'Comment'}})));
  // Keep the next batch outside the viewport, so only clicking next requests it.
  p.dom.window.Element.prototype.getBoundingClientRect=function(){return {top:10000,bottom:10100};};
  await new Promise(r=>setTimeout(r,5));
  const next=[...p.doc.getElementById('9').querySelectorAll('.hv-comment-nav a')].find(a=>a.textContent==='next');
  const click=new p.dom.window.MouseEvent('click',{bubbles:true,cancelable:true});next.dispatchEvent(click);
  assert.equal(click.defaultPrevented,true);assert.equal(next.getAttribute('aria-busy'),'true');
  request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  assert.deepEqual([...request.ids],[10,11]);
  api.lazyResult(request.token,[10,11].map(id=>({id,effect:id===10?'blocked':'visible',item:{id,type:'comment',by:'reader',parent:1,text:'Comment'}})));
  await new Promise(r=>setTimeout(r,5));
  assert.ok(scrolled.contains(p.doc.getElementById('11')));
  assert.equal(next.textContent,'next');assert.equal(next.hasAttribute('aria-busy'),false);
  assert.equal(p.dom.window.location.href,'https://news.ycombinator.com/item?id=1');
  const prev=[...p.doc.getElementById('11').querySelectorAll('.hv-comment-nav a')].find(a=>a.textContent==='prev');
  prev.click();assert.ok(scrolled.contains(p.doc.getElementById('9')));
  const modified=new p.dom.window.MouseEvent('click',{bubbles:true,cancelable:true,metaKey:true});next.dispatchEvent(modified);
  assert.equal(modified.defaultPrevented,false);
  p.dom.window.close();
});

test('lazy failure shows the supplied reason and retries locally without exposing unchecked content',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'unresolved',reason:'You’re offline. Couldn’t load this contribution.'}]);
  assert.match(p.doc.body.textContent,/You’re offline/);
  assert.equal(p.doc.querySelector('.commtext'),null);
  p.doc.querySelector('.hv-own button').click();
  assert.match(p.doc.body.textContent,/Retrying/);
  request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'comment',by:'reader',text:'Recovered'}}]);
  assert.equal(p.doc.querySelector('.commtext').textContent,'Recovered');
  p.dom.window.close();
});

test('vote controls only expose authenticated HN actions for the exact item',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  p.dom.window.IntersectionObserver=class {constructor(callback){this.callback=callback;}observe(target){this.callback([{target,isIntersecting:true}]);}unobserve(){}};
  p.dom.window.fetch=async()=>({ok:true,text:async()=>`<a id="me" href="user?id=reader">reader</a><table>
    <tr class="athing" id="1"><td class="votelinks"><a href="vote?id=1&how=up&auth=fixture">up</a><a href="vote?id=999&how=down&auth=fixture">wrong item</a><a href="https://evil.test/vote?id=1&how=down&auth=fixture">wrong origin</a></td></tr>
    </table>`});
  const request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'comment',by:'reader',text:'Comment'}}]);
  const [up,down]=p.doc.querySelectorAll('.hv-vote');
  assert.equal(up.hidden,true);assert.equal(down.hidden,true);
  await new Promise(r=>setTimeout(r,20));
  assert.equal(up.hidden,false);assert.equal(down.hidden,true);
  assert.equal(p.doc.querySelector('.qhn-op-badge').textContent,'You');
  p.dom.window.close();
});

test('signed-out voting links leave both controls hidden',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  p.dom.window.IntersectionObserver=class {constructor(callback){this.callback=callback;}observe(target){this.callback([{target,isIntersecting:true}]);}unobserve(){}};
  p.dom.window.fetch=async()=>({ok:true,text:async()=>'<table><tr class="athing" id="1"><td class="votelinks"><a href="vote?id=1&how=up">login required</a></td></tr></table>'});
  const request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'comment',by:'reader',text:'Comment'}}]);
  await new Promise(r=>setTimeout(r,20));
  assert.ok([...p.doc.querySelectorAll('.hv-vote')].every(button=>button.hidden));
  p.dom.window.close();
});

test('nested root targets its top-level comment, not the story or immediate parent',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let scrolled;
  p.dom.window.Element.prototype.scrollIntoView=function(){scrolled=this;};
  for(const item of [
    {id:1,type:'story',title:'Story',kids:[2]},
    {id:2,type:'comment',by:'a',parent:1,text:'Thread root',kids:[3]},
    {id:3,type:'comment',by:'b',parent:2,text:'Parent',kids:[4]},
    {id:4,type:'comment',by:'c',parent:3,text:'Nested reply'}
  ]) {
    const request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
    api.lazyResult(request.token,[{id:item.id,effect:'visible',item}]);
    await new Promise(r=>setTimeout(r,5));
  }
  const root=[...p.doc.getElementById('4').querySelectorAll('.hv-comment-nav a')].find(a=>a.textContent==='root');
  assert.equal(root.href,'https://news.ycombinator.com/item?id=2');
  root.click();assert.equal(scrolled,p.doc.getElementById('2').closest('.hv-node'));
  const parent=[...p.doc.getElementById('4').querySelectorAll('.hv-comment-nav a')].find(a=>a.textContent==='parent');
  assert.equal(parent.href,'https://news.ycombinator.com/item?id=3');
  p.dom.window.close();
});

test('independent comments render out of order while positions and pool bounds stay stable',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',title:'Topic',kids:Array.from({length:100},(_,i)=>i+2)}}]);
  await new Promise(r=>setTimeout(r,5));
  const requests=p.messages.filter(m=>m.kind==='lazyItems' && !m.ids.includes(1));
  assert.equal(requests.reduce((n,r)=>n+r.ids.length,0),32);
  const first=requests[0];const id=first.ids[1];
  api.lazyResult(first.token,[{id,effect:'visible',item:{id,type:'comment',by:'fast',text:'Fast sibling',kids:[200]}}]);
  assert.equal(p.doc.getElementById(String(first.ids[0])),null);
  assert.equal(p.doc.getElementById(String(id)).querySelector('.commtext').textContent,'Fast sibling');
  await new Promise(r=>setTimeout(r,5));
  const newRequests=p.messages.filter(m=>m.kind==='lazyItems' && !m.ids.includes(1));
  assert.equal(newRequests.reduce((n,r)=>n+r.ids.length,0),33,'One finished check immediately frees one slot');
  api.lazyResult(first.token,[{id:first.ids[0],effect:'visible',item:{id:first.ids[0],type:'comment',by:'slow',text:'Slow sibling'}}]);
  const order=[...p.doc.querySelectorAll('.comtr')].map(row=>Number(row.id));
  assert.deepEqual(order.slice(0,2),[first.ids[0],id]);
  api.retry(); // invalidates all old requests
  api.lazyResult(first.token,[{id:first.ids[2],effect:'visible',item:{id:first.ids[2],type:'comment',text:'Stale'}}]);
  assert.equal(p.doc.body.textContent.includes('Stale'),false);
  p.dom.window.close();
});

test('a late comment above the viewport preserves the current reading anchor',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',title:'Topic',kids:[2,3]}}]);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:3,effect:'visible',item:{id:3,type:'comment',by:'reader',text:'Currently reading'}}]);
  Object.defineProperty(p.dom.window,'scrollY',{value:100,configurable:true});
  let position;
  p.dom.window.scrollTo=(x,y)=>{position=y;};
  p.doc.getElementById('1').getBoundingClientRect=()=>({top:-200,bottom:-100});
  p.doc.getElementById('3').getBoundingClientRect=()=>({top:p.doc.getElementById('2')?150:20,bottom:300});
  api.lazyResult(request.token,[{id:2,effect:'visible',item:{id:2,type:'comment',by:'slow',text:'Late comment'}}]);
  assert.equal(position,230);
  p.dom.window.close();
});

test('deleted comments show a tombstone directly and preserve surviving replies without Retry',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'comment',deleted:true,parent:99,kids:[2]}}]);
  assert.match(p.doc.body.textContent,/\[deleted\]/);
  assert.equal(p.doc.querySelector('.qhn-record'),null);
  assert.equal(p.doc.querySelector('.hv-vote'),null);
  assert.equal(p.doc.body.textContent.includes('Retry'),false);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  assert.deepEqual([...request.ids],[2]);
  api.lazyResult(request.token,[{id:2,effect:'visible',item:{id:2,type:'comment',by:'reader',parent:1,text:'Surviving reply'}}]);
  assert.equal(p.doc.querySelector('.commtext').textContent,'Surviving reply');
  p.dom.window.close();
});

test('deleted leaves disappear from discussions instead of showing a filter error',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',title:'Topic',kids:[2]}}]);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:2,effect:'visible',item:{id:2,type:'comment',deleted:true,parent:1}}]);
  assert.equal(p.doc.querySelector('.hv-deleted'),null);
  assert.equal(p.doc.body.textContent.includes('Retry'),false);
  assert.equal(p.doc.querySelector('.comtr'),null);
  p.dom.window.close();
});

test('local filter edits update loaded rows without requesting or hiding the whole page',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',title:'Topic',kids:[2,3]}}]);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[2,3].map(id=>({id,effect:'visible',item:{id,type:'comment',by:'reader',parent:1,text:'Comment '+id}})));
  await new Promise(r=>setTimeout(r,5));
  const survivor=p.doc.getElementById('3');
  Object.defineProperty(p.dom.window,'scrollY',{value:100,configurable:true});
  p.doc.getElementById('1').getBoundingClientRect=()=>({top:-200,bottom:-100});
  p.doc.getElementById('2').getBoundingClientRect=()=>({top:0,bottom:100});
  survivor.getBoundingClientRect=()=>({top:p.doc.getElementById('2')?120:20,bottom:200});
  let restored;
  p.dom.window.scrollTo=(x,y)=>{restored=y;};
  p.messages.length=0;
  api.setOrdered(true,true);
  assert.ok(p.doc.getElementById('2'),'Content stays visible while the local check runs');
  const local=p.messages.find(m=>m.kind==='localRecheck');
  assert.deepEqual([...local.ids],[1,2,3]);
  api.localResult(local.token,{1:'visible',2:'blocked',3:'visible'},{2:'Blocked'});
  await new Promise(r=>setTimeout(r,10));
  assert.equal(p.doc.getElementById('2'),null);
  assert.equal(restored,120,'The next surviving comment replaces the removed reading anchor');
  assert.equal(p.doc.getElementById('3'),survivor,'Unchanged rows retain their DOM');
  assert.equal(p.messages.some(m=>['lazyItems','ancestors','pending','networkAcquire'].includes(m.kind)),false);
  api.setOrdered(false,true);
  const second=p.messages.filter(m=>m.kind==='localRecheck').at(-1);
  api.localResult(local.token,{3:'blocked'},{});
  assert.ok(p.doc.getElementById('3'),'Ignore stale local results');
  api.localResult(second.token,{1:'visible',2:'visible',3:'visible'},{});
  assert.ok(p.doc.getElementById('2'),'Unblocking reuses retained content');
  p.dom.window.close();
});

test('refresh targets the saved contribution and restores its offset as it arrives',async()=>{
  const p=await lazyPage({id:3,top:-25,y:900,ancestors:[1,2]});
  const api=p.dom.window.HackerViews;
  let restored;
  p.dom.window.scrollTo=(x,y)=>{restored=y;};
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',title:'Topic',kids:[2]}}]);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').find(m=>m.ids.includes(2));
  api.lazyResult(request.token,[{id:2,effect:'visible',item:{id:2,type:'comment',by:'parent',parent:1,text:'Parent',kids:[3]}}]);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').find(m=>m.ids.includes(3));
  assert.ok(request,'Load the branch containing the saved anchor');
  api.lazyResult(request.token,[{id:3,effect:'visible',item:{id:3,type:'comment',by:'reader',parent:2,text:'Reading here'}}]);
  assert.equal(restored,25,'Use the contribution offset instead of the old pixel position');
  p.dom.window.close();
});

test('filter edits show an actionable paused state and explicit resume restarts unfinished comments',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',title:'Topic',kids:[2,3]}}]);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:2,effect:'visible',item:{id:2,type:'comment',by:'reader',parent:1,text:'Loaded'}}]);
  p.dom.window.scrollTo=()=>{};
  p.messages.length=0;
  api.setOrdered(true,true);
  const check=p.messages.find(m=>m.kind==='localRecheck');
  api.localResult(check.token,{1:'visible',2:'visible'},{});
  const paused=p.doc.querySelector('[data-hv-paused]');
  assert.ok(paused);
  assert.equal(paused.querySelector('.qhn-spinner'),null);
  assert.equal(p.messages.some(m=>m.kind==='lazyItems'),false);
  paused.querySelector('button').click();
  const resumed=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  assert.deepEqual([...resumed.ids],[3]);
  api.lazyResult(resumed.token,[{id:3,effect:'visible',item:{id:3,type:'comment',by:'reader',parent:1,text:'Resumed'}}]);
  assert.ok(p.doc.getElementById('3'));
  assert.equal(p.doc.querySelector('[data-hv-paused]'),null);
  p.dom.window.close();
});

test('scroll diagnostics emit aggregate measurements only when enabled',async()=>{
  const p=await page('<p>Diagnostic fixture</p>',{blocked:[],diagnostics:true});
  assert.ok(p.messages.some(m=>m.event==='scroll.instrumented' && m.version===2));
  p.dom.window.HackerViews.readingPosition();
  for(let i=0;i<10;i++)p.dom.window.dispatchEvent(new p.dom.window.Event('wheel'));
  assert.equal(p.messages.filter(m=>m.event==='scroll.sample').length,0,'Do not bridge every wheel event');
  await new Promise(r=>setTimeout(r,1050));
  const sample=p.messages.find(m=>m.event==='scroll.sample');
  assert.equal(sample.wheels,10);
  assert.ok(sample.anchorCalls>=1);
  assert.ok(sample.anchorTotal>=0);
  assert.equal(sample.anchorRowsMax,0);
  assert.equal(JSON.stringify(sample).includes('Diagnostic fixture'),false);
  p.dom.window.close();
});

test('scrolling defers above-viewport results through momentum while allowing lower content',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',title:'Topic',kids:[2,3,4]}}]);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  const entry=id=>({id,effect:'visible',item:{id,type:'comment',by:'reader',parent:1,text:'Comment '+id}});
  api.lazyResult(request.token,[entry(3)]);
  Object.defineProperty(p.dom.window,'scrollY',{value:100,configurable:true});
  p.doc.getElementById('1').getBoundingClientRect=()=>({top:-300,bottom:-200});
  p.doc.getElementById('3').getBoundingClientRect=()=>({top:p.doc.getElementById('2')?220:20,bottom:400});
  const owns=p.doc.querySelectorAll('.hv-own');
  owns[1].getBoundingClientRect=()=>({top:-50,bottom:-10});
  owns[3].getBoundingClientRect=()=>({top:400,bottom:450});
  const frames=[];p.dom.window.requestAnimationFrame=callback=>frames.push(callback);
  let corrections=0;p.dom.window.scrollTo=()=>corrections++;
  p.dom.window.dispatchEvent(new p.dom.window.Event('wheel'));
  api.lazyResult(request.token,[entry(2)]);
  api.lazyResult(request.token,[entry(4)]);
  assert.equal(frames.length,1,'Coalesce deliveries into one frame');
  frames.shift()();
  assert.equal(p.doc.getElementById('2'),null);
  assert.ok(p.doc.getElementById('4'));
  assert.equal(corrections,0,'Do not correct position during scrolling');
  frames.splice(0).forEach(f=>f());
  await new Promise(r=>setTimeout(r,120));
  p.dom.window.dispatchEvent(new p.dom.window.Event('scroll'));
  await new Promise(r=>setTimeout(r,120));
  frames.splice(0).forEach(f=>f());
  assert.equal(p.doc.getElementById('2'),null,'Momentum extends the deferral');
  await new Promise(r=>setTimeout(r,120));
  frames.splice(0).forEach(f=>f());
  assert.ok(p.doc.getElementById('2'),'Apply the deferred result after scrolling settles');
  assert.equal(corrections,1,'One anchor correction for the settled batch');
  assert.equal(filter.includes('contain-intrinsic-size: auto 120px'),false);
  p.dom.window.close();
});

test('a filter edit invalidates results waiting for an animation frame',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  const request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  const frames=[];p.dom.window.requestAnimationFrame=callback=>frames.push(callback);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',title:'Obsolete result'}}]);
  api.setOrdered(true,true);
  frames.splice(0).forEach(f=>f());
  assert.equal(p.doc.body.textContent.includes('Obsolete result'),false);
  p.dom.window.close();
});


test('nested replies and story comments return to their containing topic',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',by:'op',title:'Topic',kids:[2]}}]);
  assert.ok(p.doc.querySelector('.hv-comment-toggle'),'the story comments inline rather than through HN\u2019s reply page');
  assert.equal(p.doc.querySelector('.reply a'),null);
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:2,effect:'visible',item:{id:2,type:'comment',by:'reader',parent:1,text:'Reply target'}}]);
  const link=p.doc.getElementById('2').querySelector('.comhead a.hv-reply');
  const url=new URL(link.href);
  assert.equal(url.searchParams.get('id'),'2');
  assert.equal(url.searchParams.get('goto'),'item?id=1#2');
  p.dom.window.close();
});


test('own posts get one outlined identity badge combined with OP and preserve filter labels',async()=>{
  const p=await page(`<a id="me" href="user?id=alice">alice</a><table>${row(10,'alice')}${row(11,'bob')}</table>`,{blocked:[]});
  assert.equal(p.doc.getElementById('10').querySelector('.qhn-op-badge').textContent,'You');
  assert.equal(p.doc.getElementById('11').querySelector('.qhn-op'),null);
  p.dom.window.HackerViews.originalPoster('alice');
  assert.equal(p.doc.getElementById('10').querySelector('.qhn-op-badge').textContent,'You · OP');
  p.dom.window.HackerViews.originalPoster('alice');
  assert.equal(p.doc.querySelectorAll('.qhn-op-badge').length,1);
  p.doc.getElementById('me').remove();
  p.dom.window.HackerViews.originalPoster('bob');
  assert.equal(p.doc.getElementById('10').querySelector('.qhn-op'),null);
  assert.equal(p.doc.getElementById('11').querySelector('.qhn-op-badge').textContent,'OP');
  p.dom.window.close();
});


test('topic loading drains offscreen and collapsed branches without scrolling',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  const proto=p.dom.window.HTMLElement.prototype;
  proto.getBoundingClientRect=function(){return {top:100000,bottom:100100,height:100};};
  proto.getClientRects=function(){return [];};
  const handled=new Set();const seen=new Set();
  for(let turn=0;turn<25;turn++) {
    for(const request of p.messages.filter(m=>m.kind==='lazyItems'&&!handled.has(m.token))) {
      handled.add(request.token);
      assert.ok(request.ids.length<=8);
      api.lazyResult(request.token,request.ids.map(id=>{
        seen.add(id);
        return {id,effect:'visible',item:{id,type:id===1?'story':'comment',by:'reader',parent:id===1?undefined:1,
          title:'Topic',text:'Comment',kids:id===1?Array.from({length:80},(_,i)=>i+2):id===2?[100]:[]}};
      }));
    }
    await new Promise(r=>setTimeout(r,5));
    if(seen.size===82)break;
  }
  assert.equal(seen.size,82,'Load every allowed descendant without a viewport trigger');
  p.dom.window.close();
});

test('scroll reports persist the visible comment and offset, not only page pixels',async()=>{
  const p=await page(`<table>${row(10,'alice')}${row(11,'bob')}</table>`,{blocked:[]});
  const first=p.doc.getElementById('10'),second=p.doc.getElementById('11');
  first.getClientRects=second.getClientRects=()=>[{}];
  first.getBoundingClientRect=()=>({top:-200,bottom:-50});
  second.getBoundingClientRect=()=>({top:-25,bottom:150});
  Object.defineProperty(p.dom.window,'scrollY',{value:800,configurable:true});
  p.dom.window.dispatchEvent(new p.dom.window.Event('scroll'));
  await new Promise(r=>setTimeout(r,180));
  const report=p.messages.filter(m=>m.kind==='scrollPosition').at(-1);
  assert.equal(report.y,800);
  assert.equal(report.anchor.id,11);
  assert.equal(report.anchor.top,-25);
  p.dom.window.close();
});


test('list checks include DOM authors and contribution types for native fast filtering',async()=>{
  const p=await page(`<table>${story(10,'alice')}${row(11,'bob')}</table>`,{blocked:[]});
  p.dom.window.HackerViews.setOrdered(true);
  const request=p.messages.filter(m=>m.kind==='ancestors').at(-1);
  assert.deepEqual(JSON.parse(JSON.stringify(request.items)).sort((a,b)=>a.id-b.id),[
    {id:10,by:'alice',type:'story'},{id:11,by:'bob',type:'comment'}]);
  p.dom.window.close();
});


test('lazy metadata restores authenticated actions, relative age, domain and community fading',async()=>{
  const p=await lazyPage();const api=p.dom.window.HackerViews;
  p.dom.window.IntersectionObserver=class {constructor(callback){this.callback=callback;}observe(target){this.callback([{target,isIntersecting:true}]);}unobserve(){}};
  p.dom.window.fetch=async()=>({ok:true,text:async()=>`<table><tr class="athing comtr" id="1"><td><span class="comhead"><a href="edit?id=1">edit</a><a href="delete-confirm?id=1">delete</a><a href="https://evil.test/flag?id=1">flag</a></span><span class="commtext c5a">Comment</span></td></tr></table>`});
  let request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'comment',by:'reader',text:'Comment',time:Date.now()/1000-7200}}]);
  await new Promise(r=>setTimeout(r,20));
  assert.match(p.doc.querySelector('.comhead').textContent,/2 hours ago/);
  assert.ok(p.doc.querySelector('a[href="https://news.ycombinator.com/edit?id=1"]'));
  assert.ok(p.doc.querySelector('a[href="https://news.ycombinator.com/delete-confirm?id=1"]'));
  assert.equal(p.doc.querySelector('a[href^="https://evil.test"]'),null);
  assert.ok(Number(p.doc.querySelector('.commtext').style.opacity)<1);
  p.dom.window.close();
});

test('dead content stays hidden unless authenticated HN HTML includes its text',async()=>{
  for(const showDead of [false,true]) {
    const p=await lazyPage();const api=p.dom.window.HackerViews;
    p.dom.window.fetch=async()=>({ok:true,text:async()=>showDead?`<table><tr class="athing comtr" id="1"><td><span class="commtext">Moderated text</span></td></tr></table>`:'<table></table>'});
    const request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
    api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'comment',by:'reader',dead:true,text:'Moderated text'}}]);
    assert.equal(p.doc.querySelector('.commtext'),null,'No initial flash of moderated content');
    await new Promise(r=>setTimeout(r,20));
    assert.equal(!!p.doc.querySelector('.commtext'),showDead);
    p.dom.window.close();
  }
});


test('story headers show source domain and jobs omit fabricated points and author',async()=>{
  for(const job of [false,true]) {
    const p=await lazyPage();const api=p.dom.window.HackerViews;
    const request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
    api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:job?'job':'story',by:job?undefined:'author',title:'Topic',url:'https://example.com/article',time:Date.now()/1000-60}}]);
    assert.equal(p.doc.querySelector('.sitebit').textContent,' (example.com)');
    if(job){assert.equal(p.doc.querySelector('.subtext').textContent.includes('points by'),false);assert.equal(p.doc.querySelector('.subtext').textContent.includes('[deleted]'),false);}
    p.dom.window.close();
  }
});

test('profile note editors coalesce for five seconds and flush on blur, pagehide and Done', async () => {
  for (const kind of ['profileSaveNote', 'profileRefNote', 'profileUpsertNote']) {
    const p = await page('<table><tr><td><a class="hnuser" href="user?id=alice">alice</a></td></tr></table>', {blocked: [], url:'https://news.ycombinator.com/user?id=alice'});
    const w = p.dom.window;
    w.HackerViews.profileRecord('alice', {note:kind === 'profileSaveNote' ? 'Original' : '', references:kind === 'profileRefNote' ? [{id:'ref1',url:'https://example.com',annotation:'Original'}] : []});
    if (kind === 'profileUpsertNote') p.doc.querySelector('#qhn-profile-record > header button').click();
    else p.doc.querySelector('.qhn-note footer button').click();
    const input = p.doc.querySelector('.qhn-note textarea');
    let scheduled, nextID = 0;
    const timers = new Map();
    w.setTimeout = (fn, delay) => { scheduled = {id:++nextID,fn,delay}; timers.set(scheduled.id,scheduled); return scheduled.id; };
    w.clearTimeout = id => timers.delete(id);
    const saves = () => p.messages.filter(m => m.kind === kind);
    for (const text of ['First', 'Latest draft']) { input.value=text; input.dispatchEvent(new w.Event('input')); }
    assert.equal(scheduled.delay,5000);
    assert.equal(timers.size,1);
    assert.equal(saves().length,0);
    scheduled.fn();
    assert.equal(saves().length,1);
    assert.equal(saves()[0].text,'Latest draft');
    w.HackerViews.profileSaveStatus(true);
    for (const event of ['blur','pagehide','done']) {
      input.value=event; input.dispatchEvent(new w.Event('input'));
      if (event === 'done') p.doc.querySelector('.qhn-note-editor > button').click();
      else (event === 'blur' ? input : w).dispatchEvent(new w.Event(event));
      assert.equal(saves().at(-1).text,event);
      assert.equal(timers.size,0);
      w.HackerViews.profileSaveStatus(true);
    }
    assert.equal(saves().length,4);
    w.close();
  }
});

test('refresh restores nested collapsed threads before rendering and preserves later expansion', async()=>{
  const items={1:{id:1,type:'story',title:'Topic',kids:[2,5]},2:{id:2,type:'comment',parent:1,by:'a',text:'Parent',kids:[3]},3:{id:3,type:'comment',parent:2,by:'b',text:'Child',kids:[4]},4:{id:4,type:'comment',parent:3,by:'c',text:'Grandchild'},5:{id:5,type:'comment',parent:1,by:'d',text:'Sibling'}};
  async function populate(p) {
    const seen=new Set();
    for(let turn=0;turn<10;turn++) {
      for(const request of p.messages.filter(m=>m.kind==='lazyItems' && !seen.has(m.token))) {
        seen.add(request.token);
        p.dom.window.HackerViews.lazyResult(request.token,request.ids.map(id=>({id,effect:'visible',item:items[id]})));
      }
      await new Promise(r=>setTimeout(r,5));
    }
  }
  const first=await lazyPage();await populate(first);
  first.doc.querySelector('[id="3"] .hv-collapse').click();first.doc.querySelector('[id="2"] .hv-collapse').click();
  assert.deepEqual([...first.messages.filter(m=>m.kind==='collapsedState').at(-1).ids].sort(),[2,3]);
  const state=first.dom.window.HackerViews.refreshState();
  assert.deepEqual([...state.collapsed].sort(),[2,3]);
  first.dom.window.close();
  const restored=await lazyPage(state);
  restored.dom.window.scrollTo=()=>{};
  assert.deepEqual([...restored.dom.window.HackerViews.refreshState().collapsed].sort(),[2,3]);
  await populate(restored);
  for(const id of [2,3]) {
    assert.equal(restored.doc.querySelector(`[id="${id}"] .hv-collapse`).getAttribute('aria-expanded'),'false');
    assert.equal(restored.doc.querySelector(`[id="${id}"] .comment`).hidden,true);
  }
  restored.doc.querySelector('[id="2"] .hv-collapse').click();
  assert.deepEqual([...restored.dom.window.HackerViews.refreshState().collapsed],[3]);
  assert.deepEqual([...restored.messages.filter(m=>m.kind==='collapsedState').at(-1).ids],[3]);
  assert.equal(restored.doc.querySelector('[id="3"] .comment').hidden,true);
  assert.equal(restored.doc.querySelector('[id="5"] .comment').hidden,false);
  restored.dom.window.close();
});

test('upvote state survives a fresh reader document without resurrecting hidden HN actions',async()=>{
  let voted=false;const requests=[];
  async function open() {
    const p=await lazyPage();const w=p.dom.window;
    w.IntersectionObserver=class {constructor(callback){this.callback=callback;}observe(target){this.callback([{target,isIntersecting:true}]);}unobserve(){}};
    w.fetch=async(url,options)=>{
      requests.push({url,options});
      if(new URL(url).pathname==='/vote'){voted=new URL(url).searchParams.get('how')!=='un';return {ok:true};}
      return {ok:true,text:async()=>`<table><tr class="athing comtr" id="1"><td class="votelinks">
        <a id="up_1" class="${voted?'nosee':''}" href="vote?id=1&how=up&auth=fixture">up</a>
        <a id="down_1" style="${voted?'visibility:hidden':''}" href="vote?id=1&how=down&auth=fixture">down</a>
        </td><td><span class="comhead">author ${voted?'<a id="un_1" href="vote?id=1&how=un&auth=fixture">unvote</a>':''}</span></td></tr></table>`};
    };
    const request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
    w.HackerViews.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'comment',by:'author',text:'Comment'}}]);
    await new Promise(r=>setTimeout(r,20));return p;
  }
  const first=await open();
  let [up,down]=first.doc.querySelectorAll('.hv-vote');
  assert.ok(!up.hidden && !down.hidden);
  up.click();
  await new Promise(r=>setTimeout(r,10));
  assert.ok(!up.hidden && up.classList.contains('hv-voted') && up.getAttribute('aria-pressed')==='true','the cast arrow stays, marked');
  assert.equal(up.getAttribute('aria-label'),'Upvoted. Click to undo');
  assert.ok(!down.hidden && down.classList.contains('hv-vacant') && down.disabled && down.getAttribute('aria-hidden')==='true','the other arrow keeps its place, unseen');
  assert.equal(first.doc.querySelector('.hv-vote-status'),null,'no text is appended to the row');
  up.click();
  await new Promise(r=>setTimeout(r,10));
  assert.ok([...first.doc.querySelectorAll('.hv-vote')].every(button=>!button.hidden && !button.disabled && !button.classList.contains('hv-voted')));
  up.click();
  await new Promise(r=>setTimeout(r,10));
  first.dom.window.close();
  const refreshed=await open();
  [up,down]=refreshed.doc.querySelectorAll('.hv-vote');
  assert.ok(!up.hidden && up.classList.contains('hv-voted'),'a fresh document shows the vote HN reports');
  assert.ok(!down.hidden && down.classList.contains('hv-vacant'));
  assert.equal(up.getAttribute('aria-label'),'Upvoted. Click to undo');
  up.click();up.click();
  await new Promise(r=>setTimeout(r,10));
  assert.ok([...refreshed.doc.querySelectorAll('.hv-vote')].every(button=>!button.hidden && !button.disabled && !button.classList.contains('hv-voted')));
  assert.equal(requests.filter(r=>new URL(r.url).pathname==='/vote').length,4);
  assert.deepEqual(requests.filter(r=>new URL(r.url).pathname==='/vote').map(r=>new URL(r.url).searchParams.get('how')),['up','un','up','un']);
  assert.ok(requests.every(r=>r.options.cache==='no-store'));
  refreshed.dom.window.close();
});

test('hidden authenticated vote links are unavailable even without an undo link',async()=>{
  const p=await lazyPage();
  p.dom.window.IntersectionObserver=class {constructor(callback){this.callback=callback;}observe(target){this.callback([{target,isIntersecting:true}]);}unobserve(){}};
  p.dom.window.fetch=async()=>({ok:true,text:async()=>'<table><tr class="athing" id="1"><td class="votelinks"><span class="noshow"><a href="vote?id=1&how=up&auth=fixture">up</a></span><a hidden href="vote?id=1&how=down&auth=fixture">down</a></td></tr></table>'});
  const request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  p.dom.window.HackerViews.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'comment',by:'author',text:'Comment'}}]);
  await new Promise(r=>setTimeout(r,20));
  assert.ok([...p.doc.querySelectorAll('.hv-vote')].every(button=>button.hidden));
  assert.equal(p.doc.querySelector('.hv-vote-status'),null);
  p.dom.window.close();
});

test('failed undo stays retryable and restored controls respect current eligibility',async()=>{
  const p=await lazyPage();let voted=true,fail=true,undoRequests=0;
  p.dom.window.IntersectionObserver=class {constructor(callback){this.callback=callback;}observe(target){this.callback([{target,isIntersecting:true}]);}unobserve(){}};
  p.dom.window.fetch=async url=>{
    if(new URL(url).pathname==='/vote'){undoRequests++;if(fail)return {ok:false};voted=false;return {ok:true};}
    return {ok:true,text:async()=>`<table><tr class="athing" id="1"><td class="votelinks"><a class="${voted?'nosee':''}" href="vote?id=1&how=up&auth=fixture">up</a></td><td>${voted?'<a id="un_1" href="vote?id=1&how=un&auth=fixture">undown</a>':''}</td></tr></table>`};
  };
  const request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  p.dom.window.HackerViews.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'comment',by:'author',text:'Comment'}}]);
  await new Promise(r=>setTimeout(r,20));
  const [up,down]=p.doc.querySelectorAll('.hv-vote');
  assert.ok(!up.hidden && up.classList.contains('hv-vacant'),'the upvote arrow holds its slot above the cast downvote');
  assert.ok(!down.hidden && down.classList.contains('hv-voted'));
  assert.equal(down.getAttribute('aria-label'),'Downvoted. Click to undo');
  down.click();
  await new Promise(r=>setTimeout(r,10));
  assert.equal(down.getAttribute('aria-label'),'Undo failed. Click to retry');
  assert.equal(down.disabled,false);
  assert.ok(!down.hidden && down.classList.contains('hv-voted'),'the vote stays shown until the undo succeeds');
  fail=false;down.click();
  await new Promise(r=>setTimeout(r,10));
  assert.equal(undoRequests,2);
  assert.equal(up.hidden,false);assert.equal(up.disabled,false);assert.equal(up.classList.contains('hv-vacant'),false);assert.equal(down.hidden,true);
  assert.equal(up.classList.contains('hv-voted'),false);
  p.dom.window.close();
});

const hnHeader = (right, current = '') => `<table id="hnmain" border="0" cellpadding="0" cellspacing="0" width="85%"><tbody><tr><td bgcolor="#ff6600"><table border="0" cellpadding="0" cellspacing="0" width="100%" style="padding:2px"><tbody><tr>
  <td style="width:18px;padding-right:4px"><a href="https://news.ycombinator.com"><img src="y18.svg" width="18" height="18"></a></td>
  <td style="line-height:12pt; height:10px;"><span class="pagetop"><b class="hnname"><a href="news">Hacker News</a></b>
    <a href="newest">new</a> | ${current === 'threads' ? '<span class="topsel">' : '<span>'}<a href="threads?id=alice">threads</a></span> | <a href="front">past</a> | <a href="newcomments">comments</a> | <a href="ask">ask</a> | <a href="show">show</a> | <a href="jobs">jobs</a> | <a href="submit">submit</a> | <a href="https://evil.test/newest">offsite</a></span></td>
  <td style="text-align:right;padding-right:4px;"><span class="pagetop">${right}</span></td>
</tr></tbody></table></td></tr><tr id="pagespace" style="height:10px"></tr><tr><td><table class="itemlist"><tbody>${story(1,'carol')}</tbody></table></td></tr></tbody></table>`;
const signedIn = `<a id="me" href="user?id=alice">alice</a> (973) | <a id="logout" href="logout?auth=tok123&amp;goto=news">logout</a>`;

test('feed pages replace HN\'s header with the shared header, keeping identity, karma and auth links', async () => {
  const p = await page(hnHeader(signedIn, 'threads'), {blocked: [], url: 'https://news.ycombinator.com/threads?id=alice'});
  const header = p.doc.querySelector('#hnmain > tbody > tr:first-child > td > header.hv-header');
  assert.ok(header, 'header mounted inside HN\'s header cell');
  assert.equal(p.doc.querySelector('.pagetop'), null);
  assert.equal(p.doc.querySelector('.hnname'), null);
  assert.equal(p.doc.querySelector('img[src="y18.svg"]'), null);
  assert.deepEqual([...header.querySelectorAll('.hv-nav a')].map(a => a.textContent), ['home','new','threads','past','comments','ask','show','jobs','submit']);
  assert.equal(header.querySelector('.hv-nav a').href, 'https://news.ycombinator.com/');
  assert.equal(header.querySelector('.hv-nav a[aria-current="page"]').textContent, 'threads');
  assert.equal(header.querySelector('a[href="https://news.ycombinator.com/threads?id=alice"]').textContent, 'threads');
  const me = header.querySelector('.hv-side a#me');
  assert.equal(me.textContent, 'alice');
  assert.equal(me.href, 'https://news.ycombinator.com/user?id=alice');
  assert.equal(header.querySelector('.hv-karma').textContent, '973');
  assert.equal(header.querySelector('.hv-side a#logout').href, 'https://news.ycombinator.com/logout?auth=tok123&goto=news');
  assert.equal(header.querySelector('.hv-side a[href*="login"]'), null);
  // The signed-in identity still drives the "You" badge after the header is rebuilt.
  assert.equal(p.doc.getElementById('1').nextElementSibling.querySelector('.qhn-op'), null);
  p.dom.window.HackerViews.originalPoster('alice');
  assert.equal(p.doc.querySelector('.hv-header .qhn-op'), null, 'header links never get badges');
  p.dom.window.close();
});

test('home is current on the front page and signed-out headers offer login', async () => {
  const p = await page(hnHeader(`<a href="login?goto=news">login</a>`), {blocked: [], url: 'https://news.ycombinator.com/'});
  const header = p.doc.querySelector('header.hv-header');
  assert.equal(header.querySelector('.hv-nav a[aria-current="page"]').textContent, 'home');
  assert.equal(header.querySelector('.hv-side a').textContent, 'login');
  assert.equal(header.querySelector('.hv-side a').href, 'https://news.ycombinator.com/login?goto=news');
  assert.equal(header.querySelector('#me'), null);
  assert.equal(header.querySelector('.hv-skeleton'), null);
  p.dom.window.close();
});

test('the header shows hidden and unchecked counts and retry re-runs the page checks', async () => {
  const p = await page(hnHeader(signedIn) + `<table>${row(10,'bob')}${row(11,'dave')}${row(12,'erin')}</table>`, {blocked: []});
  p.dom.window.HackerViews.setOrdered(true);
  p.resolve({1: 'visible', 10: 'blocked', 11: 'unresolved', 12: 'visible'});
  const header = p.doc.querySelector('header.hv-header');
  const chips = [...header.querySelectorAll('.hv-chip')];
  assert.deepEqual(chips.map(chip => chip.textContent), ['1 hidden', '1 unchecked · retry'], 'unchecked rows are counted separately from filtered ones');
  assert.equal(chips[1].tagName, 'BUTTON');
  const before = p.messages.filter(m => m.kind === 'ancestors').length;
  chips[1].click();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(p.messages.filter(m => m.kind === 'ancestors').length, before + 1, 'retry requests fresh checks');
  p.resolve({1: 'visible', 10: 'visible', 11: 'visible', 12: 'visible'});
  assert.equal(header.querySelector('.hv-chip'), null, 'chips disappear when nothing is hidden or unchecked');
  assert.equal(p.messages.filter(m => m.kind === 'ready').at(-1).hidden, 0);
  p.dom.window.close();
});

test('the topic shell renders the same header with a pending identity until HN\'s HTML arrives', async () => {
  const p = await lazyPage();
  const header = p.doc.getElementById('hv-header');
  assert.deepEqual([...header.querySelectorAll('.hv-nav a')].map(a => a.textContent), ['home','new','threads','past','comments','ask','show','jobs','submit']);
  assert.equal(header.querySelector('.hv-nav a[aria-current]'), null, 'no section is current inside a discussion');
  assert.ok(header.querySelector('.hv-side .hv-skeleton'), 'identity slot holds its width');
  assert.equal(header.querySelector('.hv-side a'), null);
  p.dom.window.IntersectionObserver = class {constructor(callback){this.callback=callback;}observe(target){this.callback([{target,isIntersecting:true}]);}unobserve(){}};
  p.dom.window.fetch = async () => ({ok: true, text: async () => hnHeader(signedIn)});
  const request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  p.dom.window.HackerViews.lazyResult(request.token, [{id: 1, effect: 'visible', item: {id: 1, type: 'comment', by: 'reader', text: 'Comment'}}]);
  await new Promise(r => setTimeout(r, 20));
  assert.equal(header.querySelector('.hv-skeleton'), null);
  assert.equal(header.querySelector('.hv-side a#me').textContent, 'alice');
  assert.equal(header.querySelector('.hv-karma').textContent, '973');
  assert.equal(header.querySelector('.hv-side a#logout').href, 'https://news.ycombinator.com/logout?auth=tok123&goto=news');
  assert.equal(header.querySelector('.hv-nav a[href="https://news.ycombinator.com/threads?id=alice"]').textContent, 'threads');
  assert.equal(header.querySelector('.hv-nav a[aria-current]'), null, 'HN\'s topsel from the fetched page does not mark a section inside the shell');
  p.dom.window.close();
});

test('moderated and deleted comments keep their row, indent and a working, persisted collapse toggle', async () => {
  const p = await lazyPage();
  const api = p.dom.window.HackerViews;
  let request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 1, effect: 'visible', item: {id: 1, type: 'story', by: 'op', title: 'Story', kids: [2]}}]);
  await new Promise(r => setTimeout(r, 5));
  request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 2, effect: 'visible', item: {id: 2, type: 'comment', by: null, parent: 1, dead: true, time: 1, kids: [3]}}]);
  await new Promise(r => setTimeout(r, 5));
  request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 3, effect: 'visible', item: {id: 3, type: 'comment', by: 'alice', parent: 2, text: 'Surviving reply'}}]);
  await new Promise(r => setTimeout(r, 5));
  const row = p.doc.getElementById('2');
  assert.ok(row.classList.contains('comtr') && row.classList.contains('hv-tombstone'), 'tombstone renders as a comment row');
  assert.equal(row.querySelector('.hv-tombstone-label').textContent, '[moderated]');
  assert.equal(row.querySelector('td.ind').getAttribute('indent'), '0', 'top-level tombstone sits at depth 0');
  assert.equal(p.doc.getElementById('3').querySelector('td.ind').getAttribute('indent'), '40', 'its reply is indented one level');
  assert.match(row.querySelector('.hv-comment-nav').textContent, /parent/);
  assert.equal(p.doc.querySelector('.hv-deleted'), null, 'no bare placeholder for comments');
  const children = p.doc.getElementById('3').closest('.hv-children');
  assert.equal(children.hidden, false);
  const toggle = row.querySelector('.hv-collapse');
  assert.equal(toggle.textContent, '[-]');
  toggle.click();
  assert.equal(children.hidden, true, 'collapsing a tombstone hides its replies');
  assert.equal(toggle.textContent, '[+] 1 reply');
  assert.deepEqual([...p.messages.filter(m => m.kind === 'collapsedState').at(-1).ids], [2], 'collapse state is persisted');
  assert.deepEqual([...api.refreshState().collapsed], [2]);
  toggle.click();
  assert.equal(children.hidden, false);
  p.dom.window.close();
});

test('a tombstone restored as collapsed loads collapsed', async () => {
  const p = await lazyPage({id: 1, top: 0, y: 0, ancestors: [], collapsed: [2]});
  const api = p.dom.window.HackerViews;
  let request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 1, effect: 'visible', item: {id: 1, type: 'story', by: 'op', title: 'Story', kids: [2]}}]);
  await new Promise(r => setTimeout(r, 5));
  request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 2, effect: 'visible', item: {id: 2, type: 'comment', by: null, parent: 1, deleted: true, kids: [3]}}]);
  await new Promise(r => setTimeout(r, 5));
  const row = p.doc.getElementById('2');
  assert.equal(row.querySelector('.hv-tombstone-label').textContent, '[deleted]');
  assert.equal(row.querySelector('.hv-collapse').textContent, '[+] 1 reply');
  assert.equal(row.closest('.hv-node').querySelector('.hv-children').hidden, true);
  p.dom.window.close();
});

const flatRow = (id, name) => `<tr class="athing" id="${id}"><td class="ind"></td><td valign="top" class="votelinks"><center><a id="up_${id}" href="vote?id=${id}&how=up">up</a></center></td><td class="default"><div><span class="comhead"><a href="user?id=${name}" class="hnuser">${name}</a> <span class="age"><a href="item?id=${id}">1 minute ago</a></span><span class="navs"> | <a href="item?id=9">parent</a></span></span></div><br><div class="comment"><div class="commtext c00">Flat comment ${id}</div></div></td></tr><tr class="spacer"><td></td></tr>`;

test('flat comment lists such as newcomments are filtered and styled like threaded comments', async () => {
  const p = await page(`<table id="hnmain"><tbody><tr><td><span class="pagetop"><a href="newest">new</a></span></td></tr><tr><td><table><tbody>${flatRow(20,'bob')}${flatRow(21,'carol')}</tbody></table></td></tr></tbody></table>`, {url: 'https://news.ycombinator.com/newcomments'});
  assert.ok(p.doc.getElementById('20').classList.contains('comtr'), 'flat rows are treated as comment rows');
  assert.ok(p.doc.getElementById('20').classList.contains('qhn-root'));
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  assert.ok(request && [...request.ids].includes(20) && [...request.ids].includes(21), 'flat rows are checked');
  p.resolve({20: 'blocked', 21: 'visible'});
  assert.equal(hidden(p, 20), true, 'a blocked author\'s comment is hidden on a flat list');
  assert.equal(hidden(p, 21), false);
  assert.ok(p.doc.getElementById('21').querySelector('.qhn-record'), 'flat rows get the ⋯ control');
  p.dom.window.close();
});

test('pages without HN\'s header still get the shared header and a gutter', async () => {
  const p = await page(`<b>Login</b><br><br><form method="post"><table><tr><td>username:</td><td><input name="acct"></td></tr></table></form>`, {blocked: [], url: 'https://news.ycombinator.com/login'});
  const header = p.doc.querySelector('body > header#hv-header.hv-header');
  assert.ok(header, 'header is prepended to headerless pages');
  assert.ok(p.doc.body.classList.contains('hv-plain'));
  assert.deepEqual([...header.querySelectorAll('.hv-nav a')].map(a => a.textContent), ['home','new','threads','past','comments','ask','show','jobs','submit']);
  assert.equal(header.querySelector('.hv-side a'), null, 'the login page does not advertise a login link');
  p.dom.window.close();
});

test('the hidden chip temporarily reveals filtered rows in place with their reasons, and filter changes hide them again', async () => {
  const p = await page(hnHeader(signedIn) + `<table>${row(10,'bob')}${row(11,'dave')}${row(12,'erin')}</table>`, {blocked: []});
  p.dom.window.HackerViews.setOrdered(true);
  p.dom.window.HackerViews.resolve(p.messages.filter(m => m.kind === 'ancestors').at(-1).token, {1: 'blocked', 10: 'blocked', 11: 'unresolved', 12: 'visible'}, {1: 'Blocked', 10: 'Blocked · Blocked ancestor'});
  const header = p.doc.querySelector('header.hv-header');
  const chip = () => header.querySelector('.hv-chip[aria-pressed]');
  assert.equal(chip().textContent, '2 hidden');
  assert.equal(chip().getAttribute('aria-pressed'), 'false');
  assert.equal(hidden(p, 10), true);
  chip().click();
  assert.equal(chip().textContent, 'Showing 2 hidden');
  assert.equal(chip().getAttribute('aria-pressed'), 'true');
  assert.equal(hidden(p, 10), false, 'a blocked comment is revealed in place');
  assert.ok(p.doc.getElementById('10').classList.contains('qhn-revealed'));
  assert.equal(p.doc.getElementById('10').querySelector('.qhn-reveal-label').textContent, 'Hidden by Blocked · Blocked ancestor');
  assert.equal(hidden(p, 1), false, 'a blocked story is revealed');
  assert.equal(p.doc.getElementById('1').nextElementSibling.hasAttribute('data-qhn-hidden'), false, 'its metadata row comes back too');
  assert.equal(p.doc.getElementById('1').nextElementSibling.querySelector('.qhn-reveal-label').textContent, 'Hidden by Blocked');
  assert.equal(hidden(p, 11), true, 'unchecked rows stay hidden');
  assert.equal(header.querySelector('.hv-sr').textContent, 'Showing 2 hidden contributions temporarily');
  chip().click();
  assert.equal(chip().textContent, '2 hidden');
  assert.equal(hidden(p, 10), true);
  assert.equal(p.doc.querySelector('.qhn-reveal-label'), null, 'labels are removed when hidden again');
  chip().click();
  assert.equal(hidden(p, 10), false);
  p.dom.window.HackerViews.setOrdered(true);
  p.dom.window.HackerViews.resolve(p.messages.filter(m => m.kind === 'ancestors').at(-1).token, {1: 'blocked', 10: 'blocked', 11: 'visible', 12: 'visible'});
  assert.equal(hidden(p, 10), true, 'a filter change ends the temporary reveal');
  assert.equal(chip().getAttribute('aria-pressed'), 'false');
  p.dom.window.close();
});

test('in a discussion the chip reveals blocked comments, loads their replies, and hides them again', async () => {
  const p = await lazyPage();
  const api = p.dom.window.HackerViews;
  let request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 1, effect: 'visible', item: {id: 1, type: 'story', by: 'op', title: 'Story', kids: [2, 4]}}]);
  await new Promise(r => setTimeout(r, 5));
  request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 2, effect: 'blocked', label: 'Blocked', item: {id: 2, type: 'comment', by: 'bob', parent: 1, text: 'Blocked text', kids: [3]}},
    {id: 4, effect: 'visible', item: {id: 4, type: 'comment', by: 'erin', parent: 1, text: 'Fine'}}]);
  await new Promise(r => setTimeout(r, 5));
  assert.equal(p.doc.getElementById('2'), null, 'blocked comment renders nothing');
  assert.doesNotMatch(p.doc.body.textContent, /Reveal this contribution/, 'a visible root shows no reveal button');
  const requestsBefore = p.messages.filter(m => m.kind === 'lazyItems').length;
  const chip = () => p.doc.querySelector('#hv-header .hv-chip[aria-pressed]');
  assert.equal(chip().textContent, '1 hidden');
  chip().click();
  await new Promise(r => setTimeout(r, 5));
  const row = p.doc.getElementById('2');
  assert.ok(row && row.classList.contains('qhn-revealed'), 'blocked comment is rendered as revealed');
  assert.match(row.textContent, /Blocked text/);
  assert.equal(row.querySelector('.qhn-reveal-label').textContent, 'Hidden by Blocked');
  assert.ok(p.messages.filter(m => m.kind === 'lazyItems').length > requestsBefore, 'its replies are requested');
  assert.equal(chip().textContent, 'Showing 1 hidden');
  chip().click();
  await new Promise(r => setTimeout(r, 5));
  assert.equal(p.doc.getElementById('2'), null, 'hidden again');
  assert.equal(chip().textContent, '1 hidden');
  p.dom.window.close();
});

test('following an item link out of a revealed row asks the app to keep the destination revealed', async () => {
  const feedRow = (id, author) => `<tr class="athing submission" id="${id}"><td><span class="titleline"><a href="https://example.com/${id}">Story ${id}</a></span></td></tr><tr><td class="subtext"><a class="hnuser" href="user?id=${author}">${author}</a> | <a href="item?id=${id}">${id} comments</a></td></tr><tr class="spacer"><td></td></tr>`;
  const p = await page(hnHeader(signedIn) + `<table>${feedRow(1, 'bob')}${feedRow(2, 'erin')}</table>`, {blocked: []});
  p.doc.addEventListener('click', event => event.preventDefault());
  p.dom.window.HackerViews.setOrdered(true);
  p.dom.window.HackerViews.resolve(p.messages.filter(m => m.kind === 'ancestors').at(-1).token, {1: 'blocked', 2: 'visible'}, {1: 'Newbies'});
  const intents = () => p.messages.filter(m => m.kind === 'revealIntent').map(m => m.id);
  const chip = () => p.doc.querySelector('.hv-header .hv-chip[aria-pressed]');
  const follow = href => p.doc.querySelector(`a[href="${href}"]`).click();
  follow('item?id=1');
  assert.deepEqual(intents(), [], 'a hidden row carries nothing');
  chip().click();
  follow('item?id=1');
  assert.deepEqual(intents(), [1], 'a link out of the revealed row carries its discussion');
  follow('user?id=bob'); follow('item?id=2');
  assert.deepEqual(intents(), [1], 'profile links and rows that were never hidden carry nothing');
  chip().click();
  follow('item?id=1');
  assert.deepEqual(intents(), [1], 'hidden again, the row carries nothing');
  p.dom.window.close();
});

test('a discussion opened from a revealed row starts revealed, and replies hidden only through it come along unlabelled', async () => {
  const p = await lazyPage(undefined, {reveal: true}); const api = p.dom.window.HackerViews;
  const text = () => p.doc.body.textContent;
  const button = label => [...p.doc.querySelectorAll('button')].find(b => b.textContent === label);
  const chip = () => p.doc.querySelector('#hv-header .hv-chip[aria-pressed]');
  let request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 1, effect: 'blocked', label: 'Newbies', item: {id: 1, type: 'story', by: 'newbie', title: 'Hidden title', kids: [2, 3]}}]);
  await new Promise(r => setTimeout(r, 5));
  assert.match(text(), /Hidden title/, 'the destination is shown without a second reveal');
  assert.match(text(), /Temporarily revealed · Hidden by Newbies/);
  assert.equal(button('Reveal this contribution'), undefined);
  assert.ok(p.doc.querySelector('.fatitem').closest('[data-qhn-revealed]'), 'links out of the revealed destination carry the reveal');
  request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  assert.deepEqual([...request.ids].sort(), [2, 3], 'its replies load');
  api.lazyResult(request.token, [
    {id: 2, effect: 'blocked', label: 'Newbies · Blocked ancestor', inheritedFrom: 1, item: {id: 2, type: 'comment', by: 'reader', parent: 1, text: 'Lifted reply', kids: [4]}},
    {id: 3, effect: 'blocked', label: 'Trolls', item: {id: 3, type: 'comment', by: 'troll', parent: 1, text: 'Own block'}}]);
  await new Promise(r => setTimeout(r, 5));
  assert.match(text(), /Lifted reply/, 'a reply hidden only through the destination is shown');
  assert.equal(p.doc.getElementById('2').querySelector('.qhn-reveal-label'), null, 'without a label');
  assert.equal(p.doc.getElementById('2').classList.contains('qhn-revealed'), false, 'and without fading');
  assert.ok(p.doc.getElementById('2').closest('[data-qhn-revealed]'), 'links out of it carry the reveal');
  assert.equal(p.doc.getElementById('3'), null, 'a reply hidden by its own rule stays hidden');
  assert.equal(chip().textContent, '1 hidden', 'the chip counts only what is hidden on its own account');
  request = p.messages.filter(m => m.kind === 'lazyItems').find(m => m.ids.includes(4));
  api.lazyResult(request.token, [{id: 4, effect: 'blocked', label: 'Newbies · Blocked ancestor', inheritedFrom: 1, item: {id: 4, type: 'comment', by: 'other', parent: 2, text: 'Nested lifted'}}]);
  await new Promise(r => setTimeout(r, 5));
  assert.match(text(), /Nested lifted/, 'nested replies are lifted too');
  assert.equal(chip().textContent, '1 hidden');
  chip().click(); await new Promise(r => setTimeout(r, 5));
  assert.equal(chip().textContent, 'Showing 1 hidden');
  assert.equal(p.doc.getElementById('3').querySelector('.qhn-reveal-label').textContent, 'Hidden by Trolls');
  assert.equal(p.doc.getElementById('2').querySelector('.qhn-reveal-label'), null, 'lifted replies stay unlabelled under the chip');
  chip().click(); await new Promise(r => setTimeout(r, 5));
  assert.equal(p.doc.getElementById('3'), null);
  button('Hide again').click(); await new Promise(r => setTimeout(r, 5));
  assert.ok(button('Reveal this contribution'), 'the destination is hidden again');
  assert.doesNotMatch(text(), /Hidden title/);
  assert.ok(p.doc.getElementById('2').closest('[hidden]'), 'its replies go with it');
  assert.equal(chip().textContent, '2 hidden');
  button('Reveal this contribution').click(); await new Promise(r => setTimeout(r, 5));
  assert.equal(p.doc.getElementById('2').closest('[hidden]'), null, 'revealing it brings the replies back');
  assert.equal(chip().textContent, '1 hidden');
  p.dom.window.close();
});

test('hiding the destination again also ends a chip reveal, so the control visibly hides it', async () => {
  const p = await lazyPage(undefined, {reveal: true}); const api = p.dom.window.HackerViews;
  const button = label => [...p.doc.querySelectorAll('button')].find(b => b.textContent === label);
  const chip = () => p.doc.querySelector('#hv-header .hv-chip[aria-pressed]');
  let request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 1, effect: 'blocked', label: 'Newbies', item: {id: 1, type: 'story', by: 'newbie', title: 'Hidden title', kids: [3]}}]);
  await new Promise(r => setTimeout(r, 5));
  request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 3, effect: 'blocked', label: 'Trolls', item: {id: 3, type: 'comment', by: 'troll', parent: 1, text: 'Own block'}}]);
  await new Promise(r => setTimeout(r, 5));
  chip().click(); await new Promise(r => setTimeout(r, 5));
  assert.equal(chip().textContent, 'Showing 1 hidden');
  button('Hide again').click(); await new Promise(r => setTimeout(r, 5));
  assert.doesNotMatch(p.doc.body.textContent, /Hidden title/);
  assert.equal(p.doc.getElementById('3'), null);
  assert.equal(chip().textContent, '2 hidden');
  assert.equal(chip().getAttribute('aria-pressed'), 'false');
  p.dom.window.close();
});

test('revealing a comment hidden through an ancestor outside the page lifts replies hidden for the same reason', async () => {
  const p = await lazyPage(); const api = p.dom.window.HackerViews;
  const text = () => p.doc.body.textContent;
  const chip = () => p.doc.querySelector('#hv-header .hv-chip[aria-pressed]');
  let request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 1, effect: 'blocked', label: 'Newbies · Blocked ancestor', inheritedFrom: 99, item: {id: 1, type: 'comment', by: 'reader', parent: 99, text: 'Subthread root', kids: [2]}}]);
  await new Promise(r => setTimeout(r, 5));
  assert.match(text(), /Hidden by Newbies · Blocked ancestor/);
  assert.equal(chip().textContent, '1 hidden');
  api.revealDestination(); await new Promise(r => setTimeout(r, 5));
  assert.match(text(), /Subthread root/);
  request = p.messages.filter(m => m.kind === 'lazyItems').find(m => m.ids.includes(2));
  api.lazyResult(request.token, [{id: 2, effect: 'blocked', label: 'Newbies · Blocked ancestor', inheritedFrom: 99, item: {id: 2, type: 'comment', by: 'other', parent: 1, text: 'Same reason'}}]);
  await new Promise(r => setTimeout(r, 5));
  assert.match(text(), /Same reason/, 'the reply shares the root’s reason and follows it');
  assert.equal(p.doc.getElementById('2').querySelector('.qhn-reveal-label'), null);
  assert.equal(chip(), null, 'nothing is left hidden on its own account');
  p.dom.window.close();
});

test('on an HTML page a revealed destination lifts replies blocked only through it', async () => {
  const p = await page(`<table>${row(10,'alice')}${row(11,'bob',1)}${row(12,'carol',1)}</table>`, {blocked: [], url: 'https://news.ycombinator.com/item?id=10'});
  const api = p.dom.window.HackerViews;
  api.setOrdered(true);
  api.revealDestination();
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  api.resolve(request.token, {'10': 'blocked', '11': 'blocked', '12': 'blocked'}, {'10': 'Newbies', '11': 'Newbies · Blocked ancestor', '12': 'Trolls'}, {'11': 10});
  assert.equal(hidden(p, 10), false);
  assert.equal(hidden(p, 11), false, 'a reply blocked through the destination is lifted');
  assert.equal(hidden(p, 12), true, 'a reply blocked by its own rule stays hidden');
  p.dom.window.close();
});

const canonicalStory = form => `<table><tr class="athing" id="1"><td><span class="titleline"><a href="https://example.com">Topic</a></span></td></tr><tr><td class="subtext"><a href="hide?id=1">hide</a></td></tr></table>` +
  (form ? `<form action="comment" method="post"><input type="hidden" name="parent" value="1"><input type="hidden" name="goto" value="item?id=1"><input type="hidden" name="hmac" value="secret"><textarea name="text"></textarea><input type="submit" value="add comment"></form>` : '');
async function storyPage(canonical) {
  const p = await lazyPage(); const api = p.dom.window.HackerViews;
  p.dom.window.IntersectionObserver = class {constructor(callback) {this.callback = callback;} observe(target) {this.callback([{target, isIntersecting: true}]);} unobserve() {}};
  p.dom.window.fetch = canonical;
  const request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 1, effect: 'visible', item: {id: 1, type: 'story', by: 'op', title: 'Topic', kids: []}}]);
  await new Promise(r => setTimeout(r, 5));
  return p;
}

test('the story root offers an inline comment box built from HN’s own form, posting through HN', async () => {
  let release; const canonical = new Promise(r => { release = r; });
  const p = await storyPage(async () => { await canonical; return {ok: true, text: async () => canonicalStory(true)}; });
  const toggle = () => p.doc.querySelector('.hv-comment-toggle');
  assert.ok(toggle(), 'the story has a comment control');
  assert.equal(toggle().textContent, 'comment');
  assert.ok(toggle().closest('.subtext'), 'it sits in the story’s own line');
  assert.equal(p.doc.querySelector('a[href*="/reply?id="]'), null, 'no link to HN’s reply page, which rejects stories');
  toggle().click();
  assert.match(p.doc.querySelector('.hv-comment-host').textContent, /Loading the comment form/);
  release(); await new Promise(r => setTimeout(r, 20));
  const form = p.doc.querySelector('.hv-comment-form');
  assert.ok(form, 'the form appears once HN’s HTML arrives');
  assert.equal(form.method, 'post');
  assert.equal(form.action, 'https://news.ycombinator.com/comment');
  assert.deepEqual([...form.querySelectorAll('input[type=hidden]')].map(i => [i.name, i.value]), [['parent', '1'], ['goto', 'item?id=1'], ['hmac', 'secret']], 'HN’s hidden fields, token included, are carried over');
  assert.ok(form.querySelector('textarea[name=text]'));
  assert.equal(toggle().getAttribute('aria-expanded'), 'true');
  p.doc.querySelector('.hv-comment-cancel').click();
  assert.equal(p.doc.querySelector('.hv-comment-host').hidden, true);
  assert.equal(toggle().getAttribute('aria-expanded'), 'false');
  toggle().click();
  assert.equal(p.doc.querySelector('.hv-comment-host').hidden, false, 'the action toggles the box');
  toggle().click();
  assert.equal(p.doc.querySelector('.hv-comment-host').hidden, true);
  p.dom.window.close();
});

test('when HN’s HTML has no comment form, the box explains and offers HN’s own page', async () => {
  const p = await storyPage(async () => ({ok: true, text: async () => canonicalStory(false)}));
  await new Promise(r => setTimeout(r, 20));
  p.doc.querySelector('.hv-comment-toggle').click();
  const note = p.doc.querySelector('.hv-comment-host .qhn-loading');
  assert.match(note.textContent, /isn’t offering a comment form/);
  [...note.querySelectorAll('button')].find(b => b.textContent === 'Open on Hacker News').click();
  const message = p.messages.at(-1);
  assert.equal(message.kind, 'canonical');
  assert.equal(message.url, 'https://news.ycombinator.com/item?id=1');
  p.dom.window.close();
});

test('when HN’s HTML cannot be fetched, the box says so instead of loading forever', async () => {
  const p = await storyPage(async () => { throw new Error('offline'); });
  await new Promise(r => setTimeout(r, 20));
  p.doc.querySelector('.hv-comment-toggle').click();
  assert.match(p.doc.querySelector('.hv-comment-host').textContent, /couldn’t be loaded/);
  assert.ok([...p.doc.querySelectorAll('.hv-comment-host button')].some(b => b.textContent === 'Open on Hacker News'));
  p.dom.window.close();
});

test('the story line reads like HN’s with the score in the gutter, and a vote marks the arrow without moving anything', async () => {
  const p = await lazyPage(); const w = p.dom.window;
  w.IntersectionObserver = class {constructor(callback) {this.callback = callback;} observe(target) {this.callback([{target, isIntersecting: true}]);} unobserve() {}};
  let voted = false;
  w.fetch = async url => {
    if (new URL(url).pathname === '/vote') { voted = true; return {ok: true}; }
    return {ok: true, text: async () => `<table><tr class="athing" id="1"><td class="votelinks"><a id="up_1" class="${voted ? 'nosee' : ''}" href="vote?id=1&how=up&auth=fixture">up</a></td><td><span class="titleline"><a href="https://example.com/a">Topic</a></span></td></tr><tr><td class="subtext"><span class="comhead">author ${voted ? '<a id="un_1" href="vote?id=1&how=un&auth=fixture">unvote</a>' : ''}</span> | <a href="flag?id=1">flag</a> | <a href="hide?id=1">hide</a> | <a href="fave?id=1">favorite</a> | <a href="item?id=1">7 comments</a></td></tr></table>`};
  };
  const request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  w.HackerViews.lazyResult(request.token, [{id: 1, effect: 'visible', item: {id: 1, type: 'story', by: 'author', score: 38, descendants: 5, time: Date.now() / 1000 - 3600, title: 'Topic', url: 'https://example.com/a', kids: []}}]);
  await new Promise(r => setTimeout(r, 20));
  const subtext = p.doc.querySelector('.fatitem .subtext');
  const line = () => subtext.textContent.replace(/\s+/g, ' ').trim();
  assert.equal(line(), 'by author 1 hour ago | flag | hide | favorite | note | comment | 7 comments', 'one separator, HN’s order, HN’s count');
  assert.equal(p.doc.querySelector('.fatitem .hv-score').textContent, '38', 'the score sits in the gutter');
  assert.equal(subtext.querySelector('.qhn-record:not(.qhn-record-text)'), null, 'the story author gets the note action, not the ellipsis');
  assert.equal(subtext.querySelector('.qhn-record-text').textContent, 'note');
  assert.equal(p.doc.querySelector('.hv-visit').hidden, true, 'no visit line on a first visit');
  assert.deepEqual(p.messages.filter(m => m.kind === 'visitCount').map(m => [m.id, m.count]), [[1, 7]], 'HN’s live count is reported for the visit record');
  const arrow = p.doc.querySelector('.fatitem .hv-vote');
  arrow.click();
  await new Promise(r => setTimeout(r, 10));
  assert.ok(!arrow.hidden && arrow.classList.contains('hv-voted'), 'the arrow stays and shows the vote');
  assert.equal(arrow.getAttribute('aria-label'), 'Upvoted. Click to undo');
  assert.equal(p.doc.querySelector('.hv-vote-status'), null);
  assert.equal(line(), 'by author 1 hour ago | flag | hide | favorite | note | comment | 7 comments', 'the line does not change');
  p.dom.window.close();
});

test('a revisited discussion counts new comments as they load, marks them, reads them as you jump on, and steps through them', async () => {
  const viewedAt = 1700000000;
  const p = await lazyPage(undefined, {visit: {viewedAt, leftAt: viewedAt + 600, descendants: 3, anchor: {id: 2, top: 10, y: 400, ancestors: [1]}}});
  const api = p.dom.window.HackerViews;
  const scrolled = []; p.dom.window.Element.prototype.scrollIntoView = function () { scrolled.push(this.id); };
  const jumps = []; p.dom.window.scrollTo = (x, y) => jumps.push(y);
  let request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 1, effect: 'visible', item: {id: 1, type: 'story', by: 'op', title: 'Topic', descendants: 5, score: 12, kids: [2, 3]}}]);
  await new Promise(r => setTimeout(r, 5));
  const line = () => p.doc.querySelector('.hv-visit');
  const text = () => line().querySelector('.hv-visit-text').textContent;
  const row = id => p.doc.getElementById(String(id));
  const newLink = id => row(id).querySelector('.hv-comment-nav .hv-new-nav a');
  assert.equal(line().hidden, false);
  assert.equal(text(), 'Looking for new comments since your last visit', 'no promise before comments load');
  assert.ok(line().querySelector('.hv-resume'));
  line().querySelector('.hv-next-new').click();
  assert.equal(line().querySelector('.hv-next-new').textContent, 'Loading…', 'asking for the next new one before any is loaded waits');
  request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [
    {id: 2, effect: 'visible', item: {id: 2, type: 'comment', by: 'old', parent: 1, time: viewedAt - 100, text: 'Seen before', kids: [4]}},
    {id: 3, effect: 'visible', item: {id: 3, type: 'comment', by: 'fresh', parent: 1, time: viewedAt + 100, text: 'New reply'}}]);
  await new Promise(r => setTimeout(r, 5));
  assert.equal(row(2).classList.contains('hv-new'), false, 'a comment from before the last view is not new');
  assert.ok(row(3).classList.contains('hv-new'));
  assert.ok(row(3).querySelector('.comhead .hv-new-dot'), 'a new comment carries one dot before its author');
  assert.equal(scrolled.at(-1), '3', 'the waiting jump lands on the first new comment to arrive');
  assert.equal(text(), '1 new comment since your last visit');
  assert.ok(line().querySelector('.hv-visit-loading'), 'the count says it is still loading while replies remain');
  assert.equal(newLink(3).textContent, 'next new', 'while the thread is still loading the only new comment still offers the next');
  assert.equal(row(2).querySelector('.hv-new-nav'), null, 'comments that are not new carry no such link');
  request = p.messages.filter(m => m.kind === 'lazyItems').find(m => m.ids.includes(4));
  api.lazyResult(request.token, [{id: 4, effect: 'visible', item: {id: 4, type: 'comment', by: 'fresh', parent: 2, time: viewedAt + 200, text: 'Nested new'}}]);
  await new Promise(r => setTimeout(r, 5));
  assert.equal(text(), '2 new comments since your last visit');
  assert.equal(line().querySelector('.hv-visit-loading'), null, 'complete once every comment is loaded');
  assert.equal(newLink(4).textContent, 'next new', 'the first new comment in thread order points onward');
  assert.equal(newLink(3).textContent, 'first new', 'the last one wraps');
  const toggle = row(2).querySelector('.hv-collapse');
  toggle.click();
  assert.equal(toggle.textContent, '[+] 1 reply · 1 new', 'a collapsed branch says how many replies it holds and how many are new');
  assert.equal(toggle.getAttribute('aria-label'), 'Expand thread, 1 reply, 1 new comment');
  line().querySelector('.hv-next-new').click();
  assert.equal(scrolled.at(-1), '4', 'next new goes to the first unread comment in thread order, opening its collapsed branch');
  assert.equal(toggle.textContent, '[-]');
  assert.ok(row(3).classList.contains('hv-new-read') && !row(3).classList.contains('hv-new'), 'the comment jumped away from is read');
  assert.equal(text(), '1 new comment since your last visit', 'the count is what is left to read');
  assert.equal(newLink(3).textContent, 'first new', 'a read comment still offers the way to what is unread');
  assert.equal(newLink(4).closest('.hv-new-nav').hidden, true, 'the only unread comment offers nothing onward');
  p.doc.dispatchEvent(new p.dom.window.KeyboardEvent('keydown', {key: 'n', bubbles: true}));
  assert.equal(scrolled.at(-1), '4', 'the N key goes to the unread one');
  assert.ok(row(4).classList.contains('hv-new'), 'the comment you are on stays unread until you jump on');
  newLink(3).click();
  assert.equal(scrolled.length, 4);
  line().querySelector('.hv-resume').click();
  assert.equal(jumps.length, 1, 'jumping to where you left off scrolls to the saved comment');
  p.dom.window.close();
});

test('after a refresh the line measures from the load it replaced and offers no jump back', async () => {
  const viewedAt = 1700000000;
  const p = await lazyPage(undefined, {visit: {viewedAt, leftAt: viewedAt + 60, descendants: 5, reload: true, anchor: {id: 2, top: 10, y: 400, ancestors: [1]}}});
  const request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  p.dom.window.HackerViews.lazyResult(request.token, [{id: 1, effect: 'visible', item: {id: 1, type: 'story', by: 'op', title: 'Topic', descendants: 5, kids: []}}]);
  await new Promise(r => setTimeout(r, 5));
  const line = p.doc.querySelector('.hv-visit');
  assert.equal(line.querySelector('.hv-visit-text').textContent, 'Nothing new since your last visit');
  assert.equal(line.querySelector('.hv-resume'), null, 'a refresh already restores the position');
  p.dom.window.close();
});

test('a revisited discussion with nothing new says so, quietly', async () => {
  const viewedAt = 1700000000;
  const p = await lazyPage(undefined, {visit: {viewedAt, leftAt: viewedAt + 60, descendants: 5}});
  const request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  p.dom.window.HackerViews.lazyResult(request.token, [{id: 1, effect: 'visible', item: {id: 1, type: 'story', by: 'op', title: 'Topic', descendants: 5, kids: []}}]);
  await new Promise(r => setTimeout(r, 5));
  const line = p.doc.querySelector('.hv-visit');
  assert.equal(line.querySelector('.hv-visit-text').textContent, 'Nothing new since your last visit');
  assert.equal(line.querySelector('.hv-visit-new'), null);
  assert.equal(line.querySelector('.hv-next-new'), null);
  assert.equal(line.querySelector('.hv-resume'), null, 'no jump without a saved position');
  p.dom.window.close();
});

test('feed rows the reader has opened before show how many comments arrived since', async () => {
  const feedRow = (id, count) => `<tr class="athing submission" id="${id}"><td><span class="titleline"><a href="https://example.com/${id}">Story ${id}</a></span></td></tr><tr><td class="subtext"><a class="hnuser" href="user?id=op">op</a> | <a href="item?id=${id}">${count}&nbsp;comments</a></td></tr><tr class="spacer"><td></td></tr>`;
  const p = await page(hnHeader(signedIn) + `<table>${feedRow(101, 143)}${feedRow(102, 40)}${feedRow(103, 9)}</table>`, {blocked: []});
  p.dom.window.HackerViews.setOrdered(true);
  p.dom.window.HackerViews.resolve(p.messages.filter(m => m.kind === 'ancestors').at(-1).token, {101: 'visible', 102: 'visible', 103: 'visible'});
  const asked = p.messages.find(m => m.kind === 'visits');
  assert.ok([101, 102, 103].every(id => asked.ids.includes(id)), 'the page asks which stories were visited');
  p.dom.window.HackerViews.visitResults({'101': {descendants: 131, viewedAt: 1700000000}, '102': {descendants: 40, viewedAt: 1700000000}});
  assert.equal(p.doc.getElementById('101').nextElementSibling.querySelector('.hv-new-count').textContent, ' · +12 new');
  assert.equal(p.doc.getElementById('102').nextElementSibling.querySelector('.hv-new-count'), null, 'nothing when the count has not grown');
  assert.equal(p.doc.getElementById('103').nextElementSibling.querySelector('.hv-new-count'), null, 'nothing for a story never opened');
  p.dom.window.close();
});

test('a discussion opened again restores the threads collapsed on the previous visit, unless history says otherwise', async () => {
  const viewedAt = 1700000000;
  const story = api => { const request = api.messages.filter(m => m.kind === 'lazyItems').at(-1); api.dom.window.HackerViews.lazyResult(request.token, [{id: 1, effect: 'visible', item: {id: 1, type: 'story', by: 'op', title: 'Topic', descendants: 2, kids: [2, 3]}}]); };
  const replies = api => { const request = api.messages.filter(m => m.kind === 'lazyItems').at(-1); api.dom.window.HackerViews.lazyResult(request.token, [
    {id: 2, effect: 'visible', item: {id: 2, type: 'comment', by: 'a', parent: 1, time: viewedAt - 50, text: 'One', kids: [4]}},
    {id: 3, effect: 'visible', item: {id: 3, type: 'comment', by: 'b', parent: 1, time: viewedAt - 40, text: 'Two'}}]); };
  const p = await lazyPage(undefined, {visit: {viewedAt, leftAt: viewedAt + 60, descendants: 2, collapsed: [2]}});
  const seeded = p.messages.find(m => m.kind === 'collapsedState');
  assert.deepEqual([...(seeded?.ids || [])], [2], 'the seeded set is posted so the history entry and the next visit carry it');
  story(p); await new Promise(r => setTimeout(r, 5)); replies(p); await new Promise(r => setTimeout(r, 5));
  assert.equal(p.doc.getElementById('2').querySelector('.hv-collapse').textContent, '[+] 1 reply', 'the thread collapsed last time is collapsed again');
  assert.equal(p.doc.getElementById('2').querySelector('.comment').hidden, true);
  assert.equal(p.doc.getElementById('3').querySelector('.hv-collapse').textContent, '[-]');
  p.dom.window.close();
  const q = await lazyPage({id: 3, top: 0, y: 0, ancestors: [1], collapsed: []}, {visit: {viewedAt, leftAt: viewedAt + 60, descendants: 2, collapsed: [2]}});
  assert.equal(q.messages.find(m => m.kind === 'collapsedState'), undefined, 'history state that says nothing is collapsed is not overridden');
  story(q); await new Promise(r => setTimeout(r, 5)); replies(q); await new Promise(r => setTimeout(r, 5));
  assert.equal(q.doc.getElementById('2').querySelector('.hv-collapse').textContent, '[-]');
  q.dom.window.close();
});

test('a comment is its header and its text: HN’s line with reply and note, no pill, and the branch rail collapses the branch', async () => {
  const p = await lazyPage(); const api = p.dom.window.HackerViews;
  let request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 1, effect: 'visible', item: {id: 1, type: 'story', by: 'op', title: 'Topic', kids: [2]}}]);
  await new Promise(r => setTimeout(r, 5));
  request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 2, effect: 'visible', item: {id: 2, type: 'comment', by: 'alice', parent: 1, time: Date.now() / 1000 - 120, text: 'Parent', kids: [3, 4]}}]);
  await new Promise(r => setTimeout(r, 5));
  request = p.messages.filter(m => m.kind === 'lazyItems').at(-1);
  api.lazyResult(request.token, [{id: 3, effect: 'visible', item: {id: 3, type: 'comment', by: 'bob', parent: 2, text: 'Child one'}}, {id: 4, effect: 'visible', item: {id: 4, type: 'comment', by: 'carol', parent: 2, text: 'Child two'}}]);
  await new Promise(r => setTimeout(r, 5));
  const row = p.doc.getElementById('2'), head = row.querySelector('.comhead');
  assert.equal(head.textContent.replace(/\s+/g, ' ').trim(), 'alice 2 minutes ago | parent | reply | note [-]', 'one separator, HN’s words, ours at the end');
  assert.equal(row.querySelector('.reply'), null, 'no reply pill under the text');
  assert.equal(row.querySelector('.qhn-record:not(.qhn-record-text)'), null, 'no ellipsis; note is a word');
  assert.match(head.querySelector('a.hv-reply').href, /\/reply\?id=2&goto=item%3Fid%3D1%232$/);
  const children = row.closest('.hv-node').querySelector(':scope > .hv-children');
  const rail = children.querySelector(':scope > .hv-rail');
  assert.ok(rail, 'a comment with replies owns one rail for its branch');
  assert.equal(rail.style.left, '4px', 'at depth 0 the rail hangs under the arrows');
  assert.equal(p.doc.getElementById('3').closest('.hv-node').querySelector(':scope > .hv-children'), null, 'a reply without replies has no rail');
  rail.dispatchEvent(new p.dom.window.MouseEvent('mouseenter'));
  assert.equal(rail.title, 'Collapse 2 replies');
  rail.click();
  assert.equal(children.hidden, true, 'clicking the rail collapses the branch');
  assert.equal(row.querySelector('.hv-collapse').textContent, '[+] 2 replies');
  assert.deepEqual([...p.messages.filter(m => m.kind === 'collapsedState').at(-1).ids], [2], 'through the same toggle, so the state persists');
  row.querySelector('.hv-collapse').click();
  assert.equal(children.hidden, false);
  p.dom.window.close();
});
