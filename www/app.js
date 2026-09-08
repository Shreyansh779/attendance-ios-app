/* Today — UPES dashboard as an app.
 *
 * The portal is opened in an InAppBrowser so the captcha can be solved by
 * hand, then executeScript reads the dashboard's DOM out of that webview.
 * Nothing leaves the device and there is no server.
 *
 * Modules: config, math, matching, scrapers, portal, storage, views, router.
 */

/* =========================================================== 1. config === */

const CFG = {
  loginURL: 'https://myupes-beta.upes.ac.in/',
  dashboardRoute: /\/connectportal\/user\/student\/home\/dashboard/,
  threshold: 75,
  pollMs: 700,
  maxTries: 30,
  staleAfterHours: 12,
};

/* ============================================================= 2. math ===
 * Integer arithmetic throughout, so no rounding error can shift an answer by
 * one class. a = attended, t = held, T = required percent.
 *   miss n more:     a/(t+n)     >= T/100  =>  n <= (100a - T*t) / T
 *   attend m more:  (a+m)/(t+m)  >= T/100  =>  m >= (T*t - 100a) / (100 - T)
 */

function budget(a, t) {
  const T = CFG.threshold;
  if (!t) return { state: 'empty', v: 0, pct: 0 };
  const pct = (a / t) * 100;
  const safe = Math.floor((a * 100 - T * t) / T);
  if (safe >= 0) return { state: 'safe', v: safe, pct };
  return { state: 'short', v: Math.ceil((T * t - a * 100) / (100 - T)), pct };
}

function summarise(rows) {
  const subjects = (rows || [])
    .map(r => ({ ...r, ...budget(r.attended, r.total) }))
    // Risk order. A subject with no classes held yet reads 0% but carries no
    // risk, so it sits at the bottom rather than heading the list.
    .sort((x, y) => {
      if (x.state === 'empty' && y.state !== 'empty') return 1;
      if (y.state === 'empty' && x.state !== 'empty') return -1;
      return x.pct - y.pct;
    });
  const attended = (rows || []).reduce((s, r) => s + r.attended, 0);
  const total = (rows || []).reduce((s, r) => s + r.total, 0);
  return {
    subjects,
    overall: { attended, total, ...budget(attended, total) },
    failing: subjects.filter(s => s.state === 'short'),
  };
}

// "09:00 AM" -> minutes since midnight.
function toMinutes(t) {
  const m = String(t).match(/(\d{1,2}):(\d{2})\s*([AP])/i);
  if (!m) return null;
  let h = Number(m[1]) % 12;
  if (/p/i.test(m[3])) h += 12;
  return h * 60 + Number(m[2]);
}
const hhmm = m => `${String(Math.floor(m / 60) % 12 || 12)}:${String(m % 60).padStart(2, '0')}`;
const ampm = m => (m < 720 ? 'am' : 'pm');

/* ========================================================= 3. matching ===
 * The two cards can name the same subject differently — "&" against "and", a
 * truncated title, a trailing "Lab" — so tie them together by normalising and
 * then trying progressively looser tests. Returning null is a valid answer:
 * better to show no attendance than another subject's.
 */

const STOP = new Set(['and', 'the', 'of', 'for', 'to', 'in', 'a', 'an', 'lab', 'theory']);

function norm(s) {
  return String(s == null ? '' : s)
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
    .replace(/\s+/g, ' ');
}

function tokens(s) {
  return new Set(norm(s).split(' ').filter(w => w.length > 2 && !STOP.has(w)));
}

function matchSubject(name, rows) {
  if (!name || !rows || !rows.length) return null;
  const n = norm(name);

  let hit = rows.find(r => norm(r.key || r.subject) === n);
  if (hit) return hit;

  hit = rows.find(r => {
    const k = norm(r.key || r.subject);
    return k.length > 6 && n.length > 6 && (k.startsWith(n) || n.startsWith(k));
  });
  if (hit) return hit;

  const a = tokens(name);
  let best = null;
  let bestScore = 0;
  for (const r of rows) {
    const b = tokens(r.key || r.subject);
    if (!a.size || !b.size) continue;
    let inter = 0;
    a.forEach(w => {
      if (b.has(w)) inter++;
    });
    const score = inter / Math.min(a.size, b.size);
    if (score > bestScore) {
      bestScore = score;
      best = r;
    }
  }
  return bestScore >= 0.6 ? best : null;
}

