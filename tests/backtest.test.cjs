const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');
const vm = require('node:vm');

const html = fs.readFileSync(new URL('../index.html', `file://${__filename}`), 'utf8');
const source = html.slice(html.indexOf('  function backtest(d'), html.indexOf('  /* ---- 三个标的并排对比'));

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

test('take-profit sells the configured share once the gain threshold is hit', () => {
  // 第 1 个月涨 50% 触发:卖出一半落袋;第 2 个月腰斩,只有剩下那一半跟着跌
  const result = run([100, 150, 75, ...Array(10).fill(75)], { tp: { x: 0.5, y: 0.5 }, bankM: 0 });
  assert.equal(result.count, 1, result.err);
  assert.equal(result.med, 75);         // 一直拿着:100 → 150 → 75
  assert.equal(result.tp.med, 112.5);   // 止盈:落袋 75 + 剩下的 75 腰斩成 37.5
  assert.equal(result.tp.hitPct, 100);
  assert.equal(result.tp.winPct, 100);
});
