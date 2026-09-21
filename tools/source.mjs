// The SideStore source, built from the releases that already exist.
//
//   node tools/source.mjs            # writes _site/
//
// SideStore (and AltStore, which it forks) takes a URL to a JSON file listing
// apps and their versions, checks it periodically, and offers an update when
// it sees a version it does not have. So "a repo" is one static file - which
// means it can be generated from the GitHub releases API and served from
// Pages, with nothing to keep up by hand.
//
// The one thing that needs care here: MARKETING_VERSION is pinned at 2.0 and
// bumped only when a release adds something, while the build number is the CI
// run. A store that dedupes on the version string would therefore see one
// version forever and never offer an update. So the version published here is
// `<marketing>.<build>` - 2.0.105 - which is honest, strictly increasing, and
// unambiguous to any client. `buildVersion` is sent as well for the clients
// that read it.
import fs from 'fs';
import path from 'path';

const REPO = process.env.GITHUB_REPOSITORY || 'Shreyansh779/attendance-ios-app';
const [OWNER, NAME] = REPO.split('/');
const PAGES = process.env.PAGES_URL || `https://${OWNER.toLowerCase()}.github.io/${NAME}`;
const BUNDLE = 'com.shreyansh.today';
const MINT = '#7FD9AE';
const OUT = '_site';

// Enough history to see what changed lately without the file growing forever.
const KEEP = 20;

const api = async (p) => {
  const r = await fetch(`https://api.github.com${p}`, {
    headers: {
      accept: 'application/vnd.github+json',
      ...(process.env.GITHUB_TOKEN ? { authorization: `Bearer ${process.env.GITHUB_TOKEN}` } : {}),
    },
  });
  if (!r.ok) throw new Error(`${p} -> ${r.status} ${await r.text()}`);
  return r.json();
};

// A full page, then sorted here. The releases endpoint orders tags as
// strings, so `build-99` sorts above `build-105` and asking it for the newest
// twenty would have quietly returned the wrong twenty - and the wrong one
// first, which is the version SideStore would have offered as the update.
const releases = await api(`/repos/${REPO}/releases?per_page=100`);

const versions = [];
for (const rel of releases) {
  if (rel.draft) continue;

  const ipa = (rel.assets || []).find((a) => a.name.toLowerCase().endsWith('.ipa'));
  // A release with no IPA is a release nobody can install. Skipped rather
  // than published as a version that would fail on download.
  if (!ipa) continue;

  // `build-105` from the tag; `Today 2.0 (build-105)` from the title. The tag
  // is the reliable one - the title has changed shape before.
  const build = /(\d+)\s*$/.exec(rel.tag_name)?.[1];
  if (!build) continue;
  // The earliest releases were titled `Today build-19`, with no version in
  // them at all. Falling back to the current one would have published those
  // as 2.0.19, which is a claim about a build from before 2.0 existed - so
  // they fall back to 0.0 and read as the prehistory they are.
  const marketing = /Today\s+(\d+(?:\.\d+)*)/.exec(rel.name || '')?.[1] ?? '0.0';

  // The first line of the notes is the commit subject, which is what actually
  // changed. The rest is the same sideloading boilerplate on every release.
  const note = (rel.body || '').split('\n').map((l) => l.trim()).find((l) => l.length > 0);

  versions.push({
    version: `${marketing}.${build}`,
    buildVersion: build,
    date: rel.published_at,
    localizedDescription: note || 'No notes for this build.',
    downloadURL: ipa.browser_download_url,
    size: ipa.size,
    minOSVersion: '26.0',
  });
}

// Newest first, by build number, because that is the only field here that
// actually counts. SideStore offers the first entry, so getting this wrong
// offers an old build as an upgrade.
versions.sort((a, b) => Number(b.buildVersion) - Number(a.buildVersion));
versions.splice(KEEP);

if (!versions.length) throw new Error('no installable releases found');