// Marks the class on now and the next one due, and ties each to its subject.
function shapeDay(sessions, attRows, nowMin) {
  const list = (sessions || [])
    .map(s => ({ ...s, s0: toMinutes(s.start), s1: toMinutes(s.end) }))
    .filter(s => s.s0 != null)
    .sort((a, b) => a.s0 - b.s0);

  let nextIdx = -1;
  list.forEach((s, i) => {
    s.live = nowMin >= s.s0 && nowMin < s.s1;
    s.past = nowMin >= s.s1;
    if (!s.past && !s.live && nextIdx === -1) nextIdx = i;
    const row = matchSubject(s.subject, attRows);
    s.att = row ? { ...row, ...budget(row.attended, row.total) } : null;
  });
  if (nextIdx >= 0) list[nextIdx].next = true;
  return list;
}

/* ========================================================= 4. scrapers ===
 * Both run inside the portal page and return a JSON string, because
 * executeScript hands back the value of the last expression and cannot wait on
 * an in-page callback.
 *
 * Neither uses CSS selectors. The attendance card is not a <table> and the
 * sessions card has no stable classes, so rows are found by walking text nodes
 * for a distinctive string — "24/28" for attendance, "09:00 AM - 09:55 AM" for
 * sessions — then climbing to the element that contains it.
 */

