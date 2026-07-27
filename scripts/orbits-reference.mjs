// Faithful transliteration of thinking-orbs' src/engine/core.ts, orbits.ts and
// the drawGlobe half of lattice.ts, carrying Peeksy's rate quantisation.
// Independent implementation used ONLY to generate expected values for
// OrbitsModeTests / GlobeModeTests, so a transcription slip in the Swift port
// shows up as a number mismatch rather than as a wrong-looking orb nobody may
// screenshot.
//
//   node scripts/orbits-reference.mjs

const QUANTUM = 1 / 8;
const RADIUS_FRACTION = 0.82;

const ORBITS = {
  orbitN: 3, ghostN: 10, particles: 3,
  ghostR: 2.16, ghostA: 0.5, partR: 2.88, partRDepth: 3.84,
  rsPow: 0.6, rMin: 0.3, yaw: 0.125, tilt: 0.3,
};

// globe base profile x the `size: 20` preset:
//   latRings   max(2, round(17 * sqrt(0.105))) = 6
//   lonDensity max(2, round(44 * sqrt(0.105))) = 14
//   rBase 0.6 * 1.75 = 1.05, rDepth 1.7 * 1.75 = 2.975
//   (rBoost is NOT one of scaleRadii's keys, so it stays 1.0)
const GLOBE = {
  latRings: 6, lonDensity: 14,
  rBase: 1.05, rDepth: 2.975, rBoost: 1.0,
  inkFar: 0.62, inkSpan: 0.54, dimBase: 0.45,
  rsPow: 0.6, rMin: 0.3,
  spin: 0.5,          // already 4/8
  tiltRate: 0.375,    // upstream 0.35, quantised
  scanRate: 5.75,     // upstream 0.5 + (1.7 - 0.5) * 4.335 = 5.702, quantised
};

function hashD(a, b) {
  const h = Math.sin(a * 12.9898 + b * 78.233) * 43758.5453;
  return h - Math.floor(h);
}
function angleDelta(a, b) {
  return Math.atan2(Math.sin(a - b), Math.cos(a - b));
}
function radiusScale(size, pow) {
  return (size / 300) ** pow;
}
function makeProj(yaw, tilt, cx, cy, scale) {
  const st = Math.sin(tilt), ct = Math.cos(tilt);
  const sy = Math.sin(yaw), cyw = Math.cos(yaw);
  return (x, y, z) => {
    const x1 = x * cyw + z * sy;
    const z1 = -x * sy + z * cyw;
    const y1 = y * ct - z1 * st;
    const z2 = y * st + z1 * ct;
    return [cx + x1 * scale, cy - y1 * scale, z2];
  };
}
function quantise(rate) {
  return Math.round(rate / QUANTUM) * QUANTUM;
}

function orbitsDots(size, t, o = ORBITS) {
  const cx = size / 2, cy = size / 2;
  const R = (size / 2) * RADIUS_FRACTION;
  const pt = makeProj(t * o.yaw, o.tilt, cx, cy, 1);
  const rs = radiusScale(size, o.rsPow);
  const out = [];

  for (let orb = 0; orb < o.orbitN; orb++) {
    const h1 = hashD(orb, 1.7), h2 = hashD(orb, 5.2), h3 = hashD(orb, 8.9);
    const ro = R * (0.45 + 0.52 * h1);
    const th = h1 * 2 * Math.PI;
    const phi = Math.acos(2 * h2 - 1);
    const nx = Math.sin(phi) * Math.cos(th);
    const ny = Math.cos(phi);
    const nz = Math.sin(phi) * Math.sin(th);
    let ux = -ny, uy = nx;
    const uz = 0;
    const ul = Math.max(1e-6, Math.sqrt(ux * ux + uy * uy));
    ux /= ul; uy /= ul;
    const vx = ny * uz - nz * uy;
    const vy = nz * ux - nx * uz;
    const vz = nx * uy - ny * ux;
    const mag = quantise(0.25 + 0.55 * h3);
    const speed = h3 > 0.5 ? mag : -mag;

    for (let k = 0; k < o.ghostN; k++) {
      const a = (k / o.ghostN) * 2 * Math.PI;
      const [px, py, z] = pt(
        (ux * Math.cos(a) + vx * Math.sin(a)) * ro,
        (uy * Math.cos(a) + vy * Math.sin(a)) * ro,
        (uz * Math.cos(a) + vz * Math.sin(a)) * ro,
      );
      const depth = (z / ro + 1) / 2;
      out.push({ x: px, y: py, z, r: Math.max(o.rMin, o.ghostR * rs), ink: 0.72, a: o.ghostA * (0.4 + 0.6 * depth) });
    }
    for (let m = 0; m < o.particles; m++) {
      const a = t * speed + (m / o.particles) * 2 * Math.PI + h2 * 6;
      const [px, py, z] = pt(
        (ux * Math.cos(a) + vx * Math.sin(a)) * ro,
        (uy * Math.cos(a) + vy * Math.sin(a)) * ro,
        (uz * Math.cos(a) + vz * Math.sin(a)) * ro,
      );
      const depth = (z / ro + 1) / 2;
      out.push({ x: px, y: py, z, r: Math.max(o.rMin, (o.partR + o.partRDepth * depth) * rs), ink: 0.3 - 0.22 * depth, a: 1 });
    }
  }
  // Total order, not just by depth: a globe frame has 54 dots but only 37
  // distinct z values, and ties permuting between frames looks exactly like
  // motion to an index-wise comparison. Swift's sort is not stable either.
  out.sort((a, b) => a.z - b.z || a.x - b.x || a.y - b.y);
  return out;
}

