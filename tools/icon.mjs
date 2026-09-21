// The app icon, drawn from the same palette as the app.
//
//   node tools/icon.mjs
//
// There is no image tooling on the dev machine - no Swift compiler either,
// which is the whole shape of this project - so the PNG is written by hand.
// Node's zlib is the only thing needed and it ships with node.
//
// The mark is the threshold: a ring three quarters closed, which is the one
// number this app exists to answer against. Mint for the part that is done,
// the app's own dim track for what is missing, on the app's own ground. No
// letter, no glyph, nothing that needs reading at 40 points.
import zlib from 'zlib';
import fs from 'fs';
import path from 'path';

const SIZE = 1024;
const CX = SIZE / 2;
const CY = SIZE / 2;
const R = 330; // ring radius, leaving ~13% margin, which is where an iOS icon breathes
const W = 96; // stroke, as chunky as the meters in the app
const SS = 4; // subsamples per axis; 16 levels of coverage is plenty here

// Straight out of Theme.swift.
const GROUND_TOP = [26, 26, 30]; // a shade above bg, so the square is not flat
const GROUND_BOTTOM = [12, 12, 14];
const TRACK = [48, 48, 50]; // `track`: white at 13% over the ground
const MINT = [127, 217, 174]; // 0x7FD9AE
const GLOW = 0.05; // the lit edge the cards have, as the faintest halo

const TAU = Math.PI * 2;
const SWEEP = TAU * 0.75; // THRESHOLD, in radians
// The gap sits centred on twelve o'clock rather than starting there. Same
// three quarters either way, but a cap parked at the top reads as a spinner
// caught mid-load; symmetry reads as a mark somebody drew.
const START = -Math.PI / 2 + (TAU - SWEEP) / 2;

const end = (a) => [CX + R * Math.cos(a), CY + R * Math.sin(a)];
const [E0X, E0Y] = end(START);
const [E1X, E1Y] = end(START + SWEEP);

/// Distance from a point to the arc's centre line, capped at both ends the
/// way a rounded stroke is.
function toArc(x, y) {
  const dx = x - CX;
  const dy = y - CY;
  let t = Math.atan2(dy, dx) - START;
  t -= Math.floor(t / TAU) * TAU;
  if (t <= SWEEP) return Math.abs(Math.hypot(dx, dy) - R);
  return Math.min(Math.hypot(x - E0X, y - E0Y), Math.hypot(x - E1X, y - E1Y));
}

const px = Buffer.alloc(SIZE * SIZE * 3);

for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    let r = 0, g = 0, b = 0;

    for (let sy = 0; sy < SS; sy++) {
      for (let sx = 0; sx < SS; sx++) {
        const px_ = x + (sx + 0.5) / SS;
        const py_ = y + (sy + 0.5) / SS;

        // Ground, with the faintest vertical lift so the tile has a top.
        const k = py_ / SIZE;
        let cr = GROUND_TOP[0] + (GROUND_BOTTOM[0] - GROUND_TOP[0]) * k;
        let cg = GROUND_TOP[1] + (GROUND_BOTTOM[1] - GROUND_TOP[1]) * k;
        let cb = GROUND_TOP[2] + (GROUND_BOTTOM[2] - GROUND_TOP[2]) * k;

        // A halo, so the ring sits on the ground rather than being stamped
        // into it - the same reason every card in the app carries a shadow.
        const ring = Math.abs(Math.hypot(px_ - CX, py_ - CY) - R);
        const halo = GLOW * Math.exp(-((ring / (W * 1.6)) ** 2));
        cr += (MINT[0] - cr) * halo;
        cg += (MINT[1] - cg) * halo;
        cb += (MINT[2] - cb) * halo;

        // Track first, then the mint over it: the quarter still to go is
        // visible as the gap, which is the whole point of the mark.
        if (ring <= W / 2) [cr, cg, cb] = TRACK;
        if (toArc(px_, py_) <= W / 2) [cr, cg, cb] = MINT;

        r += cr;
        g += cg;
        b += cb;
      }
    }

    const n = SS * SS;
    const at = (y * SIZE + x) * 3;
    px[at] = Math.round(r / n);
    px[at + 1] = Math.round(g / n);
    px[at + 2] = Math.round(b / n);
  }
}

// MARK: - PNG

const TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc(buf) {
  let c = -1;
  for (const byte of buf) c = TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const sum = Buffer.alloc(4);
  sum.writeUInt32BE(crc(body));
  return Buffer.concat([len, body, sum]);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(SIZE, 0);
ihdr.writeUInt32BE(SIZE, 4);
ihdr[8] = 8; // bit depth
ihdr[9] = 2; // truecolour, no alpha - an iOS app icon must be opaque
ihdr[10] = 0; // deflate
ihdr[11] = 0; // adaptive filtering
ihdr[12] = 0; // no interlace

// One filter byte per scanline. Filter 0 (none) throughout: the image is
// mostly flat colour, so deflate does the work and there is nothing to gain
// from paeth here.
const raw = Buffer.alloc(SIZE * (SIZE * 3 + 1));
for (let y = 0; y < SIZE; y++) {
  raw[y * (SIZE * 3 + 1)] = 0;
  px.copy(raw, y * (SIZE * 3 + 1) + 1, y * SIZE * 3, (y + 1) * SIZE * 3);
}

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);

const out = path.join('App', 'Assets.xcassets', 'AppIcon.appiconset', 'icon-1024.png');
fs.writeFileSync(out, png);
console.log(`${out}  ${SIZE}x${SIZE}  ${(png.length / 1024).toFixed(1)} KB`);
