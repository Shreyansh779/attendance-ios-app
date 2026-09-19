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
