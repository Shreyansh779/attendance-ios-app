// Runs the verify suite whenever the Swift it models changes.
//
// check-scrapers.mjs only parses the JavaScript blobs. The other half of the
// suite is a JS transcription of the maths in Models.swift and Matching.swift,
// guarded by PINS that assert the Swift still contains the exact formulas
// transcribed. A transcription can drift from its original silently, which
// makes that half worse than useless - so the pins have to run on the edit,
// not when somebody remembers.
//
// The suite is ~0.4s with no dependencies. Cheap enough to run on every edit
// under App/.
import { spawnSync } from 'child_process';
import fs from 'fs';

let ev;
try {
  ev = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  process.exit(0); // not invoked as a hook; nothing to do
}

const file = (ev.tool_input?.file_path ?? '').replace(/\\/g, '/');
if (!/\/App\/.*\.swift$/.test(file)) process.exit(0);

const r = spawnSync(process.execPath, ['.claude/skills/verify/run.mjs'], {
  encoding: 'utf8',
});

if (r.status !== 0) {
  console.error(
    'verify failed after that edit:\n\n' +
      ((r.stdout ?? '') + (r.stderr ?? '')).trim() +
      '\n\nIf a PIN failed, the Swift moved and the JS transcription did not.\n' +
      'Fix the transcription in .claude/skills/verify/run.mjs - do not delete\n' +
      'the pin.'
  );
  process.exit(2);
}

process.exit(0);
