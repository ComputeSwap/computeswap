// Canvas charts (no libraries): the pool's curve in reserve space, the liquidity distribution, and the payoff of the
// ETH weight. All take plain data in human units (see curve.js).
import * as C from "./curve.js";

function theme() {
  const cs = getComputedStyle(document.documentElement);
  const v = (name) => cs.getPropertyValue(name).trim();
  return { fg: v("--fg"), muted: v("--muted"), line: v("--line"), green: v("--green"), navy: v("--navy"), bg: v("--bg") };
}

function setup(canvas) {
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;
  canvas.width = Math.round(w * dpr);
  canvas.height = Math.round(h * dpr);
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  ctx.font = "11px system-ui, -apple-system, Segoe UI, sans-serif";
  return { ctx, w, h };
}

export function fmtNum(v, digits = 4) {
  if (!isFinite(v)) return "–";
  const a = Math.abs(v);
  if (a !== 0 && (a < 1e-3 || a >= 1e7)) return v.toExponential(2);
  return v.toLocaleString(undefined, { maximumFractionDigits: a >= 100 ? 2 : digits });
}

function niceTicks(min, max, count = 4) {
  const raw = (max - min) / count;
  const p = Math.pow(10, Math.floor(Math.log10(raw)));
  const m = raw / p;
  const step = (m < 1.5 ? 1 : m < 3.5 ? 2 : m < 7.5 ? 5 : 10) * p;
  const ticks = [];
  for (let v = Math.ceil(min / step) * step; v <= max + 1e-9 * step; v += step) ticks.push(v);
  return ticks;
}

function logTicks(min, max) {
  const ticks = [];
  for (let e = Math.floor(Math.log10(min)) - 1; e <= Math.ceil(Math.log10(max)); e++) {
    for (const m of [1, 2, 5]) {
      const v = m * Math.pow(10, e);
      if (v >= min && v <= max) ticks.push(v);
    }
  }
  if (ticks.length < 3) {
    for (const m of [1.5, 3, 4, 7]) for (let e = Math.floor(Math.log10(min)); e <= Math.ceil(Math.log10(max)); e++) {
      const v = m * Math.pow(10, e);
      if (v >= min && v <= max) ticks.push(v);
    }
    ticks.sort((a, b) => a - b);
  }
  return ticks;
}

function text(ctx, str, x, y, color, align = "left") {
  // keep labels inside the canvas
  const width = ctx.measureText(str).width;
  const right = ctx.canvas.clientWidth - 4;
  const left0 = align === "right" ? x - width : align === "center" ? x - width / 2 : x;
  x += left0 + width > right ? right - (left0 + width) : left0 < 4 ? 4 - left0 : 0;
  ctx.textAlign = align;
  ctx.fillStyle = color;
  ctx.fillText(str, x, y);
  ctx.textAlign = "left";
}

function dot(ctx, x, y, r, fill, stroke) {
  ctx.beginPath();
  ctx.arc(x, y, r, 0, 2 * Math.PI);
  ctx.fillStyle = fill;
  ctx.fill();
  if (stroke) {
    ctx.strokeStyle = stroke;
    ctx.lineWidth = 2;
    ctx.stroke();
  }
}

function logSpace(a, b, n) {
  const out = [];
  for (let i = 0; i <= n; i++) out.push(a * Math.pow(b / a, i / n));
  return out;
}

function empty(ctx, w, h, t, msg) {
  text(ctx, msg, w / 2, h / 2, t.muted, "center");
}

function baseline(ctx, t, x0, y0, x1, y1) {
  ctx.strokeStyle = t.line;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(x0, y0);
  ctx.lineTo(x1, y1);
  ctx.stroke();
}