const ATT_SCRAPER = `

(function () {
  var OURS = ".arw-badge, .arw-overall";
  var PCT_RE = /\\d+(?:\\.\\d+)?\\s*%/;
  var allFractions = function () { return /(\\d{1,3})\\s*\\/\\s*(\\d{1,3})/g; };
  var oneFraction  = function () { return /(\\d{1,3})\\s*\\/\\s*(\\d{1,3})/; };
  var exactFraction = function () { return /^\\s*(\\d{1,3})\\s*\\/\\s*(\\d{1,3})\\s*$/; };
  var clean = function (t) { return String(t == null ? "" : t).replace(/\\s+/g, " ").trim(); };

  // Four tiers, loosest last. The userscript's version required a leaf node
  // holding both "attendance" and "summary", which misses a heading split as
  // <h4><span>Attendance</span> <span>Summary</span></h4> and misses a card
  // titled just "Attendance". Tier 4 drops headings entirely and finds the
  // tightest container of fraction rows, so a renamed card still resolves.
  function findCard() {
    var els = document.querySelectorAll("h1,h2,h3,h4,h5,h6,div,span,p,strong,b,label,legend,a,td,th");
    var tiers = [null, null, null];

    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var t = clean(el.textContent).toLowerCase();
      // Short text, not a leaf requirement - a wrapped heading still qualifies.
      if (!t || t.length > 40) continue;

      var tier = -1;
      if (t === "attendance summary") tier = 0;
      else if (t.indexOf("attendance") > -1 && t.indexOf("summary") > -1) tier = 1;
      else if (t.indexOf("attendance") > -1) tier = 2;
      if (tier < 0 || tiers[tier]) continue;

      var p = el.parentElement;
      for (var j = 0; j < 9 && p && p !== document.body; j++) {
        if ((p.textContent.match(allFractions()) || []).length >= 1) { tiers[tier] = p; break; }
        p = p.parentElement;
      }
    }

    if (tiers[0]) return tiers[0];
    if (tiers[1]) return tiers[1];
    if (tiers[2]) return tiers[2];

    // Tier 4 - no heading match at all. Group every fraction row in the
    // document by its parent and take the parent holding the most.
    var buckets = new Map();
    var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    var n;
    while ((n = w.nextNode())) {
      if (!exactFraction().test(n.nodeValue || "")) continue;
      var host = n.parentElement;
      if (!host || host.closest(OURS)) continue;
      var row = findRow(host);
      if (!row || !row.parentElement) continue;
      var key = row.parentElement;
      if (!buckets.has(key)) buckets.set(key, 0);
      buckets.set(key, buckets.get(key) + 1);
    }
    var bestEl = null, bestN = 0;
    buckets.forEach(function (count, el2) {
      if (count > bestN) { bestN = count; bestEl = el2; }
    });
    return bestN >= 2 ? bestEl : null;
  }

  function findRow(host) {
    var el = host;
    for (var i = 0; i < 10 && el && el !== document.body; i++) {
      var txt = el.textContent || "";
      var count = (txt.match(allFractions()) || []).length;
      if (count > 1) return null;
      if (count === 1 && PCT_RE.test(txt) && /[A-Za-z]{4,}/.test(txt)) return el;
      el = el.parentElement;
    }
    return null;
  }

  function rowShape(el) {
    return el.tagName + "|" + (el.getAttribute("class") || "").trim().replace(/\\s+/g, " ");
  }

  // A leading digit is not disqualifying: "3D Modelling and Animation"
  // is an ordinary subject name.
  function isLabel(t) {
    if (!/[A-Za-z]{4,}/.test(t)) return false;
    if (exactFraction().test(t)) return false;
    if (/^\\d+(?:\\.\\d+)?\\s*%?$/.test(t)) return false;
    return true;
  }

  function findNameNode(row) {
    var w = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
    var best = null, len = 0, n;
    while ((n = w.nextNode())) {
      if (n.parentElement && n.parentElement.closest(OURS)) continue;
      var t = clean(n.nodeValue);
      if (!t || t.length <= len || !isLabel(t)) continue;
      best = t; len = t.length;
    }
    return best;
  }

  function collect(card) {
    var found = new Map();

    // Pass 1 - strict. Fraction, percentage and title together.
    var w = document.createTreeWalker(card, NodeFilter.SHOW_TEXT);
    var n;
    while ((n = w.nextNode())) {
      var m = exactFraction().exec(n.nodeValue || "");
      if (!m) continue;
      var host = n.parentElement;
      if (!host || host.closest(OURS)) continue;
      var a = +m[1], t = +m[2];
      if (a > t) continue;
      var row = findRow(host);
      if (!row || found.has(row)) continue;
      found.set(row, { a: a, t: t });
    }

    // Pass 2 - learn the row shape, sweep siblings pass 1 skipped. Catches a
    // newly registered subject rendering as "0/0" with a dash for the percentage.
    var shapes = new Map();
    found.forEach(function (v, r) {
      var p = r.parentElement;
      if (!p) return;
      if (!shapes.has(p)) shapes.set(p, new Set());
      shapes.get(p).add(rowShape(r));
    });
    shapes.forEach(function (sigs, p) {
      var kids = Array.prototype.slice.call(p.children);
      for (var i = 0; i < kids.length; i++) {
        var c = kids[i];
        if (found.has(c) || !sigs.has(rowShape(c))) continue;
        var txt = c.textContent || "";
        if (!/[A-Za-z]{4,}/.test(txt)) continue;
        var m2 = oneFraction().exec(txt);
        if (!m2) continue;
        var a2 = +m2[1], t2 = +m2[2];
        if (a2 > t2) continue;
        found.set(c, { a: a2, t: t2 });
      }
    });

    var rows = Array.from(found.keys()).sort(function (x, y) {
      return (x.compareDocumentPosition(y) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1;
    });

    // Two subjects can legitimately share a title. Keep the keys distinct so
    // the aggregate never silently collapses them into one.
    var used = new Map();
    return rows.map(function (r) {
      var d = found.get(r);
      var name = findNameNode(r) || "Subject";
      var seen = (used.get(name) || 0) + 1;
      used.set(name, seen);
      return {
        subject: name,
        key: seen > 1 ? name + " #" + seen : name,
        attended: d.a,
        total: d.t,
      };
    });
  }

  var card = findCard();
  var rows = card ? collect(card) : [];
  return JSON.stringify({
    ok: rows.length > 0,
    rows: rows,
    route: location.pathname,
    cardFound: !!card
  });
})();`;

