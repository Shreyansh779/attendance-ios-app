// The only test suite this project has. No framework, no deps - just node.
//
// Two halves, and they are not equally trustworthy:
//
//   REAL      the JavaScript checks execute the actual blobs out of
//             Scrapers.swift, so they test shipped code.
//   MODELLED  the Swift checks run a transcription of the Swift into JS,
//             because there is no Swift toolchain on Windows. A transcription
//             can drift from its original silently.
//
// The PINS section below is what stops that drift being silent: it asserts the
// Swift still contains the exact formulas transcribed here. Change the Swift
// maths and this suite fails, telling you to update the port. That is the
// whole reason it can be trusted at all.
//
// ponytail: transcription + pins rather than a real Swift test target. Swap
// this half for `swift test` the moment a macOS machine is in the loop.
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8').replace(/\r\n/g, '\n');

let failures = 0;
const ok = (msg) => console.log('  ok   ' + msg);
function check(msg, fn) {
  try {
    fn();
    ok(msg);
  } catch (e) {
    failures++;
    console.error('  FAIL ' + msg + '\n       ' + e.message);
  }
}
function eq(got, want, what) {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) throw new Error(`${what}: got ${a}, want ${b}`);
}
function truthy(v, what) { if (!v) throw new Error(what); }

/* =====================================================================
   PINS - the Swift lines this file transcribes.
   ===================================================================== */
console.log('\nPINS  (Swift source still matches the transcription below)');
const PINS = [
  ['App/Models.swift', 'let THRESHOLD = 75'],
  ['App/Models.swift', 'let spare = (a * 100 - T * t) / T'],
  ['App/Models.swift', 'value = num / den + (num % den == 0 ? 0 : 1)'],
  ['App/Models.swift', 'let reachable = 100 * (a + R) >= T * (t + R)'],
  ['App/Models.swift', 'let raw = (100 * a + (100 - T) * R - T * t) / 100'],
  ['App/Models.swift', 'let skippable = reachable ? max(0, min(R, raw)) : 0'],
  ['App/Models.swift', 'if let e = toMinutes(s.end), e > a { b = e } else { b = a + 55 }'],
  ['App/Matching.swift', 'abs($0.1.count - n.count) < abs($1.1.count - n.count)'],
  ['App/Models.swift', 'let absorbed = Swift.max(0, row.total - base)'],
  ['App/Models.swift', 'let ordered = list.sorted { markOrder($0.key) < markOrder($1.key) }'],
  ['App/Notify.swift', 'f.dateFormat = "yyyy-MM-dd hh:mm a"'],
  ['App/Notify.swift', 'f.locale = Locale(identifier: "en_US_POSIX")'],
];
for (const [file, line] of PINS) {
  check(`${file}  «${line.slice(0, 52)}${line.length > 52 ? '…' : ''}»`, () => {
    truthy(read(file).includes(line), 'not found - the Swift changed, update the port in run.mjs');
  });
}

/* =====================================================================
   REAL - the scraper blobs, executed.
   ===================================================================== */
console.log('\nSCRAPERS  (real code out of Scrapers.swift)');
const src = read('App/Scrapers.swift');
const blobs = {};
{
  const re = /static let (\w+) = #"""\n([\s\S]*?)\n"""#/g;
  let m;
  while ((m = re.exec(src))) blobs[m[1]] = m[2];
}
check(`${Object.keys(blobs).length} blobs found and all parse`, () => {
  truthy(Object.keys(blobs).length >= 10, `only ${Object.keys(blobs).length} blobs found`);
  for (const [name, code] of Object.entries(blobs)) {
    try { new Function('return (' + code + ')'); }
    catch (e) { throw new Error(`${name}: ${e.message}`); }
  }
});

// --- installSpy: must not detach the real XMLHttpRequest -------------------
check('installSpy keeps constructor identity, statics and instanceof', () => {
  class FakeXHR {
    constructor() { this._ls = {}; this.status = 0; this.responseText = ''; }
    open(m, u) { this._m = m; this._u = u; }
    send() { this.status = 200; this.responseText = this._body || ''; (this._ls.loadend || []).forEach(f => f()); }
    addEventListener(k, f) { (this._ls[k] = this._ls[k] || []).push(f); }
  }
  FakeXHR.DONE = 4;
  const win = { XMLHttpRequest: FakeXHR };
  const original = win.XMLHttpRequest;
  new Function('window', 'return (' + blobs.installSpy + ')')(win);
  eq(win.XMLHttpRequest === original, true, 'global identity preserved');
  eq(win.XMLHttpRequest.DONE, 4, 'XMLHttpRequest.DONE preserved');
  eq(new win.XMLHttpRequest() instanceof win.XMLHttpRequest, true, 'instanceof works');
  win.__test = true;
});

