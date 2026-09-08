import Foundation

/// The two page scrapers, verbatim from the tested JavaScript.
///
/// Held in Swift raw string literals so the regex backslashes survive; a
/// normal string literal would reject the escapes outright.
///
/// Neither uses CSS selectors. The attendance card is not a `<table>` and the
/// sessions card has no stable classes, so rows are found by walking text nodes
/// for a distinctive string — "24/28" for attendance, "09:00 AM - 09:55 AM" for
/// sessions — then climbing to the element that contains it. Each returns a
/// JSON string, which is what `evaluateJavaScript` hands back.
enum Scrapers {

    static let attendance = #"""
(function () {
  var OURS = ".arw-badge, .arw-overall";
  var PCT_RE = /\d+(?:\.\d+)?\s*%/;
  var allFractions = function () { return /(\d{1,3})\s*\/\s*(\d{1,3})/g; };
  var oneFraction  = function () { return /(\d{1,3})\s*\/\s*(\d{1,3})/; };
  var exactFraction = function () { return /^\s*(\d{1,3})\s*\/\s*(\d{1,3})\s*$/; };
  var clean = function (t) { return String(t == null ? "" : t).replace(/\s+/g, " ").trim(); };

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
    return el.tagName + "|" + (el.getAttribute("class") || "").trim().replace(/\s+/g, " ");
  }

  // A leading digit is not disqualifying: "3D Modelling and Animation"
  // is an ordinary subject name.
  function isLabel(t) {
    if (!/[A-Za-z]{4,}/.test(t)) return false;
    if (exactFraction().test(t)) return false;
    if (/^\d+(?:\.\d+)?\s*%?$/.test(t)) return false;
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
})()
"""#

    static let sessions = #"""
(function () {
  var TIME = /(\d{1,2}:\d{2}\s*[AP]\.?M\.?)\s*[-\u2013\u2014]\s*(\d{1,2}:\d{2}\s*[AP]\.?M\.?)/i;
  var TIME_G = function () { return /(\d{1,2}:\d{2}\s*[AP]\.?M\.?)\s*[-\u2013\u2014]\s*(\d{1,2}:\d{2}\s*[AP]\.?M\.?)/gi; };
  var clean = function (t) { return String(t == null ? '' : t).replace(/\s+/g, ' ').trim(); };

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
      if (/^room\s*:/i.test(t)) continue;
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
    var rm = txt.match(/room\s*:\s*([^\s].*?)\s*$/i);
    if (rm) {
      room = rm[1];
      // The portal prints the room twice, as "11213(11213)". Keep one.
      var dup = room.match(/^(.+?)\s*\(\s*\1\s*\)$/);
      if (dup) room = dup[1];
    }

    var online = /online classroom/i.test(txt);

    // The join link is usually an <a href>, but the portal sometimes puts the
    // URL in an onclick or a data attribute instead, so try all three.
    var link = null;
    var anchors = r.querySelectorAll('a');
    for (var ai = 0; ai < anchors.length && !link; ai++) {
      var href = anchors[ai].getAttribute('href') || '';
      if (/^https?:/i.test(href)) { link = href; break; }
      var attrs = anchors[ai].attributes;
      for (var x = 0; x < attrs.length; x++) {
        var hit = String(attrs[x].value || '').match(/https?:\/\/[^'"\s)]+/);
        if (hit) { link = hit[0]; break; }
      }
    }
    if (!link) {
      var loose = txt.match(/https?:\/\/[^\s'"<>]+/);
      if (loose) link = loose[0];
    }

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
        var p = c.match(/(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
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
      start: d.start.toUpperCase().replace(/\./g, ''),
      end: d.end.toUpperCase().replace(/\./g, ''),
      room: room,
      online: online,
      mode: mode,
      link: link
    };
  });

  return JSON.stringify({ ok: out.length > 0, sessions: out });
})()
"""#

    /// The student's own name, for the header. Tries a greeting first, then a
    /// title-case name in the nav area. Returns nothing rather than guessing
    /// wrong, and the header falls back to "Today".
    /// The name lives on the profile page, not the dashboard, printed as
    /// "Shreyansh Singhal (590011979)". That parenthesised SAP ID is a far
    /// stronger anchor than guessing at title-case text in the nav. Only the
    /// name is kept; the ID is discarded.
    static let student = #"""
(function () {
  var clean = function (t) { return String(t == null ? '' : t).replace(/\s+/g, ' ').trim(); };
  var body = document.body ? (document.body.innerText || document.body.textContent || '') : '';
  var lines = body.split(/[\r\n]+/);

  for (var i = 0; i < lines.length; i++) {
    var m = clean(lines[i]).match(/^(.{2,48}?)\s*\(\s*(\d{6,12})\s*\)\s*$/);
    if (!m) continue;
    var name = clean(m[1]);
    if (!/^[A-Za-z][A-Za-z'.\- ]+$/.test(name)) continue;
    return JSON.stringify({ ok: true, name: name });
  }

  // Same pattern, but inside a single element rather than on its own line.
  var els = document.querySelectorAll('h1,h2,h3,h4,h5,b,strong,span,div,p');
  for (var j = 0; j < els.length; j++) {
    if (els[j].children.length) continue;
    var t = clean(els[j].textContent);
    var n = t.match(/^(.{2,48}?)\s*\(\s*(\d{6,12})\s*\)\s*$/);
    if (n && /^[A-Za-z][A-Za-z'.\- ]+$/.test(clean(n[1]))) {
      return JSON.stringify({ ok: true, name: clean(n[1]) });
    }
  }

  return JSON.stringify({ ok: false, name: null });
})()
"""#

    /// The whole visible week off the curriculum-scheduling page, in Agenda
    /// mode. That view only ever shows six days from today, which is fine: rows
    /// are keyed by date and merged into the cache, so repeated refreshes
    /// accumulate rather than overwrite.
    static let week = #"""
(function () {
  var clean = function (t) { return String(t == null ? '' : t).replace(/\s+/g, ' ').trim(); };
  var TIME = /(\d{1,2}):(\d{2})\s*[-\u2013\u2014]\s*(\d{1,2}):(\d{2})/;
  var MON = { jan:1, feb:2, mar:3, apr:4, may:5, jun:6, jul:7, aug:8, sep:9, oct:10, nov:11, dec:12 };
  var DAY = /(\d{1,2})\s*(Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day\s*([A-Za-z]{3,9})\.?,?\s*(\d{4})/;
  var VIRTUAL = /teams|zoom|webex|meet\.google|google\s*meet|online|virtual/i;

  // The agenda prints 24h times; normalise to the same "09:00 AM" shape the
  // dashboard card uses so downstream parsing stays identical.
  var ampm = function (h, m) {
    var suffix = h < 12 ? 'AM' : 'PM';
    var hh = h % 12; if (hh === 0) hh = 12;
    return (hh < 10 ? '0' + hh : hh) + ':' + m + ' ' + suffix;
  };

  var pad = function (n) { return n < 10 ? '0' + n : String(n); };

  var iso = function (d, monName, y) {
    var mo = MON[String(monName).slice(0, 3).toLowerCase()];
    if (!mo) return null;
    // Pad the number, not the string: "08" would otherwise become "008".
    return y + '-' + pad(mo) + '-' + pad(+d);
  };

  // The subject is the first <p> in the event cell. The cell also holds
  // "Room :...", "Meeting Link : Link", the faculty name and the cohort code,
  // and the cohort code is *longer* than the subject - so picking the longest
  // text node (the old approach) reliably picked the wrong one.
  function subjectOf(ev) {
    var ps = ev.querySelectorAll('p');
    for (var j = 0; j < ps.length; j++) {
      var t = clean(ps[j].textContent);
      if (!t || !/[A-Za-z]{4,}/.test(t)) continue;
      if (/^room\s*:/i.test(t)) continue;
      if (/^meeting\s*link/i.test(t)) continue;
      return t;
    }
    // No <p> at all: take the cell text up to where the details start.
    var t2 = clean(ev.textContent).replace(/\s*Room\s*:[\s\S]*$/i, '');
    return /[A-Za-z]{4,}/.test(t2) ? t2 : null;
  }

  function linkOf(tr) {
    var a = tr.querySelector('a.meeting-link[href]') || tr.querySelector('a[href^="http"]');
    if (a) return a.getAttribute('href');
    // Some rows put the URL in an onclick or a data attribute instead.
    var all = tr.querySelectorAll('a');
    for (var i = 0; i < all.length; i++) {
      var at = all[i].attributes;
      for (var x = 0; x < at.length; x++) {
        var g = String(at[x].value || '').match(/https?:\/\/[^'"\s)]+/);
        if (g) return g[0];
      }
    }
    return null;
  }

  var out = [];
  var current = null;
  var sample = null;
  var rows = document.querySelectorAll('tr');

  for (var i = 0; i < rows.length; i++) {
    var tr = rows[i];

    // The agenda is a table of tables. The outer wrapper rows contain every
    // inner row, so their text spans the whole week and parses as one giant
    // bogus entry dated to the first day found. A row holding another row is
    // never a data row.
    if (tr.querySelector('tr')) continue;

    var whole = clean(tr.textContent);

    // A date cell carries a rowspan, so it appears on the first row of its day
    // and the rest of that day's rows inherit it.
    var dm = whole.match(DAY);
    if (dm) {
      var d = iso(dm[1], dm[3], dm[4]);
      if (d) current = d;
    }

    var tds = tr.querySelectorAll('td');
    if (!tds.length || !current) continue;

    var timeCell = null;
    for (var c = 0; c < tds.length; c++) {
      var ct = clean(tds[c].textContent);
      if (TIME.test(ct)) { timeCell = ct; break; }
    }
    if (!timeCell) continue;

    var tm = timeCell.match(TIME);
    var start = ampm(+tm[1], tm[2]);
    var end = ampm(+tm[3], tm[4]);

    // The event cell is whichever cell holds the task block; fall back to the
    // last cell in the row.
    var task = tr.querySelector('.k-task');
    var ev = (task && task.closest('td')) || tds[tds.length - 1];

    // Free periods have a time but no subject, so they drop out here.
    var subject = subjectOf(ev);
    if (!subject) continue;

    var link = linkOf(tr);

    // "Room :11114" for a physical room, "Room :MS Teams" for a virtual one.
    // This page never says "Online Classroom" - that wording is the dashboard
    // card's - so keying off the room text is what actually works here.
    var det = ev.querySelector('.event-room-details') || ev;
    var rm = clean(det.textContent).match(/room\s*:\s*(.*?)(?:\s*meeting\s*link|$)/i);
    var roomText = rm ? clean(rm[1]) : null;

    var virtualRoom = VIRTUAL.test(roomText || '');
    var online = virtualRoom || (!!link && !/\d{3}/.test(roomText || ''));
    var room = (!roomText || virtualRoom) ? null : roomText;
    if (room) {
      var dup = room.match(/^(.+?)\s*\(\s*\1\s*\)$/);
      if (dup) room = dup[1];
    }

    if (!sample) sample = [subject, start, roomText || '', link ? 'link' : 'no-link'];

    out.push({
      date: current,
      subject: subject,
      start: start,
      end: end,
      room: room,
      online: !!online,
      mode: online ? 'virtual' : 'class',
      link: link
    });
  }

  // Same slot can appear twice if the table repeats headers.
  var seen = {};
  var uniq = [];
  for (var k = 0; k < out.length; k++) {
    var key = out[k].date + '|' + out[k].start + '|' + out[k].subject;
    if (seen[key]) continue;
    seen[key] = 1;
    uniq.push(out[k]);
  }

  // When nothing parses, report enough to tell which assumption broke rather
  // than just returning empty.
  var days = {};
  for (var z = 0; z < uniq.length; z++) days[uniq[z].date] = 1;

  // Which view the scheduler is actually in is the single most useful fact
  // when this comes back empty, so it goes in the diagnostic first.
  var view = 'none';
  if (document.querySelector('.k-scheduler-agendaview')) view = 'agenda';
  else if (document.querySelector('.k-scheduler-monthview')) view = 'month';
  else if (document.querySelector('.k-scheduler-timesview, .k-scheduler-dayview')) view = 'day/week';
  else if (document.querySelector('kendo-scheduler, .k-scheduler')) view = 'scheduler-other';

  var diag = 'view=' + view + ' tasks=' + document.querySelectorAll('.k-task').length
    + ' rows=' + rows.length + ' parsed=' + uniq.length
    + ' days=' + Object.keys(days).length + ' lastDate=' + (current || 'none')
    + ' at=' + location.pathname;
  if (!uniq.length) {
    var firstRows = [];
    for (var q = 0; q < rows.length && firstRows.length < 4; q++) {
      var t = clean(rows[q].textContent);
      if (t) firstRows.push(t.slice(0, 80));
    }
    diag += ' | ' + firstRows.join(' // ');
  }
  return JSON.stringify({
    ok: uniq.length > 0,
    sessions: uniq,
    sample: sample,
    diag: diag,
    tasks: document.querySelectorAll('.k-task').length,
    view: view
  });
})()
"""#

    /// Builds the week from the timetable API payload the page already
    /// fetched, rather than from rendered HTML.
    ///
    /// The scheduler requests `POST /apigateway/api/timetable`, gets a ~1.1MB
    /// JSON array back with a 200, and then renders nothing - the DOM scrape
    /// was reading a table that was never going to fill in. The spy stashes
    /// that array on `window.__ttData`; this turns it into sessions.
    ///
    /// Field names are matched by shape rather than hardcoded, because the
    /// only sample available was the first 200 bytes of the response. The
    /// diagnostic reports the keys it actually saw so a mismatch is
    /// immediately visible instead of silent.
    static let weekApi = #"""
(function () {
  var D = window.__ttData;
  if (!D) {
    return JSON.stringify({
      ok: false,
      sessions: [],
      diag: 'api=none' + (window.__ttErr ? (' parseErr=' + window.__ttErr) : '')
    });
  }

  var arr = D;
  if (!Array.isArray(arr)) {
    arr = D.Items || D.Item || D.Data || D.data || D.Result || null;
  }
  if (!Array.isArray(arr)) {
    return JSON.stringify({ ok: false, sessions: [], diag: 'api=not-array keys=' + Object.keys(D).slice(0, 12).join(',') });
  }

  var pad = function (n) { return n < 10 ? '0' + n : String(n); };
  var clean = function (t) { return String(t == null ? '' : t).replace(/\s+/g, ' ').trim(); };

  var ISO = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?/;
  // Times are read out of the string directly rather than through Date(),
  // which would shift them by the device's timezone offset.
  var ampm = function (h, m) {
    var hh = h % 12; if (hh === 0) hh = 12;
    return pad(hh) + ':' + pad(m) + ' ' + (h < 12 ? 'AM' : 'PM');
  };

  // Only the near future is worth caching; the payload covers the whole term.
  var now = new Date();
  var todayIso = now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate());
  var horizon = new Date(now.getTime() + 14 * 86400000);
  var maxIso = horizon.getFullYear() + '-' + pad(horizon.getMonth() + 1) + '-' + pad(horizon.getDate());

  function flat(o, out, path, depth) {
    if (o == null || depth > 3) return;
    if (typeof o !== 'object') { out.push([path, o]); return; }
    if (Array.isArray(o)) {
      for (var i = 0; i < o.length && i < 4; i++) flat(o[i], out, path + '[]', depth + 1);
      return;
    }
    for (var k in o) {
      if (!Object.prototype.hasOwnProperty.call(o, k)) continue;
      flat(o[k], out, path ? path + '.' + k : k, depth + 1);
    }
  }

  // Anything describing the room, the teacher or the cohort is not the
  // subject, and cohort codes are longer than subject names so they win any
  // "pick the longest" contest. Hence an explicit deny-list.
  var NOT_SUBJECT = /venue|faculty|teacher|employee|grade|batch|cohort|section|room|floor|building|block|campus|event|slot|status|type|category|program|school|department/i;

  function pick(pairs) {
    var byDate = [], link = null, venue = null, category = null;
    var subj = [null, null, null, null];

    for (var i = 0; i < pairs.length; i++) {
      var path = pairs[i][0], v = pairs[i][1];
      if (typeof v !== 'string') continue;
      var lower = path.toLowerCase();
      var key = lower.split('.').pop().replace(/\[\]/g, '');

      if (ISO.test(v)) { byDate.push([lower, v]); continue; }
      if (/^https?:\/\//i.test(v)) { if (!link) link = v; continue; }

      // Venue first: room numbers like "11114" carry no letters and would be
      // thrown away by the letters test below.
      if (key === 'venuename' || key === 'venuecode') { if (!venue) venue = v; continue; }
      if (key.indexOf('venuecategory') === 0) { if (!category) category = v; continue; }

      if (!/[A-Za-z]{3,}/.test(v)) continue;

      if (NOT_SUBJECT.test(lower)) continue;
      if (lower.indexOf('course') > -1 && /name|title/.test(key)) { subj[0] = subj[0] || v; }
      else if (/^(subject|subjectname|papername|coursetitle|coursename)$/.test(key)) { subj[1] = subj[1] || v; }
      else if (lower.indexOf('course') > -1 && key === 'name') { subj[2] = subj[2] || v; }
      else if (key === 'name' || key === 'title') { subj[3] = subj[3] || v; }
    }

    var subject = subj[0] || subj[1] || subj[2] || subj[3];

    // Prefer keys that say so; otherwise take the two earliest timestamps.
    var st = null, en = null;
    for (var j = 0; j < byDate.length; j++) {
      var p2 = byDate[j][0];
      if (!st && /start|from|begin/.test(p2)) st = byDate[j][1];
      if (!en && /end|finish|to/.test(p2)) en = byDate[j][1];
    }
    if (!st || !en) {
      var sorted = byDate.map(function (x) { return x[1]; }).sort();
      if (!st) st = sorted[0] || null;
      if (!en) en = sorted.length > 1 ? sorted[sorted.length - 1] : null;
    }

    return { subject: subject, st: st, en: en, link: link, venue: venue, category: category };
  }

  var VIRTUAL = /virtual|online|teams|zoom|webex|meet/i;
  var out = [];

  for (var i = 0; i < arr.length; i++) {
    var pairs = [];
    flat(arr[i], pairs, '', 0);
    var g = pick(pairs);
    if (!g.subject || !g.st) continue;

    var ms = g.st.match(ISO);
    if (!ms || ms[4] == null) continue;
    var date = ms[1] + '-' + ms[2] + '-' + ms[3];
    if (date < todayIso || date > maxIso) continue;

    var start = ampm(+ms[4], +ms[5]);
    var end = start;
    if (g.en) {
      var me = g.en.match(ISO);
      if (me && me[4] != null) end = ampm(+me[4], +me[5]);
    }

    var online = VIRTUAL.test(g.category || '') || VIRTUAL.test(g.venue || '');
    out.push({
      date: date,
      subject: clean(g.subject),
      start: start,
      end: end,
      room: online ? null : (g.venue ? clean(g.venue) : null),
      online: online,
      mode: online ? 'virtual' : 'class',
      link: g.link
    });
  }

  var seen = {}, uniq = [];
  for (var k = 0; k < out.length; k++) {
    var key2 = out[k].date + '|' + out[k].start + '|' + out[k].subject;
    if (seen[key2]) continue;
    seen[key2] = 1;
    uniq.push(out[k]);
  }
  uniq.sort(function (a, b) {
    return a.date === b.date ? (a.start < b.start ? -1 : 1) : (a.date < b.date ? -1 : 1);
  });

  var days = {};
  for (var z = 0; z < uniq.length; z++) days[uniq[z].date] = 1;

  var diag = 'api items=' + arr.length + ' parsed=' + uniq.length
    + ' days=' + Object.keys(days).length;
  if (!uniq.length) {
    var pairs0 = [];
    flat(arr[0], pairs0, '', 0);
    diag += ' | keys=' + pairs0.map(function (x) { return x[0]; }).slice(0, 26).join(',');
  } else {
    diag += ' first=' + uniq[0].date + ' ' + uniq[0].start + ' ' + uniq[0].subject.slice(0, 34);
  }

  return JSON.stringify({ ok: uniq.length > 0, sessions: uniq, diag: diag });
})()
"""#

    /// Records the page's own network calls so an empty scheduler can be
    /// explained instead of guessed at.
    ///
    /// The timetable renders correctly and reports zero events, which means
    /// the answer is in the request the page makes for them: whether it fires
    /// at all, what it returns, and what status. Angular's HttpClient goes
    /// through XMLHttpRequest, so that is the important patch; `fetch` is
    /// covered too in case anything else uses it.
    ///
    /// Install once per document - a hard reload wipes it.
    static let installSpy = #"""
(function () {
  if (window.__spyOn) return 'already';
  window.__spyOn = true;
  window.__spy = [];

  var keep = function (rec) {
    try { if (window.__spy.length < 60) window.__spy.push(rec); } catch (e) {}
  };

  var OX = window.XMLHttpRequest;
  if (OX) {
    window.XMLHttpRequest = function () {
      var x = new OX();
      var rec = { k: 'xhr', u: '', m: '', s: 0, n: 0, b: '' };
      var open = x.open;
      x.open = function (m, u) {
        rec.m = String(m || '');
        rec.u = String(u || '');
        return open.apply(x, arguments);
      };
      x.addEventListener('loadend', function () {
        try {
          rec.s = x.status;
          var t = '';
          try { t = x.responseText || ''; } catch (e) { t = '[not-text]'; }
          rec.n = t.length;
          rec.b = t.slice(0, 200);

          // This is the one that matters. The scheduler fetches the whole
          // timetable as JSON and then fails to render any of it, so the
          // payload is taken straight from the wire instead. Note the
          // negative lookahead: /api/timetable/masters is a different, tiny
          // response (the venue-category colour table).
          if (/\/api\/timetable(?:\?|$)/.test(rec.u)) {
            try { window.__ttData = JSON.parse(t); } catch (e2) { window.__ttErr = String(e2); }
          }
        } catch (e) {}
        keep(rec);
      });
      return x;
    };
  }

  var of = window.fetch;
  if (of) {
    window.fetch = function (input) {
      var u = (input && input.url) ? input.url : String(input);
      var pr = of.apply(this, arguments);
      pr.then(function (r) {
        var rec = { k: 'fetch', u: u, m: '', s: r.status, n: 0, b: '' };
        try {
          r.clone().text().then(function (t) {
            rec.n = t.length;
            rec.b = t.slice(0, 200);
          });
        } catch (e) {}
        keep(rec);
      }, function () {
        keep({ k: 'fetch', u: u, m: '', s: -1, n: 0, b: 'rejected' });
      });
      return pr;
    };
  }

  return 'installed';
})()
"""#

    /// Reads back the recorded calls, dropping assets, newest last. Also
    /// reports what date range the scheduler thinks it is showing, since a
    /// nonsense range would explain an empty result on its own.
    static let spyDump = #"""
(function () {
  var clean = function (t) { return String(t == null ? '' : t).replace(/\s+/g, ' ').trim(); };
  var log = window.__spy || [];
  var out = [];
  for (var i = 0; i < log.length; i++) {
    var u = log[i].u || '';
    if (/\.(js|css|png|jpe?g|svg|woff2?|ttf|ico|map)(\?|$)/i.test(u)) continue;
    if (/site24x7|razorpay|google|gstatic|cloudflare/i.test(u)) continue;
    out.push(log[i]);
  }
  var nav = document.querySelector('.k-nav-current');
  return JSON.stringify({
    installed: !!window.__spyOn,
    total: log.length,
    calls: out.slice(-8),
    range: nav ? clean(nav.textContent) : null
  });
})()
"""#

    /// Routes the SPA to the timetable **without reloading the page**.
    ///
    /// A hard `load()` of the timetable URL renders the scheduler but never
    /// gets any events - the diagnostic came back `view=agenda tasks=0
    /// rows=3`, i.e. the widget mounted and stayed empty. A full reload
    /// re-bootstraps Angular at that route, so whatever the dashboard puts in
    /// the app's services isn't there. Soft-routing keeps the running app
    /// instance and just changes the route, the way tapping the menu does.
    ///
    /// Angular's router doesn't react to `pushState` alone, but it does react
    /// to a `popstate`, so the two together are a working in-app navigation.
    ///
    /// Returns: "already", "link", "pushstate".
    static let gotoWeek = #"""
(function () {
  var target = '/connectportal/user/student/curriculum-scheduling';
  if (location.pathname.indexOf('curriculum-scheduling') > -1) return 'already';

  // A real in-app link is better than faking history, when one is rendered.
  var a = document.querySelector('a[href*="curriculum-scheduling"]');
  if (a) { a.click(); return 'link'; }

  history.pushState({}, '', target);
  window.dispatchEvent(new PopStateEvent('popstate', { state: history.state }));
  return 'pushstate';
})()
"""#

    /// Clicks the scheduler's own "Today" button to force it to re-query its
    /// date range. Used when the agenda has mounted but no events arrived, on
    /// the theory that the initial fetch never fired.
    ///
    /// Returns: "today", "range" or "none".
    static let nudge = #"""
(function () {
  var t = document.querySelector('.k-nav-today');
  if (t) { t.click(); return 'today'; }
  // No Today button: step forward and back, which also re-queries.
  var n = document.querySelector('.k-nav-next');
  var p = document.querySelector('.k-nav-prev');
  if (n && p) { n.click(); p.click(); return 'range'; }
  return 'none';
})()
"""#

    /// Switches the portal's Kendo scheduler into Agenda view and reports what
    /// it did.
    ///
    /// This is the fix for "only today ever showed up". The scheduler opens in
    /// whatever view it defaults to - a Day/Week time grid - and only the
    /// Agenda view renders the date-column table the weekly scraper reads. A
    /// page saved *after* manually picking Agenda looks completely different
    /// from a page freshly navigated to, which is why the scraper tested clean
    /// against a saved copy and still came back empty on device.
    ///
    /// Returns: "already", "select", "button", "no-scheduler" or "not-found".
    static let agenda = #"""
(function () {
  var clean = function (t) { return String(t == null ? '' : t).replace(/\s+/g, ' ').trim(); };

  if (document.querySelector('.k-scheduler-agendaview')) return 'already';
  if (!document.querySelector('kendo-scheduler, .k-scheduler')) return 'no-scheduler';

  // At phone widths Kendo renders the view picker as a native <select>, so
  // this is the path that actually runs for us. Angular listens for 'change'.
  var sels = document.querySelectorAll('select');
  for (var i = 0; i < sels.length; i++) {
    var opts = sels[i].options || [];
    for (var j = 0; j < opts.length; j++) {
      if (!/agenda/i.test(clean(opts[j].textContent))) continue;
      sels[i].selectedIndex = j;
      sels[i].value = opts[j].value;
      sels[i].dispatchEvent(new Event('input', { bubbles: true }));
      sels[i].dispatchEvent(new Event('change', { bubbles: true }));
      return 'select';
    }
  }

  // Wider layouts get a button group instead. click() fires the handler even
  // when the group is the hidden one of the two.
  var btns = document.querySelectorAll('button');
  for (var k = 0; k < btns.length; k++) {
    if (/^agenda$/i.test(clean(btns[k].textContent))) { btns[k].click(); return 'button'; }
  }

  return 'not-found';
})()
"""#

    /// Cheap check for whether the router has landed on the dashboard yet.
    static let route = "location.pathname"
}
