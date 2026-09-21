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
    // Bounded on the right. The $ anchor alone made the lazy group run to the
    // end of the row, so a join URL rendered after the room was swallowed into
    // the room name - and the "11213(11213)" de-duplication below then stopped
    // matching too.
    var rm = txt.match(/room\s*:\s*([^\s].*?)\s*(?:\s(?:https?:\/\/|meeting\s*link)|$)/i);
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
    /// Builds the week from the timetable API payload the page already
    /// fetched, rather than from rendered HTML.
    ///
    /// The scheduler requests `POST /apigateway/api/timetable`, gets a ~1.1MB
    /// JSON array back with a 200, and then renders nothing - the DOM scrape
    /// was reading a table that was never going to fill in. The spy stashes
    /// that array on `window.__ttData`; this turns it into sessions.
    ///
    /// Field names are matched by shape rather than hardcoded, because the
    /// only sample available was the first 200 bytes of the response. When
    /// nothing matches, the diagnostic prints the real field paths and a
    /// per-reason skip count, so a mismatch names itself instead of failing
    /// silently.
    /// Builds the week from the timetable API payload the page already
    /// fetched, rather than from rendered HTML.
    ///
    /// The scheduler requests `POST /apigateway/api/timetable`, gets a ~1.1MB
    /// JSON array back with a 200, and then renders nothing - the DOM scrape
    /// was reading a table that was never going to fill in. The spy stashes
    /// that array on `window.__ttData`; this turns it into sessions.
    ///
    /// The payload's real shape, confirmed on device:
    ///
    ///     SlotDate            "2026-Aug-03"     (not ISO - month is a name)
    ///     SlotStartTime       "12:00 PM"        (not 24h)
    ///     SlotEndTime         "12:55 PM"
    ///     ModuleList[0]       { ModuleName, ModuleCode, ModuleId }
    ///     FloorPlanDetails    { VenueName, VenueCategory, MeetingLink, ... }
    ///
    /// A looser field-matching pass runs for any entry the direct read can't
    /// handle, and when nothing parses the diagnostic prints the actual field
    /// paths so a format change names itself.
    static let weekApi = #"""
