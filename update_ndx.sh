#!/usr/bin/env bash
#
# 拉取 纳指100 + 标普500 月末收盘,生成 ndx-data.js / spx-data.js(供 qd.html 历史回测用)。
#
#   bash update_ndx.sh               正常更新
#   bash update_ndx.sh --probe       自检:东财 secid 候选 + 各源可用性,逐个打印
#   bash update_ndx.sh [输出路径]     指定 ndx 输出(默认脚本同目录;spx 落在同目录)
#
# 数据源顺序(每指数独立降级,某指数全失败只保留它的旧文件):
#   东财 push2his(多节点重试) -> FRED REST -> Shiller 学术数据集 -> stooq -> 雅虎
#   -> TwelveData / AlphaVantage / Tiingo(需 key)
#
# 关于 FRED:fredgraph.csv 是网页下载端点,机房 IP 会被 Cloudflare 挂到超时;
# api.stlouisfed.org 才是给程序用的,需免费 key。另外 SP500 序列受 S&P 版权
# 限制只放最近 10 年,所以标普不指望 FRED,靠东财或 Shiller。
#
# 可选配置 ndx.conf(chmod 600):
#   NDX_EMD_SECID=100.NDX      手动钉死东财 secid
#   SPX_EMD_SECID=100.SPX
#   NDX_FRED_KEY=xxx           https://fredaccount.stlouisfed.org/apikeys
#   NDX_12D9_KEY=xxx           https://twelvedata.com/pricing      (800 次/天)
#   NDX_AV_KEY=xxx             https://www.alphavantage.co/support (25 次/天)
#   NDX_TI_KEY=xxx             https://www.tiingo.com/account/general/apikeys
#   NDX_SHILLER_URL=...        覆盖 Shiller 数据集地址
set -euo pipefail

MODE=update
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_NDX=""
for a in "$@"; do
  case "$a" in
    --probe) MODE=probe ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) OUT_NDX="$a" ;;
  esac
done
# 配置文件可能是在 Windows 上编辑的,先剥掉 \r 再 source —— 否则 key 尾部带
# 回车符,发出去的请求必挂,而日志看起来"已配置"。
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
if [[ -f "$SCRIPT_DIR/ndx.conf" ]]; then
  sed 's/\r$//' "$SCRIPT_DIR/ndx.conf" > "$TMPD/conf" && . "$TMPD/conf"
fi
OUT_NDX="${OUT_NDX:-$SCRIPT_DIR/ndx-data.js}"
OUT_DIR="$(cd "$(dirname "$OUT_NDX")" 2>/dev/null && pwd || dirname "$OUT_NDX")"
OUT_SPX="$OUT_DIR/spx-data.js"
thismonth="$(date +%Y-%m)"
RAW=""
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36"
log() { echo "[$(date '+%F %T')] $*"; }
warn() { echo "[$(date '+%F %T')] $*" >&2; }

# CentOS/RHEL 自带 curl 的 HTTP/2 实现有 bug(报 92 INTERNAL_ERROR);
# 个别老版本又不认 --http1.1,所以探测一次再决定加不加。
HTTP11=""
if curl --http1.1 --version >/dev/null 2>&1; then HTTP11="--http1.1"; fi
log "curl: $(curl --version | head -1 | cut -d' ' -f1-2)${HTTP11:+ +$HTTP11}"

cf()  { curl -fsSL --connect-timeout 8 --max-time 20 -A "$UA" $HTTP11 "$@"; }
cfr() { cf -e "https://quote.eastmoney.com/" "$@"; }

