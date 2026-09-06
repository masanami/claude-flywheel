#!/usr/bin/env bash
#
# spec-split-gate.test.sh — run-cycle 手順2 の「対話前提スキルを含む課題はタスク案を
# 仕様書までで区切る」規定と、「L サイズは設計確定だけの委譲を 1 段挟んでよい（任意）」の
# 注記（Issue #145 提案 D）の構造不変条件テスト。
#
# 実行: bash scripts/tests/spec-split-gate.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・awk。読み取り専用。
#
# 検査の要:
#   - **検査は手順2 の節を切り出してから**行う。SKILL.md 全文への grep は、同じ語が手順3 や
#     別の節にあるだけで空虚に真になる（PR #143 / #146 で実測）。
#   - **抽出器を自己検査する**（(A)）。切り出しが壊れて全文が返ると、以降の検査がすべて
#     空虚に真になるため、手順2 固有のアンカーが在ること**と**手順3 固有のアンカーが
#     無いことの両方を見る。
#   - **「規定が手順2 に在る」は出現回数の一致で固定する**（全文の出現回数 == 手順2 内の
#     出現回数）。規定を手順3 や docs へ移しただけでは通らない＝位置まで固定される。
#   - **任意規定は「任意であること」も検査する**。許可（挟んでよい）が義務（必ず挟む）へ
#     書き換わると、S/M と L の扱いを分けた意図が失われるため、否定検査を対で置く。
#   - **規定が参照する先の実在も検査する**（(D)）。手順2 は判定を手順3【意思決定の主体】の
#     判定基準へ委ねており、参照先の見出し語が消えると規定は判定不能になる。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

SKILL_MD="skills/run-cycle/SKILL.md"
POSITION_TPL="templates/position.md"
SOURCES_TPL="templates/challenge-sources.md"

# 規範文（手順2 に逐語で在ることを固定する）。
SPLIT_RULE='タスク案を「仕様書を作る」までで区切る'
REF_TERM='対話前提スキルの判定基準'
REF_PHRASE='手順3【意思決定の主体】の「対話前提スキルの判定基準」で判定'
RESYNC_A='別の課題として台帳に入れ'
RESYNC_B='改めて FR-13 を通る'
L_NOTE='設計確定だけの委譲'
L_PERMIT='1 段挟んでよい'

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
# $2（テキスト）に $3（固定文字列）が含まれる／含まれない
has()   { if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "見つからない: $3"; fi; }
hasnt() { if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1" "見つかった: $3"; else pass "$1"; fi; }
count_of() { printf '%s\n' "$1" | grep -cF -- "$2" | tr -d ' '; }

step2="$(awk '/^### 2\. /{f=1} /^### 3\. /{f=0} f' "${SKILL_MD}")"
step3="$(awk '/^### 3\. /{f=1} /^### 4\. /{f=0} f' "${SKILL_MD}")"
whole="$(cat "${SKILL_MD}")"

echo "=== (A) 抽出器の自己検査（手順2 / 手順3 を取り違えていない） ==="

assert_eq "(A) 手順2 の節を切り出せた（空でない）" "true" \
  "$(if [ -n "${step2}" ]; then echo true; else echo false; fi)"
assert_eq "(A) 手順3 の節を切り出せた（空でない）" "true" \
  "$(if [ -n "${step3}" ]; then echo true; else echo false; fi)"
has   "(A) 手順2 に手順2 固有のアンカーがある" "${step2}" '- 目標 → タスクに分解し'
hasnt "(A) 手順2 に手順3 固有のアンカーが混ざっていない（全文を返していない）" "${step2}" \
  '【費用ガード】委譲コマンドには必ず'
has   "(A) 手順3 に手順3 固有のアンカーがある" "${step3}" '【費用ガード】委譲コマンドには必ず'
hasnt "(A) 手順3 に手順2 固有のアンカーが混ざっていない" "${step3}" '- 目標 → タスクに分解し'

echo ""
echo "=== (B) 手順2: 対話前提スキルを含む課題は仕様書までで区切る ==="

has "(B) 手順2 に区切りの規定がある" "${step2}" "${SPLIT_RULE}"
has "(B) 規定の対象は対話前提スキルを含む課題" "${step2}" '対話前提スキル'
has "(B) 判定は手順3 の判定基準へ委ねる（判定軸を二重定義しない）" "${step2}" "${REF_PHRASE}"
has "(B) ポジションの宣言が優先であることを示す" "${step2}" 'ポジションの宣言が優先'
has "(B) 起票された Issue が別課題として台帳に入る" "${step2}" "${RESYNC_A}"
has "(B) それぞれが改めて FR-13 を通る（期待値の再同期点）" "${step2}" "${RESYNC_B}"
has "(B) 再同期の単位に想定サイズ・予算上限が付く" "${step2}" '自分の `想定サイズ`・`予算上限` を付けて'

# 位置の固定: 全文と手順2 で出現回数が一致する＝手順3 や別節へ移しただけでは通らない。
assert_eq "(B) 区切りの規定が手順2 にちょうど 1 回ある" "1" "$(count_of "${step2}" "${SPLIT_RULE}")"
assert_eq "(B) 区切りの規定は手順2 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step2}" "${SPLIT_RULE}")" "$(count_of "${whole}" "${SPLIT_RULE}")"