(function () {
  var D = window.__ttData;
  if (!D) {
    return JSON.stringify({
      ok: false, sessions: [],
      diag: 'api=none' + (window.__ttErr ? (' parseErr=' + window.__ttErr) : '')
    });
  }

  var arr = Array.isArray(D) ? D : (D.Items || D.Item || D.Data || D.data || D.Result || null);
  if (!Array.isArray(arr)) {
    return JSON.stringify({ ok: false, sessions: [], diag: 'api=not-array keys=' + Object.keys(D).slice(0, 12).join(',') });
  }

  var pad = function (n) { return n < 10 ? '0' + n : String(n); };
  var clean = function (t) { return String(t == null ? '' : t).replace(/\s+/g, ' ').trim(); };

  var MON = {
    jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6,
    jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12
  };

  // Case-insensitive field lookup, because the payload mixes conventions
  // ("DayofWeekDetails" next to "DayOfWeekName").
  function get(o, name) {
    if (!o || typeof o !== 'object') return null;
    for (var k in o) {
      if (Object.prototype.hasOwnProperty.call(o, k) && k.toLowerCase() === name) return o[k];
    }
    return null;
  }

  // "2026-Aug-03" is what this portal sends. ISO and "03-Aug-2026" are
  // accepted too so a format change doesn't silently zero everything out.
  function normDate(v) {
    if (typeof v !== 'string') return null;
    var t = clean(v);
    var m = t.match(/^(\d{4})-(\d{2})-(\d{2})/);
    if (m) return m[1] + '-' + m[2] + '-' + m[3];
    m = t.match(/^(\d{4})[-\/\s]([A-Za-z]{3,9})[-\/\s](\d{1,2})/);
    if (m) {
      var mo1 = MON[m[2].slice(0, 3).toLowerCase()];
      if (mo1) return m[1] + '-' + pad(mo1) + '-' + pad(+m[3]);
    }
    m = t.match(/^(\d{1,2})[-\/\s]([A-Za-z]{3,9})[-\/\s](\d{4})/);
    if (m) {
      var mo2 = MON[m[2].slice(0, 3).toLowerCase()];
      if (mo2) return m[3] + '-' + pad(mo2) + '-' + pad(+m[1]);
    }
    return null;
  }

  // "12:00 PM" is already the shape the app parses, so it passes through.
  // A bare 24h "13:00" is converted rather than rejected.
  function normTime(v) {
    if (typeof v !== 'string') return null;
    var t = clean(v).toUpperCase().replace(/\./g, '');
    var m = t.match(/^(\d{1,2}):(\d{2})(?::\d{2})?\s*([AP])M?$/);
    if (m) return pad(+m[1]) + ':' + m[2] + ' ' + m[3] + 'M';
    m = t.match(/^(\d{1,2}):(\d{2})(?::\d{2})?$/);
    if (m) {
      var h = +m[1], hh = h % 12; if (hh === 0) hh = 12;
      return pad(hh) + ':' + m[2] + ' ' + (h < 12 ? 'AM' : 'PM');
    }
    return null;
  }

  // The whole remaining term is kept, not just the next fortnight. Knowing
  // how many classes are actually left is what lets the app say "you cannot
  // reach 75% any more" instead of cheerfully asking for twelve more when
  // only five remain. Past dates still go, they answer nothing.
  var now = new Date();
  var todayIso = now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate());
  // The payload is the whole term, and it used to be cut off at today - which
  // is why every past day in the app was blank. Sixty days back is the whole
  // of a semester so far without carrying a second term around in
  // UserDefaults.
  var back = new Date(now.getTime() - 60 * 864e5);
  var backIso = back.getFullYear() + '-' + pad(back.getMonth() + 1) + '-' + pad(back.getDate());

  var VIRTUAL = /virtual|online|teams|zoom|webex|meet/i;

  // The shape this portal actually sends, read directly:
  //   SlotDate "2026-Aug-03", SlotStartTime/SlotEndTime "12:00 PM",
  //   ModuleList[0].ModuleName, FloorPlanDetails.VenueName/VenueCategory,
  //   FloorPlanDetails.MeetingLink ("" when it is a physical room).
  function direct(it) {
    var date = normDate(get(it, 'slotdate') || get(it, 'date') || get(it, 'classdate'));
    var st = normTime(get(it, 'slotstarttime') || get(it, 'starttime') || get(it, 'fromtime'));
    var en = normTime(get(it, 'slotendtime') || get(it, 'endtime') || get(it, 'totime'));
    if (!date || !st) return null;

    var mods = get(it, 'modulelist') || get(it, 'modules') || null;
    var mod = (Array.isArray(mods) && mods.length) ? mods[0] : (get(it, 'moduledetails') || {});
    var subject = get(mod, 'modulename') || get(mod, 'name')
      || get(it, 'modulename') || get(it, 'coursename') || get(it, 'subjectname');
    if (!subject) return null;

    var fp = get(it, 'floorplandetails') || {};
    var venue = get(fp, 'venuename') || get(fp, 'venuecode') || get(it, 'venuename');
    var cat = get(fp, 'venuecategory') || get(fp, 'venuecategorycode') || '';
    var rawLink = get(fp, 'meetinglink') || get(it, 'meetinglink') || '';
    var link = /^https?:\/\//i.test(clean(rawLink)) ? clean(rawLink) : null;

    var virtual = VIRTUAL.test(String(cat)) || VIRTUAL.test(String(venue || ''));
    return {
      date: date,
      subject: clean(subject),
      start: st,
      end: en || st,
      room: virtual ? null : (venue ? clean(String(venue)) : null),
      online: virtual,
      // Hybrid rooms have both a room and a link; the UI offers Join whenever
      // a link exists, so the distinction is only cosmetic.
      mode: virtual ? 'virtual' : (link ? 'hybrid' : 'class'),
      link: link
    };
  }

  // --- generic fallback, in case the field names move -------------------
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

  var SUBJECTISH = /module|course|subject|paper/i;
  var NOT_SUBJECT = /venue|faculty|teacher|employee|grade|batch|cohort|section|room|floor|building|block|campus|event|slot|status|program|school|department|center|centre|day/i;
  var NOT_NAME = /code|id$|family|type|category|abbr|short/i;

  function loose(it) {
    var pairs = [];
    flat(it, pairs, '', 0);
    var dates = [], starts = [], ends = [], subj = [null, null], venue = null, cat = null, link = null;

    for (var i = 0; i < pairs.length; i++) {
      var lower = pairs[i][0].toLowerCase(), v = pairs[i][1];
      if (typeof v !== 'string') continue;
      var key = lower.split('.').pop().replace(/\[\]/g, '');

      if (/^https?:\/\//i.test(v)) { if (!link) link = v; continue; }
      if (key === 'venuename' || key === 'venuecode') { if (!venue) venue = v; continue; }
      if (key.indexOf('venuecategory') === 0) { if (!cat) cat = v; continue; }

      var nd = normDate(v);
      if (nd) { dates.push(nd); continue; }
      var nt = normTime(v);
      if (nt) {
        if (/start|from|begin/.test(lower)) starts.push(nt);
        else if (/end|finish/.test(lower)) ends.push(nt);
        continue;
      }
      if (!/[A-Za-z]{3,}/.test(v)) continue;

      if (SUBJECTISH.test(lower) && !NOT_NAME.test(key)) {
        if (/name|title|description/.test(key)) subj[0] = subj[0] || v;
        continue;
      }
      if (NOT_SUBJECT.test(lower)) continue;
      if (key === 'name' || key === 'title') subj[1] = subj[1] || v;
    }

    var subject = subj[0] || subj[1];
    if (!subject || !dates.length || !starts.length) return null;
    var virtual = VIRTUAL.test(cat || '') || VIRTUAL.test(venue || '');
    return {
      date: dates.sort()[0],
      subject: clean(subject),
      start: starts[0],
      end: ends.length ? ends[0] : starts[0],
      room: virtual ? null : (venue ? clean(venue) : null),
      online: virtual,
      mode: virtual ? 'virtual' : (link ? 'hybrid' : 'class'),
      link: link
    };
  }

  var out = [];
  var skipped = { shape: 0, range: 0 };
  var usedLoose = 0;

  for (var i = 0; i < arr.length; i++) {
    var g = direct(arr[i]);
    if (!g) { g = loose(arr[i]); if (g) usedLoose++; }
    if (!g) { skipped.shape++; continue; }
    if (g.date < backIso) { skipped.range++; continue; }
    out.push(g);
  }

  var seen = {}, uniq = [];
  for (var k = 0; k < out.length; k++) {
    var key2 = out[k].date + '|' + out[k].start + '|' + out[k].subject;
    if (seen[key2]) continue;
    seen[key2] = 1;
    uniq.push(out[k]);
  }
  uniq.sort(function (a, b) {
    if (a.date !== b.date) return a.date < b.date ? -1 : 1;
    var am = a.start.match(/^(\d+):(\d+) ([AP])/), bm = b.start.match(/^(\d+):(\d+) ([AP])/);
    var av = ((+am[1]) % 12 + (am[3] === 'P' ? 12 : 0)) * 60 + (+am[2]);
    var bv = ((+bm[1]) % 12 + (bm[3] === 'P' ? 12 : 0)) * 60 + (+bm[2]);
    return av - bv;
  });

  var days = {};
  for (var z = 0; z < uniq.length; z++) days[uniq[z].date] = 1;

  var diag = 'api items=' + arr.length + ' parsed=' + uniq.length
    + ' days=' + Object.keys(days).length
    + ' skip(' + skipped.shape + 'shape/' + skipped.range + 'range)'
    + (usedLoose ? ' loose=' + usedLoose : '');
  if (uniq.length) {
    diag += ' first=' + uniq[0].date + ' ' + uniq[0].start + ' ' + uniq[0].subject.slice(0, 30);
  } else if (arr.length) {
    var pairs0 = [];
    flat(arr[0], pairs0, '', 0);
    diag += ' | ' + pairs0.map(function (x) {
      var v = x[1];
      if (typeof v === 'string') v = v.slice(0, 18);
      return x[0] + '=' + v;
    }).slice(0, 24).join(' ');
  }

  // Who teaches you what. Built straight off the raw feed rather than off
  // the parsed sessions, because it needs nothing the parse could fail at -
  // and it is the only place in the whole portal that says which of a
  // course's twenty teachers is yours. The LMS needs that to tell your own
  // teacher's material from the rest of the department's.
  var teachers = {};
  for (var t = 0; t < arr.length; t++) {
    var mods = arr[t] && arr[t].ModuleList;
    var who = arr[t] && arr[t].TeacherList;
    if (!mods || !mods.length || !who || !who.length) continue;
    var subj = clean(mods[0].ModuleName);
    if (!subj) continue;
    if (!teachers[subj]) teachers[subj] = [];
    for (var u = 0; u < who.length; u++) {
      var nm = clean(who[u].Name);
      if (nm && teachers[subj].indexOf(nm) < 0) teachers[subj].push(nm);
    }
  }

  // items is how the app distinguishes the real term feed (hundreds) from
  // the dashboard's own six-item "today" call to the same endpoint.
  return JSON.stringify({
    ok: uniq.length > 0, sessions: uniq, diag: diag, items: arr.length,
    teachers: teachers
  });
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

  // Patched on the prototype, in place. Replacing the global with a wrapper
  // function - which is what this used to do - detaches the real constructor:
  // zone.js bootstraps by patching window.XMLHttpRequest.prototype, so it
  // would patch the wrapper's empty prototype while every actual request went
  // through the untouched original. Angular then never runs change detection
  // when a response lands, which is exactly the "fetches the whole timetable
  // and renders none of it" symptom weekApi exists to work around. Patching
  // the prototype also leaves XMLHttpRequest.DONE and instanceof intact.
  var OX = window.XMLHttpRequest;
  if (OX && OX.prototype && OX.prototype.open) {
    var oOpen = OX.prototype.open;
    OX.prototype.open = function (m, u) {
      var x = this;
      x.__spyRec = { k: 'xhr', u: String(u || ''), m: String(m || ''), s: 0, n: 0, b: '' };
      // One listener per instance, even when open() is called again to reuse it.
      if (x.__spyWired) return oOpen.apply(this, arguments);
      x.__spyWired = true;
      x.addEventListener('loadend', function () {
        var rec = x.__spyRec;
        if (!rec) return;
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
            try {
              var parsed = JSON.parse(t);
              // The dashboard hits this same endpoint for its "today" card,
              // so there are two responses in a session: a 6-item one for
              // today and the full ~424-item term. Last-write-wins would hand
              // back whichever happened to land last, which is how the week
              // came back as a single day. Keep the biggest instead.
              var n = Array.isArray(parsed) ? parsed.length : 0;
              var have = Array.isArray(window.__ttData) ? window.__ttData.length : -1;
              if (n > have) { window.__ttData = parsed; window.__ttCount = n; }
            } catch (e2) { window.__ttErr = String(e2); }
          }
        } catch (e) {}
        keep(rec);
      });
      return oOpen.apply(this, arguments);
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

    /// The student's photo, straight off the dashboard header.
    ///
    /// The portal renders it as `<img class="header-profile-img"
    /// src="data:image/jpeg;base64,...">`, so the bytes are already in the
    /// page - no second authenticated request, no URL to expire. Only data
    /// URIs are accepted; a remote src would need cookies the app can't
    /// replay from an image view.
    static let photo = #"""
(function () {
  var pick = function (el) {
    if (!el) return null;
    var src = el.getAttribute('src') || '';
    return /^data:image\/(jpe?g|png|webp);base64,/i.test(src) ? src : null;
  };

  var direct = pick(document.querySelector('img.header-profile-img'))
    || pick(document.querySelector('img.nav-avatar'))
    || pick(document.querySelector('img.user-avatar'))
    || pick(document.querySelector('img.profile-image'));
  if (direct) return direct;

  // Any inline image that isn't a logo or an icon, smallest markup wins.
  var imgs = document.querySelectorAll('img[src^="data:image"]');
  for (var i = 0; i < imgs.length; i++) {
    var cls = (imgs[i].getAttribute('class') || '').toLowerCase();
    var id = (imgs[i].getAttribute('id') || '').toLowerCase();
    if (/logo|icon|brand/.test(cls + ' ' + id)) continue;
    var src2 = pick(imgs[i]);
    if (src2) return src2;
  }
  return null;
})()
"""#

    /// The holiday table, so the term maths stops counting classes that will
    /// never be held.
    ///
    /// Dates are DD-MM-YYYY with a weekday chip beside them, and a row can
    /// span days — Diwali is five, Winter Break crosses a year boundary. Rows
    /// are matched by shape rather than column index: take every DD-MM-YYYY
    /// in the row, first is the start and last is the end. That survives a
    /// column being added or reordered, which a fixed index would not.
    static let holidays = #"""
(function () {
  var clean = function (t) { return String(t == null ? '' : t).replace(/\s+/g, ' ').trim(); };
  var DMY = /\b(\d{2})-(\d{2})-(\d{4})\b/g;

  var out = [];
  var rows = document.querySelectorAll('tr');

  for (var i = 0; i < rows.length; i++) {
    var tr = rows[i];
    // A row holding another row is a layout wrapper, not a data row.
    if (tr.querySelector('tr')) continue;

    var tds = tr.querySelectorAll('td');
    if (tds.length < 2) continue;

    var whole = clean(tr.textContent);
    var found = [], m;
    DMY.lastIndex = 0;
    while ((m = DMY.exec(whole))) {
      // DD-MM-YYYY in, ISO out.
      found.push(m[3] + '-' + m[2] + '-' + m[1]);
    }
    if (!found.length) continue;

    // The name is the first cell. Reading it from the cell rather than the
    // row keeps the weekday chips in the date columns out of it.
    var name = clean(tds[0].textContent);
    if (!name || !/[A-Za-z]{3,}/.test(name)) continue;

    out.push({
      name: name,
      type: clean(tds[1].textContent),
      from: found[0],
      to: found[found.length - 1]
    });
  }

  // The grid paginates, so the visible page is all there is to see. The row
  // count goes back too: a short list is then a signal rather than silence.
  return JSON.stringify({ ok: out.length > 0, holidays: out, rows: rows.length });
})()
"""#

    /// Ask the portal for the whole register, in one call.
    ///
    /// The search page was driven by hand for four builds: fill three Kendo
    /// dropdowns, type two read-only date fields, press Search, scrape a grid
    /// that turned out to be two tables. None of it was ever going to work -
    /// the date inputs are readonly and only the calendar can set them.
    ///
    /// The page is talking to /student-attendance/studentattendancesummary,
    /// which takes a list of courses and answers with JSON: every session,
    /// its date, its time and whether you were there. One request, no UI.
    /// This kicks it off and parks the answer on window.__reg, because
    /// evaluateJavaScript cannot wait for a promise.
    static let registerStart = #"""
(function () {
  if (window.__regBusy) return JSON.stringify({ ok: true, diag: 'running' });

  // The session, wherever it is kept. Both keys are obfuscated and there is no
  // reason to believe they are stable, so this looks at the shape of the value
  // rather than at the name of the key.
  function scan(pick) {
    for (var i = 0; i < localStorage.length; i++) {
      var v = localStorage.getItem(localStorage.key(i));
      if (!v || v.charAt(0) !== '{') continue;
      try { var hit = pick(JSON.parse(v)); if (hit) return hit; } catch (e) { }
    }
    return null;
  }
  var token = scan(function (o) { return o && o.Identity && o.Identity.AccessToken; });
  var student = scan(function (o) { return o && o.StudentId; });
  if (!token || !student) return JSON.stringify({ ok: false, diag: 'no session yet' });

  window.__regBusy = 1;
  window.__reg = null;

  // x-appsecret is a constant in the portal's own bundle, not a credential of
  // yours; the gateway rejects the call without it.
  var H = {
    'Content-Type': 'application/json', 'Accept': 'application/json, text/plain, */*',
    'Authorization': 'Bearer ' + token, 'x-applicationname': 'connectportal',
    'x-appsecret': 'ku7GUMtyT8er51rTfTc7HC', 'x-requestfrom': 'web', 'x-studentUniqueId': student
  };

  (async function () {
    var out = { done: true, ok: false, rows: [], diag: '' };
    try {
      var dd = await fetch('/apigateway/student-attendance/attendancedropdown', {
        method: 'POST', headers: H,
        body: JSON.stringify({ StudentUniqueID: student, IsAttendance: true })
      });
      if (!dd.ok) { out.diag = 'dropdown ' + dd.status; window.__reg = out; window.__regBusy = 0; return; }

      var fams = await dd.json();
      var fam = fams && fams[0];
      var list = (fam && fam.TermDropdownDetailsList) || [];
      var term = null;
      for (var i = 0; i < list.length; i++) { if (list[i].IsCurrentTerm) term = list[i]; }
      if (!term) term = list[list.length - 1];
      if (!term) { out.diag = 'no term in dropdown'; window.__reg = out; window.__regBusy = 0; return; }

      var now = new Date();
      var pad = function (n) { return n < 10 ? '0' + n : '' + n; };
      // Every course in one call. The page asks for one at a time because it
      // has one dropdown; the endpoint takes a list.
      var body = {
        StudentUniqueID: student,
        CourseFamilyId: fam.CourseFamilyId,
        TermCodeId: term.TermCodeId,
        CourseList: (term.ModuleDropdownDetailsList || []).map(function (m) {
          return { ID: m.ModuleId, Name: m.ModuleName };
        }),
        StartDate: String(term.TermStartDate).slice(0, 10),
        EndDate: now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate()),
        TermStartDate: String(term.TermStartDate).slice(0, 10),
        TermEndDate: String(term.TermEndDate).slice(0, 10)
      };

      var r = await fetch('/apigateway/student-attendance/studentattendancesummary', {
        method: 'POST', headers: H, body: JSON.stringify(body)
      });
      if (!r.ok) { out.diag = 'summary ' + r.status; window.__reg = out; window.__regBusy = 0; return; }

      var j = await r.json();
      var info = j.AttendanceInfo || [];
      for (var c = 0; c < info.length; c++) {
        var det = info[c].AttendanceDetails || [];
        for (var d = 0; d < det.length; d++) {
          var day = String(det[d].SessionDate || '').slice(0, 10);
          if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) continue;
          out.rows.push({
            subject: String(info[c].CourseName || ''),
            date: day,
            time: String(det[d].SessionTime || ''),
            present: String(det[d].AttendanceStatus || '').toUpperCase().indexOf('PRESENT') === 0
          });
        }
      }
      out.ok = out.rows.length > 0;
      out.diag = 'term=' + term.TermCode + ' courses=' + info.length + ' rows=' + out.rows.length;
    } catch (e) {
      out.diag = 'threw ' + String(e).slice(0, 90);
    }
    window.__reg = out;
    window.__regBusy = 0;
  })();

  return JSON.stringify({ ok: true, diag: 'started' });
})()
"""#

    /// Collect what registerStart parked, once it has landed.
    static let registerRead = #"""