check('installSpy leaves later prototype patching (zone.js) working', () => {
  class FakeXHR {
    constructor() { this._ls = {}; this.status = 0; this.responseText = ''; }
    open(m, u) { this._m = m; this._u = u; }
    send() { this.status = 200; this.responseText = this._body || ''; (this._ls.loadend || []).forEach(f => f()); }
    addEventListener(k, f) { (this._ls[k] = this._ls[k] || []).push(f); }
  }
  const win = { XMLHttpRequest: FakeXHR };
  new Function('window', 'return (' + blobs.installSpy + ')')(win);

  // zone.js loads AFTER us and patches the prototype it finds on the global.
  let seen = 0;
  const inner = win.XMLHttpRequest.prototype.open;
  win.XMLHttpRequest.prototype.open = function () { seen++; return inner.apply(this, arguments); };

  const big = JSON.stringify(Array.from({ length: 424 }, (_, i) => ({ i })));
  const mk = (url, body) => { const x = new win.XMLHttpRequest(); x.open('POST', url); x._body = body; x.send(); };
  mk('https://p/apigateway/api/timetable', JSON.stringify([{ i: 0 }]));
  mk('https://p/apigateway/api/timetable', big);
  mk('https://p/apigateway/api/timetable/masters', '[1]');

  eq(seen, 3, 'a later prototype patch sees every real request');
  eq(win.__ttData.length, 424, 'biggest payload wins');
  eq(win.__spy.length, 3, 'all calls recorded');
});

// --- sessions: the room capture must stop before trailing junk -------------
check('sessions room regex does not swallow a trailing join URL', () => {
  const re = eval('(' + blobs.sessions.match(/var rm = txt\.match\((\/room[\s\S]*?\/i)\);/)[1] + ')');
  const room = (txt) => {
    const m = txt.match(re);
    if (!m) return null;
    let r = m[1];
    const dup = r.match(/^(.+?)\s*\(\s*\1\s*\)$/);
    return dup ? dup[1] : r;
  };
  eq(room('Physics 10:00 AM - 10:55 AM Room :11213(11213)'), '11213', 'plain duplicated room');
  eq(room('DS 09:00 AM Online Classroom Room :11213(11213) https://teams.microsoft.com/l/x'), '11213', 'trailing URL');
  eq(room('DS 09:00 AM Room :11114 Meeting Link : Link'), '11114', 'trailing meeting link');
  eq(room('DS 09:00 AM Room :LT-3'), 'LT-3', 'non-numeric room');
  eq(room('DS 09:00 AM - 09:55 AM'), null, 'no room at all');
});

// --- weekApi: must keep the whole term ------------------------------------
const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const pad2 = (n) => (n < 10 ? '0' + n : String(n));
const SUBJECTS = ['Engineering Physics', 'Data Structures', 'Design and Analysis of Algorithms', 'Engineering Physics Lab'];
let scraped = [];
check('weekApi keeps the whole term and reports payload size', () => {
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const payload = [];
  for (let d = 0; d < 70; d++) {
    const day = new Date(today.getTime() + d * 86400000);
    if (day.getDay() === 0 || day.getDay() === 6) continue;
    SUBJECTS.forEach((subj, i) => {
      if ((d + i) % 2) return;
      payload.push({
        SlotDate: day.getFullYear() + '-' + MONTHS[day.getMonth()] + '-' + pad2(day.getDate()),
        SlotStartTime: (9 + i) + ':00 AM', SlotEndTime: (9 + i) + ':55 AM',
        ModuleList: [{ ModuleName: subj }],
        FloorPlanDetails: { VenueName: '1121' + i, VenueCategory: 'Class Room', MeetingLink: '' },
      });
    });
  }
  payload.push({ // a past class, which must be dropped
    SlotDate: '2020-Jan-05', SlotStartTime: '09:00 AM', SlotEndTime: '09:55 AM',
    ModuleList: [{ ModuleName: 'Engineering Physics' }],
    FloorPlanDetails: { VenueName: '11110', VenueCategory: 'Class Room', MeetingLink: '' },
  });

  const win = { __ttData: payload };
  const out = JSON.parse(new Function('window', 'return (' + blobs.weekApi + ')')(win));
  truthy(out.ok, 'weekApi parsed the payload: ' + out.diag);
  eq(out.items, payload.length, 'items reports the raw payload size');

  const days = [...new Set(out.sessions.map(s => s.date))].sort();
  const span = (new Date(days[days.length - 1]) - new Date(days[0])) / 86400000;
  truthy(span > 14, `term must not be truncated at 14 days (span ${span})`);
  const todayIso = today.getFullYear() + '-' + pad2(today.getMonth() + 1) + '-' + pad2(today.getDate());
  truthy(days[0] >= todayIso, `no session before today (first ${days[0]})`);
  scraped = out.sessions;
});

