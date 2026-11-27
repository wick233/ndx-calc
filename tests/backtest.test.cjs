const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');
const vm = require('node:vm');

const html = fs.readFileSync(new URL('../index.html', `file://${__filename}`), 'utf8');
const source = html.slice(html.indexOf('  function btQuantile('), html.indexOf('  /* ---- 三个标的并排对比'));
const pathSource = html.slice(html.indexOf('  function btPath('), html.indexOf('  function drawBtChart('));
const btPath = vm.runInNewContext(pathSource + '\nbtPath');

// 默认方案:本金 100、不定投、投 1 年;over 里可以换年限、加停投/支出/止盈
function run(closes, over = {}) {
  const backtest = vm.runInNewContext(source + '\nbacktest', {
    idxKey: () => 'qqq', IDX: { qqq: { name: 'QQQ' } },
    idxData: () => ({ start: '2000-01', end: '2001-02', closes }),
    idxLabel: () => '2001-02', readVal: () => 0,
    SIMPLE: { btdiv: { value: '0' }, btwin: { value: '0' }, btfx: { value: '0' } },
  });
  return backtest({ yrs: 1, lump: 100, payAt: () => 0, pts: [{ val: 100, prin: 100 }], ...over });
}

test('exactly one year of returns yields one valid window', () => {
  const result = run(Array(13).fill(100));
  assert.equal(result.count, 1, result.err);
  assert.equal(result.med, 100);
});

test('two complete windows are shown and their median averages both outcomes', () => {
  const result = run([...Array(13).fill(100), 200]);
  assert.equal(result.count, 2, result.err);
  assert.equal(result.med, 150);
});

test('less than one year cannot produce a complete window', () => {
  assert.match(run(Array(12).fill(100)).err, /至少 1 年/);
});

test('four windows use the midpoint rather than the higher middle outcome', () => {
  const result = run([...Array(13).fill(100), 200, 300, 400]);
  assert.equal(result.count, 4);
  assert.equal(result.med, 250);
});

// ---- 停投后每月支出:行情全平(月收益为 0),本金 100,第 1 年末停投,第 2 年每月取钱 ----
const flatTwoYears = Array(25).fill(100);

test('money withdrawn after the stop counts as return, not as a loss', () => {
  const result = run(flatTwoYears, { yrs: 2, stop: 1, spend: 5 });
  assert.equal(result.count, 1, result.err);
  assert.equal(result.med, 40);         // 期末账户里还剩 100 − 12×5
  assert.equal(result.medTot, 100);     // 加上取出的 60,正好保本
  assert.equal(result.lossPct, 0);      // 以前只看期末余额 40 < 100,会算成亏损
  assert.equal(result.ruin.n, 0);
});

test('a window drained before the end is counted as depleted, with what was actually withdrawn', () => {
  const result = run(flatTwoYears, { yrs: 2, stop: 1, spend: 30 });
  assert.equal(result.med, 0);
  assert.equal(result.medTot, 100);     // 只取得出账户里有的 100,不是 12×30
  assert.equal(result.lossPct, 0);
  assert.equal(result.ruin.n, 1);
  assert.equal(result.ruin.pct, 100);
  assert.equal(result.ruin.first.m, 16); // 12 个月不动,再取 30、30、30、10
});

test('a plan without a withdrawal phase reports no depletion figure', () => {
  assert.equal(run(Array(13).fill(100)).ruin, null);
  assert.equal(run(flatTwoYears, { yrs: 2, stop: 1, spend: 0 }).ruin, null);
});

test('inflation-indexed withdrawals apply to all three strategies and the chart band', () => {
  const plan = {
    yrs: 2, stop: 1, spend: 5, spendAt: (m) => m >= 12 ? 6 : 5,
    lump: 100, payAt: (m) => m < 12 ? 1 : 0, tp: { x: 0.5, y: 0.5 }, bankM: 0,
    pts: [{ val: 40, prin: 112 }],
  };
  const result = run(flatTwoYears, plan);
  assert.equal(result.med, 40);
  assert.equal(result.medTot, 112);
  assert.equal(result.one.med, 40);
  assert.equal(result.tp.med, 40);
  assert.deepEqual(Array.from(result.band.lo), [100, 112, 40]);
  assert.ok(Math.abs(result.irr.med) < 1e-10);
  for (const strategy of [undefined, 'one', 'tp']) {
    assert.equal(btPath(plan, result.rets, 0, strategy).at(-1), 40);
  }
});

