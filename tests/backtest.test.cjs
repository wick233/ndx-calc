const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');
const vm = require('node:vm');

const html = fs.readFileSync(new URL('../index.html', `file://${__filename}`), 'utf8');
const source = html.slice(html.indexOf('  function backtest(d'), html.indexOf('  /* ---- 三个标的并排对比'));

function run(closes) {
  const backtest = vm.runInNewContext(source + '\nbacktest', {
    idxKey: () => 'qqq', IDX: { qqq: { name: 'QQQ' } },
    idxData: () => ({ start: '2000-01', end: '2001-02', closes }),
    idxLabel: () => '2001-02', readVal: () => 0,
    SIMPLE: { btdiv: { value: '0' }, btwin: { value: '0' }, btfx: { value: '0' } },
  });
  return backtest({ yrs: 1, lump: 100, payAt: () => 0, pts: [{ val: 100, prin: 100 }] });
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
