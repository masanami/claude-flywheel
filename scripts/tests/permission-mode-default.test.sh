#!/usr/bin/env bash
#
# permission-mode-default.test.sh — 委譲（headless `claude -p`）の `--permission-mode` を `auto` に
# 揃えた規定（Issue #167）の構造不変条件テスト。
#
# 実行: bash scripts/tests/permission-mode-default.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・sed・awk・sort。
#   - 読み取り専用。書き込みはしない。
#
# 検査の要:
#   - **値の併存を落とす**（(C)）。起動例は `acceptEdits`、【権限前提】の例は `bypassPermissions` と
#     同一ファイル内で値が 2 つ並んでいた。`--permission-mode <値>` の形で書かれた箇所をすべて抜き出し、
#     値が `auto` 以外なら落とす。散文で他のモード名を比較対象として挙げるのは正当なので、
#     フラグの形で書かれた箇所だけを数える。
#   - **走査対象は実行時テキスト（skills/ templates/）と、起動例を持つ設計文書 docs/architecture.md**。
#     docs/ の他の文書や CHANGELOG は経緯として旧値を引用しうるため対象外にする。
#   - **検出器の自己検査を持つ**（(A)）。grep は「マッチなし」と「パターンが壊れて検出できない」を
#     区別しないため、既知の形（空白区切り・`=` 区切り・行末の `\`）を毎回掛ける。
#   - **空虚に真にならないよう、抽出件数の下限を置く**（run-cycle 手順3 の 2 箇所・docs の 1 箇所）。
#   - **手順3 は節を切り出してから検査する**。全文 grep は別の節に同じ語があるだけで真になる。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

RUN_CYCLE="skills/run-cycle/SKILL.md"
ADHOC="skills/adhoc/SKILL.md"
ARCH="docs/architecture.md"
EXPECTED_MODE="auto"

# `--permission-mode` の後ろの値を拾う検出器（空白 1 個以上または `=` で区切られた値）。
MODE_RE='--permission-mode([[:space:]]+|=)[A-Za-z]+'

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

# 標準入力のテキストから `--permission-mode` の値だけを 1 行 1 件で出す。
extract_modes() {
  grep -oE -- "$MODE_RE" | sed -E 's/^--permission-mode([[:space:]]+|=)//'
}

echo "=== (A) 検出器の自己検査 ==="

assert_eq "(A) 空白区切りの値を拾う" "acceptEdits" \
  "$(printf '%s\n' 'cat brief.md | claude -p --output-format json --permission-mode acceptEdits --max-budget-usd 20' | extract_modes)"
assert_eq "(A) = 区切りの値を拾う" "bypassPermissions" \
  "$(printf '%s\n' 'claude -p --permission-mode=bypassPermissions' | extract_modes)"
assert_eq "(A) 行末に \\ が続く複数行形の値を拾う" "auto" \
  "$(printf '%s\n' '      --permission-mode auto \' | extract_modes)"
assert_eq "(A) 1 行に 2 箇所あれば 2 件拾う" "2" \
  "$(printf '%s\n' '`--permission-mode auto` と `--permission-mode bypassPermissions`' | extract_modes | grep -c .)"
assert_eq "(A) 値を伴わない言及（\`--permission-mode\` と settings.json）は拾わない" "0" \
  "$(printf '%s\n' '非対話の権限は `--permission-mode` と settings.json に委ねる' | extract_modes | grep -c .)"

echo ""
echo "=== (B) run-cycle 手順3 の起動例と【権限前提】が auto に揃っている ==="

step3="$(awk '/^### 3\. /{f=1} /^### 4\. /{f=0} f' "$RUN_CYCLE")"
assert_eq "(B) 手順3 の節を切り出せた（空でない）" "true" \
  "$(if [ -n "$step3" ]; then echo true; else echo false; fi)"
launch_line="$(printf '%s\n' "$step3" | grep -F -- 'cat brief.md | claude -p' | head -1)"
assert_eq "(B) 手順3 に起動例の行がある" "true" \
  "$(if [ -n "$launch_line" ]; then echo true; else echo false; fi)"
