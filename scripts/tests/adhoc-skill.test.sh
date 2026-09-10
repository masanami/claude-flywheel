#!/usr/bin/env bash
#
# adhoc-skill.test.sh — 差し込み作業スキル（skills/adhoc/SKILL.md）の構造不変条件テスト。
#
# 実行: bash scripts/tests/adhoc-skill.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・awk。テストフレームワーク不使用。
#   - 読み取り専用。
#
# 散文の SKILL.md には型検査もコンパイラも効かず、「文言が在るか」だけを見るテストは、
# 規定が骨抜きになっても緑のままになる。ここで固定するのは次の 4 つの構造:
#
#   1. **正本が 1 箇所**: 記録規律の運用詳細はスキル側にだけ在り、templates/CLAUDE.md へ
#      再掲されていない（否定検査）。**同じ検出語彙をスキル側では在ることの検査に使う**
#      ——両方向に掛けることで、パターンが壊れて否定検査が空虚に真になる形を潰す。
#   2. **書き込み範囲の完全性（語彙駆動）**: run-cycle がコミットするパス集合の正本
#      contracts/cycle-commit-paths.txt の [commit] に載るパスは、**全件**がスキルの
#      「読み取りだけ」側に列挙されている。正本へパスを足したのにスキルが追従しなければ
#      ここで落ちる（2 つのリストを手で同期させない）。
#   3. **代替手段が用意されている**: 「書くな」だけの行を作らない。代替手段の表の各行に
#      行き先（書かず〜／取得しない〜）が書かれていること。禁止だけでは守られない。
#   4. **停止条件の明文化**: 未終了 adhoc_start の扱い 3 点が在る。
#
# **走査対象・抽出結果が空のまま pass しない**ことを各所で確認する（空リストは全称条件を
# 空虚に真にする）。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

SKILL="skills/adhoc/SKILL.md"
CLAUDE_TPL="templates/CLAUDE.md"
COMMIT_PATHS="contracts/cycle-commit-paths.txt"

PASS=0
FAIL=0
FAILED=()

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED+=("$1")
  echo "FAIL - $1"
  [ $# -ge 2 ] && echo "       $2"
  return 0
}
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected=$2 actual=$3"; fi
}

echo "=== (A) 対象ファイルが実在する（0 件の「違反なし」を pass にしない） ==="

for f in "$SKILL" "$CLAUDE_TPL" "$COMMIT_PATHS"; do
  if [ -r "$f" ]; then pass "(A) 読める: ${f}"; else fail "(A) 読める: ${f}" "見つからない"; fi
done

# 以降の検査は 3 ファイルが読めることが前提。読めないなら空虚に真にせずここで落とす。
if [ ! -r "$SKILL" ] || [ ! -r "$CLAUDE_TPL" ] || [ ! -r "$COMMIT_PATHS" ]; then
  echo ""
  echo "=== summary === pass: ${PASS}, fail: ${FAIL}"
  exit 1
fi

echo ""
echo "=== (B) 記録規律の正本はスキル 1 箇所（CLAUDE.md へ再掲しない） ==="

# 「運用詳細」を表す語彙。**同じ語彙を両方向に掛ける**:
#   スキル側に在る（検出器が生きている） ∧ CLAUDE.md 側に無い（正本が 1 箇所）
# 片側だけを見ると、パターンの打ち間違いで否定検査が黙って通る。
DETAIL_TOKENS=(
  'log-run-event.sh'
  'dangling_start'
  'adhoc-YYYYMMDD'
  '--result'
  '代筆'
)
for tok in "${DETAIL_TOKENS[@]}"; do
  if grep -qF -- "$tok" "$SKILL"; then
    pass "(B) 運用詳細がスキル側に在る: ${tok}"
  else
    fail "(B) 運用詳細がスキル側に在る: ${tok}" "${SKILL} に無い（検出語彙が実態とずれている）"
  fi
  if grep -qF -- "$tok" "$CLAUDE_TPL"; then
    fail "(B) 運用詳細が CLAUDE.md に無い: ${tok}" "${CLAUDE_TPL} に再掲されている（正本の二重化）"
  else
    pass "(B) 運用詳細が CLAUDE.md に無い: ${tok}"
  fi
done

# 正本の所在（スキル名）が CLAUDE.md から張られている。詳細を落としたうえで所在も無いと、
# 規定ごと消えたのと同じになる。
if grep -qF -- '/claude-flywheel:adhoc' "$CLAUDE_TPL"; then
  pass "(B) CLAUDE.md が正本の所在（スキル名）を名指ししている"
else
  fail "(B) CLAUDE.md が正本の所在（スキル名）を名指ししている" "/claude-flywheel:adhoc が無い"
fi

# 旧規定（台帳起票と adhoc_start の二者択一）が残っていないこと。並走中の台帳書き込みを
# 許す読み方が復活すると、run-cycle と競合する。
if grep -qF -- '着手前に台帳起票または' "$CLAUDE_TPL"; then
  fail "(B) 旧規定「台帳起票または adhoc_start」が残っていない" "見つかった"
