// The app icon, drawn from the same palette as the app.
//
//   node tools/icon.mjs
//
// There is no image tooling on the dev machine - no Swift compiler either,
// which is the whole shape of this project - so the PNG is written by hand.
// Node's zlib is the only thing needed and it ships with node.
//
// The mark is a T, because the app is Today and New York is the one face this
// app spends on anything that matters. It is drawn here rather than set: the
// font cannot be bundled and tracing the closest installed serif would be a
// worse lie than building the letter honestly. So it is constructed the way a
// transitional serif is - a thick vertical stem, a thinner arm, serifs that
// bracket into both rather than butting against them.
//
// A ring lived here before. It was a progress ring standing in for an idea,
// which is the shape every tracking app reaches for; a letterform is an
// identity and a shape is not.
import zlib from 'zlib';
import fs from 'fs';
import path from 'path';

const SIZE = 1024;
const SS = 4; // subsamples per axis; 16 coverage levels is plenty at this size

// Straight out of Theme.swift.
const GROUND_TOP = [26, 26, 30]; // a shade above bg, so the tile has a top
const GROUND_BOTTOM = [12, 12, 14];
const MINT = [127, 217, 174]; // 0x7FD9AE

// MARK: - The letter
//
// Proportioned against the cap height, the way a type designer would, so the
// numbers below mean something if anyone ever wants a heavier or lighter cut.
const CAP = 560;
const TOP = 226; // optical centre sits a touch high; a T is top-heavy
const BASE = TOP + CAP;
const MID = SIZE / 2;

const STEM = CAP * 0.122; // the thick stroke
const ARM = CAP * 0.076; // the thin one - roughly 0.62 of the stem
const WIDTH = CAP * 0.7; // a T is narrower than it is tall

const SL = MID - STEM / 2;
const SR = MID + STEM / 2;
const AL = MID - WIDTH / 2;
const AR = MID + WIDTH / 2;
const ARM_B = TOP + ARM; // underside of the arm

const SPUR = CAP * 0.055; // the vertical serif hanging off each arm end
const SPUR_B = ARM_B + CAP * 0.132; // dropping properly, not a nub

const FOOT = CAP * 0.058; // the foot serif - thinner than the arm, as it is cut
const FOOT_W = CAP * 0.38;
const FOOT_T = BASE - FOOT;

// Brackets: the curve that carries a stroke into its serif. Without these the
// letter is a slab, and a slab is not what this app's type sounds like.
// Small on purpose. A bracket is a cove where two strokes meet, and at any
// radius that fills the gap it stops being a cove and becomes a rounded
// rectangle punched out of the negative space.
const R_FOOT = CAP * 0.05;
const R_ARM = CAP * 0.03;
const R_SPUR = CAP * 0.022;

const box = (x, y, x0, y0, x1, y1) => x >= x0 && x <= x1 && y >= y0 && y <= y1;

/// A concave fillet in the corner of `box`, curving away from `(kx, ky)` -
/// the corner of that box which sits outside the letter.
const fillet = (x, y, x0, y0, x1, y1, kx, ky, r) =>
  box(x, y, x0, y0, x1, y1) && Math.hypot(x - kx, y - ky) > r;

function inLetter(x, y) {
  // The arm, its two hanging serifs, the stem, and the foot.
  if (box(x, y, AL, TOP, AR, ARM_B)) return true;
  if (box(x, y, AL, ARM_B, AL + SPUR, SPUR_B)) return true;
  if (box(x, y, AR - SPUR, ARM_B, AR, SPUR_B)) return true;
  if (box(x, y, SL, ARM_B, SR, BASE)) return true;
  if (box(x, y, MID - FOOT_W / 2, FOOT_T, MID + FOOT_W / 2, BASE)) return true;

  // Where the stem leaves the arm.
  const a = R_ARM;
  if (fillet(x, y, SL - a, ARM_B, SL, ARM_B + a, SL - a, ARM_B + a, a)) return true;
  if (fillet(x, y, SR, ARM_B, SR + a, ARM_B + a, SR + a, ARM_B + a, a)) return true;

  // Where each arm serif leaves the arm, on its inner side only - the outer
  // side is the edge of the letter and carries no bracket.
  const s = R_SPUR;
  if (fillet(x, y, AL + SPUR, ARM_B, AL + SPUR + s, ARM_B + s, AL + SPUR + s, ARM_B + s, s)) return true;
  if (fillet(x, y, AR - SPUR - s, ARM_B, AR - SPUR, ARM_B + s, AR - SPUR - s, ARM_B + s, s)) return true;

  // Where the stem flares into the foot.
  const f = R_FOOT;
  if (fillet(x, y, SL - f, FOOT_T - f, SL, FOOT_T, SL - f, FOOT_T - f, f)) return true;
  if (fillet(x, y, SR, FOOT_T - f, SR + f, FOOT_T, SR + f, FOOT_T - f, f)) return true;

  return false;
}

// MARK: - Render

const px = Buffer.alloc(SIZE * SIZE * 3);

for (let y = 0; y < SIZE; y++) {
  // The ground does not vary across a row, so it is computed per subrow.
  for (let x = 0; x < SIZE; x++) {
    let r = 0, g = 0, b = 0;

    for (let sy = 0; sy < SS; sy++) {
      const py = y + (sy + 0.5) / SS;
      const k = py / SIZE;
      const gr = GROUND_TOP[0] + (GROUND_BOTTOM[0] - GROUND_TOP[0]) * k;
      const gg = GROUND_TOP[1] + (GROUND_BOTTOM[1] - GROUND_TOP[1]) * k;
      const gb = GROUND_TOP[2] + (GROUND_BOTTOM[2] - GROUND_TOP[2]) * k;

      for (let sx = 0; sx < SS; sx++) {
        const pxx = x + (sx + 0.5) / SS;
        if (inLetter(pxx, py)) {
          r += MINT[0];
          g += MINT[1];
          b += MINT[2];
        } else {
          r += gr;
          g += gg;
          b += gb;
        }
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

// One filter byte per scanline, filter 0 throughout: the image is mostly flat
// colour, so deflate does the work and paeth would buy nothing.
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
