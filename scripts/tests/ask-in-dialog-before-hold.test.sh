#!/usr/bin/env bash
#
# ask-in-dialog-before-hold.test.sh — run-cycle 手順3 の「保留の前にその場で問う」経路（Issue #192）の
# 構造不変条件テスト。散文の規定が消えた・置き場所から外れたことを機械で検出する。
#
# 実行: bash scripts/tests/ask-in-dialog-before-hold.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・awk。
#   - リポジトリへは書き込まない。
#
# 検査の要:
#   - **規定は 1 箇所に置き、他は参照する**（(B)）。定義行がちょうど 1 つであることと、
#     人間へ問いを上げる 3 箇所（行 1・親も答えられない問い・回答を渡す resume の前）が
#     定義を参照していることを固定する。3 箇所に同じ文を複製すると、片方だけ直す退行が起きる。
#   - **規定は手順3 の中に置く**（(A)）。語が SKILL.md のどこかにあるだけでは通さない。
#   - **保留の経路を消さない**（(D)）。その場で問う経路は保留の前段であって置き換えではない。
#   - **手順1 の真理値表を変えない**（(E)）。その場で答えた周は保留に入らないので、表の行数・
#     保留ステータスは Issue #192 の前後で同じであるべき。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

RUN_CYCLE="skills/run-cycle/SKILL.md"
LEDGER_FMT="docs/challenge-ledger-format.md"
RULE_NAME='【その場で問う】'
ANSWER_COMMENT='<!-- YYYY-MM-DD 対話で回答（<サイクル名>） -->'

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
has() {
  if printf '%s\n' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "見つからない: $2"; fi
}
eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "期待: $3 / 実際: $2"; fi
}
# section <file> <start-regex> <end-regex>: start に一致する行から end に一致する行の手前まで
section() {
  awk -v s="$2" -v e="$3" 'f && $0 ~ e { exit } $0 ~ s { f = 1 } f' "$1"
}
# line_with <text> <fixed-string>: fixed-string を含む行（最初の 1 行）
line_with() { printf '%s\n' "$1" | grep -F -- "$2" | head -1; }

step3="$(section "$RUN_CYCLE" '^### 3\. ' '^### 4\. ')"
# 定義の箇条（定義行から、同じ深さの次の「- **【」の手前まで）
rule="$(printf '%s\n' "$step3" | awk -v n="$RULE_NAME" '
  f && /^  - \*\*【/ { exit }
  index($0, "  - **" n) == 1 { f = 1 }
  f')"

echo "=== (A) 規定が手順3 に在る ==="
if [ -n "$step3" ]; then pass "(A) 手順3 の節を切り出せる（検出器の自己検査）"
else fail "(A) 手順3 の節を切り出せる（検出器の自己検査）" "見出し '### 3. ' / '### 4. ' が見つからない"; fi
if [ -n "$rule" ]; then pass "(A) ${RULE_NAME} の定義が手順3 に在る"
else fail "(A) ${RULE_NAME} の定義が手順3 に在る" "定義行 '  - **${RULE_NAME}' が無い"; fi

echo "=== (B) 定義は 1 箇所・3 箇所から参照 ==="
n_def="$(grep -cF -- "- **${RULE_NAME}" "$RUN_CYCLE")"
eq "(B) ${RULE_NAME} の定義行はちょうど 1 つ" "$n_def" "1"
for anchor in \
  '**人間が意思決定者のとき（行 1）**' \
  '**親も答えられない問いは親が代わりに決めない**' \
  '**回答を渡す resume の前に、その回答を親が出してよいかを確認する**' \
  '**【保留の記録】'; do
  line="$(line_with "$step3" "$anchor")"
  if [ -z "$line" ]; then
    fail "(B) 参照元が手順3 に在る: $anchor" "行が見つからない（見出し語が変わったならテストを追従させる）"
    continue
  fi
  has "(B) ${anchor} が ${RULE_NAME} を参照している" "$RULE_NAME" "$line"
done

echo "=== (C) 経路の中身 ==="
has "(C) 対話実行中でその場に人間がいる場合に限る" 'その場に人間がいる' "$rule"
has "(C) 推奨・選択肢・判断材料を添えて提示する" '推奨 → 選択肢 → 判断材料' "$rule"
has "(C) 回答を人間の回答に記入する" '`人間の回答`' "$rule"
has "(C) 回答の記録コメントが手順1 と同じ形" "$ANSWER_COMMENT" "$rule"
has "(C) 同じ周に resume する" '同じ周にその回答を渡して `--resume` する' "$rule"
has "(C) ステータスは着手中のまま" '`着手中` のまま' "$rule"
has "(C) 人間対応待ちを経由しない" '`人間対応待ち` を経由しない' "$rule"
has "(C) 問い合わせ中も cycle.lock を保持する" '`cycle.lock` を保持する' "$rule"
has "(C) 親が回答を作らない" '親が回答を作らない' "$rule"

echo "=== (D) 保留の経路を残す ==="
has "(D) あとで答えるを選んだら保留" '「あとで答える」' "$rule"
has "(D) 中断を選んだら保留" '「中断」' "$rule"
has "(D) 非対話の実行は保留" '非対話の実行' "$rule"
has "(D) 保留は【保留の記録】に従う" '【保留の記録】に従う' "$rule"
has "(D) 台帳フォーマットにも経路が書かれている" "$RULE_NAME" "$(cat "$LEDGER_FMT")"

echo "=== (E) 手順1 の真理値表を変えない ==="
step1="$(section "$RUN_CYCLE" '^### 1\. ' '^### 2\. ')"
n_rows="$(printf '%s\n' "$step1" | grep -cE '^  \| [0-9]+ \|')"
eq "(E) 真理値表は 3 行のまま" "$n_rows" "3"
n_hold_rows="$(printf '%s\n' "$step1" | grep -E '^  \| [0-9]+ \|' | grep -cF '`人間対応待ち`')"
eq "(E) 真理値表の全行が人間対応待ちの行のまま" "$n_hold_rows" "3"
n_rule_in_step1="$(printf '%s\n' "$step1" | grep -cF -- "$RULE_NAME")"
eq "(E) 手順1 に ${RULE_NAME} を持ち込まない（表の対象外）" "$n_rule_in_step1" "0"

echo
echo "pass: $PASS / fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0