// ---------------------------------------------------------------------------------------------------------------------
// Reserve space: the pool's curve (the sum of every position's offset curve), where the pool is now, and - while a
// swap is typed - the path it takes with dots at 25 / 50 / 75 / 100% of the amount.
// ---------------------------------------------------------------------------------------------------------------------
export function drawReserves(canvas, { positions, price, preview }) {
  const { ctx, w, h } = setup(canvas);
  const t = theme();
  if (!positions.length || !price) return empty(ctx, w, h, t, "No liquidity yet");

  const pad = { l: 44, r: 12, t: 12, b: 26 };
  const W = w - pad.l - pad.r;
  const H = h - pad.t - pad.b;
  const lo = Math.min(price, preview ? preview.price : price);
  const hi = Math.max(price, preview ? preview.price : price);
  const pMin = Math.max(Math.min(...positions.map((p) => p.pa)), lo / 1.3);
  const pMax = Math.min(Math.max(...positions.map((p) => p.pb)), hi * 1.3);
  const curve = logSpace(pMin, pMax, 300).map((P) => C.totals(positions, P));
  const xs = curve.map((r) => r.x);
  const ys = curve.map((r) => r.y);
  let [xMin, xMax, yMin, yMax] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
  const xPad = (xMax - xMin) * 0.06 || 1;
  const yPad = (yMax - yMin) * 0.06 || 1;
  [xMin, xMax, yMin, yMax] = [Math.max(0, xMin - xPad), xMax + xPad, Math.max(0, yMin - yPad), yMax + yPad];
  const sx = (x) => pad.l + ((x - xMin) / (xMax - xMin)) * W;
  const sy = (y) => pad.t + H - ((y - yMin) / (yMax - yMin)) * H;

  baseline(ctx, t, pad.l, pad.t + H, pad.l + W, pad.t + H);
  baseline(ctx, t, pad.l, pad.t, pad.l, pad.t + H);
  for (const v of niceTicks(xMin, xMax)) text(ctx, fmtNum(v, 1), sx(v), pad.t + H + 15, t.muted, "center");
  for (const v of niceTicks(yMin, yMax)) text(ctx, fmtNum(v, 1), pad.l - 6, sy(v) + 4, t.muted, "right");
  text(ctx, "ETH", pad.l + W, pad.t + H - 6, t.muted, "right");
  text(ctx, "USDC", pad.l + 6, pad.t + 10, t.muted, "left");

  ctx.save();
  ctx.beginPath();
  ctx.rect(pad.l, pad.t, W, H);
  ctx.clip();
  ctx.strokeStyle = t.navy;
  ctx.lineWidth = 2;
  ctx.beginPath();
  curve.forEach((r, i) => (i ? ctx.lineTo(sx(r.x), sy(r.y)) : ctx.moveTo(sx(r.x), sy(r.y))));
  ctx.stroke();

  const now = C.totals(positions, price);
  if (preview && preview.ok) {
    const path = logSpace(price, preview.price, 60).map((P) => C.totals(positions, P));
    ctx.strokeStyle = t.green;
    ctx.lineWidth = 4;
    ctx.beginPath();
    path.forEach((r, i) => (i ? ctx.lineTo(sx(r.x), sy(r.y)) : ctx.moveTo(sx(r.x), sy(r.y))));
    ctx.stroke();
    for (const f of [0.25, 0.5, 0.75]) {
      const s = C.simulateSwap(positions, price, preview.zeroForOne, preview.exactIn, preview.amount * f);
      if (s.ok) {
        const r = C.totals(positions, s.price);
        dot(ctx, sx(r.x), sy(r.y), 3.5, t.green);
      }
    }
    const end = C.totals(positions, preview.price);
    dot(ctx, sx(end.x), sy(end.y), 6, t.bg, t.green);
    const below = preview.price < price; // selling ETH moves down the curve
    text(ctx, `$${fmtNum(preview.price, 4)}`, sx(end.x) + (below ? 10 : -10), sy(end.y) + (below ? 16 : -10), t.green, below ? "left" : "right");
  }
  dot(ctx, sx(now.x), sy(now.y), 5, t.fg);
  const below = preview && preview.ok && preview.price < price;
  text(ctx, `$${fmtNum(price, 4)}`, sx(now.x) + 10, sy(now.y) + (below ? -8 : 16), t.fg, "left");
  ctx.restore();
}

