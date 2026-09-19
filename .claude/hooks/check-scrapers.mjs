// Syntax-gate for the JavaScript that lives inside Scrapers.swift.
//
// Roughly a third of this app is JavaScript held in Swift raw string literals.
// Nothing in the build checks it: swiftc sees an opaque string, the blob ships,
// evaluateJavaScript throws at runtime, and `(try? await eval(...)) ?? nil`
// swallows the throw into a blank screen. A typo therefore costs a full
// push / CI / sideload / relaunch cycle to discover, and presents as "the
// portal is being slow" rather than as an error.
//
// This runs on every edit and turns that into an immediate failure.
import fs from 'fs';

let ev;
try {
  ev = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  process.exit(0); // not invoked as a hook; nothing to do
}

const file = ev.tool_input?.file_path ?? '';
if (!/Scrapers\.swift$/.test(file)) process.exit(0);

let src;
try {
  src = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
} catch {
  process.exit(0); // deleted or moved between the edit and this check
}

const re = /static let (\w+) = #"""\n([\s\S]*?)\n"""#/g;
const bad = [];
let found = 0;
let m;
while ((m = re.exec(src))) {
  found++;
  try {
    // The blobs are all bare expressions - an IIFE, or `location.pathname`.
    new Function('return (' + m[2] + ')');
  } catch (e) {
    bad.push(`  ${m[1]}: ${e.message}`);
  }
}

if (found === 0) {
  console.error(
    'check-scrapers: no #""" blobs found in Scrapers.swift.\n' +
      'Either every scraper was removed, or the raw-string delimiters changed\n' +
      'and this hook is now blind. Check before continuing.'
  );
  process.exit(2);
}

if (bad.length) {
  console.error(
    `Broken JavaScript in ${bad.length} of ${found} scraper blobs:\n` +
      bad.join('\n') +
      '\n\nThis compiles fine and fails silently on device. Fix before moving on.'
  );
  process.exit(2);
}

process.exit(0);