# ---- 指数档案 ----
KINDS="ndx spx"
declare -A ANAME=(   [ndx]="纳指100"     [spx]="标普500" )
declare -A EMSEARCH=( [ndx]="纳斯达克100" [spx]="标普500" )  # 东财搜索词(仅 --probe 用)
declare -A EMNAME=(  [ndx]="纳斯达克"    [spx]="标普" )     # 返回名称须含此串
declare -A EMBAK=(   [ndx]="100.NDX 106.IXIC 100.NDXI" [spx]="100.SPX 100.INX" )
declare -A FRED=(    [ndx]="NASDAQ100"   [spx]="SP500" )
declare -A FREDFULL=([ndx]=1            [spx]=0 )           # 该指数 FRED 是否给全历史
declare -A STQ=(     [ndx]="%5Endx"      [spx]="%5Espx" )
declare -A YA=(      [ndx]="%5ENDX"      [spx]="%5EGSPC" )
declare -A T12=(     [ndx]="NDX"         [spx]="SPX" )
declare -A TENC=(    [ndx]="usNDX"       [spx]="usINX" )   # 腾讯行情指数代码
declare -A AV=(      [ndx]="NDX"         [spx]="SPY" )
declare -A TIING=(   [ndx]="NDX"         [spx]="SPY" )
declare -A REF=(     [ndx]=29000         [spx]=7700 )       # 末值参考,0.55~1.8 倍算合理
declare -A MINM=(    [ndx]=400           [spx]=240 )        # 防呆:最少月份数
declare -A GLOB=(    [ndx]="NDX_DATA"    [spx]="SPX_DATA" )

SHILLER_URL="${NDX_SHILLER_URL:-https://econ.yale.edu/~shiller/data/ie_data.csv}"

# ================= 东方财富 =================
# push2his 是 DNS 轮询的一堆节点,对机房 IP 有的会直接空响应((52) Empty reply)。
# 同一个域名换编号子域名就是另一批节点,所以内置几个轮着试。
EM_HOSTS=(push2his.eastmoney.com 92.push2his.eastmoney.com 41.push2his.eastmoney.com 23.push2his.eastmoney.com)

# 拉月K。$1=secid $2=输出文件;(可选)$3=只用这一个主机。任一节点拿到就返回。
em_fetch() {
  local sec="$1" out="$2" only="${3:-}" h
  for h in "${EM_HOSTS[@]}"; do
    [[ -n "$only" && "$h" != "$only" ]] && continue
    if curl -fsSL --connect-timeout 5 --max-time 12 -A "$UA" $HTTP11 \
         -e "https://quote.eastmoney.com/" \
         "https://$h/api/qt/stock/kline/get?secid=$sec&fields1=f1,f2,f3&fields2=f51,f53&klt=103&fqt=0&beg=19800101&end=20500101&lmt=1000000" \
         -o "$out" 2>/dev/null && grep -q '"klines":\[' "$out"; then
      return 0
    fi
  done
  return 1
}
# klines 元素形如 "1986-01-31,132.90"
em_parse() {
  grep -o '"klines":\[[^]]*\]' "$1" \
    | sed 's/^"klines":\[//; s/\]$//; s/","/\n/g; s/^"//; s/"$//' \
    | awk -F, '$1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ && $2 ~ /^[0-9.]+$/ && $2+0>0 {print $1, $2}'
}
em_name() { sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "$1" | head -1; }

# 只给 --probe 用:东财搜索接口,名字 -> 候选 secid。正常运行不碰,免得再打爆限流。
em_suggest() {   # $1=查询词
  cf -G --data-urlencode "input=$1" --data "type=14" --data "count=20" \
     "https://searchapi.eastmoney.com/api/suggest/get" -o "$TMPD/sug" || return 1
  {
    grep -o '"QuoteID":"[0-9]\{1,3\}\.[^"]*"' "$TMPD/sug" | sed 's/.*:"//; s/"$//'
    tr '{' '\n' < "$TMPD/sug" | while IFS= read -r o; do
      code=$(printf '%s' "$o" | sed -n 's/.*"Code":"\([^"]*\)".*/\1/p')
      mkt=$(printf '%s' "$o"  | sed -n 's/.*"MarketID":"\{0,1\}\([0-9]\{1,3\}\)".*/\1/p')
      [[ -z "$mkt" ]] && mkt=$(printf '%s' "$o" | sed -n 's/.*"JYS":"\{0,1\}\([0-9]\{1,3\}\)".*/\1/p')
      [[ -n "$code" && -n "$mkt" ]] && printf '%s.%s\n' "$mkt" "$code"
    done
  } 2>/dev/null | grep -E '^[0-9]{1,3}\.[A-Za-z0-9._-]{1,10}$' | sort -u
}