const SES_SCRAPER = `

(function () {
  var TIME = /(\\d{1,2}:\\d{2}\\s*[AP]\\.?M\\.?)\\s*[-\\u2013\\u2014]\\s*(\\d{1,2}:\\d{2}\\s*[AP]\\.?M\\.?)/i;
  var TIME_G = function () { return /(\\d{1,2}:\\d{2}\\s*[AP]\\.?M\\.?)\\s*[-\\u2013\\u2014]\\s*(\\d{1,2}:\\d{2}\\s*[AP]\\.?M\\.?)/gi; };
  var clean = function (t) { return String(t == null ? '' : t).replace(/\\s+/g, ' ').trim(); };

  function findRow(host) {
    var el = host;
    for (var i = 0; i < 12 && el && el !== document.body; i++) {
      var txt = el.textContent || '';
      var c = (txt.match(TIME_G()) || []).length;
      if (c > 1) return null;
      // Keep climbing until the element actually holds a subject name. Testing
      // for any 4-letter run stops one level too early, because "Room" passes.
      if (c === 1 && nameOf(el)) return el;
      el = el.parentElement;
    }
    return null;
  }

  // The subject name is the longest text node that is not the time, the room,
  // the online-classroom link, or the colour-key legend.
  function nameOf(row) {
    var w = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
    var best = null, len = 0, n;
    while ((n = w.nextNode())) {
      var t = clean(n.nodeValue);
      if (!t || t.length <= len) continue;
      if (!/[A-Za-z]{4,}/.test(t)) continue;
      if (TIME.test(t)) continue;
      if (/^room\\s*:/i.test(t)) continue;
      if (/online classroom/i.test(t)) continue;
      if (/^(class room|hybrid class room|virtual class room)$/i.test(t)) continue;
      best = t; len = t.length;
    }
    return best;
  }

  var found = new Map();
  var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  var n;
  while ((n = w.nextNode())) {
    var m = TIME.exec(clean(n.nodeValue || ''));
    if (!m) continue;
    var row = n.parentElement && findRow(n.parentElement);
    if (!row || found.has(row)) continue;
    found.set(row, { start: clean(m[1]), end: clean(m[2]) });
  }

  var rows = Array.from(found.keys()).sort(function (x, y) {
    return (x.compareDocumentPosition(y) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1;
  });

  var out = rows.map(function (r) {
    var d = found.get(r);
    var txt = clean(r.textContent || '');

    var room = null;
    var rm = txt.match(/room\\s*:\\s*([^\\s].*?)\\s*$/i);
    if (rm) {
      room = rm[1];
      // The portal prints the room twice, as "11213(11213)". Keep one.
      var dup = room.match(/^(.+?)\\s*\\(\\s*\\1\\s*\\)$/);
      if (dup) room = dup[1];
    }

    var online = /online classroom/i.test(txt);

    // The left bar colour is the only place the room type is encoded, so read
    // it off the computed style rather than guessing from the room number.
    var mode = 'class';
    try {
      if (online) throw 0;
      var probe = [r].concat(Array.prototype.slice.call(r.querySelectorAll('*')));
      for (var i = 0; i < probe.length; i++) {
        var cs = getComputedStyle(probe[i]);
        var col = cs.borderLeftColor || '';
        var bg = cs.backgroundColor || '';
        var c = /rgb/.test(col) && parseFloat(cs.borderLeftWidth) > 1 ? col : null;
        if (!c && /rgb/.test(bg) && probe[i].offsetWidth > 0 && probe[i].offsetWidth <= 8) c = bg;
        if (!c) continue;
        var p = c.match(/(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)/);
        if (!p) continue;
        var R = +p[1], G = +p[2], B = +p[3];
        if (R > 180 && B < 160 && G < 120) { mode = 'virtual'; break; }
        if (R > 180 && G > 140 && B < 110) { mode = 'hybrid'; break; }
        if (B > 100 && B > R) { mode = 'class'; break; }
      }
    } catch (e) {}
    if (online) mode = 'virtual';

    return {
      subject: nameOf(r) || 'Class',
      start: d.start.toUpperCase().replace(/\\./g, ''),
      end: d.end.toUpperCase().replace(/\\./g, ''),
      room: room,
      online: online,
      mode: mode
    };
  });

  return JSON.stringify({ ok: out.length > 0, sessions: out });
})();`;