/* =====================================================================
   MODELLED - transcriptions of the Swift, pinned above.
   ===================================================================== */
console.log('\nMATHS  (transcribed from Swift - see PINS)');
const T = 75;
const tdiv = (n, d) => Math.trunc(n / d), tmod = (n, d) => n - tdiv(n, d) * d;

function budget(a, t) {
  if (t <= 0) return { state: 'empty', value: 0 };
  const n0 = a * 100 - T * t, spare = tdiv(n0, T);
  const floored = (n0 < 0 && tmod(n0, T) !== 0) ? spare - 1 : spare;
  if (floored >= 0) return { state: 'safe', value: floored };
  const num = T * t - a * 100, den = 100 - T;
  return { state: 'short', value: tdiv(num, den) + (tmod(num, den) === 0 ? 0 : 1) };
}

check('Budget: every (attended, held) up to 400 held', () => {
  for (let t = 1; t < 400; t++) {
    for (let a = 0; a <= t; a++) {
      const { state, value: v } = budget(a, t);
      if (state === 'safe') {
        truthy(a * 100 >= T * (t + v), `skip ${v} should hold at ${a}/${t}`);
        truthy(!(a * 100 >= T * (t + v + 1)), `skip ${v} not maximal at ${a}/${t}`);
      } else {
        truthy((a + v) * 100 >= T * (t + v), `attend ${v} should clear at ${a}/${t}`);
        truthy(v === 0 || !((a + v - 1) * 100 >= T * (t + v - 1)), `attend ${v} not minimal at ${a}/${t}`);
      }
    }
  }
});

function term(a, t, R) {
  const reachable = 100 * (a + R) >= T * (t + R);
  const raw = tdiv(100 * a + (100 - T) * R - T * t, 100);
  const skippable = reachable ? Math.max(0, Math.min(R, raw)) : 0;
  const b = budget(a, t);
  const clearsAt = (b.state === 'short' && reachable && b.value >= 1 && b.value <= R) ? b.value : null;
  return { reachable, skippable, clearsAt };
}

check('Term: every (attended, held, remaining) up to 120', () => {
  for (let t = 0; t <= 120; t++) {
    for (let a = 0; a <= t; a++) {
      for (let R = 0; R <= 120; R++) {
        const g = term(a, t, R);
        eq(g.reachable, 100 * (a + R) >= T * (t + R), `reachable ${a}/${t} R=${R}`);
        if (g.reachable) {
          truthy(100 * (a + R - g.skippable) >= T * (t + R), `skip ${g.skippable} holds ${a}/${t} R=${R}`);
          if (g.skippable < R) {
            truthy(!(100 * (a + R - g.skippable - 1) >= T * (t + R)), `skip not maximal ${a}/${t} R=${R}`);
          }
        } else {
          eq(g.skippable, 0, `unreachable skips 0 ${a}/${t} R=${R}`);
        }
        if (g.clearsAt !== null) {
          const k = g.clearsAt;
          truthy(100 * (a + k) >= T * (t + k), `clears at ${k} holds ${a}/${t}`);
          truthy(!(100 * (a + k - 1) >= T * (t + k - 1)), `clears at ${k} is first ${a}/${t}`);
          truthy(k <= R, `clears within remaining ${a}/${t} R=${R}`);
        }
      }
    }
  }
});

// --- subject matching -----------------------------------------------------
const stop = new Set(['and','the','of','for','to','in','a','an','lab','theory']);
const norm = (s) => [...s.toLowerCase().split('&').join(' and ')]
  .map(c => (/[a-z0-9]/.test(c) ? c : ' ')).join('').split(' ').filter(Boolean).join(' ');
const toks = (s) => new Set(norm(s).split(' ').filter(t => t.length > 2 && !stop.has(t)));
function matchSubject(name, rows) {
  if (!name.length || !rows.length) return null;
  const n = norm(name);
  const exact = rows.find(r => norm(r.key) === n);
  if (exact) return exact;
  if (n.length > 6) {
    const hits = rows.map(r => [r, norm(r.key)])
      .filter(p => p[1].length > 6 && (p[1].startsWith(n) || n.startsWith(p[1])))
      .sort((x, y) => Math.abs(x[1].length - n.length) - Math.abs(y[1].length - n.length));
    if (hits.length === 1) return hits[0][0];
    if (hits.length > 1) {
      const best = Math.abs(hits[0][1].length - n.length);
      return Math.abs(hits[1][1].length - n.length) === best ? null : hits[0][0];
    }
  }
  const a = toks(name);
  if (!a.size) return null;
  let bestRow = null, bestScore = 0;
  for (const r of rows) {
    const b = toks(r.key);
    if (!b.size) continue;
    const score = [...a].filter(t => b.has(t)).length / Math.min(a.size, b.size);
    if (score > bestScore) { bestScore = score; bestRow = r; }
  }
  return bestScore >= 0.6 ? bestRow : null;
}

