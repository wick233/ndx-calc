// index.html 里的脚本没有构建步骤,写错一个括号整页就是空白。
// 这里只做一件事:把每段内联 <script> 拿出来编译一遍(不执行),语法错误在这儿就会报出来。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

test('every inline <script> in index.html parses', () => {
  // 带 src 的 <script src="..."> 不匹配这个模式,只取内联的几段:主题早期脚本、内嵌数据、主逻辑
  const blocks = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  assert.ok(blocks.length >= 3, 'expected at least 3 inline scripts, found ' + blocks.length);
  blocks.forEach((code, i) => {
    assert.doesNotThrow(() => new vm.Script(code, { filename: 'index.html#inline-script-' + (i + 1) }));
  });
});
