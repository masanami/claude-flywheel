#!/usr/bin/env bash
#
# runtime-text-refs.test.sh — 実行時テキスト（skills/ templates/）から docs/ を参照しないことの
# 回帰テスト。規約の正本は docs/runtime-text-conventions.md（Issue #117）。
#
# 実行: bash scripts/tests/runtime-text-refs.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・sed。テストフレームワーク不使用。
#   - 読み取り専用。書き込みはすべて一時ディレクトリ内で完結する。
#
# 検査の要:
#   - **本規約が機械で守れるのは「docs/ 参照の不在」だけ**。「行動を変えない補足が混ざって
#     いないこと」は文の意味に依存し、決定的スクリプトでは検査できない（境界は正本 §6）。
#     テストが緑であることを「書き分けができている」と読み替えないための線引きを、
#     ここと正本の両方に置く。
#   - **除外はファイル名の allowlist にしない**。ファイルの列挙は規約本文とは別に維持される
#     第 2 のリストになり、ずれても誰も気付かない。除外は**構造**（行全体が HTML コメント）
#     で定め、除外した行は毎回出力する（黙って除外しない）。
#   - **templates/ は HTML コメント内でも違反**。scaffold 先に docs/ は存在せず、保守者向け
#     注記の置き場としても機能しない（利用先の人間が辿れないポインタになる）。面ごとに
#     除外規則が違うので、両方の面で規則が効いていることを固定する。
#   - **検出器の自己検査を持つ**（(A)）。grep は「マッチなし」と「パターンが壊れて検出でき
#     ない」を区別しないため、既知の違反形・正当形をパターンに直接掛けて検出器が生きて
#     いることを毎回確認する。ここが無いと (B)(C) は空虚に真になりうる。
#   - **走査対象が空でないことを確認する**（(E)）。対象 0 件の「違反なし」を pass にしない。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

CONV_DOC="docs/runtime-text-conventions.md"

# docs/ 配下の Markdown への参照。`docs/` の直前が英数・`/`・`-`・`.` の場合は別パスの
# 一部（例: `some/docs/x.md`）なので対象外にはせず、そのまま拾う（本リポジトリの
# 実行時テキストが他リポジトリの docs を指す必要は無いため、広く拾って良い）。
DOCS_REF_RE='docs/[A-Za-z0-9_./-]*\.md'

# 行全体が HTML コメントである行（前後の空白と Markdown の引用記号 `> ` を剥がして判定）。
# **行末に付けたコメントは該当しない** — 規範行の末尾にコメントを足せば検査を抜けられる、
# という穴を残さないため。
COMMENT_ONLY_RE='^[[:space:]]*(>[[:space:]]*)*<!--.*-->[[:space:]]*$'

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

# 指定パス群を走査し、違反行を `<file>:<line>:<内容>` で出力する。
# $1 = "comment-exempt" なら行全体が HTML コメントの行を除外、"strict" なら除外しない。
scan() {
  local mode="$1"; shift
  local out rc
  out="$(grep -rnE -- "$DOCS_REF_RE" "$@" 2>/dev/null)"
  rc=$?
  # grep の exit 2（実行エラー＝検査不能）を「違反なし」に化けさせない。
  if [ "$rc" -gt 1 ]; then printf 'SCAN-ERROR\n'; return 0; fi
  if [ "$mode" = "comment-exempt" ]; then
    printf '%s\n' "$out" | grep -v '^$' | while IFS= read -r line; do
      # `<file>:<line>:` を落とした本文で判定する
      body="$(printf '%s' "$line" | sed -E 's/^[^:]*:[0-9]+://')"
      printf '%s' "$body" | grep -qE -- "$COMMENT_ONLY_RE" && continue
      printf '%s\n' "$line"
    done
  else
    printf '%s\n' "$out" | grep -v '^$'
  fi
}

echo "=== (A) 検出器の自己検査（grep が壊れていたら以降の検査は空虚に真になる） ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/surface"