check('matchSubject prefers the closest key and refuses a tie', () => {
  const R = (k) => ({ key: k });
  const name = (r) => (r ? r.key : null);
  const pair = [R('Engineering Physics'), R('Engineering Physics Lab')];
  eq(name(matchSubject('Engineering Physics Laboratory', pair)), 'Engineering Physics Lab', 'lab beats theory');
  eq(name(matchSubject('Engineering Physics Laboratory', [...pair].reverse())), 'Engineering Physics Lab', 'order independent');
  eq(name(matchSubject('Engineering Physics', pair)), 'Engineering Physics', 'exact tier wins');
  eq(name(matchSubject('Design & Analysis of Algorithms', [R('Design and Analysis of Algorithms')])),
    'Design and Analysis of Algorithms', 'ampersand normalises');
  eq(name(matchSubject('Engineering Physicsxy', [R('Engineering Physicsab'), R('Engineering Physicscd')])),
    null, 'ambiguous pair returns nil');
});

// --- shapeDay durations ---------------------------------------------------
function toMinutes(t) {
  const m = String(t).toUpperCase().match(/(\d{1,2}):(\d{2})\s*([AP])/);
  if (!m) return null;
  let h = (+m[1]) % 12;
  if (m[0].includes('P')) h += 12;
  return h * 60 + (+m[2]);
}
check('shapeDay never produces a zero-length class', () => {
  const shape = (start, end, now) => {
    const a = toMinutes(start), raw = toMinutes(end);
    const b = (raw !== null && raw > a) ? raw : a + 55;
    return { s0: a, s1: b, live: now >= a && now < b, past: now >= b };
  };
  eq(shape('09:00 AM', '09:55 AM', 570), { s0: 540, s1: 595, live: true, past: false }, 'normal class');
  eq(shape('09:00 AM', '09:00 AM', 550).past, false, 'zero-length is not already over');
  eq(shape('09:00 AM', '09:00 AM', 550).live, true, 'zero-length reads as live');
  eq(shape('09:00 AM', '', 550).s1, 595, 'unparseable end falls back to a slot');
  eq(shape('09:00 AM', '08:00 AM', 550).s1, 595, 'end before start falls back');
  eq(toMinutes('12:00 PM'), 720, 'noon');
  eq(toMinutes('12:30 AM'), 30, 'after midnight');
});

// --- the two halves together ----------------------------------------------
check('scraped term feeds the maths and every session is counted once', () => {
  const rows = [
    { key: 'Engineering Physics', attended: 18, total: 30 },
    { key: 'Data Structures', attended: 30, total: 40 },
    { key: 'Design and Analysis of Algorithms', attended: 38, total: 40 },
    { key: 'Engineering Physics Lab', attended: 2, total: 20 },
  ];
  const byKey = {}, seen = new Map();
  for (const s of scraped) {
    if (!seen.has(s.subject)) seen.set(s.subject, (matchSubject(s.subject, rows) || {}).key ?? null);
    const k = seen.get(s.subject);
    if (k == null) continue;
    (byKey[k] = byKey[k] || []).push(s.date);
  }
  let counted = 0;
  for (const r of rows) {
    const dates = (byKey[r.key] || []).sort();
    counted += dates.length;
    const tm = term(r.attended, r.total, dates.length);
    if (r.key === 'Engineering Physics Lab') eq(tm.reachable, false, '10% with a partial term is unreachable');
    if (r.key === 'Engineering Physics') truthy(tm.clearsAt !== null, '60% recoverable has a clearance class');
  }
  eq(counted, scraped.length, 'every scraped session counted exactly once');
});

// --- the LMS pair ---------------------------------------------------------
// Both blobs hang their work off fetch().then(), and check() is synchronous.
// A thenable that resolves in place runs the whole chain before the call
// returns, which is cheaper than making the whole runner async for two tests.
const sync = (v) => ({
  then: (f) => { const r = f(v); return r && typeof r.then === 'function' ? r : sync(r); },
  catch: () => sync(v),
});

