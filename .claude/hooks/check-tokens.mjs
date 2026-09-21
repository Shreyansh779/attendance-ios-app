// Keeps raw colour out of the views.
//
// Every colour in this app is a token in Theme.swift, solved once against the
// one ground the app renders on. A raw `Color(red:green:blue:)` or a bare hex
// in a view bypasses the ink ramp: it is not contrast-checked, it does not
// belong to the urgency vocabulary (mint / amber / coral), and nothing in the
// build or the verify suite can see it. It shows up as one row that looks
// slightly wrong on a device, which is the most expensive kind of bug this
// project has.
//
// Theme.swift is where the hexes live, so it is exempt. Everything else under
// App/ has to spell its colour as a token.
import fs from 'fs';

let ev;
try {
  ev = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  process.exit(0); // not invoked as a hook; nothing to do
}

const file = (ev.tool_input?.file_path ?? '').replace(/\\/g, '/');
if (!/\/App\/.*\.swift$/.test(file)) process.exit(0);
// Theme.swift defines the tokens; Demo.swift is DEBUG-only fixture data.
if (/\/(Theme|Demo)\.swift$/.test(file)) process.exit(0);

let src;
try {
  src = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
} catch {
  process.exit(0); // deleted or moved between the edit and this check
}

// `Color(0xRRGGBB)` is the token constructor and only Theme.swift should call
// it; `Color(red:...)`, `UIColor(red:...)` and `.opacity` on a literal white
// are the other ways a raw colour gets in.
const patterns = [
  [/\bColor\(\s*0x[0-9A-Fa-f]{6}/, 'a raw hex'],
  [/\b(Color|UIColor)\(\s*red:/, 'a raw RGB literal'],
  [/\b(Color|UIColor)\(\s*white:/, 'a raw greyscale literal'],
  [/\b(Color|UIColor)\(\s*hue:/, 'a raw HSB literal'],
];

const bad = [];
src.split('\n').forEach((line, i) => {
  if (/^\s*(\/\/|\/\/\/)/.test(line)) return; // a comment may name a hex
  for (const [re, what] of patterns) {
    if (re.test(line)) bad.push(`  ${file}:${i + 1}  ${what}\n    ${line.trim()}`);
  }
});

if (bad.length) {
  console.error(
    `Raw colour outside Theme.swift, in ${bad.length} place${bad.length > 1 ? 's' : ''}:\n` +
      bad.join('\n') +
      '\n\nUse a token from Theme.swift instead (ink/ink2/ink3/ink4, sur/surDim/\n' +
      'surLive/surLow, mint/amber/coral, edge/shade). A raw colour is not\n' +
      'contrast-checked and nothing downstream can see it. If this genuinely\n' +
      'needs a new colour, add it to Theme.swift as a named token.'
  );
  process.exit(2);
}

process.exit(0);