(function () {
  var r = window.__reg;
  if (!r) {
    return JSON.stringify({
      done: false, ok: false, rows: [],
      diag: window.__regBusy ? 'running' : 'not started'
    });
  }
  return JSON.stringify(r);
})()
"""#

    /// Ask the portal for a key to the LMS.
    ///
    /// Coursework does not exist on the portal at all: the nav's "LMS" tile
    /// posts to /sso/user/oauth2/access-lms and gets back a one-shot Moodle
    /// login URL. So this asks for the same URL and hands it back for the
    /// webview to load - there is no way to reach Moodle signed in without
    /// spending one of these keys.
    ///
    /// Parked on window.__lmsk because evaluateJavaScript cannot wait for a
    /// promise, and re-entrant because the caller polls it.
    static let lmsKey = #"""
(function () {
  if (window.__lmsk) return JSON.stringify(window.__lmsk);

  // Same shape-scan as the register: both storage keys are obfuscated and
  // neither looks stable, so the value is what gets recognised.
  function scan(pick) {
    for (var i = 0; i < localStorage.length; i++) {
      var v = localStorage.getItem(localStorage.key(i));
      if (!v || v.charAt(0) !== '{') continue;
      try { var hit = pick(JSON.parse(v)); if (hit) return hit; } catch (e) { }
    }
    return null;
  }
  var token = scan(function (o) { return o && o.Identity && o.Identity.AccessToken; });
  var student = scan(function (o) { return o && o.StudentId; });
  // Deliberately not parked. The caller stops polling the moment it sees
  // done, so answering "no session" from a document that has not booted yet
  // would end the read on a page that was about to work.
  if (!token || !student) {
    return JSON.stringify({ done: false, ok: false, url: '', diag: 'no session yet' });
  }

  var st = { done: false, ok: false, url: '', diag: 'started' };
  window.__lmsk = st;

  fetch('https://myupes-beta.upes.ac.in/sso/user/oauth2/access-lms?uniqueId=' + student, {
    method: 'POST',
    headers: {
      'Authorization': 'Bearer ' + token,
      'x-applicationname': 'connectportal',
      // A constant out of the portal's own public bundle, not a secret of
      // this account's - the page sends it on every call.
      'x-appsecret': 'ku7GUMtyT8er51rTfTc7HC',
      'x-requestfrom': 'web',
      'x-studentUniqueId': student,
      'Content-Type': 'application/json'
    },
    body: '{}'
  }).then(function (r) {
    return r.json().then(function (j) {
      st.url = j && j.redirectUrl ? j.redirectUrl : '';
      st.ok = !!st.url;
      st.diag = st.ok ? 'key issued' : 'no redirectUrl, http ' + r.status;
      st.done = true;
    });
  }).catch(function (e) {
    st.done = true;
    st.diag = 'lms key threw ' + e;
  });

  return JSON.stringify(st);
})()
"""#

    /// Everything the LMS is waiting on, once the key above has been spent.
    ///
    /// Moodle is a Moodle, so there is no scraping to do: the page's own AJAX
    /// endpoint answers the question the calendar block asks, and sesskey is
    /// sitting in M.cfg. Only assignments and quizzes are kept - the same feed
    /// carries "Lecture-1 should be completed" nags for every file anyone ever
    /// uploaded, and none of those are a deadline.
    static let lmsDue = #"""