check('lmsDue keeps only real deadlines and tidies the course name', () => {
  // Shaped like the live reply: two things genuinely due, and a "should be
  // completed" nag on an uploaded file, which is not a deadline.
  const events = [
    {
      name: 'Lecture-1 should be completed', modulename: 'resource', timesort: 1786000000,
      url: 'https://lms/mod/resource/view.php?id=1',
      course: { fullname: 'Ethical Hacking &amp; Penetration Testing_Sem5' },
    },
    {
      name: 'PBL_Submission 1 is due', modulename: 'assign', timesort: 1790000000,
      url: 'https://lms/mod/assign/view.php?id=2',
      course: { fullname: 'Ethical Hacking &amp; Penetration Testing_Sem5' },
    },
    {
      name: 'Quiz 2 closes', modulename: 'quiz', timesort: 1791000000,
      url: 'https://lms/mod/quiz/view.php?id=3',
      course: { fullname: 'Web Analytics_Sem12' },
    },
  ];
  const win = { M: { cfg: { sesskey: 'abc123' } } };
  const fetch = (url, opt) => {
    truthy(url.includes('sesskey=abc123'), 'sesskey not sent');
    const body = JSON.parse(opt.body);
    eq(body[0].methodname, 'core_calendar_get_action_events_by_timesort', 'wrong ws method');
    // limitnum, not limit. "limit" is accepted by the signature check and
    // then rejected as "Invalid parameter value detected" - which is a whole
    // build spent on a typo.
    truthy('limitnum' in body[0].args, 'limitnum missing from the args');
    return sync({ json: () => sync([{ error: false, data: { events } }]) });
  };
  const call = () => JSON.parse(
    new Function('window', 'M', 'fetch', 'return (' + blobs.lmsDue + ')')(win, win.M, fetch)
  );

  call();
  const out = call();
  truthy(out.done && out.ok, 'never finished: ' + out.diag);
  eq(out.items.length, 2, 'the resource nag was not dropped');
  eq(out.items[0].course, 'Ethical Hacking & Penetration Testing', 'course name not tidied');
  eq(out.items[1].course, 'Web Analytics', 'the _Sem suffix survived');
  // Swift parses this with .withFractionalSeconds; without them the date
  // decodes to nil and the card quietly shows a dash.
  truthy(/\.\d{3}Z$/.test(out.items[0].due), 'due is not fractional-second ISO: ' + out.items[0].due);
});

check('lmsCourses keeps your teachers, their folders, and the shared sections', () => {
  const courses = [
    { id: 100891, fullname: 'Cryptography and Network Security_Sem5' },
    { id: 101886, fullname: 'Ethical Hacking &amp; Penetration Testing_Sem5' },
    // No _Sem suffix, so not this semester however "inprogress" it claims to be.
    { id: 39504, fullname: 'Leading Conversations' },
  ];

  const crypto = {
    course: { sectionlist: ['1', '2', '3'] },
    section: [
      // Visible material belonging to a teacher who is not mine. uservisible
      // does not hide this one, which is the whole reason for the name match.
      { id: '1', title: 'Dr. Justin Joseph | CCVT B1-B6', visible: true, parentsectionid: null, cmlist: ['a'] },
      { id: '2', title: 'Ayush Gurjar', visible: true, parentsectionid: null, cmlist: ['b'] },
      { id: '3', title: 'General', visible: true, parentsectionid: null, cmlist: ['c'] },
    ],
    cm: [
      { id: 'a', name: 'Resources', modname: 'Page', uservisible: true, url: 'https://lms/x' },
      { id: 'b', name: 'Assignment_1', modname: 'Assignment', uservisible: true, url: 'https://lms/a1' },
      { id: 'c', name: 'Course Plan', modname: 'File', uservisible: true, url: 'https://lms/cp' },
    ],
  };

  const ethical = {
    course: { sectionlist: ['10', '11', '12'] },
    section: [
      { id: '10', title: 'Dr.  Navin Mani Upadhyay (B-7, B-8, B-9)', visible: true, parentsectionid: null, cmlist: ['p', 'sub'] },
      // A folder inside that teacher, not a teacher of its own.
      { id: '11', title: 'Unit-1', visible: true, parentsectionid: '10', cmlist: ['q'] },
      { id: '12', title: 'Sushma_Choudhary', visible: true, parentsectionid: null, cmlist: ['r'] },
    ],
    cm: [
      { id: 'p', name: 'Syllabus', modname: 'File', uservisible: true, url: 'https://lms/s' },
      { id: 'sub', name: 'Unit-1', modname: 'Subsection', uservisible: true, url: 'https://lms/sub' },
      { id: 'q', name: 'Lecture-1', modname: 'File', uservisible: true, url: 'https://lms/l1' },
      { id: 'r', name: 'Someone else', modname: 'File', uservisible: true, url: 'https://lms/e' },
    ],
  };

  const win = {
    M: { cfg: { sesskey: 'sk1' } },
    __mine: {
      // Spaced and cased as the timetable writes them, which is not how the
      // LMS writes them.
      'Cryptography and Network Security': ['Ayush  Gurjar'],
      // Middle name the timetable has never heard of.
      'Ethical Hacking & Penetration Testing': ['Navin  Upadhyay'],
    },
  };
  let asked = 0;
  const fetch = (url, opt) => {
    asked++;
    const calls = JSON.parse(opt.body);
    if (calls[0].methodname.indexOf('timeline_classification') > -1) {
      eq(calls[0].args.classification, 'inprogress', 'wrong classification');
      return sync({ json: () => sync([{ error: false, data: { courses } }]) });
    }
    eq(calls.length, 2, 'Leading Conversations was not dropped before the state calls');
    const bodies = [crypto, ethical];
    return sync({
      json: () => sync(calls.map((c, i) => ({ index: i, error: false, data: JSON.stringify(bodies[i]) }))),
    });
  };
  const call = () => JSON.parse(
    new Function('window', 'M', 'fetch', 'return (' + blobs.lmsCourses + ')')(win, win.M, fetch)
  );

  call();
  const out = call();
  truthy(out.done && out.ok, 'never finished: ' + out.diag);
  eq(out.courses.length, 2, 'wrong course count');

  const c = out.courses[0];
  eq(c.name, 'Cryptography and Network Security', 'course name not tidied');
  eq(
    c.items.map((i) => i.group + '/' + i.folder + '/' + i.title),
    ['Ayush Gurjar//Assignment_1', 'General//Course Plan'],
    "another teacher's section, or the shared one, was handled wrong"
  );

  const e = out.courses[1];
  eq(e.name, 'Ethical Hacking & Penetration Testing', 'ampersand not unescaped');
  eq(
    e.items.map((i) => i.folder + '/' + i.title),
    ['/Syllabus', 'Unit-1/Lecture-1'],
    'the folder is not being attributed to its teacher'
  );
  // Every item of a course belongs to the teacher, never to the folder.
  truthy(
    e.items.every((i) => i.group.indexOf('Upadhyay') > -1),
    'a folder was promoted to a teacher: ' + JSON.stringify(e.items.map((i) => i.group))
  );
  eq(asked, 2, 'more requests than the list plus one batch');
});