/* =========================================================== 5. portal === */

function openPortal() {
  const IAB = window.cordova && window.cordova.InAppBrowser;
  if (!IAB) throw new Error('Portal browser unavailable. Try reinstalling.');
  return IAB.open(
    CFG.loginURL,
    '_blank',
    'location=yes,toolbar=yes,hidden=no,clearcache=no,clearsessioncache=no,' +
      'closebuttoncaption=Done,beforeload=no'
  );
}

function evalIn(ref, code) {
  return new Promise((resolve, reject) => {
    try {
      ref.executeScript({ code }, v => resolve(Array.isArray(v) ? v[0] : v));
    } catch (e) {
      reject(e);
    }
  });
}

async function readOnce(ref) {
  const out = { att: null, ses: [] };
  try {
    out.att = JSON.parse(String(await evalIn(ref, ATT_SCRAPER)));
  } catch (e) {
    out.att = null;
  }
  try {
    const s = JSON.parse(String(await evalIn(ref, SES_SCRAPER)));
    if (s && s.ok) out.ses = s.sessions;
  } catch (e) {
    out.ses = [];
  }
  return out;
}

// The cards populate well after the document finishes loading, so read
// repeatedly and settle only once the attendance rows stop changing.
async function scrapeUntilSettled(ref, onTick) {
  let lastSig = '';
  let stable = 0;
  let last = null;

  for (let i = 1; i <= CFG.maxTries; i++) {
    await new Promise(r => setTimeout(r, CFG.pollMs));
    const res = await readOnce(ref);
    if (!res.att) continue;
    last = res;

    const sig = res.att.rows.map(r => `${r.key}:${r.attended}/${r.total}`).join(',');
    stable = res.att.rows.length && sig === lastSig ? stable + 1 : 0;
    lastSig = sig;

    if (onTick) onTick(res);
    if (res.att.rows.length && stable >= 2) return res;
  }
  return last;
}

async function refresh() {
  closeMenu();
  say('Log in and solve the captcha. Wait for the dashboard, then tap Done.');

  let ref;
  try {
    ref = openPortal();
  } catch (e) {
    say(e.message);
    return;
  }

  let got = null;
  let closed = false;
  ref.addEventListener('exit', () => {
    closed = true;
  });

  // Poll while the dialog is still open, so the read is usually finished by the
  // time it closes.
  const poll = (async () => {
    while (!closed) {
      await new Promise(r => setTimeout(r, 500));
      let path = '';
      try {
        path = String(await evalIn(ref, 'location.pathname'));
      } catch (e) {
        continue;
      }
      if (!CFG.dashboardRoute.test(path)) continue;

      const res = await scrapeUntilSettled(ref, r =>
        say(`Reading the dashboard. ${r.att.rows.length} subjects so far.`)
      );
      if (res && res.att && res.att.ok) {
        got = res;
        try {
          ref.close();
        } catch (e) {}
        return;
      }
    }
  })();

  await new Promise(r => ref.addEventListener('exit', r));
  closed = true;
  await poll.catch(() => {});

  if (!got) {
    say(
      STATE.data
        ? 'Could not read the dashboard. Showing what was saved earlier.'
        : 'Could not read the dashboard. Check the login went through, and that the page had finished loading before you tapped Done.'
    );
    return;
  }

  STATE.data = { savedAt: Date.now(), rows: got.att.rows, sessions: got.ses };
  await save(STATE.data);
  say('');
  paint();
}