// ---------------------------------------------------------------------------------------------------------------------
// Liquidity distribution over log-price: each position is a band of height L across its range. Left of the price it
// is held as USDC (green, the band's area there is exactly its USDC), right of it as ETH (navy).
// Returns the bands' rectangles for hit-testing.
// ---------------------------------------------------------------------------------------------------------------------
export function drawLiquidity(canvas, { positions, price, previewPrice, ghost, hoverId }) {
  const { ctx, w, h } = setup(canvas);
  const t = theme();
  const all = ghost ? [...positions, ghost] : positions;
  if (!all.length || !price) {
    empty(ctx, w, h, t, "No liquidity yet");
    return [];
  }
  const pad = { l: 12, r: 12, t: 24, b: 26 };
  const W = w - pad.l - pad.r;
  const H = h - pad.t - pad.b;
  const pMin = Math.min(price, ...all.map((p) => p.pa)) / 1.25;
  const pMax = Math.max(price, ...all.map((p) => p.pb)) * 1.25;
  const lx = (P) => pad.l + (Math.log(P / pMin) / Math.log(pMax / pMin)) * W;
  const edges = [...new Set(all.flatMap((p) => [p.pa, p.pb]))].sort((a, b) => a - b);
  const segments = [];
  let yMax = 0;
  for (let i = 0; i + 1 < edges.length; i++) {
    const mid = Math.sqrt(edges[i] * edges[i + 1]);
    const stack = all.filter((p) => p.pa <= mid && mid < p.pb);
    yMax = Math.max(yMax, stack.reduce((s, p) => s + p.L, 0));
    segments.push({ lo: edges[i], hi: edges[i + 1], stack });
  }
  yMax = (yMax || 1) * 1.1;
  const ly = (L) => pad.t + H - (L / yMax) * H;
  const px = lx(price);

  baseline(ctx, t, pad.l, pad.t + H, pad.l + W, pad.t + H);
  for (const v of logTicks(pMin, pMax)) text(ctx, "$" + fmtNum(v, 2), lx(v), pad.t + H + 15, t.muted, "center");

  const hits = [];
  for (const seg of segments) {
    let base = 0;
    const x0 = lx(seg.lo);
    const x1 = lx(seg.hi);
    for (const p of seg.stack) {
      const yTop = ly(base + p.L);
      const yBot = ly(base);
      if (p === ghost) {
        ctx.setLineDash([4, 3]);
        ctx.strokeStyle = t.muted;
        ctx.lineWidth = 1.5;
        ctx.strokeRect(x0, yTop, x1 - x0, yBot - yTop);
        ctx.setLineDash([]);
      } else {
        const split = Math.min(Math.max(px, x0), x1);
        ctx.globalAlpha = hoverId === undefined || hoverId === p.id ? 1 : 0.55;
        ctx.fillStyle = t.green;
        ctx.fillRect(x0, yTop, split - x0, yBot - yTop);
        ctx.fillStyle = t.navy;
        ctx.fillRect(split, yTop, x1 - split, yBot - yTop);
        ctx.globalAlpha = 1;
        // thin white seams between stacked positions
        ctx.strokeStyle = t.bg;
        ctx.lineWidth = 1;
        ctx.strokeRect(x0, yTop, x1 - x0, yBot - yTop);
        hits.push({ id: p.id, x0, x1, y0: yTop, y1: yBot });
      }
      base += p.L;
    }
  }

  // legend
  ctx.fillStyle = t.green;
  ctx.fillRect(pad.l, 6, 9, 9);
  text(ctx, "USDC", pad.l + 13, 14, t.muted);
  ctx.fillStyle = t.navy;
  ctx.fillRect(pad.l + 52, 6, 9, 9);
  text(ctx, "ETH", pad.l + 65, 14, t.muted);

  // price now, and after the typed swap
  ctx.strokeStyle = t.fg;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.moveTo(px, pad.t - 4);
  ctx.lineTo(px, pad.t + H);
  ctx.stroke();
  text(ctx, `$${fmtNum(price, 4)}`, px, 14, t.fg, "center");
  if (previewPrice && isFinite(previewPrice)) {
    const qx = lx(previewPrice);
    ctx.strokeStyle = t.green;
    ctx.setLineDash([4, 3]);
    ctx.beginPath();
    ctx.moveTo(qx, pad.t);
    ctx.lineTo(qx, pad.t + H);
    ctx.stroke();
    ctx.setLineDash([]);
  }
  return hits;
}