check('lmsKey finds the session by shape and spends only one key', () => {
  const store = {
    a9x: JSON.stringify({ Identity: { AccessToken: 'tok' } }),
    rzp_device_id: '1.not-json-at-all',
    b2y: JSON.stringify({ StudentId: 'uniq-1', FirstName: 'X' }),
  };
  const keys = Object.keys(store);
  let calls = 0;
  const win = {};
  const localStorage = { length: keys.length, key: (i) => keys[i], getItem: (k) => store[k] };
  const fetch = (url, opt) => {
    calls++;
    truthy(url.includes('uniqueId=uniq-1'), 'student id not in the url');
    eq(opt.headers.Authorization, 'Bearer tok', 'token not sent');
    return sync({ status: 200, json: () => sync({ redirectUrl: 'https://lms/auth/userkey/login.php?key=k' }) });
  };
  const call = () => JSON.parse(
    new Function('window', 'localStorage', 'fetch', 'return (' + blobs.lmsKey + ')')(win, localStorage, fetch)
  );

  call();
  const out = call();
  truthy(out.done && out.ok, 'no key: ' + out.diag);
  truthy(out.url.includes('login.php?key=k'), 'wrong url: ' + out.url);
  call();
  // Each key is good for exactly one login, so a re-poll must not burn one.
  eq(calls, 1, 'the key was requested more than once');
});

/* ---------------------------------------------------------------------
   The holiday grid. Dates arrive DD-MM-YYYY with a weekday chip beside them,
   and a row can span days - so both the ordering and the range matter.
   --------------------------------------------------------------------- */
console.log('\nHOLIDAYS  (real code out of Scrapers.swift)');

