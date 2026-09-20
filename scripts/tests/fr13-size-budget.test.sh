#!/usr/bin/env bash
#
# fr13-size-budget.test.sh — run-cycle 手順2・手順3 の「想定サイズ・予算上限・スコープ外」規定
# （FR-13 の承認対象の拡張と、承認済みサイズからの `--max-budget-usd` 導出。Issue #145）の
# 構造不変条件テスト。
#
# 実行: bash scripts/tests/fr13-size-budget.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・sed・awk・ruby（バリデータ）。
#   - 読み取り専用。書き込みはすべて一時ディレクトリ内で完結する。
#
# 検査の要:
#   - **検査対象は当該の節（手順2 / 手順3）を切り出してから**行う。SKILL.md 全文への grep は
#     同じ語が別の節にあるだけで空虚に真になる（PR #143 で実測）。否定検査だけは全文で行う。
#   - **固定文言は 3 面（SKILL.md / 規定 / 雛形）で逐語一致**させる。面ごとに言い換えると
#     手順3 の機械読み取りが面によって成立しなくなる。
#   - **機械読み取りの検出器を自己検査する**（(A)）。規定は「正規表現 1 本でサイズ・実装枠・
#     レビュー対応枠の値を取れる」ことを要件にしており、検出器が壊れていると以降の検査が
#     空虚に真になる。検出器は雛形・規定の記入例と、実運用の試験記入の形（`USD/PR` 付き）の
#     両方に掛ける。**枠分割（#173）の後方互換もここで固定する**——`レビュー対応上限` の無い
#     旧エントリから実装枠が同じ検出器で読め、レビュー対応枠だけが空（＝導出へ落ちる）になること。
#   - **バリデータが固定文言入りの台帳を受理する**ことと、**その鏡像（インデント欠落）を
#     拒否する**ことを対で固定する（受理だけだと「何を渡しても通る」と区別できない）。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

SKILL_MD="skills/run-cycle/SKILL.md"
FORMAT_DOC="docs/challenge-ledger-format.md"
LEDGER_TPL="templates/challenge-ledger.md"
CONTRACTS_MD="contracts/README.md"
VALIDATOR="scripts/validate-artifact.rb"
VALID_FIXTURE="contracts/fixtures/ledger/valid/multiline-and-refs.md"

# 機械読み取りの検出器（規定 §複数行フィールドの記入形式 と同じ 3 本）。
SIZE_RE='想定サイズ: *[SML]'
BUDGET_RE='予算上限 *[0-9]+ *USD'
# レビュー対応枠（#173）。`予算上限` 側の正規表現は枠分割の前後で変わらない（後方互換の要）。
REVIEW_RE='レビュー対応上限 *[0-9]+ *USD'

# 3 面で逐語一致させる規範文。
FIXED_PHRASE='`想定サイズ: <S|M|L>（触るファイル数・PR 本数）・予算上限 <数値> USD・レビュー対応上限 <数値> USD・スコープ外: <踏み込まないもの>`'
SIZE_DEF='S＝触るファイル 1〜5・PR 1 本 / M＝6〜10・PR 1 本 / L＝10 超または PR 複数'
USD_TABLE='S＝30 / M＝50 / L＝100'
REVIEW_USD_TABLE='S＝25 / M＝30 / L＝40'
NO_BACKFILL='既存エントリは遡って埋めない'

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

