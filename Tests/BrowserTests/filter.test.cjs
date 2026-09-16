const {test} = require('node:test');
const assert = require('node:assert/strict');
const {JSDOM} = require('jsdom');
const fs = require('node:fs');
const filter = fs.readFileSync('QuietHN/Resources/filter.js', 'utf8');
const row = (id, name, depth = 0) => `<tr class="athing comtr" id="${id}"><td><table><tr><td class="ind" indent="${depth}"></td><td><a class="hnuser" href="user?id=${name}">${name}</a><a href="vote?id=${id}&how=up">up</a><a href="reply?id=${id}">reply</a><div class="commtext">Comment ${id}</div></td></tr></table></td></tr>`;
const story = (id, author) => `<tr class="athing submission" id="${id}"><td><span class="titleline"><a href="https://example.com">Story ${id}</a></span></td></tr><tr><td><a class="hnuser" href="user?id=${author}">${author}</a></td></tr><tr class="spacer"><td></td></tr>`;
async function page(html, {blocked = ['bob'], url = 'https://news.ycombinator.com/news'} = {}) {
  const messages = [];
  const dom = new JSDOM(`<html><head><title>HN</title></head><body>${html}</body></html>`, {url, runScripts: 'outside-only'});
  dom.window.__quietHNBlocked = blocked;
  dom.window.webkit = {messageHandlers: {quietHN: {postMessage: message => messages.push(message)}}};
  dom.window.eval(filter);
  await new Promise(resolve => setImmediate(resolve));
  return {dom, doc: dom.window.document, messages,
    resolve(decisions) { const request = messages.filter(m => m.kind === 'ancestors').at(-1); dom.window.QuietHN.resolve(request.token, decisions); }};
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
  p.dom.window.QuietHN.setBlocked([]);
  assert.equal(hidden(p,2),false); assert.equal(hidden(p,3),false);
  assert.equal(p.doc.getElementById('3').style.display,'none');
  assert.equal(p.messages.at(-1).kind,'ready');
  p.dom.window.close();
});
test('old ancestry responses cannot override updated filters', async () => {
  const p = await page(`<table>${row(2,'bob')}</table>`);
  const token = p.messages.find(m => m.kind==='ancestors').token;
  p.dom.window.QuietHN.setBlocked([]);
  p.dom.window.QuietHN.resolve(token, {'2':'blocked'});
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
  p.dom.window.QuietHN.setFilters([], true);
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  assert.deepEqual(Array.from(request.ids).sort((a,b) => a-b), [1,2,3,4,10]);
  p.resolve({'1':'visible','2':'blocked','3':'blocked','4':'visible','10':'blocked'});
  assert.equal(hidden(p,1),false); assert.equal(hidden(p,2),true);
  assert.equal(hidden(p,3),true); assert.equal(hidden(p,4),false);
  assert.equal(hidden(p,10),true);
  assert.equal(p.doc.getElementById('10').nextElementSibling.hasAttribute('data-qhn-hidden'),true);
  p.dom.window.QuietHN.setFilters([], false);
  assert.equal(hidden(p,2),false); assert.equal(hidden(p,10),false);
  p.dom.window.close();
});

test('preferred authors highlight their contributions without highlighting replies or bypassing blocks', async () => {
  const p = await page(`<table>${story(10,'alice')}${row(1,'alice')}${row(2,'bob',1)}${row(3,'carol')}</table>`, {blocked: []});
  p.dom.window.QuietHN.configure(['alice'], false, ['alice'], false);
  p.resolve({'1':'blocked','3':'visible'});
  assert.equal(p.doc.getElementById('1').classList.contains('qhn-preferred'),true);
  assert.equal(p.doc.getElementById('2').classList.contains('qhn-preferred'),false);
  assert.equal(hidden(p,1),true); assert.equal(hidden(p,2),true); assert.equal(hidden(p,10),true);
  p.dom.window.QuietHN.configure([], false, [], true);
  const request = p.messages.filter(m => m.kind === 'highlights').at(-1);
  p.dom.window.QuietHN.resolveHighlights(request.token, ['carol']);
  assert.equal(p.doc.getElementById('3').classList.contains('qhn-preferred'),true);
  assert.equal(p.doc.getElementById('1').classList.contains('qhn-preferred'),false);
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),false);
  p.dom.window.QuietHN.configure([], false, [], false);
  p.dom.window.QuietHN.resolveHighlights(request.token, ['alice']);
  assert.equal(p.doc.querySelectorAll('.qhn-preferred').length,0);
  p.dom.window.close();
});