check('the holiday grid parses, including ranges and a year boundary', () => {
  const ROWS = [
    ['Harela Parv', 'State Holiday', '16-07-2026', 'THURSDAY', '16-07-2026', 'THURSDAY'],
    ['Gandhi Jayanti', 'National Holiday', '02-10-2026', 'FRIDAY', '02-10-2026', 'FRIDAY'],
    ['Diwali', 'City Holiday', '09-11-2026', 'MONDAY', '13-11-2026', 'FRIDAY'],
    ['Winter Break', 'State Holiday', '25-12-2026', 'FRIDAY', '01-01-2027', 'FRIDAY'],
  ];
  const cell = (v) => ({ textContent: String(v) });
  const trs = [
    // a header row, which has no <td> and must be skipped
    { textContent: 'Holiday/Event name Type Start Date End Date',
      querySelector: () => null, querySelectorAll: () => [] },
    ...ROWS.map((r) => {
      const tds = [cell(r[0]), cell(r[1]), cell(r[2] + ' ' + r[3]), cell(r[4] + ' ' + r[5])];
      return {
        textContent: r.join(' '),
        querySelector: () => null,
        querySelectorAll: (sel) => (sel === 'td' ? tds : []),
      };
    }),
  ];
  const doc = { querySelectorAll: (sel) => (sel === 'tr' ? trs : []) };
  const out = JSON.parse(new Function('document', 'return (' + blobs.holidays + ')')(doc));

  truthy(out.ok, 'parsed nothing: ' + JSON.stringify(out).slice(0, 120));
  eq(out.holidays.length, 4, 'four data rows, header skipped');

  const by = Object.fromEntries(out.holidays.map((h) => [h.name, h]));
  eq([by['Gandhi Jayanti'].from, by['Gandhi Jayanti'].to], ['2026-10-02', '2026-10-02'], 'single day');
  eq([by['Diwali'].from, by['Diwali'].to], ['2026-11-09', '2026-11-13'], 'five-day range');
  eq([by['Winter Break'].from, by['Winter Break'].to], ['2026-12-25', '2027-01-01'], 'crosses a year');
  eq(by['Gandhi Jayanti'].type, 'National Holiday', 'type captured');
});

check('a weekday chip is never mistaken for a date', () => {
  // THURSDAY contains no digits, but the guard that matters is that the name
  // comes from the first cell rather than the whole row.
  const tds = [
    { textContent: 'Diwali' }, { textContent: 'City Holiday' },
    { textContent: '09-11-2026 MONDAY' }, { textContent: '13-11-2026 FRIDAY' },
  ];
  const tr = {
    textContent: 'Diwali City Holiday 09-11-2026 MONDAY 13-11-2026 FRIDAY',
    querySelector: () => null,
    querySelectorAll: (sel) => (sel === 'td' ? tds : []),
  };
  const doc = { querySelectorAll: (sel) => (sel === 'tr' ? [tr] : []) };
  const out = JSON.parse(new Function('document', 'return (' + blobs.holidays + ')')(doc));
  eq(out.holidays[0].name, 'Diwali', 'name is the first cell only');
});

/* ---------------------------------------------------------------------
   survivingMarks: which hand-marks a refresh is allowed to throw away.

   Too eager and you silently lose work you did by hand; too lax and a class
   gets counted twice, which is worse - it overstates attendance, which is the
   direction that gets you a surprise at the end of term.
   --------------------------------------------------------------------- */
console.log('\nMARKS  (transcribed from Swift - see PINS)');

function survivingMarks(marks, rows) {
  if (!Object.keys(marks).length || !rows.length) return {};
  const grouped = {};
  for (const [key, mark] of Object.entries(marks)) {
    const row = rows.find(r => r.key === mark.subject);
    if (!row) continue;
    (grouped[row.key] = grouped[row.key] || []).push({ key, mark });
  }
  const out = {};
  for (const [rowKey, list] of Object.entries(grouped)) {
    const row = rows.find(r => r.key === rowKey);
    if (!row) continue;
    // Same ordering as markOrder() in Swift: by clock time, not string order.
    const order = (k) => {
      const p = k.split('|');
      const m = (p[1] || '').match(/^(\d{1,2}):(\d{2}) ([AP])M$/);
      const mins = m ? ((+m[1] % 12) + (m[3] === 'P' ? 12 : 0)) * 60 + +m[2] : 0;
      return `${p[0]}|${String(mins).padStart(4, '0')}`;
    };
    const ordered = [...list].sort((a, b) => (order(a.key) < order(b.key) ? -1 : 1));
    const base = Math.min(...ordered.map(e => e.mark.total));
    const absorbed = Math.max(0, row.total - base);
    ordered.forEach((e, i) => { if (i >= absorbed) out[e.key] = e.mark; });
  }
  return out;
}

check('a mark survives until the portal counts it', () => {
  const rows = (total) => [{ key: 'Physics', attended: 10, total }];
  const one = { '2026-09-19|09:00 AM|Physics': { subject: 'Physics', attended: true, total: 19 } };

  eq(Object.keys(survivingMarks(one, rows(19))).length, 1, 'portal unchanged -> mark kept');
  eq(Object.keys(survivingMarks(one, rows(20))).length, 0, 'portal caught up -> mark spent');
  eq(Object.keys(survivingMarks(one, rows(25))).length, 0, 'portal well past -> mark spent');
});

