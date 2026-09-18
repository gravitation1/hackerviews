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

async function lazyPage(anchor) {
  const p=await page('<main id="hv-topic"><div id="hv-topic-root"></div></main>',{blocked:[],url:'https://news.ycombinator.com/item?id=1'});
  p.dom.window.Element.prototype.getClientRects=function(){return this.closest('[hidden]')?[]:[{}];};
  p.dom.window.Element.prototype.getBoundingClientRect=function(){return {top:0,bottom:100};};
  p.doc.body.dataset.hvTopic='1';
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
  assert.equal(p.doc.querySelector('.reply a').href,'https://news.ycombinator.com/reply?id=1&goto=item%3Fid%3D1');
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
  api.lazyResult(request.token,[{id:1,effect:'visible',item:{id:1,type:'story',title:'Topic',kids:[2]}}]);
  assert.equal(new URL(p.doc.querySelector('.reply a').href).searchParams.get('goto'),'item?id=1');
  await new Promise(r=>setTimeout(r,5));
  request=p.messages.filter(m=>m.kind==='lazyItems').at(-1);
  api.lazyResult(request.token,[{id:2,effect:'visible',item:{id:2,type:'comment',by:'reader',parent:1,text:'Reply target'}}]);
  const link=p.doc.getElementById('2').querySelector('.reply a');
  const url=new URL(link.href);
  assert.equal(url.searchParams.get('id'),'2');
  assert.equal(url.searchParams.get('goto'),'item?id=1');
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