function globeDots(size, t, o = GLOBE) {
  const cx = size / 2, cy = size / 2;
  const radius = (size / 2) * RADIUS_FRACTION;
  const tilt = 0.4 + 0.06 * Math.sin(t * o.tiltRate);
  const pt = makeProj(t * o.spin, tilt, cx, cy, radius);
  const scan = t * o.scanRate;
  const rs = radiusScale(size, o.rsPow);
  const out = [];

  for (let li = 0; li <= o.latRings; li++) {
    const lat = -Math.PI / 2 + (li / o.latRings) * Math.PI;
    const cosLat = Math.cos(lat), sinLat = Math.sin(lat);
    const lonCount = Math.max(1, Math.round(Math.abs(cosLat) * o.lonDensity));
    for (let lj = 0; lj < lonCount; lj++) {
      const lon = (lj / lonCount) * 2 * Math.PI;
      const [px, py, z] = pt(cosLat * Math.cos(lon), sinLat, cosLat * Math.sin(lon));
      const depth = (z + 1) / 2;
      const d = angleDelta(lon + t * o.spin, scan);
      const boost = Math.exp(-(d * d) / 0.18) * Math.max(0, z);
      out.push({
        x: px, y: py, z,
        r: Math.max(o.rMin, (o.rBase + o.rDepth * depth + o.rBoost * boost) * rs),
        ink: o.inkFar - o.inkSpan * depth,
        a: o.dimBase + (1 - o.dimBase) * Math.min(1, boost),
      });
    }
  }
  // Total order, not just by depth: a globe frame has 54 dots but only 37
  // distinct z values, and ties permuting between frames looks exactly like
  // motion to an index-wise comparison. Swift's sort is not stable either.
  out.sort((a, b) => a.z - b.z || a.x - b.x || a.y - b.y);
  return out;
}

const f = (n) => Number(n.toFixed(9));
const digest = (ds) => ({
  count: ds.length,
  sumX: f(ds.reduce((s, d) => s + d.x, 0)),
  sumY: f(ds.reduce((s, d) => s + d.y, 0)),
  sumZ: f(ds.reduce((s, d) => s + d.z, 0)),
  sumR: f(ds.reduce((s, d) => s + d.r, 0)),
  sumInk: f(ds.reduce((s, d) => s + d.ink, 0)),
  sumAlpha: f(ds.reduce((s, d) => s + d.a, 0)),
  first: [f(ds[0].x), f(ds[0].y), f(ds[0].z), f(ds[0].r), f(ds[0].ink), f(ds[0].a)],
  last: [f(ds.at(-1).x), f(ds.at(-1).y), f(ds.at(-1).z), f(ds.at(-1).r), f(ds.at(-1).ink), f(ds.at(-1).a)],
});

// Periodicity: the whole point of the quantisation. The frame at t and the
// frame at t + 16π must be the same picture.
//
// Compared as an order-insensitive MULTISET, per component. Index-wise looks
// broken and is not: at t = 0 the globe is a symmetric configuration where 17
// of its 54 dots tie on depth, and their x/y differ between the two frames only
// by float noise — so any total order permutes them and an index-wise diff
// reports a drift of ~13pt on a 16pt canvas while the picture is pixel-
// identical. Sorting each component independently asks the only question that
// matters: is the same set of dots in the same set of places?
const PERIOD = 2 * Math.PI / QUANTUM;
const drift = (fn) => (t) => {
  const a = fn(16, t), b = fn(16, t + PERIOD);
  if (a.length !== b.length) return Infinity;
  const worst = (key) => {
    const xs = a.map((d) => d[key]).sort((p, q) => p - q);
    const ys = b.map((d) => d[key]).sort((p, q) => p - q);
    return Math.max(...xs.map((v, i) => Math.abs(v - ys[i])));
  };
  return Math.max(worst('x'), worst('y'), worst('r'), worst('ink'));
};

console.log(JSON.stringify({
  orbits: {
    rest: digest(orbitsDots(16, 0.6)),
    moving: digest(orbitsDots(16, 3.0)),
    movingX: orbitsDots(16, 3.0).map((d) => f(d.x)),
    periodDrift: [0, 0.6, 3.0].map(drift(orbitsDots)).map(f),
  },
  globe: {
    rest: digest(globeDots(16, 0.6)),
    moving: digest(globeDots(16, 3.0)),
    movingX: globeDots(16, 3.0).map((d) => f(d.x)),
    periodDrift: [0, 0.6, 3.0].map(drift(globeDots)).map(f),
  },
  shared: {
    hash: [f(hashD(0, 1.7)), f(hashD(0, 5.2)), f(hashD(0, 8.9)),
           f(hashD(1, 1.7)), f(hashD(1, 5.2)), f(hashD(1, 8.9)),
           f(hashD(2, 1.7)), f(hashD(2, 5.2)), f(hashD(2, 8.9))],
    radiusScale16: f(radiusScale(16, 0.6)),
    quantisedOrbitRates: [0, 1, 2].map((i) => f(quantise(0.25 + 0.55 * hashD(i, 8.9)))),
  },
}, null, 2));