else
  pass "(B) 旧規定「台帳起票または adhoc_start」が残っていない"
fi

echo ""
echo "=== (C) 記録の対（adhoc_start / adhoc_end）が両方在る ==="

for ev in adhoc_start adhoc_end; do
  n="$(grep -cF -- "log-run-event.sh\" ${ev}" "$SKILL")"
  n="$(printf '%s' "$n" | tr -d ' ')"
  if [ "$n" -ge 1 ]; then
    pass "(C) ${ev} の記録コマンドが在る"
  else
    fail "(C) ${ev} の記録コマンドが在る" "log-run-event.sh の呼び出しが見つからない"
  fi
done

echo ""
echo "=== (D) 書き込み範囲の完全性（run-cycle のコミット対象は全件が読み取り専用側） ==="

# 正本は contracts/cycle-commit-paths.txt の [commit] セクション 1 本。ここで表を持たない。
commit_paths="$(awk '/^\[commit\]$/{f=1;next} /^\[/{f=0} f && $0 !~ /^#/ && NF {print $0}' "$COMMIT_PATHS")"
n_paths="$(printf '%s\n' "$commit_paths" | grep -c . )"
n_paths="$(printf '%s' "$n_paths" | tr -d ' ')"
assert_eq "(D) [commit] のパスを 1 件以上抽出できた" "true" \
  "$(if [ "$n_paths" -ge 1 ]; then echo true; else echo false; fi)"

# スキルの「読み取りだけ」の行を 1 行だけ取り出す。行が見つからなければ以降は空虚に真に
# なるため、行の存在自体を検査する。
readonly_line="$(grep -F '**読み取りだけ（書かない）**' "$SKILL" | head -1)"
if [ -n "$readonly_line" ]; then
  pass "(D) スキルに「読み取りだけ」の列挙行が在る"
else
  fail "(D) スキルに「読み取りだけ」の列挙行が在る" "見つからない"
fi

if [ -n "$readonly_line" ] && [ "$n_paths" -ge 1 ]; then
  missing=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$readonly_line" in
      *"$p"*) ;;
      *) missing="${missing} ${p}" ;;
    esac
  done <<EOF
$commit_paths
EOF
  if [ -z "$missing" ]; then
    pass "(D) [commit] のパス ${n_paths} 件がすべて「読み取りだけ」に列挙されている"
  else
    fail "(D) [commit] のパス ${n_paths} 件がすべて「読み取りだけ」に列挙されている" "欠落:${missing}"
  fi

  # 検出器の自己検査: 正本に無いパスは「列挙されている」と判定されないこと。
  case "$readonly_line" in
    *'never-a-cycle-state-file'*) fail "(D) 検出器の自己検査（偽陽性が出ない）" "在るはずのない語にマッチした" ;;
    *) pass "(D) 検出器の自己検査（偽陽性が出ない）" ;;
  esac
fi

echo ""
echo "=== (E) 代替手段が用意されている（禁止だけの行を作らない） ==="

# 「書きたくなったときの代替手段」表の本文行を取り出す（見出し行・区切り行は除く）。
alt_rows="$(awk '
  /書きたくなったときの代替手段/ {f=1; next}
  f && $0 !~ /^\|/ && NF==0 {next}
  f && $0 !~ /^\|/ {f=0}
  f && $0 ~ /^\|/ {
    if ($0 ~ /^\| *---/) next
    if ($0 ~ /書きたくなった対象/) next
    print $0
  }
' "$SKILL")"
n_rows="$(printf '%s\n' "$alt_rows" | grep -c .)"
n_rows="$(printf '%s' "$n_rows" | tr -d ' ')"
assert_eq "(E) 代替手段の表から本文行を 1 行以上抽出できた" "true" \
  "$(if [ "$n_rows" -ge 1 ]; then echo true; else echo false; fi)"

if [ "$n_rows" -ge 1 ]; then
  bare=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    # 行き先（何をするか）が書かれていない行＝禁止だけの行。
    if printf '%s' "$row" | grep -qE '書かず|取得しない|報告に出す'; then
      continue
    fi
    bare=$((bare + 1))
    echo "     禁止だけの行: ${row}"
  done <<EOF
$alt_rows
EOF
  assert_eq "(E) 代替手段の表に「禁止だけの行」が無い（${n_rows} 行）" "0" "$bare"
fi

echo ""
echo "=== (F) 未終了 adhoc_start の停止条件が明文化されている ==="

STOP_PHRASES=(
  '**誰も代筆しない**'
  '同じ `id` で継続する'
  '未記録である事実と `id` を手順5 の報告に明記する'
)
for ph in "${STOP_PHRASES[@]}"; do
  if grep -qF -- "$ph" "$SKILL"; then
    pass "(F) 停止条件が在る: ${ph}"
  else
    fail "(F) 停止条件が在る: ${ph}" "見つからない"
  fi
done

echo ""
echo "=== summary === pass: ${PASS}, fail: ${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  echo "failed:"
  for t in ${FAILED+"${FAILED[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