test('ordered effects apply selected colors and later changes remove stale highlights', async () => {
  const p = await page(`<table>${story(10,'alice')}${row(1,'alice')}${row(2,'bob',1)}</table>`, {blocked: []});
  p.dom.window.QuietHN.setOrdered(true);
  p.resolve({'10':'highlight:#e98caf','1':'highlight:#599bea','2':'visible'});
  assert.equal(hidden(p,10),false);
  assert.equal(p.doc.getElementById('10').style.getPropertyValue('--qhn-highlight'),'#e98caf');
  assert.equal(p.doc.getElementById('1').style.getPropertyValue('--qhn-highlight'),'#599bea');
  assert.equal(p.doc.getElementById('2').classList.contains('qhn-preferred'),false);
  p.dom.window.QuietHN.setOrdered(true);
  p.resolve({'10':'blocked','1':'blocked','2':'blocked'});
  assert.equal(hidden(p,10),true); assert.equal(hidden(p,2),true);
  assert.equal(p.doc.querySelectorAll('.qhn-preferred').length,0);
  p.dom.window.QuietHN.setOrdered(false);
  assert.equal(hidden(p,10),false);
  p.dom.window.close();
});

test('profiles show matching effect and priority while remaining readable when blocked', async () => {
  const p = await page('<table><tr><td>user:</td><td><a class="hnuser" href="user?id=alice">alice</a></td></tr><tr><td>karma:</td><td>1000</td></tr></table>', {blocked: [], url: 'https://news.ycombinator.com/user?id=alice'});
  let request = p.messages.filter(m => m.kind === 'profile').at(-1);
  assert.equal(request.username,'alice');
  const panel = p.doc.getElementById('qhn-profile-effect');
  p.dom.window.QuietHN.resolveProfile(request.token, {effect:'highlight:#599bea', label:'Highlight · Blue', priority:2, ruleName:'Experienced accounts'});
  assert.match(panel.textContent,/Filter 2: Experienced accounts/);
  assert.equal(panel.style.getPropertyValue('--qhn-profile-color'),'#599bea');
  p.dom.window.QuietHN.setOrdered(true);
  const current = p.messages.filter(m => m.kind === 'profile').at(-1);
  p.dom.window.QuietHN.resolveProfile(current.token,{effect:'blocked',label:'Blocked',priority:1,ruleName:'Alice'});
  p.dom.window.QuietHN.resolveProfile(request.token,{effect:'visible',label:'Wrong stale result',priority:0});
  assert.match(panel.textContent,/Blocked/);
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),false);
  p.dom.window.QuietHN.resolveProfile(current.token,{effect:'unresolved',label:'Couldn’t verify effect',priority:1,ruleName:'Karma'});
  assert.equal(panel.querySelector('button').textContent,'Retry');
  assert.equal(p.doc.querySelectorAll('#qhn-profile-effect').length,1);
  p.dom.window.close();
});

test('general highlights label the matching filter and clear the label for account-specific highlights', async () => {
  const p = await page(`<table>${row(1,'alice')}${story(10,'bob')}</table>`, {blocked: []});
  p.dom.window.QuietHN.setOrdered(true);
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  p.dom.window.QuietHN.resolve(request.token, {'1':'highlight:#599bea','10':'highlight:#27a99a'}, {'1':'High karma <10000>', '10':'Veterans'});
  const author = p.doc.getElementById('1').querySelector('.hnuser');
  assert.equal(author.getAttribute('data-qhn-filter-label'),'High karma <10000>');
  assert.equal(author.textContent,'alice');
  assert.equal(p.doc.getElementById('10').nextElementSibling.querySelector('.hnuser').getAttribute('data-qhn-filter-label'),'Veterans');
  p.dom.window.QuietHN.setOrdered(true);
  p.resolve({'1':'highlight:#599bea','10':'visible'});
  assert.equal(author.hasAttribute('data-qhn-filter-label'),false);
  p.dom.window.close();
});

