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
      mode: mode
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

  var isNoise = function (t) {
    if (!t) return true;
    if (TIME.test(t)) return true;
    if (DAY.test(t)) return true;
    if (/^\d{1,2}$/.test(t)) return true;
    if (/^(date|time|room|course|subject|faculty|type|venue|session|day|sept?|[A-Z][a-z]+day)$/i.test(t)) return true;
    if (/^[A-Za-z]{3,9}\.?\s+\d{4}$/.test(t)) return true;   // "Sept 2026"
    return false;
  };

  var out = [];
  var current = null;
  var sample = null;
  var rows = document.querySelectorAll('tr');

  for (var i = 0; i < rows.length; i++) {
    var whole = clean(rows[i].textContent);

    // A date cell carries a rowspan, so it appears on the first row of its day
    // and the rest of that day's rows inherit it.
    var dm = whole.match(DAY);
    if (dm) {
      var d = iso(dm[1], dm[3], dm[4]);
      if (d) current = d;
    }

    var cells = Array.prototype.slice.call(rows[i].querySelectorAll('td')).map(function (c) {
      return clean(c.innerText != null ? c.innerText : c.textContent);
    });
    if (!cells.length) continue;

    var timeCell = null;
    for (var c = 0; c < cells.length; c++) {
      if (TIME.test(cells[c])) { timeCell = cells[c]; break; }
    }
    if (!timeCell || !current) continue;

    var tm = timeCell.match(TIME);
    var start = ampm(+tm[1], tm[2]);
    var end = ampm(+tm[3], tm[4]);

    // Free periods have a time but no subject, so they drop out here.
    var subject = null;
    for (var s = 0; s < cells.length; s++) {
      var t = cells[s];
      if (isNoise(t) || !/[A-Za-z]{4,}/.test(t)) continue;
      if (/online classroom/i.test(t)) continue;
      if (!subject || t.length > subject.length) subject = t;
    }
    if (!subject) continue;

    var online = /online\s*class/i.test(whole);
    var room = null;
    var rm = whole.match(/room\s*:?\s*([A-Za-z0-9()\-\/]+)/i);
    if (rm) room = rm[1];
    if (!room) {
      for (var r = 0; r < cells.length; r++) {
        if (/^\d{3,6}(\(\d{3,6}\))?$/.test(cells[r])) { room = cells[r]; break; }
      }
    }
    if (room) {
      var dup = room.match(/^(.+?)\s*\(\s*\1\s*\)$/);
      if (dup) room = dup[1];
    }

    if (!sample) sample = cells.slice(0, 8);

    out.push({
      date: current,
      subject: subject,
      start: start,
      end: end,
      room: room,
      online: !!online,
      mode: online ? 'virtual' : 'class'
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

  return JSON.stringify({ ok: uniq.length > 0, sessions: uniq, sample: sample });
})()
"""#

    /// Cheap check for whether the router has landed on the dashboard yet.
    static let route = "location.pathname"
}