/* ========================================================== 6. storage === */

const KEY = 'today.v1';
const Prefs = () => ((window.Capacitor && window.Capacitor.Plugins) || {}).Preferences;

async function save(data) {
  const value = JSON.stringify(data);
  const p = Prefs();
  if (p) await p.set({ key: KEY, value });
  else localStorage.setItem(KEY, value);
}

async function load() {
  try {
    const p = Prefs();
    const raw = p ? (await p.get({ key: KEY })).value : localStorage.getItem(KEY);
    return raw ? JSON.parse(raw) : null;
  } catch (e) {
    return null;
  }
}

/* ============================================================ 7. views ===
 * One function per screen. Each takes the shaped day plus the attendance
 * summary and returns a string of HTML, and knows nothing about the others.
 */

const $ = id => document.getElementById(id);
const esc = s =>
  String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const trim = (s, n) => (String(s).length > n ? String(s).slice(0, n - 1) + '…' : String(s));

const STATE = { route: 'today', data: null };

function say(msg) {
  const el = $('status');
  el.textContent = msg || '';
  el.hidden = !msg;
}

function ageText(savedAt) {
  const h = (Date.now() - savedAt) / 36e5;
  if (h < 1) return 'Updated just now';
  if (h < 24) return `Updated ${Math.round(h)}h ago`;
  return `Updated ${Math.round(h / 24)}d ago`;
}

function bar(pct, lo) {
  return `<span class="bar${lo ? ' lo' : ''}"><i style="width:${Math.max(
    0,
    Math.min(100, pct)
  )}%"></i></span>`;
}

// Hero is the room, because that is what you need while walking to it. The
// number under it is that subject's own slack, not the aggregate.
function viewToday(day) {
  const hero = day.find(s => s.live) || day.find(s => s.next);
  if (!hero) {
    return `<div class="empty">${
      day.length
        ? 'That was the last class for today. Nothing left to walk to.'
        : 'No classes listed for today.'
    }</div>`;
  }

  const nowMin = new Date().getHours() * 60 + new Date().getMinutes();
  const mins = hero.live ? hero.s1 - nowMin : hero.s0 - nowMin;
  const when = hero.live
    ? `Ends ${hhmm(hero.s1)}${ampm(hero.s1)}, ${mins} min left`
    : mins < 60
      ? `Starts ${hhmm(hero.s0)}${ampm(hero.s0)}, in ${mins} min`
      : `Starts ${hhmm(hero.s0)}${ampm(hero.s0)}`;

  const a = hero.att;
  const own = !a
    ? `<div class="own"><div class="c">No attendance row matches this class.</div></div>`
    : `<div class="own ${a.state === 'short' ? 'lo' : ''}">
        <div class="r1">
          <span class="n">${a.state === 'empty' ? '—' : a.state === 'short' ? '+' + a.v : a.v}</span>
          <span class="c">${
            a.state === 'empty'
              ? 'no classes held in this subject yet'
              : a.state === 'short'
                ? `to attend before this subject clears ${CFG.threshold}%`
                : a.v === 0
                  ? 'no room left in this subject'
                  : 'more you can skip in this subject'
          }</span>
        </div>
        <div class="r2">
          ${bar(a.pct, a.state === 'short')}
          <span class="pc">${a.pct.toFixed(0)}% · ${a.attended}/${a.total}</span>
        </div>
      </div>`;

  const caps = day
    .map(
      s => `<div class="cp ${s.live ? 'on' : ''} ${s.past ? 'was' : ''}">
        <b>${hhmm(s.s0)}</b><span>${s.online ? 'online' : esc(s.room || '—')}</span></div>`
    )
    .join('');

  return `
    <div class="big">
      <div class="tag ${hero.live ? '' : 'soon'}"><i></i>${hero.live ? 'In class now' : 'Up next'}</div>
      <div class="rm ${hero.online ? 'word' : ''}">${
        hero.online ? 'Online' : esc(hero.room || 'No room')
      }</div>
      <div class="sj">${esc(hero.subject)}</div>
      <div class="mt">${when}</div>
      ${own}
    </div>
    <div class="caps">${caps}</div>`;
}