test('fade levels keep contributions visible, do not fade replies, and clear on effect changes', async () => {
  const p = await page(`<table>${story(10,'alice')}${row(1,'alice')}${row(2,'bob',1)}</table>`, {blocked: []});
  p.dom.window.QuietHN.setOrdered(true);
  p.resolve({'10':'fade:25','1':'fade:75','2':'visible'});
  assert.equal(hidden(p,10),false);
  assert.equal(hidden(p,1),false);
  assert.equal(p.doc.getElementById('10').style.getPropertyValue('--qhn-fade-opacity'),'0.75');
  assert.equal(p.doc.getElementById('1').style.getPropertyValue('--qhn-fade-opacity'),'0.25');
  assert.equal(p.doc.getElementById('2').classList.contains('qhn-faded'),false);
  p.dom.window.QuietHN.setOrdered(true);
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
    if (result) p.dom.window.QuietHN.resolveProfile(request.token,result);
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
    p.dom.window.QuietHN.resolveProfile(request.token,result);
    assert.equal(panel.nextElementSibling.id,'qhn-profile-record');
  assert.equal(panel.nextElementSibling.nextElementSibling,table);
    assert.equal(p.dom.window.getComputedStyle(panel).width,'100%');
    assert.equal(p.dom.window.getComputedStyle(panel).boxSizing,'border-box');
  }
  p.dom.window.close();
});

test('progressive results reveal verified rows while unchecked rows stay hidden', async () => {
  const p = await page(`<table>${story(10,'alice')}${row(1,'alice')}${row(2,'bob',1)}</table>`, {blocked: [], url:'https://news.ycombinator.com/item?id=10'});
  p.dom.window.QuietHN.setOrdered(true);
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  assert.equal(request.ids[0],10);
  p.dom.window.QuietHN.resolvePartial(request.token, {'1':'visible'});
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),true);
  p.dom.window.QuietHN.resolvePartial(request.token, {'10':'visible'});
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),false);
  assert.equal(hidden(p,1),false);
  assert.equal(hidden(p,2),true);
  assert.ok(p.doc.getElementById('qhn-progress'));
  p.dom.window.QuietHN.resolvePartial(request.token, {'2':'fade:50'});
  assert.equal(hidden(p,2),false);
  assert.equal(p.doc.getElementById('2').classList.contains('qhn-faded'),true);
  p.resolve({'10':'visible','1':'visible','2':'fade:50'});
  assert.equal(p.doc.getElementById('qhn-progress'),null);
  p.dom.window.QuietHN.resolvePartial(request.token, {'10':'blocked','1':'blocked','2':'blocked'});
  assert.equal(hidden(p,1),false);
  p.dom.window.close();
});

test('progressive blocked roots never reveal the thread', async () => {
  const p = await page(`<table>${story(10,'alice')}${row(1,'bob')}</table>`, {blocked: [], url:'https://news.ycombinator.com/item?id=10'});
  p.dom.window.QuietHN.setOrdered(true);
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  p.dom.window.QuietHN.resolvePartial(request.token, {'10':'blocked','1':'visible'});
  assert.equal(p.doc.documentElement.hasAttribute('data-qhn-pending'),true);
  assert.equal(p.messages.at(-1).kind,'held');
  p.dom.window.close();
});

test('faded comments and stories label their matching filter and clear it on changes', async () => {
  const p = await page(`<table>${row(1,'alice')}${story(10,'bob')}</table>`, {blocked: []});
  p.dom.window.QuietHN.setOrdered(true);
  const request = p.messages.filter(m => m.kind === 'ancestors').at(-1);
  p.dom.window.QuietHN.resolvePartial(request.token, {'1':'fade:50','10':'fade:75'}, {'1':'Potential bot', '10':'New accounts'});
  const author = p.doc.getElementById('1').querySelector('.hnuser');
  assert.equal(author.getAttribute('data-qhn-filter-label'),'Potential bot');
  assert.equal(author.textContent,'alice');
  assert.ok(author.classList.contains('qhn-faded-author'));
  assert.equal(p.doc.getElementById('10').nextElementSibling.querySelector('.hnuser').getAttribute('data-qhn-filter-label'),'New accounts');
  p.dom.window.QuietHN.setOrdered(true);
  p.resolve({'1':'visible','10':'visible'});
  assert.equal(p.doc.querySelectorAll('.qhn-faded-author').length,0);
  assert.equal(author.hasAttribute('data-qhn-filter-label'),false);
  p.dom.window.close();
});


test('unified notes show profile notes and annotations without expansion and preserve drafts', async () => {
  const p = await page('<table><tr><td><a class="hnuser" href="user?id=alice">alice</a></td></tr></table>', {blocked: [], url:'https://news.ycombinator.com/user?id=alice'});
  const api = p.dom.window.QuietHN;
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
  const api = p.dom.window.QuietHN;
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