const app = {
  name: 'Today',
  bundleIdentifier: BUNDLE,
  developerName: 'Shreyansh Singhal',
  subtitle: 'UPES attendance, and whether you can skip',
  localizedDescription: [
    'Reads the UPES student portal and answers one question well: can I skip this class?',
    '',
    'Today shows the class you are walking to and how much room you have left in it.',
    'Attendance shows every subject with the number of classes you can still miss, the',
    'day each one clears 75%, and which one is the blocker. The timetable pages back',
    'through the term as well as forward. Coursework and deadlines come from the LMS,',
    'filtered to the teachers your own timetable says take your classes.',
    '',
    'Arithmetic is integer throughout, so no rounding can shift an answer by one class.',
    'Reminders are scheduled on the phone and nothing leaves it: there is no server, no',
    'account, and the portal session lives in one webview that you log into by hand.',
  ].join('\n'),
  iconURL: `${PAGES}/icon.png`,
  tintColor: MINT,
  category: 'education',
  // Both spellings on purpose. The key was renamed between source format
  // versions and this has to work on whichever one the installed client
  // reads; an unknown key is ignored either way.
  screenshots: SHOTS(),
  screenshotURLs: SHOTS(),
  versions,
};

function SHOTS() {
  const dir = 'shots';
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith('.png'))
    .sort()
    .map((f) => `${PAGES}/shots/${f}`);
}

const source = {
  name: 'Today',
  identifier: `${BUNDLE}.source`,
  subtitle: 'One app, one phone',
  description:
    'The source for Today, an attendance tracker for the UPES student portal. ' +
    'Built unsigned on every push to main; SideStore re-signs it on install.',
  iconURL: `${PAGES}/icon.png`,
  website: `https://github.com/${REPO}`,
  tintColor: MINT,
  apps: [app],
  news: [],
};

fs.mkdirSync(path.join(OUT, 'shots'), { recursive: true });
fs.writeFileSync(path.join(OUT, 'source.json'), JSON.stringify(source, null, 2));
fs.copyFileSync(
  path.join('App', 'Assets.xcassets', 'AppIcon.appiconset', 'icon-1024.png'),
  path.join(OUT, 'icon.png')
);
for (const f of fs.existsSync('shots') ? fs.readdirSync('shots') : []) {
  if (f.endsWith('.png')) fs.copyFileSync(path.join('shots', f), path.join(OUT, 'shots', f));
}

// A page whose only job is the one-tap add. Typing a Pages URL in by hand is
// the worst part of this, and worse than it looks: Sources is not a tab in
// SideStore, it is buried inside Browse, and that is the step people give up
// on. The url scheme skips it entirely.
//
// Both schemes are offered. SideStore forks AltStore, and which of the two a
// build registers depends on how it was made; the wrong one does nothing at
// all, silently, so it is not worth guessing.
const addURL = `sidestore://source?url=${PAGES}/source.json`;
const altURL = `altstore://source?url=${PAGES}/source.json`;
fs.writeFileSync(
  path.join(OUT, 'index.html'),
  `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Today</title>
<style>
  :root { color-scheme: dark; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-content: center;
    gap: 1.5rem; justify-items: center; padding: 2rem 1rem;
    background: #111113; color: #f5f5f7;
    font: 400 1rem/1.55 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
    text-align: center;
  }
  img { width: 108px; height: 108px; border-radius: 24px; }
  h1 { font-family: ui-serif, Georgia, serif; font-size: 2rem; margin: 0; letter-spacing: -0.02em; }
  p { margin: 0; color: #a8a8b3; max-width: 32ch; }
  a.add {
    display: inline-block; text-decoration: none; font-weight: 600;
    padding: 0.85rem 1.6rem; border-radius: 999px;
    background: ${MINT}; color: #131316;
  }
  a.alt {
    text-decoration: none; font-size: 0.85rem; color: #a8a8b3;
    border-bottom: 1px solid rgba(255,255,255,0.2); padding-bottom: 2px;
  }
  b { color: #f5f5f7; font-weight: 600; }
  code {
    display: block; margin-top: 0.5rem; padding: 0.7rem 0.9rem; border-radius: 14px;
    background: rgba(255,255,255,0.055); color: #a8a8b3;
    font-size: 0.8rem; word-break: break-all;
  }
</style>
</head>
<body>
  <img src="icon.png" alt="">
  <h1>Today</h1>
  <p>UPES attendance, and whether you can skip. Version ${versions[0].version}.</p>
  <a class="add" href="${addURL}">Add to SideStore</a>
  <a class="alt" href="${altURL}">Nothing happened? Try AltStore</a>
  <p>By hand: the <b>Browse</b> tab, then <b>Sources</b>, then <b>+</b>, and paste this.
  There is no Sources tab &mdash; it lives inside Browse.<code>${PAGES}/source.json</code></p>
</body>
</html>
`
);

console.log(`${OUT}/source.json  ${versions.length} versions, newest ${versions[0].version}`);