function viewTimetable(day) {
  if (!day.length) return `<div class="empty">No classes listed for today.</div>`;
  const nowMin = new Date().getHours() * 60 + new Date().getMinutes();
  const left = day.filter(s => !s.past).length;

  return `
    <div class="ttl">
      <h2>${new Date().toLocaleDateString(undefined, { weekday: 'long' })}</h2>
      <p>${day.length} ${day.length === 1 ? 'class' : 'classes'}, ${
        left ? left + ' still to come' : 'all done'
      }</p>
    </div>
    ${day
      .map(s => {
        const slack = s.att
          ? s.att.state === 'empty'
            ? ''
            : s.att.state === 'short'
              ? ` · needs ${s.att.v}`
              : ` · ${s.att.v} to spare`
          : '';
        return `
        <div class="lb ${s.live ? 'on' : ''} ${s.past ? 'was' : ''} ${
          !s.live && !s.past && s.mode === 'virtual' ? 'vr' : ''
        }">
          <div class="lb-l">
            <span class="lb-t">${hhmm(s.s0)}<i>${ampm(s.s0)}</i></span>
            ${s.live ? `<span class="lb-n">${s.s1 - nowMin} min left</span>` : ''}
          </div>
          <div>
            <span class="lb-s">${esc(s.subject)}</span>
            <span class="lb-w">${
              s.online ? 'Online classroom' : 'Room ' + esc(s.room || 'not listed')
            }${slack}</span>
          </div>
        </div>`;
      })
      .join('')}`;
}

function viewAttendance(sum) {
  if (!sum.subjects.length) return `<div class="empty">No attendance data saved yet.</div>`;
  const o = sum.overall;
  const worst = sum.failing[0];

  return `
    <div class="ttl">
      <h2>${o.state === 'short' ? '+' + o.v : o.v} ${o.state === 'short' ? 'to attend' : 'to spare'}</h2>
      <p>${o.attended} of ${o.total} attended, ${o.pct.toFixed(1)}% overall</p>
    </div>
    ${
      worst
        ? `<div class="callout lo">
            <div class="n">+${worst.v}</div>
            <div class="c">${esc(worst.key)} is the one holding you back. It needs ${
              worst.v
            } ${worst.v === 1 ? 'class' : 'classes'} in a row to clear ${CFG.threshold}%.</div>
          </div>`
        : ''
    }
    ${sum.subjects
      .map(s => {
        const lo = s.state === 'short';
        const idle = s.state === 'empty';
        return `
        <div class="ab ${lo ? 'lo' : ''} ${idle ? 'idle' : ''}">
          <div class="r1">
            <span class="nm">${esc(s.key)}</span>
            <span class="v">${idle ? '—' : lo ? '+' + s.v : s.v}</span>
          </div>
          <div class="r2">
            ${bar(idle ? 0 : s.pct, lo)}
            <span class="mt2">${
              idle ? 'not started' : `${s.pct.toFixed(0)}% · ${s.attended}/${s.total}`
            }</span>
          </div>
        </div>`;
      })
      .join('')}`;
}

/* ---- drawer ---- */

const GLYPHS = {
  today: `<span class="glyph"><i style="width:16px;height:16px;border-radius:999px"></i></span>`,
  timetable: `<span class="glyph" style="flex-wrap:wrap;width:18px"><i style="width:7px;height:7px"></i><i style="width:7px;height:7px"></i><i style="width:7px;height:7px"></i><i style="width:7px;height:7px"></i></span>`,
  attendance: `<span class="glyph" style="align-items:flex-end"><i style="width:4px;height:9px"></i><i style="width:4px;height:16px"></i><i style="width:4px;height:12px"></i></span>`,
  refresh: `<span class="glyph"><i style="width:15px;height:15px;border-radius:999px;background:none;box-shadow:inset 0 0 0 2.5px var(--ink-2)"></i></span>`,
};