check('partial catch-up spends the oldest marks first', () => {
  const rows = (total) => [{ key: 'Physics', attended: 10, total }];
  const two = {
    '2026-09-19|09:00 AM|Physics': { subject: 'Physics', attended: true, total: 19 },
    '2026-09-19|03:00 PM|Physics': { subject: 'Physics', attended: false, total: 19 },
  };
  eq(Object.keys(survivingMarks(two, rows(19))).length, 2, 'neither counted');
  const after20 = survivingMarks(two, rows(20));
  eq(Object.keys(after20).length, 1, 'one counted -> one kept');
  truthy(after20['2026-09-19|03:00 PM|Physics'], 'the later one is the survivor');
  eq(Object.keys(survivingMarks(two, rows(21))).length, 0, 'both counted');
});

check('legacy marks and unmatched subjects are dropped', () => {
  const rows = [{ key: 'Physics', attended: 10, total: 19 }];
  // total 0 is what a mark written before the field existed decodes to.
  const legacy = { 'k': { subject: 'Physics', attended: true, total: 0 } };
  eq(Object.keys(survivingMarks(legacy, rows)).length, 0, 'legacy mark dropped');
  const orphan = { 'k': { subject: 'Astrophysics', attended: true, total: 19 } };
  eq(Object.keys(survivingMarks(orphan, rows)).length, 0, 'unmatched subject dropped');
});

check('a mark can never be counted twice', () => {
  // The invariant that matters: applying surviving marks after a refresh must
  // never push a subject above what the portal says plus the marks still held.
  const rows = [{ key: 'Physics', attended: 10, total: 19 }];
  for (let newTotal = 19; newTotal <= 30; newTotal++) {
    const marks = {};
    for (let i = 0; i < 4; i++) {
      marks[`2026-09-${20 + i}|09:00 AM|Physics`] = { subject: 'Physics', attended: true, total: 19 };
    }
    const kept = Object.keys(survivingMarks(marks, [{ ...rows[0], total: newTotal }])).length;
    const counted = newTotal - 19;
    // The portal counts classes you never marked too, so "counted" can exceed
    // the four. What must hold is that a marked class is never both counted
    // and still held: every class the portal absorbed retires one mark.
    truthy(kept <= Math.max(0, 4 - counted), `total ${newTotal}: kept ${kept} with ${counted} absorbed`);
  }
});

/* ---------------------------------------------------------------------
   Notifications: the one failure mode with no error message.

   Notify builds a fire time by string-concatenating a session's ISO date and
   its start time, then parsing with "yyyy-MM-dd hh:mm a". If the scrapers ever
   emit a shape that format cannot read, every notification silently fails to
   schedule - no crash, no log, just nothing ever arriving. This checks the two
   producers against the exact format string pinned above.
   --------------------------------------------------------------------- */
console.log('\nNOTIFICATIONS  (fire times parse from what the scrapers emit)');

// en_US_POSIX "yyyy-MM-dd hh:mm a": 12-hour, zero-padded, AM/PM.
const STAMP = /^(\d{4})-(\d{2})-(\d{2}) (0[1-9]|1[0-2]):([0-5]\d) (AM|PM)$/;

check('every weekApi session builds a parseable fire time', () => {
  truthy(scraped.length > 0, 'no sessions scraped to check');
  for (const s of scraped) {
    for (const [field, value] of [['start', s.start], ['end', s.end]]) {
      const composed = `${s.date} ${value}`;
      const m = composed.match(STAMP);
      truthy(m, `${field} "${composed}" does not match yyyy-MM-dd hh:mm a`);
      const hour = +m[4] % 12 + (m[6] === 'PM' ? 12 : 0);
      truthy(hour >= 0 && hour <= 23, `${composed} -> impossible hour ${hour}`);
    }
  }
});

check('the dashboard scraper emits the same time shape', () => {
  // The sessions blob normalises with toUpperCase() and strips dots; these are
  // the shapes it produces from the portal's own markup.
  const fromDashboard = ['09:00 AM', '12:00 PM', '03:00 PM', '11:00 AM', '12:30 AM'];
  for (const t of fromDashboard) {
    const composed = `2026-09-19 ${t}`;
    truthy(composed.match(STAMP), `"${composed}" would not parse`);
  }
  // And the shapes that would NOT parse, so the test fails if the format is
  // ever loosened without thinking about it.
  for (const bad of ['9:00 AM', '09:00', '21:00', '09:00 am']) {
    truthy(!`2026-09-19 ${bad}`.match(STAMP), `"${bad}" unexpectedly parses`);
  }
});

check('the 64-notification cap is respected', () => {
  const src = read('App/Notify.swift');
  const cap = /maxPending = (\d+)/.exec(src);
  truthy(cap, 'maxPending not found');
  truthy(+cap[1] <= 64, `maxPending ${cap[1]} exceeds the iOS limit of 64`);
  truthy(src.includes('scheduled < maxPending'), 'the class loop does not check the cap');
});

/* ===================================================================== */
console.log(failures ? `\n${failures} FAILED\n` : '\nall checks passed\n');
process.exit(failures ? 1 : 0);