(function () {
  if (window.__lmsd) return JSON.stringify(window.__lmsd);

  // Getting here is a redirect chain - the key URL, then Moodle's own landing
  // page - and the documents in the middle have no sesskey. Parking a failure
  // on one of those would answer the caller before the real page existed, so
  // nothing is parked until there is something to ask.
  var sk = (window.M && M.cfg && M.cfg.sesskey) || '';
  if (!sk) {
    return JSON.stringify({ done: false, ok: false, items: [], diag: 'waiting for the lms' });
  }

  var st = { done: false, ok: false, items: [], diag: 'started' };
  window.__lmsd = st;

  // A fortnight back as well as forward: something already overdue is the
  // thing you most want to be told about.
  var from = Math.floor(Date.now() / 1000) - 86400 * 14;
  fetch('/lib/ajax/service.php?sesskey=' + sk, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify([{
      index: 0,
      methodname: 'core_calendar_get_action_events_by_timesort',
      args: { timesortfrom: from, limitnum: 50 }
    }])
  }).then(function (r) { return r.json(); }).then(function (j) {
    var d = j && j[0];
    if (!d || d.error) {
      st.done = true;
      st.diag = 'lms said ' + (d && d.exception ? d.exception.message : 'nothing');
      return;
    }
    var ev = (d.data && d.data.events) || [];
    var out = [];
    for (var i = 0; i < ev.length; i++) {
      var e = ev[i];
      if (e.modulename !== 'assign' && e.modulename !== 'quiz') continue;
      var course = (e.course && e.course.fullname) || '';
      out.push({
        title: e.name || '',
        // The LMS names every course of this term "<name>_Sem5", and the
        // ampersands come through HTML-escaped.
        course: course.replace(/&amp;/g, '&').replace(/_Sem\d+$/, ''),
        due: new Date(e.timesort * 1000).toISOString(),
        kind: e.modulename,
        url: e.url || ''
      });
    }
    st.items = out;
    st.ok = true;
    st.done = true;
    st.diag = ev.length + ' events, ' + out.length + ' with a deadline';
  }).catch(function (e) {
    st.done = true;
    st.diag = 'lms threw ' + e;
  });

  return JSON.stringify(st);
})()
"""#

    /// This semester's courses, and what *your* teachers put in them.
    ///
    /// The shape of a course here, which took a live look to establish:
    ///
    ///   top-level section   one per teacher — "Dr. Manupriya Darshani",
    ///                       "Kaustubh_Ijardar_CSF_B7_B8_B9", "Ayush Gurjar" —
    ///                       plus the occasional shared one, "General" or
    ///                       "PEMC(Batches - CCSF (4,5,6,7,8,9)...".
    ///   subsection          a folder inside one of those: BOOKS, QUIZ,
    ///                       Unit-1, CLASS TESTS. Carries parentsectionid.
    ///   module              the thing you open.
    ///
    /// A course is taught by twenty teachers to twenty batches. `uservisible`
    /// hides most of the others' material but not all of it — Cryptography
    /// leaves another teacher's page readable — so the sections are matched
    /// against the teachers the *timetable* says take your classes, handed in
    /// on window.__mine. A section that matches nobody is kept only if it does
    /// not look like a person's name, which is what keeps the shared ones.
    ///
    /// Only "_Sem5" courses: "inprogress" still includes a couple of
    /// year-long ones from before.
    ///
    /// One request for the course list, one batched request for every
    /// course's contents.
    static let lmsCourses = #"""