echo ""
echo "=== (C) L サイズの注記: 設計確定だけの委譲を 1 段挟んでよい（任意規定） ==="

l_line="$(printf '%s\n' "${step2}" | grep -F -- "${L_NOTE}" | head -1)"
assert_eq "(C) 手順2 に L サイズの注記行がある" "true" \
  "$(if [ -n "${l_line}" ]; then echo true; else echo false; fi)"
has "(C) 注記の対象は想定サイズ L" "${l_line}" '`想定サイズ: L`'
has "(C) 挟むのは設計確定だけの委譲（成果物は触るファイル・PR 分割・後回し）" "${l_line}" \
  '（触るファイル・PR 分割・後回しにするものを成果物にする）'
has "(C) 許可の形で書かれている" "${l_line}" "${L_PERMIT}"
has "(C) 任意規定であることが明示されている" "${l_line}" '**任意**'
# 否定検査（許可 → 義務への書き換えを検出する。向きを (C) の肯定検査と揃えない）
hasnt "(C) 義務化されていない（「必ず」を含まない）" "${l_line}" '必ず'
hasnt "(C) 義務化されていない（「挟む必要がある」を含まない）" "${l_line}" '必要がある'
assert_eq "(C) L サイズの注記が手順2 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step2}" "${L_NOTE}")" "$(count_of "${whole}" "${L_NOTE}")"

echo ""
echo "=== (D) 既存の【意思決定の主体】判定表・ポジション雛形と食い違わない ==="

has "(D) 手順3 に参照先の見出し語がある（手順2 の参照が切れていない）" "${step3}" "${REF_TERM}"
row1="$(printf '%s\n' "${step3}" | grep -F -- '| 1 |' | head -1)"
row3="$(printf '%s\n' "${step3}" | grep -F -- '| 3 |' | head -1)"
assert_eq "(D) 判定表の行 1 がある" "true" \
  "$(if [ -n "${row1}" ]; then echo true; else echo false; fi)"
assert_eq "(D) 判定表の行 3 がある" "true" \
  "$(if [ -n "${row3}" ]; then echo true; else echo false; fi)"
has "(D) 行 1 の条件は対話前提スキル（手順2 と同じ語）" "${row1}" '対話前提スキル'
has "(D) 行 3 の条件は対話前提スキル（手順2 と同じ語）" "${row3}" '対話前提スキル'
has "(D) 行 1 は対話相手が人間の宣言で判定する（ポジション宣言優先と整合）" "${row1}" \
  '§接続ツールの**対話相手が `人間`**'
has "(D) ポジション雛形に対話前提スキルの宣言欄がある" "$(cat "${POSITION_TPL}")" \
  '**対話前提スキルの対話相手**'
has "(D) ポジション雛形の判定語が SKILL.md と同じ（対話前提スキル）" "$(cat "${POSITION_TPL}")" \
  '対話前提スキル ＝ **成果物の中身（何を作るか）を意思決定者との対話で確定させる設計**'
assert_eq "(D) 手順2 が参照する取り込み元の雛形が実在する" "true" \
  "$(if [ -r "${SOURCES_TPL}" ]; then echo true; else echo false; fi)"
has "(D) 手順2 が取り込み元の正本名を参照している" "${step2}" '`challenge-sources.md`'

echo ""
echo "=== summary === pass: ${PASS}, fail: ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  echo "failed:"
  for t in ${FAILED+"${FAILED[@]}"}; do echo "  - ${t}"; done
  exit 1
fi
exit 0