// ---------------------------------------------------------------------------------------------------------------------
// Payoff of an ETH weight: what exercising it at price P is worth, V(P) = P·x(P), on a linear price axis.
//   0 <= P <= pa:  V = L·(P/pa)·(1 − pa/pb)   the ETH amount is at its maximum, its dollar value falls with P
//   pa <= P <= pb: V = L·(1 − P/pb)           the ETH amount shrinks as P rises
//   P >= pb:       V = 0
// Two straight lines meeting at pa: a triangle (long L/pb puts struck at pb, short L/pa puts struck at pa).
// `lines` adds dashed reference levels, e.g. the auction price.
// ---------------------------------------------------------------------------------------------------------------------
export function drawWeightPayoff(canvas, { pa, pb, L, price, lines = [] }) {
  const { ctx, w, h } = setup(canvas);
  const t = theme();
  const labelA = `pa $${fmtNum(pa, 4)}`;
  const labelB = `pb $${fmtNum(pb, 4)}`;
  const pMax = Math.max(pb, price) * 1.15;
  // on a narrow range the pa and pb labels would overlap: then pb goes on a second row
  const gap = ((pb - pa) / pMax) * (w - 28);
  const stacked = gap < (ctx.measureText(labelA).width + ctx.measureText(labelB).width) / 2 + 18;
  const pad = { l: 14, r: 14, t: 18, b: stacked ? 34 : 22 };
  const W = w - pad.l - pad.r;
  const H = h - pad.t - pad.b;
  const peak = L * (1 - pa / pb);
  const value = (P) => (P <= pa ? L * (P / pa) * (1 - pa / pb) : P < pb ? L * (1 - P / pb) : 0);
  const vMax = Math.max(peak, ...lines.map((l) => l.value)) * 1.12 || 1;
  const sx = (P) => pad.l + (P / pMax) * W;
  const sy = (v) => pad.t + H - (v / vMax) * H;
  const y0 = sy(0);
  // labels that would overlap one already drawn move up or down a line
  const boxes = [];
  const place = (str, x, y, color, align = "left") => {
    const tw = ctx.measureText(str).width;
    const left = Math.min(Math.max(align === "right" ? x - tw : align === "center" ? x - tw / 2 : x, 4), w - 4 - tw);
    const free = (yy) => !boxes.some((b) => left < b.r && left + tw > b.l && yy - 10 < b.b && yy + 2 > b.t);
    const yy = [0, -13, 13, -26, 26].map((d) => y + d).find(free) ?? y;
    boxes.push({ l: left - 3, r: left + tw + 3, t: yy - 10, b: yy + 2 });
    ctx.textAlign = "left";
    ctx.fillStyle = color;
    ctx.fillText(str, left, yy);
  };

  // the triangle, lightly filled
  ctx.beginPath();
  ctx.moveTo(sx(0), y0);
  ctx.lineTo(sx(pa), sy(peak));
  ctx.lineTo(sx(pb), y0);
  ctx.closePath();
  ctx.fillStyle = t.navy;
  ctx.globalAlpha = 0.08;
  ctx.fill();
  ctx.globalAlpha = 1;
  baseline(ctx, t, pad.l, y0, pad.l + W, y0);

  // guides and labels at the position's bounds
  ctx.strokeStyle = t.line;
  ctx.setLineDash([3, 3]);
  ctx.beginPath();
  ctx.moveTo(sx(pa), y0);
  ctx.lineTo(sx(pa), sy(peak));
  ctx.stroke();
  ctx.setLineDash([]);
  place(labelA, sx(pa), y0 + 15, t.fg, "center");
  place(labelB, sx(pb), y0 + (stacked ? 28 : 15), t.fg, "center");
  place(`max $${fmtNum(peak, 2)}`, sx(pa), sy(peak) - 7, t.fg, "center");

  // reference levels (auction price)
  for (const l of lines) {
    ctx.strokeStyle = t.muted;
    ctx.setLineDash([5, 4]);
    ctx.beginPath();
    ctx.moveTo(pad.l, sy(l.value));
    ctx.lineTo(pad.l + W, sy(l.value));
    ctx.stroke();
    ctx.setLineDash([]);
  }

  // the payoff: two straight lines meeting at pa, then flat at 0
  ctx.strokeStyle = t.navy;
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(sx(0), y0);
  ctx.lineTo(sx(pa), sy(peak));
  ctx.lineTo(sx(pb), y0);
  ctx.lineTo(sx(pMax), y0);
  ctx.stroke();

  // where the price is now
  const vNow = value(price);
  dot(ctx, sx(price), sy(vNow), 4.5, t.green);
  const right = price > (pa + pb) / 2;
  place(`now $${fmtNum(price, 4)} → $${fmtNum(vNow, 2)}`, sx(price) + (right ? -8 : 8), sy(vNow) + (vNow > peak * 0.8 ? 16 : -8), t.green, right ? "right" : "left");
  // reference labels go where the payoff is low: the left edge if the rising side is shallow, else the right edge
  const left = sx(pa) - pad.l > 0.35 * W;
  for (const l of lines) {
    place(`${l.label} $${fmtNum(l.value, 2)}`, left ? pad.l + 2 : pad.l + W, sy(l.value) - 5, t.muted, left ? "left" : "right");
  }
}