(function () {
  if (window.__lmsc) return JSON.stringify(window.__lmsc);

  // Unparked until there is a sesskey, for the same reason as lmsDue: getting
  // here is a redirect chain and the documents in the middle have none.
  var sk = (window.M && M.cfg && M.cfg.sesskey) || '';
  if (!sk) {
    return JSON.stringify({ done: false, ok: false, courses: [], diag: 'waiting for the lms' });
  }

  var st = { done: false, ok: false, courses: [], diag: 'started' };
  window.__lmsc = st;

  // Set by the app just before this runs: { subject: [teacher, ...] } out of
  // the timetable. Without it every teacher's section is kept, which is the
  // old behaviour and still better than an empty screen.
  var MINE = window.__mine || {};

  // Names come through HTML-escaped. innerHTML would undo that in one line
  // and also run whatever a course name happened to contain.
  function text(s) {
    return String(s == null ? '' : s)
      .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&#0?39;/g, "'").replace(/&nbsp;/g, ' ');
  }

  // "Kaustubh_Ijardar_CSF_B7_B8_B9" and "Dr.  Navin Mani Upadhyay (B-7, B-8,
  // B-9)" have to come out comparable with "Kaustubh  Ijardar" and "Navin
  // Upadhyay" - hence words, not strings.
  function words(s) {
    return text(s).toLowerCase()
      .replace(/[^a-z0-9]+/g, ' ')
      .split(' ')
      .filter(function (w) {
        return w && w.length > 2 && ['dr', 'prof', 'mr', 'mrs', 'ms', 'the'].indexOf(w) < 0;
      });
  }

  // Every word of the teacher's name appears in the section's title. Middle
  // names only the LMS knows about are therefore fine; a shared surname is
  // not enough on its own.
  function isTeacher(title, who) {
    var have = words(title);
    for (var i = 0; i < who.length; i++) {
      var want = words(who[i]);
      if (!want.length) continue;
      var all = true;
      for (var j = 0; j < want.length; j++) {
        if (have.indexOf(want[j]) < 0) { all = false; break; }
      }
      if (all) return true;
    }
    return false;
  }

  // A Folder module is a page with a pile of files on it. Opening one on the
  // phone means leaving the app for a list, so its files are read off it here
  // and take its place. `core_courseformat_get_state` cannot supply them - it
  // carries module names and urls only - and `core_course_get_contents` is
  // switched off on this Moodle, so the folder's own page is the only source.
  //
  // Themes differ in how they mark the anchor up, so the name is taken from
  // the link text when there is any and from the url when there is not.
  function filesIn(html) {
    // Start at the file manager when the theme provides one; otherwise the
    // whole page, which over-captures an embedded image at worst.
    var box = /<div[^>]+class="[^"]*filemanager[^"]*"[\s\S]*/i.exec(html);
    var hay = box ? box[0] : html;
    var re = /<a[^>]+href="([^"]*\/pluginfile\.php\/[^"]*)"[^>]*>([\s\S]*?)<\/a>/gi;
    var out = [], seen = {}, m;
    while ((m = re.exec(hay))) {
      var url = text(m[1]);
      if (seen[url]) continue;
      seen[url] = 1;
      var name = text(m[2].replace(/<[^>]*>/g, '')).replace(/\s+/g, ' ').trim();
      if (!name) {
        var tail = url.split('?')[0].split('/').pop();
        try { name = decodeURIComponent(tail); } catch (e) { name = tail; }
      }
      if (name) out.push({ title: name, url: url });
    }
    return out;
  }

  // Two plain words, or an honorific, and it is somebody's name. "General",
  // "PEMC(Batches - CCSF (4,5,6,7,8,9)" and "Unit-1" are not, which is how
  // the sections a course shares with every batch survive the filter.
  function personish(t) {
    var s = text(t).replace(/[_|.]/g, ' ').replace(/\s+/g, ' ').trim();
    if (/^(dr|prof|mr|mrs|ms)\b/i.test(s)) return true;
    var w = s.split(' ');
    return w.length >= 2 && /^[A-Za-z]{3,}$/.test(w[0]) && /^[A-Za-z]{2,}$/.test(w[1]);
  }

  function ws(calls) {
    return fetch('/lib/ajax/service.php?sesskey=' + sk, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(calls)
    }).then(function (r) { return r.json(); });
  }

  ws([{
    index: 0,
    methodname: 'core_course_get_enrolled_courses_by_timeline_classification',
    // "all" would be every course of the whole degree, not this semester.
    args: { classification: 'inprogress', limit: 0, offset: 0, sort: 'fullname' }
  }]).then(function (j) {
    var d = j && j[0];
    if (!d || d.error) {
      throw new Error(d && d.exception ? d.exception.message : 'no course list');
    }
    // "inprogress" still carries a year-long course or two from last
    // semester; the term is in the name.
    var list = ((d.data && d.data.courses) || []).filter(function (c) {
      return /_Sem\d+$/.test(text(c.fullname));
    });
    if (!list.length) {
      st.ok = true;
      st.done = true;
      st.diag = 'no _Sem courses in progress';
      return;
    }

    return ws(list.map(function (c, i) {
      return { index: i, methodname: 'core_courseformat_get_state', args: { courseid: c.id } };
    })).then(function (states) {
      var out = [], total = 0, unmatched = [];

      for (var i = 0; i < list.length; i++) {
        var c = list[i];
        var name = text(c.fullname).replace(/_Sem\d+$/, '');
        var mine = MINE[name] || [];
        var items = [], dropped = 0;
        var raw = states[i] && states[i].data;

        if (raw) {
          var s = JSON.parse(raw), secs = {}, cms = {};
          (s.section || []).forEach(function (x) { secs[x.id] = x; });
          (s.cm || []).forEach(function (x) { cms[x.id] = x; });

          // Which top-level section a section belongs to, and how deep it is.
          // Subsections carry parentsectionid; teachers' sections do not.
          var rootOf = function (sec) {
            var seen = 0;
            while (sec && sec.parentsectionid && secs[sec.parentsectionid] && seen < 8) {
              sec = secs[sec.parentsectionid];
              seen++;
            }
            return sec;
          };

          // sectionlist, not the section array, because only the former is in
          // the order the course page shows.
          ((s.course && s.course.sectionlist) || []).forEach(function (sid) {
            var sec = secs[sid];
            if (!sec || !sec.visible) return;

            var root = rootOf(sec);
            if (!root) return;
            var owner = text(root.title);

            // The whole point: your teacher's sections, plus the ones that
            // belong to no teacher at all.
            var keep = mine.length ? isTeacher(owner, mine) : true;
            if (!keep && !personish(owner)) keep = true;
            if (!keep) {
              dropped += (sec.cmlist || []).length;
              return;
            }

            // A subsection's own title is the folder; a top-level section has
            // no folder and its items sit loose under the teacher.
            var folder = (root.id === sec.id) ? '' : text(sec.title);

            (sec.cmlist || []).forEach(function (id) {
              var m = cms[id];
              if (!m || !m.uservisible) return;
              // A Subsection is only a pointer to a section that arrives on
              // its own, so counting it would list everything twice.
              if (m.modname === 'Subsection') return;
              items.push({
                title: text(m.name),
                kind: text(m.modname),
                url: m.url || '',
                group: owner,
                folder: folder
              });
            });
          });

          if (!items.length && dropped) unmatched.push(name.slice(0, 18));
        }

        total += items.length;
        out.push({
          id: Number(c.id),
          name: name,
          url: 'https://lms.upes.ac.in/course/view.php?id=' + c.id,
          items: items
        });
      }

      st.courses = out;
      var note = (unmatched.length ? ', nothing of yours in: ' + unmatched.join(', ') : '');

      var pending = [];
      out.forEach(function (c) {
        c.items.forEach(function (it) {
          if (String(it.kind).toLowerCase() === 'folder' && it.url) {
            pending.push({ course: c, item: it });
          }
        });
      });
      // ponytail: forty folders is already an absurd course. Raise the cap if
      // a real one ever reaches it - each is one more request on a path that
      // already runs after the read has finished.
      pending = pending.slice(0, 40);

      if (!pending.length) {
        st.ok = true;
        st.done = true;
        st.diag = out.length + ' courses, ' + total + ' items' + note;
        return;
      }

      function finish() {
        var opened = 0;
        pending.forEach(function (f) {
          if (!f.files || !f.files.length) return;
          // Looked up fresh, because an earlier splice into the same course
          // has already moved everything after it.
          var at = f.course.items.indexOf(f.item);
          if (at < 0) return;
          opened++;
          var inner = f.item.folder ? f.item.folder + ' / ' + f.item.title : f.item.title;
          var kids = f.files.map(function (x) {
            return { title: x.title, kind: 'File', url: x.url, group: f.item.group, folder: inner };
          });
          f.course.items.splice.apply(f.course.items, [at, 1].concat(kids));
        });

        var count = 0;
        out.forEach(function (c) { count += c.items.length; });
        st.ok = true;
        st.done = true;
        st.diag = out.length + ' courses, ' + count + ' items'
          + (opened ? ', ' + opened + ' of ' + pending.length + ' folders opened' : '')
          + note;
      }

      // One at a time, not Promise.all: forty parallel requests at a Moodle
      // is rude, and this runs after the read has already finished so nothing
      // is waiting on it.
      var next = 0;
      function openNext() {
        if (next >= pending.length) { finish(); return null; }
        var f = pending[next++];
        return fetch(f.item.url, { credentials: 'same-origin' })
          .then(function (r) { return r.text(); })
          .then(function (html) { f.files = filesIn(html); return openNext(); })
          // A folder that will not open stays a folder: the row still works,
          // and dropping it would lose material rather than tidy it.
          .catch(function () { f.files = []; return openNext(); });
      }
      return openNext();
    });
  }).catch(function (e) {
    st.done = true;
    st.diag = 'lms courses threw ' + e;
  });

  return JSON.stringify(st);
})()
"""#

    /// Cheap check for whether the router has landed on the dashboard yet.
    static let route = "location.pathname"
}