test('annualized cash-flow return recovers a known monthly growth rate', () => {
  const result = run(Array.from({ length: 13 }, (_, i) => 100 * 1.01 ** i), { payAt: () => 25 });
  assert.ok(Math.abs(result.irr.med - (1.01 ** 12 - 1)) < 1e-10);
});

test('peak drawdown ignores deposits; annual bands interpolate across all windows', () => {
  const drawdown = run([100, 150, ...Array(11).fill(75)], { payAt: () => 1000 });
  assert.equal(drawdown.ddWorst.v, -0.5);
  assert.equal(drawdown.dipWorst.v, -0.25);
  const band = run([...Array(13).fill(100), 200]);
  assert.deepEqual(Array.from(band.band.lo), [100, 125]);
  assert.deepEqual(Array.from(band.band.hi), [100, 175]);
});

test('take-profit sells the configured share once the gain threshold is hit', () => {
  // 第 1 个月涨 50% 触发:卖出一半落袋;第 2 个月腰斩,只有剩下那一半跟着跌
  const result = run([100, 150, 75, ...Array(10).fill(75)], { tp: { x: 0.5, y: 0.5 }, bankM: 0 });
  assert.equal(result.count, 1, result.err);
  assert.equal(result.med, 75);         // 一直拿着:100 → 150 → 75
  assert.equal(result.tp.med, 112.5);   // 止盈:落袋 75 + 剩下的 75 腰斩成 37.5
  assert.equal(result.tp.hitPct, 100);
  assert.equal(result.tp.winPct, 100);
  assert.equal(btPath({ yrs: 1, lump: 100, payAt: () => 0, tp: { x: 0.5, y: 0.5 }, bankM: 0 }, result.rets, 0, 'tp').at(-1), result.tp.med);
});

test('mix aligns different calendars and rebalances monthly with a cash sleeve', () => {
  const start = html.indexOf('  function absIndexOf(');
  const helpers = html.slice(start, html.indexOf('  /* ---- 分段定投', start));
  const fxAndMix = html.slice(html.indexOf('  function fxApply('), html.indexOf('  // 止盈规则:'));
  const SIMPLE = { btfx: { value: '0' }, btdiv: { value: '0' } };
  const mixData = vm.runInNewContext(helpers + fxAndMix + '\nmixData', {
    SIMPLE, IDX: { ndx: { yld: 0 }, spx: { yld: 0 } },
    idxData: (key) => key === 'ndx' ? { start: '2000-01', closes: [50, 100, 200, 100, 200] } : { start: '2000-02', closes: [100, 50, 100] },
    endAbs: (d) => (d.start === '2000-01' ? 24000 : 24001) + d.closes.length - 1,
    window: { FX_DATA: { start: '2000-02', closes: [7, 8, 7] } },
    readVal: () => 1.2,
  });
  const equity = mixData([0.5, 0.5, 0]);
  assert.equal(equity.start, '2000-02');
  assert.equal(equity.end, '2000-04');
  assert.ok(Math.abs(equity.closes[2] - 1.249 ** 2) < 1e-12);
  assert.ok(Math.abs(mixData([0, 0, 1]).closes[2] - 1.015 ** (2 / 12)) < 1e-12);
  SIMPLE.btfx.value = '1';
  const fx = mixData([0.5, 0.5, 0]);
  assert.ok(Math.abs(fx.closes[1] - (1.25 * 8 / 7 - 0.001)) < 1e-12);
  assert.ok(Math.abs(mixData([0, 0, 1]).closes[2] - 1.015 ** (2 / 12)) < 1e-12);
});