# 1 行からサイズ（S/M/L）・実装枠・レビュー対応枠（いずれも数値）を取り出す。取れなければ空。
extract_size()   { grep -oE -- "$SIZE_RE" | head -1 | sed -E 's/.*([SML])$/\1/'; }
extract_budget() { grep -oE -- "$BUDGET_RE" | head -1 | grep -oE '[0-9]+'; }
extract_review() { grep -oE -- "$REVIEW_RE" | head -1 | grep -oE '[0-9]+'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== (A) 検出器の自己検査（規定・雛形・実運用の試験記入の形をすべて読める） ==="

l1='  4. 想定サイズ: M（6〜10 ファイル・PR 1 本）・予算上限 50 USD・レビュー対応上限 30 USD・スコープ外: パッケージマネージャ allow の見直し'
l2='  6. 想定サイズ: L（10 ファイル超・PR 3 本）・予算上限 100 USD/PR・レビュー対応上限 40 USD・スコープ外: 既存導入先の一斉是正'
l3='>   3. 想定サイズ: S（触るファイル 1〜5・PR 1 本）・予算上限 30 USD・レビュー対応上限 25 USD・スコープ外: 隣接する既存欠陥の修正'
# **後方互換の要**: `レビュー対応上限` が無い旧エントリ。実装枠は同じ検出器で読め、レビュー対応枠だけが空になる。
l4='  3. 想定サイズ: S（触るファイル 1〜5・PR 1 本）・予算上限 20 USD・スコープ外: 隣接する既存欠陥の修正'
assert_eq "(A) M/50/30 を読める" "M 50 30" \
  "$(printf '%s\n' "$l1" | extract_size) $(printf '%s\n' "$l1" | extract_budget) $(printf '%s\n' "$l1" | extract_review)"
assert_eq "(A) L/100（USD/PR 形）/40 を読める" "L 100 40" \
  "$(printf '%s\n' "$l2" | extract_size) $(printf '%s\n' "$l2" | extract_budget) $(printf '%s\n' "$l2" | extract_review)"
assert_eq "(A) S/30/25（引用ブロック内の雛形の形）を読める" "S 30 25" \
  "$(printf '%s\n' "$l3" | extract_size) $(printf '%s\n' "$l3" | extract_budget) $(printf '%s\n' "$l3" | extract_review)"
# 枠分割の前後で `予算上限` の検出器が変わっていないこと（旧エントリから実装枠を読めること）
assert_eq "(A) 旧エントリ（レビュー対応上限なし）からも実装枠は読める" "S 20" \
  "$(printf '%s\n' "$l4" | extract_size) $(printf '%s\n' "$l4" | extract_budget)"
assert_eq "(A) 旧エントリからレビュー対応枠は取れない（空＝導出へ落ちる）" "" \
  "$(printf '%s\n' "$l4" | extract_review)"
# 2 本の検出器が互いの文字列を拾わない（`予算上限` が `レビュー対応上限 25 USD` に誤一致しない）
assert_eq "(A) レビュー対応上限だけの行を予算上限として誤読しない" "" \
  "$(printf '%s\n' '  3. レビュー対応上限 25 USD' | extract_budget)"
assert_eq "(A) 予算上限だけの行をレビュー対応上限として誤読しない" "" \
  "$(printf '%s\n' '  3. 予算上限 30 USD' | extract_review)"
assert_eq "(A) 固定文言を含まない項目からは何も取れない" "||" \
  "$(printf '%s\n' '  1. 調査する' | extract_size)|$(printf '%s\n' '  1. 調査する' | extract_budget)|$(printf '%s\n' '  1. 調査する' | extract_review)"
assert_eq "(A) 数値の無い言及（規定文）を予算上限として誤読しない" "" \
  "$(printf '%s\n' '予算上限は手順3 が渡す値' | extract_budget)"

echo ""
echo "=== (B) 手順2（計画）: 固定文言・サイズ定義・遡及しない・FR-13 の承認対象 ==="

step2="$(awk '/^### 2\. /{f=1} /^### 3\. /{f=0} f' "$SKILL_MD")"
assert_eq "(B) 手順2 の節を切り出せた（空でない）" "true" \
  "$(if [ -n "$step2" ]; then echo true; else echo false; fi)"
has "(B) 手順2 が固定文言を規定する" "$step2" "$FIXED_PHRASE"
has "(B) 固定文言は「ネストの末尾 1 項目」に置くと限定している（手順3 が位置で見つけられる）" "$step2" \
  '**タスク案のネストの末尾 1 項目は固定文言 `想定サイズ:'
has "(B) 手順2 がサイズの定義を置く" "$step2" "$SIZE_DEF"
has "(B) 手順2 が S/M/L → USD の既定（実装枠）を置く" "$step2" "$USD_TABLE"
has "(B) 手順2 が S/M/L → USD の既定（レビュー対応枠）を置く" "$step2" "$REVIEW_USD_TABLE"
# 枠を 1 つへ戻したら落ちる否定検査（#173 の診断②）。旧・実装枠 S=20 の既定が復活していないこと。
hasnt "(B) 否定検査: 実装枠の旧既定（S＝20）へ戻っていない" "$step2" 'S＝20 / M＝50 / L＝100'
has "(B) 手順2 が 1 枠で兼ねない理由（指摘件数依存で実装側の見積りでは当てられない）を置く" "$step2" \
  '**1 枠で兼ねない**'
has "(B) 手順2 が「既存エントリは遡って埋めない」を明記する" "$step2" "$NO_BACKFILL"
fr13_line="$(printf '%s\n' "$step2" | grep -F -- '【承認ゲート FR-13】' | head -1)"
assert_eq "(B) 手順2 に FR-13 の承認ゲート行がある" "true" \
  "$(if [ -n "$fr13_line" ]; then echo true; else echo false; fi)"
has "(B) FR-13 の承認対象（タスク案）に想定サイズ・予算上限・レビュー対応上限・スコープ外が含まれる" "$fr13_line" \
  '`タスク案`（末尾の想定サイズ・予算上限・レビュー対応上限・スコープ外を含む）'

echo ""
echo "=== (C) 手順3（実行）: 上限の導出・起動例・resume・上限到達の報告・レビュー打ち切り ==="

step3="$(awk '/^### 3\. /{f=1} /^### 4\. /{f=0} f' "$SKILL_MD")"
assert_eq "(C) 手順3 の節を切り出せた（空でない）" "true" \
  "$(if [ -n "$step3" ]; then echo true; else echo false; fi)"
guard_line="$(printf '%s\n' "$step3" | grep -F -- '【費用ガード】委譲コマンドには必ず' | head -1)"
assert_eq "(C) 費用ガードの規定行がある" "true" \
  "$(if [ -n "$guard_line" ]; then echo true; else echo false; fi)"
has "(C) 上限は承認済みタスク案から導く" "$guard_line" '上限は承認済みタスク案から導く'
has "(C) ① 予算上限の値をそのまま渡す" "$guard_line" '`予算上限` の値をそのまま渡す'
has "(C) ② サイズ → USD の表（実装枠）が手順2 と同じ値" "$guard_line" "$USD_TABLE"
has "(C) ③ どちらも無い旧エントリの縮退値と journal への記録" "$guard_line" '`100` を使い、その事実を journal ② に書く'
has "(C) fail-closed（無指定では起動しない）が残っている" "$guard_line" '無指定では起動しない'
# --- 枠分割（#173）: 2 枠の使い分けと、レビュー対応枠が実装枠と同じ fail-safe の型で導出されること ---
has "(C) 実装の起動には実装枠・レビュー対応の resume にはレビュー対応枠を渡す" "$guard_line" \
  '**実装の起動には実装枠（`予算上限`）を、レビュー対応の `--resume` にはレビュー対応枠（`レビュー対応上限`）を渡す**'
has "(C) ① レビュー対応上限の値をそのまま渡す" "$guard_line" '`レビュー対応上限` の値をそのまま渡す'
has "(C) ② サイズ → USD の表（レビュー対応枠）が手順2 と同じ値" "$guard_line" "$REVIEW_USD_TABLE"
has "(C) ③ レビュー対応枠の縮退値と journal への記録" "$guard_line" '`40` を使い、その事実を journal ② に書く'
has "(C) レビュー対応枠の導出が実装枠と同じ fail-safe の型だと明記されている" "$guard_line" \
  '**レビュー対応枠の導出も同じ fail-safe の型に揃える**'
has "(C) 後方互換: レビュー対応上限の無い旧エントリは ② が担い特別扱いを置かない" "$guard_line" \
  '**移行のための特別扱いは置かない**'
has "(C) fail-closed は両方の枠に掛かる" "$guard_line" '**どちらの枠も無指定では起動しない**'
launch_line="$(printf '%s\n' "$step3" | grep -F -- 'cat brief.md | claude -p' | head -1)"
assert_eq "(C) 起動例の行がある" "true" \
  "$(if [ -n "$launch_line" ]; then echo true; else echo false; fi)"
has "(C) 起動例が導出値を示す形になっている" "$launch_line" '--max-budget-usd <導出した上限>'
has "(C) 上限到達＝その枠で承認した規模を超えた、を続行前に報告する" "$step3" \
  '**上限到達は、その起動に渡した枠（実装なら `予算上限`、レビュー対応なら `レビュー対応上限`）で承認した規模を超えたことを意味し、その枠の残予算は 0 以下**のため、`--resume` や PR 作成へ進まず'
# --- 残予算は枠ごとに別々（融通しない）。1 本の残予算へ戻したら落ちる ---
has "(C) 実装の残予算の定義" "$guard_line" '**実装の残予算（`予算上限` − 実装の起動の累計 `total_cost_usd`）**'
has "(C) レビュー対応の残予算の定義" "$guard_line" \
  '**レビュー対応の残予算（`レビュー対応上限` − レビュー対応の起動の累計 `total_cost_usd`）**'
has "(C) 一方の枠の残りを他方へ融通しない" "$guard_line" '**一方の残りを他方へ融通しない**'
hasnt "(C) 否定検査: 残予算が 1 本の定義へ戻っていない" "$guard_line" '**残予算（`予算上限` − 累計 `total_cost_usd`）**'
has "(C) その枠の残予算が 0 以下なら resume・PR 作成へ進まない" "$guard_line" \
  '**その枠の残予算が 0 以下なら `--resume`・PR 作成へ進まず次アクションへ報告する**'
has "(C) 続行の --resume にはその枠の残予算を渡す" "$step3" '`--max-budget-usd` にその起動が属する枠の残予算を指定'
has "(C) やり直し・回答の再開は実装枠、レビュー対応はレビュー対応枠の残予算を渡す" "$step3" \
  '**作業のやり直し・回答を渡す再開は実装枠の残予算を、レビュー対応の再開はレビュー対応枠の残予算を渡し（上記【費用ガード】）、渡すべき枠の残予算が 0 以下なら再開せず次アクションへ報告する**'
# --- 束ね委譲（バッチ）の最小値規定はどちらの枠に掛かるか（枠ごとに独立） ---
has "(C) バッチの最小値規定を枠ごとに独立に適用する" "$step3" '**最小値規定は枠ごとに独立に適用する**'
has "(C) 2 つの枠をまたいで最小値を取らない" "$step3" '**2 つの枠をまたいで最小値を取らない**'
has "(C) レビュー対応ラウンドの打ち切り規則（2 巡目以降は Major 以上のみ）" "$step3" \
  '**レビュー対応は 2 巡目以降 Major 以上のみ対応し、残りはフォローアップ Issue 候補として完了報告に上げる**'

echo ""
echo "=== (D) 全文の否定検査: 一律の既定 100 が残っていない ==="

whole="$(cat "$SKILL_MD")"
hasnt "(D) 「既定 \`100\`」の一律指定の文言が残っていない" "$whole" '既定 `100`'
hasnt "(D) 起動例に \`--max-budget-usd 100\` が残っていない" "$whole" '--max-budget-usd 100'

echo ""
echo "=== (E) 3 面（SKILL.md / 規定 / 雛形）の逐語一致 ==="

fmt="$(cat "$FORMAT_DOC")"
tpl="$(cat "$LEDGER_TPL")"
has "(E) 規定に固定文言がある" "$fmt" "$FIXED_PHRASE"
has "(E) 雛形に固定文言がある" "$tpl" "$FIXED_PHRASE"
has "(E) 規定にサイズ定義がある" "$fmt" "$SIZE_DEF"
has "(E) 雛形にサイズ定義がある" "$tpl" "$SIZE_DEF"
has "(E) 規定に S/M/L → USD の既定（実装枠）がある" "$fmt" "$USD_TABLE"
has "(E) 雛形に S/M/L → USD の既定（実装枠）がある" "$tpl" "$USD_TABLE"
has "(E) 規定に S/M/L → USD の既定（レビュー対応枠）がある" "$fmt" "$REVIEW_USD_TABLE"
has "(E) 雛形に S/M/L → USD の既定（レビュー対応枠）がある" "$tpl" "$REVIEW_USD_TABLE"
has "(E) 規定に「遡って埋めない」がある" "$fmt" "$NO_BACKFILL"
has "(E) 雛形に「遡って埋めない」がある" "$tpl" "$NO_BACKFILL"
has "(E) 規定 §FR-13 の承認対象がタスク案末尾の 4 項目を含む" "$fmt" \
  '**タスク案**（分解した作業項目の並び＋末尾の想定サイズ・予算上限・レビュー対応上限・スコープ外。承認対象）'
has "(E) 雛形の FR-13 注記が 4 項目を判断材料に含める" "$tpl" \
  '`タスク案`（末尾の想定サイズ・予算上限・レビュー対応上限・スコープ外を含む）/ `完了条件` / `関連リポジトリ` の 3 つ'
has "(E) 契約 README がフィールド追加でないことを消費者へ伝える" "$(cat "$CONTRACTS_MD")" \
  '想定サイズ・予算上限（実装枠）・レビュー対応上限（レビュー対応枠）・スコープ外を含む〕。判断材料は タスク案／完了条件／関連リポジトリ。**フィールドは増えない**'

echo ""
echo "=== (F) 記入例の固定文言行を検出器で読める（規定が自分の要件を満たす） ==="

tpl_line="$(grep -E -- "$SIZE_RE" "$LEDGER_TPL" | grep -E -- "$BUDGET_RE" | grep -E -- "$REVIEW_RE" | head -1)"
assert_eq "(F) 雛形の記入例に固定文言行がある" "true" \
  "$(if [ -n "$tpl_line" ]; then echo true; else echo false; fi)"
assert_eq "(F) 雛形の記入例から S/30/25 を読める" "S 30 25" \
  "$(printf '%s\n' "$tpl_line" | extract_size) $(printf '%s\n' "$tpl_line" | extract_budget) $(printf '%s\n' "$tpl_line" | extract_review)"
fmt_line="$(grep -E -- "$SIZE_RE" "$FORMAT_DOC" | grep -E -- "$BUDGET_RE" | grep -E -- "$REVIEW_RE" | head -1)"
assert_eq "(F) 規定の記入例に固定文言行がある" "true" \
  "$(if [ -n "$fmt_line" ]; then echo true; else echo false; fi)"
assert_eq "(F) 規定の記入例から M/50/30 を読める" "M 50 30" \
  "$(printf '%s\n' "$fmt_line" | extract_size) $(printf '%s\n' "$fmt_line" | extract_budget) $(printf '%s\n' "$fmt_line" | extract_review)"

echo ""
echo "=== (G) バリデータが固定文言入りの台帳を受理し、インデント欠落の鏡像を拒否する ==="

if [ ! -r "$VALID_FIXTURE" ]; then
  fail "(G) 正例フィクスチャを読める" "$VALID_FIXTURE が無い"
else
  anchor='  3. ready PR を作成する'
  assert_eq "(G) 正例フィクスチャ C-101 に挿入位置（\`${anchor}\`）がある" "1" \
    "$(grep -cF -- "$anchor" "$VALID_FIXTURE")"
  new_item='  4. 想定サイズ: S（触るファイル 1〜5・PR 1 本）・予算上限 30 USD・レビュー対応上限 25 USD・スコープ外: 隣接する既存欠陥の修正'
  awk -v a="$anchor" -v n="$new_item" '{print} $0==a{print n}' "$VALID_FIXTURE" > "$TMP/with-size.md"
  assert_eq "(G) 固定文言行を 1 行挿入できた" "1" "$(grep -cE -- "$SIZE_RE" "$TMP/with-size.md")"
  assert_eq "(G) 挿入行からレビュー対応枠も読める（枠分割後の形で受理される）" "25" \
    "$(grep -E -- "$REVIEW_RE" "$TMP/with-size.md" | head -1 | extract_review)"
  if ruby "$VALIDATOR" ledger "$TMP/with-size.md" > "$TMP/valid.out" 2>&1; then
    pass "(G) 固定文言をネスト項目として持つ台帳をバリデータが受理する（exit 0）"
  else
    fail "(G) 固定文言をネスト項目として持つ台帳をバリデータが受理する（exit 0）" "$(tr '\n' '|' < "$TMP/valid.out")"
  fi
  # 鏡像: 同じ行をインデント無し（行頭 `4. …`）で置くと 形 F（結合切れ）として拒否される。
  dedented="$(printf '%s' "$new_item" | sed -E 's/^  //')"
  awk -v a="$anchor" -v n="$dedented" '{print} $0==a{print n}' "$VALID_FIXTURE" > "$TMP/dedented.md"
  if ruby "$VALIDATOR" ledger "$TMP/dedented.md" > "$TMP/invalid.out" 2>&1; then
    fail "(G) 同じ行のインデント欠落（形 F）はバリデータが拒否する（受理の検査が空虚でない証拠）" "exit 0 で受理された"
  else
    pass "(G) 同じ行のインデント欠落（形 F）はバリデータが拒否する（受理の検査が空虚でない証拠）"
  fi
fi

echo ""
echo "=== summary === pass: ${PASS}, fail: ${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  echo "failed:"
  for t in ${FAILED+"${FAILED[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