function paintDrawer(day, sum) {
  const o = sum.overall;
  const worst = sum.failing[0];

  $('nav').innerHTML = `
    <button class="nv ${STATE.route === 'today' ? 'sel' : ''}" data-go="today">
      ${GLYPHS.today}Today</button>
    <button class="nv ${STATE.route === 'timetable' ? 'sel' : ''}" data-go="timetable">
      ${GLYPHS.timetable}Timetable${day.length ? `<em>${day.length}</em>` : ''}</button>
    <button class="nv ${STATE.route === 'attendance' ? 'sel' : ''}" data-go="attendance">
      ${GLYPHS.attendance}Attendance${
        sum.subjects.length ? `<em>${o.pct.toFixed(0)}%</em>` : ''
      }</button>
    <button class="nv" data-act="refresh" style="margin-top:14px">
      ${GLYPHS.refresh}Refresh from portal</button>`;

  const initials = 'SS';
  $('initials').textContent = sum.subjects.length ? initials : '·';

  $('drawfoot').className = 'drawfoot' + (worst ? ' lo' : '');
  $('drawfoot').innerHTML = !sum.subjects.length
    ? `<div class="c">Nothing saved yet. Tap refresh and log in.</div>`
    : `<div class="n">${worst ? '+' + worst.v : o.v}</div>
       <div class="c">${
         worst
           ? `${esc(trim(worst.key, 22))} is below ${CFG.threshold}% and needs ${worst.v} in a row`
           : 'classes you can skip across everything'
       }</div>
       <div class="age">${ageText(STATE.data.savedAt)}</div>`;
}

/* =========================================================== 8. router === */

function openMenu() {
  document.body.classList.add('menu');
}
function closeMenu() {
  document.body.classList.remove('menu');
}

function paint() {
  const d = STATE.data;

  if (!d || !d.rows || !d.rows.length) {
    $('title').textContent = 'Today';
    $('sub').textContent = '';
    $('view').className = 'view';
    $('view').innerHTML = `<div class="empty">Nothing saved yet. Open the menu and tap refresh, then log in — today's classes and your attendance land here.</div>`;
    paintDrawer([], summarise([]));
    return;
  }

  const now = new Date();
  const day = shapeDay(d.sessions, d.rows, now.getHours() * 60 + now.getMinutes());
  const sum = summarise(d.rows);

  const titles = {
    today: now.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' }),
    timetable: 'Timetable',
    attendance: 'Attendance',
  };
  $('title').textContent = titles[STATE.route];

  const left = day.filter(s => !s.past).length;
  $('sub').textContent =
    STATE.route === 'attendance'
      ? `${sum.overall.pct.toFixed(1)}%`
      : STATE.route === 'timetable'
        ? 'Today'
        : left
          ? `${left} left`
          : 'done';

  const v = $('view');
  v.className = 'view' + (STATE.route === 'today' ? '' : ' scrolls');
  v.scrollTop = 0;
  v.innerHTML =
    STATE.route === 'timetable'
      ? viewTimetable(day)
      : STATE.route === 'attendance'
        ? viewAttendance(sum)
        : viewToday(day);

  paintDrawer(day, sum);

  if ((Date.now() - d.savedAt) / 36e5 > CFG.staleAfterHours) {
    say('This is saved from earlier. Refresh to bring it up to date.');
  }
}

function go(route) {
  STATE.route = route;
  closeMenu();
  paint();
}

async function boot() {
  $('menu').addEventListener('click', openMenu);
  $('scrim').addEventListener('click', closeMenu);

  $('nav').addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b) return;
    if (b.dataset.go) go(b.dataset.go);
    else if (b.dataset.act === 'refresh') refresh().catch(err => say(err.message));
  });

  STATE.data = await load();
  paint();
}

document.addEventListener('deviceready', boot, { once: true });
// Plain Safari, for checking the interface without a build.
if (!window.cordova) setTimeout(boot, 0);
