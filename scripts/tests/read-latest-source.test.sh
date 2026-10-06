#!/usr/bin/env bash
#
# read-latest-source.test.sh — 「計画の前に取り込み元の最新を読む」（run-cycle 手順2）と
# 「決定の正本は取り込み元の最新。要約は照合用」（手順3 のブリーフ規定）の構造不変条件テスト（Issue #183）。
#
# 実行: bash scripts/tests/read-latest-source.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・awk。
#   - 読み取り専用。書き込みはしない。
#
# 検査の要:
#   - **節を切り出してから検査する**。全文 grep は別の節に同じ語があるだけで真になる。
#   - **手順2 の規定はタスク案を書く規定より前にある**（「タスク案を書く前に読む」を順序でも担保する）。
#   - **fp の一致を「上流が変わっていない」と読まない**こと、**説明欄は正本ではない**ことが残っている。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

RUN_CYCLE="skills/run-cycle/SKILL.md"

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
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "見つからない: $3"; fi; }

step2="$(awk '/^### 2\. /{f=1} /^### 3\. /{f=0} f' "$RUN_CYCLE")"
step3="$(awk '/^### 3\. /{f=1} /^### 4\. /{f=0} f' "$RUN_CYCLE")"

echo "=== (A) 手順2: タスク案を書く前に取り込み元の最新を読む ==="

assert_eq "(A) 手順2 の節を切り出せた（空でない）" "true" \
  "$(if [ -n "$step2" ]; then echo true; else echo false; fi)"
has "(A) 外部取り込み分はタスク案を書く前に最新を読む" "$step2" \
  '**【取り込み元の最新を読む】外部取り込み分（取り込み元マーカーがあるエントリ）は、タスク案を書く前に取り込み元の最新を読む**'
has "(A) 説明欄は正本ではない" "$step2" \
  '台帳の説明欄は ingest-challenges が取り込み時点で作った要約であり、決定の正本ではない'
has "(A) fp の一致は上流が変わっていないことを意味しない" "$step2" \
  '**`fp` の一致も「上流が変わっていない」を意味しない**'
has "(A) github-issue はコメントと参照先（閉じたものを含む）を読む" "$step2" \
  '**github-issue ソースでは、本文に加えてコメントと、本文・コメントが参照する Issue（閉じたものを含む）を読む**'
has "(A) 決定型の Issue は必須" "$step2" \
  '**決定型の Issue**（決定・持ち越しの分岐・「決めること」をコメントに積んでいく Issue。本文が問いの形のものを含む）は**必ず読む**'
has "(A) github-issue 以外はソースが提供する範囲で読む" "$step2" \
  '**github-issue 以外のソースは、そのソースが提供する範囲で最新を読む**'
has "(A) 無効になった本文由来の内容を根拠にしない" "$step2" \
  '**本文由来の内容（説明欄・完了条件）がコメント等の後の決定で無効になっていたら、それをタスク案・完了条件の根拠にしない**'

read_line="$(printf '%s\n' "$step2" | grep -nF '【取り込み元の最新を読む】' | head -1 | cut -d: -f1)"
plan_line="$(printf '%s\n' "$step2" | grep -nF '目標 → タスクに分解し、タスク案を' | head -1 | cut -d: -f1)"
if [ -n "$read_line" ] && [ -n "$plan_line" ] && [ "$read_line" -lt "$plan_line" ]; then
  pass "(A) 最新を読む規定がタスク案を書く規定より前にある（${read_line} < ${plan_line}）"
else
  fail "(A) 最新を読む規定がタスク案を書く規定より前にある" "read=${read_line:-なし} plan=${plan_line:-なし}"
fi

echo ""
echo "=== (B) 手順3: 決定の正本は取り込み元の最新。要約は照合用とブリーフに明記 ==="

assert_eq "(B) 手順3 の節を切り出せた（空でない）" "true" \
  "$(if [ -n "$step3" ]; then echo true; else echo false; fi)"
has "(B) 正本は取り込み元の最新・要約は照合用" "$step3" \
  '**決定の正本は取り込み元の最新（コメントを含む）であり、台帳の要約や親の要約は照合用である——このことをブリーフに明記して渡す**'
has "(B) 子に本文・コメント・参照先を自分で読ませる" "$step3" \
  '**子に本文・コメント・参照先（閉じたものを含む）を自分で読ませる**'
has "(B) 食い違いは要約に合わせて進めず報告させる" "$step3" \
  '**子は要約に合わせて実装を進めず**、食い違いの内容を報告して質問で終了する'

echo ""
echo "pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed: %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0