# 判断某 secid 是不是我们真正要的那个指数(名字 + 月份数 + 末值量级)
em_validate() {   # $1=kind $2=secid $3=是否打印(1/0)
  local kind="$1" sec="$2" v="${3:-0}" f="$TMPD/v_$kind" nm n last
  if ! em_fetch "$sec" "$f"; then
    [[ "$v" == 1 ]] && printf '    %-12s 拉取失败(空响应/无数据)\n' "$sec"
    return 1
  fi
  nm="$(em_name "$f")"
  if [[ "$nm" != *"${EMNAME[$kind]}"* ]]; then
    [[ "$v" == 1 ]] && printf '    %-12s 名称不符: %s\n' "$sec" "${nm:-?}"
    return 1
  fi
  em_parse "$f" > "$TMPD/vr_$kind" || true
  read -r n _mx last < <(sort "$TMPD/vr_$kind" | awk -v TM="$thismonth" '
    { m=substr($1,1,7); if(m!=TM) { v[m]=$2; if(m>mx) mx=m } }
    END { c=0; for(k in v) c++; printf "%d %s %.1f\n", c, mx, (mx in v ? v[mx] : 0) }')
  if [[ "${n:-0}" -lt "${MINM[$kind]}" ]]; then
    [[ "$v" == 1 ]] && printf '    %-12s %-14s 月份太少: %s\n' "$sec" "$nm" "$n"
    return 1
  fi
  if ! awk -v g="$last" -v r="${REF[$kind]}" 'BEGIN{exit !(g>r*0.55 && g<r*1.8)}'; then
    [[ "$v" == 1 ]] && printf '    %-12s %-14s 末值量级不符: %s (参考 %s)\n' "$sec" "$nm" "$last" "${REF[$kind]}"
    return 1
  fi
  [[ "$v" == 1 ]] && printf '    %-12s %-14s OK  %s 个月, 最新 %s\n' "$sec" "$nm" "$n" "$last"
  return 0
}

# 正常运行时确定 secid:显式配置 > 内置候选逐个实测。不打搜索接口。
EMUSE=""
resolve_em_secid() {   # $1=kind;设 EMUSE 并 echo
  local kind="$1" cfgvar s
  cfgvar="${SECKEYVAR[$kind]}"
  if [[ -n "${!cfgvar:-}" ]]; then EMUSE="${!cfgvar}"; printf '%s' "$EMUSE"; return 0; fi
  for s in ${EMBAK[$kind]}; do
    if em_validate "$kind" "$s"; then EMUSE="$s"; printf '%s' "$s"; return 0; fi
  done
  EMUSE=""; return 1
}

f_em() {   # $1=kind
  local kind="$1"
  [[ -n "$EMUSE" ]] || return 1
  em_fetch "$EMUSE" "$TMPD/em" || return 1
  em_parse "$TMPD/em" > "$RAW"
  [[ -s "$RAW" ]]
}

# ================= 其它源 =================
f_fred_api() {   # 官方 REST;受版权限制 SP500 只有 10 年,所以只给纳指用
  [[ -n "${NDX_FRED_KEY:-}" ]] || return 1
  [[ "${FREDFULL[$1]}" == 1 ]] || return 1
  cf "https://api.stlouisfed.org/fred/series/observations?series_id=${FRED[$1]}&api_key=$NDX_FRED_KEY&file_type=json&observation_start=1985-01-01" \
     -o "$TMPD/fredapi" || return 1
  grep -q '"observations"' "$TMPD/fredapi" || return 1
  grep -o '"date":"[^"]*","value":"[^"]*"' "$TMPD/fredapi" \
    | sed 's/"date":"//; s/","value":"/ /; s/"$//' \
    | awk '$2 != "." && $2 ~ /^[0-9.]+$/ && $2+0>0 {print $1, $2}' > "$RAW"
  [[ -s "$RAW" ]]
}
# Shiller 学术数据集:标普500 月度,1871 年至今,免 key 的静态 CSV。
# 注意它给的是「当月平均」而非月末收盘,做长期回测够用,量级/新鲜度校验照走。
f_shiller() {   # $1=kind
  [[ "$1" == spx ]] || return 1
  cf "$SHILLER_URL" -o "$TMPD/sh" || return 1
  head -1 "$TMPD/sh" | grep -qi "SP500" || return 1
  # 日期可能是 1871-01-01 或 1871/01/01,两种都吃掉;第2列是月均价
  awk -F, 'NR>1 && $1 ~ /^[0-9]{4}[-\/][0-9]{2}/ && $2 ~ /^[0-9.]+$/ && $2+0>0 {
             d=$1; gsub(/\//,"-",d); if (d ~ /^[0-9]{4}-[0-9]{2}$/) d=d"-01";
             print d, $2 }' "$TMPD/sh" > "$RAW"
  [[ -s "$RAW" ]]
}
f_stooq() {   # $1=kind $2=域名
  cf "https://$2/q/d/l/?s=${STQ[$1]}&i=m" -o "$TMPD/st" || return 1
  head -1 "$TMPD/st" | grep -q "Date,Open" || return 1
  awk -F, 'NR > 1 && $5 ~ /^[0-9.]+$/ && $5+0>0 {print $1, $5}' "$TMPD/st" > "$RAW"
  [[ -s "$RAW" ]]
}
# 腾讯行情月K。real-time-fund 项目同源(qt.gtimg.cn)在同一台机器是通的,
# 指数代码也沿用它的定义: usNDX=纳斯达克100, usINX=标普500。
# 行数据形如 ["2024-12-31","开盘","收盘","高","低","量"...],收盘取第3列。
f_tencent() {   # $1=kind
  local kind="$1" code="${TENC[$kind]}" u
  for u in "https://web.ifzq.gtimg.cn/appstock/app/kline/kline?param=${code},month,,,800" \
           "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=${code},month,,,800,qfq"; do
    if cf "$u" -o "$TMPD/tx" 2>/dev/null; then
      tr ']' '\n' < "$TMPD/tx" \
        | grep -o '"[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]","[0-9.]*","[0-9.]*"' \
        | sed 's/^"//; s/","/ /g; s/"$//' \
        | awk '$3 ~ /^[0-9.]+$/ && $3+0>0 {print $1, $3}' > "$RAW"
      [[ -s "$RAW" ]] && return 0
    fi
  done
  return 1
}
f_yahoo() {   # $1=kind $2=域名
  cf "https://$2/v8/finance/chart/${YA[$1]}?range=60y&interval=1mo" -o "$TMPD/ya" || return 1
  grep -q '"timestamp"' "$TMPD/ya" || return 1
  local ts cs
  ts="$(grep -o '"timestamp":\[[^]]*\]' "$TMPD/ya" | head -1 | sed 's/.*\[//; s/\]//; s/,/\n/g')"
  cs="$(grep -o '"close":\[[^]]*\]' "$TMPD/ya" | head -1 | sed 's/.*\[//; s/\]//; s/,/\n/g')"
  [[ -n "$ts" && -n "$cs" ]] || return 1
  paste <(echo "$ts") <(echo "$cs") | while read -r t c; do
    [[ "$c" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
    echo "$(date -u -d "@$t" +%Y-%m)-01 $c"
  done > "$RAW"
  [[ -s "$RAW" ]]
}
f_12dt() {    # 以下三个都要 ndx.conf 里的 key,没配直接跳过。
  [[ -n "${NDX_12D9_KEY:-}" ]] || return 1
  local s
  # 指数字符各家写法不一(TwelveData 的标普是 ".SPX",纳指 "NDX"/".NDX" 都行)
  for s in "${T12[$1]}" ".${T12[$1]}"; do
    cf "https://api.twelvedata.com/time_series?symbol=${s}&interval=1month&outputsize=600&format=JSON&apikey=$NDX_12D9_KEY" \
       -o "$TMPD/td" || continue
    if grep -q '"datetime"' "$TMPD/td"; then
      tr '{' '\n' < "$TMPD/td" | while IFS= read -r o; do
        d=$(printf '%s' "$o" | sed -n 's/.*"datetime":"\([0-9-]\{10\}\)".*/\1/p')
        c=$(printf '%s' "$o" | sed -n 's/.*"close":"\([0-9.]*\)".*/\1/p')
        [[ -n "$d" && -n "$c" ]] && printf '%s %s\n' "$d" "$c"
      done > "$RAW"
      [[ -s "$RAW" ]] && return 0
    fi
  done
  # 把对端原文头 160 字丢给 stderr,--probe 会显示,方便区分限流/符号错/额度用尽
  head -c 160 "$TMPD/td" >&2 2>/dev/null; echo >&2
  return 1
}
f_av() {
  [[ -n "${NDX_AV_KEY:-}" ]] || return 1
  cf "https://www.alphavantage.co/query?function=TIME_SERIES_MONTHLY_ADJUSTED&symbol=${AV[$1]}&apikey=$NDX_AV_KEY" \
     -o "$TMPD/av" || return 1
  grep -q '"Monthly Adjusted Time Series"' "$TMPD/av" || return 1
  tr '{' '\n' < "$TMPD/av" | while IFS= read -r o; do
    d=$(printf '%s' "$o" | sed -n 's/.*"\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)".*/\1/p')
    c=$(printf '%s' "$o" | sed -n 's/.*"4\. Close":"\([0-9.]*\)".*/\1/p')
    [[ -n "$d" && -n "$c" ]] && printf '%s %s\n' "$d" "$c"
  done > "$RAW"
  [[ -s "$RAW" ]]
}
f_tiingo() {
  [[ -n "${NDX_TI_KEY:-}" ]] || return 1
  cf -H "Authorization: Bearer $NDX_TI_KEY" \
     "https://api.tiingo.com/tiingo/daily/${TIING[$1]}/prices?startDate=1985-01-01&format=json" \
     -o "$TMPD/ti" || return 1
  grep -q '"close"' "$TMPD/ti" || return 1
  tr '{' '\n' < "$TMPD/ti" | while IFS= read -r o; do
    d=$(printf '%s' "$o" | sed -n 's/.*"date":"\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)".*/\1/p')
    c=$(printf '%s' "$o" | sed -n 's/.*"close":"\([0-9.]*\)".*/\1/p')
    [[ -n "$d" && -n "$c" ]] && printf '%s %s\n' "$d" "$c"
  done > "$RAW"
  [[ -s "$RAW" ]]
}
f_fredgraph() {   # 网页下载端点,机房 IP 基本被 Cloudflare 挂住 —— 只当最后兜底
  cf "https://fred.stlouisfed.org/graph/fredgraph.csv?id=${FRED[$1]}" -o "$TMPD/fg" || return 1
  head -1 "$TMPD/fg" | grep -q "observation_date" || return 1
  awk -F, 'NR > 1 && $2 ~ /^[0-9.]+$/ && $2+0>0 {print $1, $2}' "$TMPD/fg" > "$RAW"
  [[ -s "$RAW" ]]
}

# ================= 生成 =================
gen_one() {
  local kind="$1" out="$2" SRC=""
  mkdir -p "$TMPD/$kind"
  RAW="$TMPD/$kind/daily.txt"

  if resolve_em_secid "$kind" >/dev/null 2>&1; then
    log "  东财 secid: $EMUSE"
  else
    warn "  东财 secid 未找到(可跑 --probe 查看候选),继续试其它源"
  fi

  try() {
    [[ -n "$SRC" ]] && return 0
    if "${@:2}"; then SRC="$1"; log "  数据源: $1 ($(wc -l < "$RAW") 条)"; else log "  源失败: $1"; fi
  }
  try "eastmoney"    f_em "$kind"
  try "fred-api"     f_fred_api "$kind"
  try "tencent"      f_tencent "$kind"
  try "shiller"      f_shiller "$kind"
  try "stooq.com"    f_stooq "$kind" stooq.com
  try "stooq.pl"     f_stooq "$kind" stooq.pl
  try "yahoo1"       f_yahoo "$kind" query1.finance.yahoo.com
  try "yahoo2"       f_yahoo "$kind" query2.finance.yahoo.com
  try "twelvedata"   f_12dt "$kind"
  try "alphavantage" f_av "$kind"
  try "tiingo"       f_tiingo "$kind"
  try "fred-graph"   f_fredgraph "$kind"
  [[ -n "$SRC" ]] || { warn "[FAIL] ${ANAME[$kind]} 所有数据源都拉不到"; return 1; }

  sort "$RAW" | awk -v TM="$thismonth" '
    { m = substr($1, 1, 7); if (m != TM) v[m] = $2 + 0 }
    END { for (m in v) printf "%s %.1f\n", m, v[m] }
  ' | sort > "$TMPD/$kind/months"

  local n lastm lm start end closes today lastv
  n="$(wc -l < "$TMPD/$kind/months" | tr -d ' ')"
  [[ "$n" -ge "${MINM[$kind]}" ]] || { warn "[FAIL] ${ANAME[$kind]} 只解析到 $n 个月,疑似源不全"; return 1; }
  lastm="$(tail -1 "$TMPD/$kind/months" | cut -d' ' -f1)"
  lm="$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m)"
  [[ "$lastm" == "$thismonth" || "$lastm" == "$lm" ]] || {
    warn "[FAIL] ${ANAME[$kind]} 最新数据只到 $lastm(预期 $lm),该源疑似停更,放弃"; return 1; }
  lastv="$(tail -1 "$TMPD/$kind/months" | awk '{print $2}')"
  awk -v g="$lastv" -v r="${REF[$kind]}" 'BEGIN{exit !(g>r*0.55 && g<r*1.8)}' || {
    warn "[FAIL] ${ANAME[$kind]} 最新值 $lastv 与参考量级 $r 差太远,放弃该源"; return 1; }

  start="$(head -1 "$TMPD/$kind/months" | cut -d' ' -f1)"
  end="$lastm"
  closes="$(awk '{printf "%s%.1f", (NR > 1 ? "," : ""), $2}' "$TMPD/$kind/months")"
  today="$(date +%F)"

  mkdir -p "$(dirname "$out")"
  {
    echo "/* ${ANAME[$kind]} 月末收盘,由 update_ndx.sh 自动生成,勿手改 (源: $SRC) */"
    echo "/* 不含分红 $start ~ $end 共 $n 个月 */"
    echo "window.${GLOB[$kind]} = {start:'$start', end:'$end', updated:'$today', months:$n, closes:[$closes]};"
  } > "$out.tmp" && mv -f "$out.tmp" "$out"
  log "[OK] ${ANAME[$kind]} $start ~ $end 共 $n 个月 -> $out"
}

# ================= 自检 =================
# 注意参数顺序:源函数约定 $1=kind,后面才是域名等附加参数。
# 数组取值全部带 :- 兜底 —— 传错 key 时 set -u 会直接把脚本静默杀掉(踩过)。
probe_src() {   # probe_src 显示名 函数 [参数...]
  local nm="$1"; shift
  local why=""
  case "$nm" in
    twelvedata)   [[ -n "${NDX_12D9_KEY:-}" ]] && why="(已配key但请求失败/格式不符)" || why="(未配 NDX_12D9_KEY)";;
    alphavantage) [[ -n "${NDX_AV_KEY:-}" ]]   && why="(已配key但请求失败/格式不符)" || why="(未配 NDX_AV_KEY)";;
    tiingo)       [[ -n "${NDX_TI_KEY:-}" ]]   && why="(已配key但请求失败/格式不符)" || why="(未配 NDX_TI_KEY)";;
    fred-api)     if [[ "${FREDFULL[${kind}]:-}" != 1 ]]; then why="(该指数 FRED 只放10年,主动跳过)"
                  elif [[ -z "${NDX_FRED_KEY:-}" ]]; then why="(未配 NDX_FRED_KEY)"
                  else why="(已配key但请求失败)"; fi;;
    shiller)      [[ "${kind:-}" == spx ]] || why="(数据集只含标普,主动跳过)";;
  esac
  # twelvedata 已配 key 时不吞 stderr —— 失败时 f_12dt 会把对端原文打出来。
  # || true 必须有:裸调用失败会在 set -e 下直接杀掉整个 probe。
  if [[ "$nm" == twelvedata && -n "${NDX_12D9_KEY:-}" ]]; then
    "$@" || true
  else
    "$@" 2>/dev/null || true
  fi
  if [[ -s "$RAW" ]]; then
    printf '  %-13s OK  %s 条\n' "$nm" "$(wc -l < "$RAW")"
  else
    printf '  %-13s 不可用%s\n' "$nm" "$why"
  fi
  : > "$RAW"
}
probe() {
  declare -A SECKEYVAR=([ndx]="NDX_EMD_SECID" [spx]="SPX_EMD_SECID")
  for kind in $KINDS; do
    echo "======== ${ANAME[$kind]} ========"
    echo "-- 东方财富 secid 实测(搜索接口候选 + 内置兜底)"
    local s found=""
    for s in $( { em_suggest "${EMSEARCH[$kind]}" 2>/dev/null || echo "(搜索接口不可达)"
                 printf '%s\n' ${EMBAK[$kind]}; } | grep -E '^[0-9]{1,3}\.' | sort -u ); do
      em_validate "$kind" "$s" 1 && found="$found $s"
    done
    if [[ -n "$found" ]]; then
      echo "  => 可用:$found"
      echo "  钉死它: echo '${SECKEYVAR[$kind]}=${found##* }' >> $SCRIPT_DIR/ndx.conf"
    else
      echo "  => 东财没有通过校验的 secid"
    fi
    echo "-- 其它源"
    RAW="$TMPD/pb_$kind"; : > "$RAW"
    probe_src "fred-api"     f_fred_api "$kind"
    probe_src "tencent"      f_tencent "$kind"
    probe_src "shiller"      f_shiller "$kind"
    probe_src "stooq.com"    f_stooq "$kind" stooq.com
    probe_src "stooq.pl"     f_stooq "$kind" stooq.pl
    probe_src "yahoo1"       f_yahoo "$kind" query1.finance.yahoo.com
    probe_src "yahoo2"       f_yahoo "$kind" query2.finance.yahoo.com
    probe_src "twelvedata"   f_12dt "$kind"
    probe_src "alphavantage" f_av "$kind"
    probe_src "tiingo"       f_tiingo "$kind"
    probe_src "fred-graph"   f_fredgraph "$kind"
  done
}

declare -A SECKEYVAR=([ndx]="NDX_EMD_SECID" [spx]="SPX_EMD_SECID")
if [[ "$MODE" == probe ]]; then probe; exit 0; fi

okcnt=0
log "== 纳指100 =="
gen_one ndx "$OUT_NDX" && okcnt=$((okcnt + 1)) || true
log "== 标普500 =="
gen_one spx "$OUT_SPX" && okcnt=$((okcnt + 1)) || true

if [[ "$okcnt" -eq 0 ]]; then
  warn "[FAIL] 两个指数都没更新成功"; exit 1
elif [[ "$okcnt" -lt 2 ]]; then
  warn "[WARN] 只更新了 $okcnt 个指数,另一个保留旧文件"
fi
