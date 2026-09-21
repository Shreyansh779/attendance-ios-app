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
import path from 'path';
import { fileURLToPath } from 'url';

let ev;
try {
  ev = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  process.exit(0); // not invoked as a hook; nothing to do
}

const file = (ev.tool_input?.file_path ?? '').replace(/\\/g, '/');
if (!/\/App\/.*\.swift$/.test(file)) process.exit(0);

// Relative to this hook, not to the cwd. A hook invoked from anywhere but the
// repo root would otherwise fail to spawn, and the branch below would read
// that as a failing suite and block every edit under App/.
const suite = path.resolve(fileURLToPath(import.meta.url), '../../skills/verify/run.mjs');

const r = spawnSync(process.execPath, [suite], { encoding: 'utf8' });

// A suite that could not be started is not a suite that failed. `status` is
// null when spawn errored or the process was killed by a signal, and blocking
// an edit on that - with no output to explain it - is worse than not checking.
if (r.error || r.status === null) {
  console.error(
    'run-verify: could not run the suite (' +
      (r.error?.message ?? 'killed by ' + r.signal) +
      ').\nThe edit stands unchecked - run `node .claude/skills/verify/run.mjs`\nby hand.'
  );
  process.exit(0);
}

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