assert_eq "(B) 起動例の --permission-mode が auto" "$EXPECTED_MODE" \
  "$(printf '%s\n' "$launch_line" | extract_modes | head -1)"
has "(B) 【権限前提】に auto で起動する規定がある" "$step3" \
  '**【権限前提】子は `--permission-mode auto` で起動する**'
has "(B) 分類器を不可逆操作の歯止めとして数えない" "$step3" \
  '**分類器を不可逆操作の歯止めとして数えない**'
has "(B) 歯止めはブリーフの明示制約と commit 済み deny が担う" "$step3" \
  '**本番影響の不可逆操作（下記【承認ゲート FR-22】）の歯止めは、ブリーフの明示制約と対象 repo に commit された deny が担う**'
has "(B) deny は前方一致で git -C 形に効かないため禁止操作をブリーフに明記する" "$step3" \
  '`git -C <path> push --force` のような形には `Bash(git push --force:*)` が効かない——禁止する操作はブリーフに明記し'
has "(B) 拒否された操作は迂回せず報告させる" "$step3" \
  '**迂回せず、拒否された操作と拒否文言を完了報告に列挙する**'
has "(B) 複合形は allow にマッチしない規律が残っている" "$step3" \
  '**allow ルールは複合コマンドにマッチしない**'
n_step3="$(printf '%s\n' "$step3" | extract_modes | grep -c .)"
if [ "$n_step3" -ge 2 ]; then
  pass "(B) 手順3 の --permission-mode 抽出が起動例と【権限前提】の例の 2 件以上（${n_step3} 件）"
else
  fail "(B) 手順3 の --permission-mode 抽出が起動例と【権限前提】の例の 2 件以上" "${n_step3} 件（検出器か本文の形が変わった）"
fi

echo ""
echo "=== (C) 値の併存が無い（skills/ templates/ ${ARCH} の --permission-mode はすべて auto） ==="

n_arch="$(extract_modes < "$ARCH" | grep -c .)"
if [ "$n_arch" -ge 1 ]; then
  pass "(C) ${ARCH} の起動例から値を抽出できた（${n_arch} 件）"
else
  fail "(C) ${ARCH} の起動例から値を抽出できた" "0 件（検出器か本文の形が変わった）"
fi
# ファイル名つきで全出現を抜き出し、auto 以外を違反として列挙する。
all_hits="$(grep -rnoE -- "$MODE_RE" skills templates "$ARCH" || true)"
n_all="$(printf '%s\n' "$all_hits" | grep -c .)"
if [ "$n_all" -ge 3 ]; then
  pass "(C) 走査で --permission-mode の出現を拾えた（${n_all} 件）"
else
  fail "(C) 走査で --permission-mode の出現を拾えた（3 件以上）" "${n_all} 件"
fi
violations="$(printf '%s\n' "$all_hits" | grep . | grep -vE -- "--permission-mode([[:space:]]+|=)${EXPECTED_MODE}\$" || true)"
if [ -z "$violations" ]; then
  pass "(C) --permission-mode の値が ${EXPECTED_MODE} 以外の箇所が無い"
else
  fail "(C) --permission-mode の値が ${EXPECTED_MODE} 以外の箇所が無い" "$(printf '%s' "$violations" | head -5)"
fi
distinct="$(printf '%s\n' "$all_hits" | grep . | sed -E 's/.*--permission-mode([[:space:]]+|=)//' | sort -u | tr '\n' ' ')"
assert_eq "(C) 出現する値の種類が 1 つだけ" "${EXPECTED_MODE} " "$distinct"

echo ""
echo "=== (D) 起動形を参照する面（adhoc）が run-cycle 手順3 に到達する ==="

has "(D) adhoc が起動形の正本として run-cycle 手順3 を指している" "$(cat "$ADHOC")" \
  '**正本は `${CLAUDE_PLUGIN_ROOT}/skills/run-cycle/SKILL.md` 手順3**（起動形'
n_adhoc="$(extract_modes < "$ADHOC" | grep -vx -- "$EXPECTED_MODE" | grep -c .)"
assert_eq "(D) adhoc が auto 以外のモード値を独自に持たない" "0" "$n_adhoc"

echo ""
echo "pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed: %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0
