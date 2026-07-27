// Faithful transliteration of thinking-orbs' src/engine/core.ts + orbits.ts,
// carrying the two AgentNotch deviations (yaw 0.12 -> 0.125, speed magnitude
// quantised to 1/8). Independent implementation used ONLY to generate expected
// values for OrbitsModeTests, so a transcription slip in the Swift port shows up
// as a number mismatch rather than as a wrong-looking orb nobody may screenshot.

const QUANTUM = 1 / 8;
const YAW_RATE = 0.125;
const TILT = 0.3;
const RADIUS_FRACTION = 0.82;

const PROFILE = {
  orbitN: 3,
  ghostN: 10,
  particles: 3,
  ghostR: 2.16,
  ghostA: 0.5,
  partR: 2.88,
  partRDepth: 3.84,
  rsPow: 0.6,
  rMin: 0.3,
};

function hashD(a, b) {
  const h = Math.sin(a * 12.9898 + b * 78.233) * 43758.5453;
  return h - Math.floor(h);
}

function radiusScale(size, pow) {
  return (size / 300) ** pow;
}

function makeProj(yaw, tilt, cx, cy) {
  const st = Math.sin(tilt), ct = Math.cos(tilt);
  const sy = Math.sin(yaw), cyw = Math.cos(yaw);
  return (x, y, z) => {
    const x1 = x * cyw + z * sy;
    const z1 = -x * sy + z * cyw;
    const y1 = y * ct - z1 * st;
    const z2 = y * st + z1 * ct;
    return [cx + x1, cy - y1, z2];
  };
}

function quantise(rate) {
  return Math.round(rate / QUANTUM) * QUANTUM;
}

function dots(size, t, o = PROFILE) {
  const cx = size / 2, cy = size / 2;
  const R = (size / 2) * RADIUS_FRACTION;
  const pt = makeProj(t * YAW_RATE, TILT, cx, cy);
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
  out.sort((a, b) => a.z - b.z);
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

// Periodicity: the whole point of the quantisation. Largest per-dot drift
// between t and t + 16π, which must be floating-point noise and nothing more.
const PERIOD = 2 * Math.PI / QUANTUM;
const drift = (t) => {
  const a = dots(16, t), b = dots(16, t + PERIOD);
  return Math.max(...a.map((d, i) => Math.max(
    Math.abs(d.x - b[i].x), Math.abs(d.y - b[i].y), Math.abs(d.r - b[i].r), Math.abs(d.ink - b[i].ink))));
};

console.log(JSON.stringify({
  hash: [f(hashD(0, 1.7)), f(hashD(0, 5.2)), f(hashD(0, 8.9)),
         f(hashD(1, 1.7)), f(hashD(1, 5.2)), f(hashD(1, 8.9)),
         f(hashD(2, 1.7)), f(hashD(2, 5.2)), f(hashD(2, 8.9))],
  radiusScale16: f(radiusScale(16, 0.6)),
  quantised: [0, 1, 2].map((i) => f(quantise(0.25 + 0.55 * hashD(i, 8.9)))),
  rest: digest(dots(16, 0.6)),
  moving: digest(dots(16, 3.0)),
  // Element-wise, so a transposed basis vector or a mis-sorted array cannot
  // hide behind an aggregate that happens to be time-invariant.
  movingX: dots(16, 3.0).map((d) => f(d.x)),
  periodDrift: [f(drift(0)), f(drift(0.6)), f(drift(3.0))],
}, null, 2));