# 既知の違反形（実際に本リポジトリに在った 3 形）
{
  printf '%s\n' '- 規定の正本は `docs/challenge-ledger-format.md` §移行フェーズ。'
  printf '%s\n' '- 正本は `${CLAUDE_PLUGIN_ROOT}/docs/challenge-ledger-format.md` §FR-13 の承認対象。'
  printf '%s\n' '- 線引きの根拠は [`docs/challenge-ledger-format.md` §既存ワークスペースの移行](../../docs/challenge-ledger-format.md)。'
} > "$TMP/surface/violations.md"
n="$(scan strict "$TMP/surface/violations.md" | grep -c .)"
assert_eq "(A) 既知の違反形 3 行をすべて検出する" "3" "$n"

# 正当形（誤検出してはいけない）
{
  printf '%s\n' '- 台帳の記入形式は現在フェーズ 1 ＝ 1 行形式（形 B）を既定とする。'
  printf '%s\n' '- 関連Issue は `<owner>/<repo>#<番号>` で書く（例: `masanami/claude-flywheel#87`）。'
  printf '%s\n' '- `README.md` より推定、のように出典ファイル名だけを書く形は対象外。'
  printf '%s\n' '- `scripts/migrate-workspace.rb` のような実行時に読むスクリプトの参照は対象外。'
} > "$TMP/surface/legit.md"
n="$(scan strict "$TMP/surface/legit.md" | grep -c .)"
assert_eq "(A) 正当形を違反と誤検出しない" "0" "$n"

# 除外規則の自己検査: 行全体コメントは除外される／行末コメントは除外されない
{
  printf '%s\n' '<!-- この表は docs/self-improvement.md §4 と同内容のミラー。 -->'
  printf '%s\n' '> <!-- 引用ブロック内の docs/architecture.md 注記も同じ扱い -->'
} > "$TMP/surface/comment-only.md"
assert_eq "(A) 行全体が HTML コメントの行は comment-exempt で除外される" "0" \
  "$(scan comment-exempt "$TMP/surface/comment-only.md" | grep -c .)"
assert_eq "(A) 同じ行は strict では違反として残る（除外規則が効いている証拠）" "2" \
  "$(scan strict "$TMP/surface/comment-only.md" | grep -c .)"

printf '%s\n' '- 台帳を編集する前に復旧する <!-- 正本: docs/challenge-ledger-format.md -->' \
  > "$TMP/surface/trailing-comment.md"
assert_eq "(A) 行末に付けた HTML コメントは除外しない（規範行へ紛れ込ませる穴を塞ぐ）" "1" \
  "$(scan comment-exempt "$TMP/surface/trailing-comment.md" | grep -c .)"

echo ""
echo "=== (B) skills/ に docs/ 参照が無い（行全体が HTML コメントの行を除く） ==="

skills_hits="$(scan comment-exempt skills)"
case "$skills_hits" in
  SCAN-ERROR) fail "skills/ の走査が実行エラーを起こしていない" "grep が exit 2 を返した" ;;
  "") pass "skills/ に docs/ 参照が無い（行全体が HTML コメントの行を除く）" ;;
  *) fail "skills/ に docs/ 参照が無い（行全体が HTML コメントの行を除く）" "$(printf '%s' "$skills_hits" | tr '\n' '|')" ;;
esac

echo ""
echo "=== (C) templates/ に docs/ 参照が無い（HTML コメント内も違反） ==="
# scaffold 先に docs/ は存在しないため、コメントに書いても利用先の人間が辿れない。

tpl_hits="$(scan strict templates)"
case "$tpl_hits" in
  SCAN-ERROR) fail "templates/ の走査が実行エラーを起こしていない" "grep が exit 2 を返した" ;;
  "") pass "templates/ に docs/ 参照が無い（HTML コメント内も対象）" ;;
  *) fail "templates/ に docs/ 参照が無い（HTML コメント内も対象）" "$(printf '%s' "$tpl_hits" | tr '\n' '|')" ;;
