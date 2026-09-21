// Guards the one XcodeGen mistake that has already cost a build.
//
// `INFOPLIST_FILE` already points the build at App/Info.plist. Listing the
// same file under `sources:` makes XcodeGen *also* add it to Copy Bundle
// Resources, so two build phases write the same path and the build fails
// after linking - producing a bundle containing only the binary. There is no
// Swift compiler on this machine, so the failure is discovered by a push and
// a full CI run.
//
// One regex here turns a 30-second round trip into an immediate refusal.
import fs from 'fs';

let ev;
try {
  ev = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  process.exit(0); // not invoked as a hook; nothing to do
}

const file = (ev.tool_input?.file_path ?? '').replace(/\\/g, '/');
if (!/\/project\.yml$/.test(file)) process.exit(0);

let src;
try {
  src = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
} catch {
  process.exit(0); // deleted or moved between the edit and this check
}

// `sources:` runs until the next key at the same indent. Info.plist is only a
// problem inside that block; it is required as INFOPLIST_FILE elsewhere.
// No /m: `$` must mean end of file, or it ends the block at the first newline.
const m = /(?:^|\n)([ \t]*)sources:[ \t]*\n([\s\S]*?)(?=\n\1[^ \t\n]|$)/.exec(src);
if (m && /Info\.plist/.test(m[2])) {
  console.error(
    'project.yml lists Info.plist under `sources:`.\n\n' +
      'INFOPLIST_FILE already targets it. Leaving it in sources makes XcodeGen\n' +
      'add it to Copy Bundle Resources as well, so two build phases write the\n' +
      'same path and the build fails after linking. This has happened before\n' +
      'and it ships a bundle containing only the binary.\n\n' +
      'Exclude it, the way the current file does.'
  );
  process.exit(2);
}

if (!/MARKETING_VERSION/.test(src)) {
  console.error(
    'project.yml no longer sets MARKETING_VERSION.\n\n' +
      'Settings shows it next to the CI build number so a bug report can start\n' +
      'from which build is actually on the phone. Put it back.'
  );
  process.exit(2);
}

process.exit(0);