esac

echo ""
echo "=== (D) 除外した行を出力する（黙って除外しない） ==="

exempted="$(scan strict skills | while IFS= read -r line; do
  body="$(printf '%s' "$line" | sed -E 's/^[^:]*:[0-9]+://')"
  printf '%s' "$body" | grep -qE -- "$COMMENT_ONLY_RE" && printf '%s\n' "$line"
done)"
if [ -z "$exempted" ]; then
  echo "     （除外行なし）"
else
  printf '%s\n' "$exempted" | sed 's/^/     除外: /'
fi
# 除外は「規範を担わない保守者向け注記」に限る想定。件数が増えたら規約側の見直しが要るため、
# 件数そのものは固定せず**必ず目に入る**形にする（上の出力）。ここでは「除外行がすべて
# 行全体コメントである」ことだけを不変条件として固定する。
bad=0
if [ -n "$exempted" ]; then
  while IFS= read -r line; do
    body="$(printf '%s' "$line" | sed -E 's/^[^:]*:[0-9]+://')"
    printf '%s' "$body" | grep -qE -- "$COMMENT_ONLY_RE" || bad=$((bad + 1))
  done <<EOF
$exempted
EOF
fi
assert_eq "(D) 除外行はすべて「行全体が HTML コメント」である" "0" "$bad"

echo ""
echo "=== (E) 走査対象が空でない（0 件の「違反なし」を pass にしない） ==="

n_skills="$(find skills -name '*.md' -type f | grep -c .)"
n_tpl="$(find templates -name '*.md' -type f | grep -c .)"
assert_eq "(E) skills/ に Markdown が 1 件以上ある" "true" \
  "$(if [ "$n_skills" -ge 1 ]; then echo true; else echo false; fi)"
assert_eq "(E) templates/ に Markdown が 1 件以上ある" "true" \
  "$(if [ "$n_tpl" -ge 1 ]; then echo true; else echo false; fi)"

echo ""
echo "=== (F) 規約の正本が在り、判定軸と境界が読み取れる ==="

assert_eq "(F) 正本ドキュメントを読める" "true" \
  "$(if [ -r "$CONV_DOC" ]; then echo true; else echo false; fi)"

if [ -r "$CONV_DOC" ]; then
  # 意味を反転しても部分一致は通るため、可変部を含まない一文まるごとで照合する。
  for phrase in \
    '**この文を削ると、次に読むモデルの振る舞いが変わるか。**' \
    '**判定軸は「ID や番号を使っているか」ではない。**' \
    '**判定軸は分量ではない。**' \
    '**検査できない**（「行動を変えるか」は文の意味に依存する）' \
    '除外は**ファイル名の列挙ではなく構造**で定める'
  do
    if grep -qF -- "$phrase" "$CONV_DOC"; then
      pass "(F) 正本に不変コアが在る: ${phrase}"
    else
      fail "(F) 正本に不変コアが在る: ${phrase}" "見つからない"
    fi
  done

  # 反転語彙の不在（「重複しているから docs へ集約する」という読み替えの再生産を止める）。
  for inverted in '正本 1 箇所へ集約する' '逐語コピーを減らす' '分量で判定する'; do
    if grep -qF -- "$inverted" "$CONV_DOC"; then
      fail "(F) 正本に反転語彙が無い: ${inverted}" "見つかった"
    else
      pass "(F) 正本に反転語彙が無い: ${inverted}"
    fi
  done

  # 正本が指す検査スクリプトが実在する（規約が宙に浮かないこと）。
  self_rel="scripts/tests/$(basename "$0")"
  if grep -qF -- "$self_rel" "$CONV_DOC"; then
    pass "(F) 正本が強制の所在としてこのテストを指している"
  else
    fail "(F) 正本が強制の所在としてこのテストを指している" "$self_rel が正本に無い"
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
