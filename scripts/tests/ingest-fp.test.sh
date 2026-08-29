#!/usr/bin/env bash
#
# ingest-fp.test.sh — scripts/ingest-fp.sh のテスト。
#
# 実行: bash scripts/tests/ingest-fp.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・perl・shasum。テストフレームワーク不使用。
#   - すべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#   - ネットワークに触れない（外部 Issue 本文はフィクスチャに焼き込んである）。
#
# 検査の要（Issue #130 / C-081 PR1）:
#   `fp` は「台帳に書いた人間記入欄の連結」ではなく「**取得したての外部 Issue 本文**」から
#   算出する。台帳の文字列を経由しないので正規化の解釈余地が消える——のは、**算式が実装として
#   1 箇所に固定されているとき**だけである。散文の算式を読み手が毎周再実装すると、同じ誤りが
#   再発する（2026-08-21 / 08-26 / 08-27 / 08-29 に 4 回再発した実績）。本テストは
#   「コピー&ペーストできる決定的な 1 コマンドで再現できる」ことを固定する。
#
#   したがって最重要は**ゴールデン値**（fixtures/ingest-fp/issue-130-body.txt →
#   `EXPECTED_FP_130`）である。この値が変わる変更は、既存の全マーカーを一斉に不一致にする
#   破壊的変更であり、テストが落ちること自体が意図した警報である。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../ingest-fp.sh"
FIXTURES="$TESTS_DIR/fixtures/ingest-fp"
SKILL_MD="$TESTS_DIR/../../skills/ingest-challenges/SKILL.md"
FORMAT_DOC="$TESTS_DIR/../../docs/challenge-ledger-format.md"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ $# -ge 2 ] && echo "       $2"; }

# eq <名前> <実測> <期待>
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got=[$2] want=[$3]"; fi
}

# ne <名前> <実測> <一致してはならない値>
ne() {
  if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "got=[$2] は [$3] と一致してはならない"; fi
}

# fp_of_stdin: 標準入力を渡して 12 桁を得る
fp_of() { printf '%s' "$1" | bash "$SCRIPT"; }

# has <名前> <ファイル> <部分文字列>
has() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "not found in ${2##*/}: $3"; fi
}
hasnt() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1" "still present in ${2##*/}: $3"; else ok "$1"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ===========================================================================
# 1. 既知 1 件の再現（ゴールデン値）
#    masanami/claude-flywheel#130 の本文を `gh issue view 130 --json body -q .body` で取得し、
#    そのまま焼き込んだフィクスチャ（実運用の入力そのもの。ブロック引用・コードフェンス・
#    表・日本語・末尾改行を含む）。CRLF は §3 の単体ケースで別に固定する。
# ===========================================================================

EXPECTED_FP_130="9c56b5c0a92d"

if [ ! -f "$FIXTURES/issue-130-body.txt" ]; then
  bad "既知1件: フィクスチャが在る" "not found: $FIXTURES/issue-130-body.txt"
else
  got="$(bash "$SCRIPT" < "$FIXTURES/issue-130-body.txt")"
  eq "既知1件: Issue #130 本文のゴールデン値を再現する" "$got" "$EXPECTED_FP_130"
  # 決定的であること（同じ入力を 2 回通しても同じ）
  got2="$(bash "$SCRIPT" < "$FIXTURES/issue-130-body.txt")"
  eq "既知1件: 2 回実行しても同じ値（決定的）" "$got2" "$EXPECTED_FP_130"
fi

# ===========================================================================
# 2. 出力の形（12 桁の小文字 16 進 ＋ 改行 1 つ）
# ===========================================================================

out="$(printf 'hello' | bash "$SCRIPT")"
eq "出力は 12 文字" "${#out}" "12"
case "$out" in
  *[!0-9a-f]*) bad "出力は小文字 16 進のみ" "got=[$out]" ;;
  *) ok "出力は小文字 16 進のみ" ;;
esac
# sha256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
eq "既知のベクタ: sha256(\"hello\") の先頭 12 桁" "$out" "2cf24dba5fb0"

# 改行が 1 つだけ付く（`$(...)` を経由しても値が変わらないことの前提）
printf 'hello' | bash "$SCRIPT" > "$tmp/nl.out"
eq "出力は改行 1 つで終わる（行数 1）" "$(wc -l < "$tmp/nl.out" | tr -d ' ')" "1"

# ===========================================================================
# 3. 正規化 — 「何を無視するか」を明示的に固定する
#    ここが揺れると全エントリが毎周「更新あり」になる。規約は 4 つだけ:
#      (1) CR をすべて削除  (2) 各行の行末空白（スペース・タブ）を削除
#      (3) 文字列全体の前後の空白を削除  (4) それ以外は一切変更しない
# ===========================================================================

base="$(fp_of 'a
b')"

# (1) CRLF ⇔ LF は同値
eq "正規化: CRLF は LF と同値" "$(printf 'a\r\nb' | bash "$SCRIPT")" "$base"
eq "正規化: 行中の孤立 CR も削除する" "$(printf 'a\rb' | bash "$SCRIPT")" "$(fp_of 'ab')"

# (2) 行末空白は無視
eq "正規化: 行末のスペースは無視" "$(printf 'a   \nb' | bash "$SCRIPT")" "$base"
eq "正規化: 行末のタブは無視" "$(printf 'a\t\nb' | bash "$SCRIPT")" "$base"

# (3) 前後の空白（改行含む）は無視
eq "正規化: 末尾の改行は無視" "$(printf 'a\nb\n' | bash "$SCRIPT")" "$base"
eq "正規化: 末尾の改行が複数でも無視" "$(printf 'a\nb\n\n\n' | bash "$SCRIPT")" "$base"
eq "正規化: 先頭の空行・空白は無視" "$(printf '\n  \na\nb' | bash "$SCRIPT")" "$base"

# (4) それ以外は変えない — 意味のある差は必ず値が動く
# 先頭行のインデントは (3) の全体 trim に飲まれる（規約どおり）。意味のある差として
# 検査すべきは**本文中**の行のインデント。
eq "正規化: 先頭行のインデントは全体 trim に含まれる" "$(fp_of '  a
b')" "$base"
ne "正規化: 本文中の行頭インデントは意味のある差（無視しない）" "$(fp_of 'a
  b')" "$base"
ne "正規化: 本文中の空行は意味のある差（無視しない）" "$(fp_of 'a

b')" "$base"
ne "正規化: 大文字小文字は意味のある差（無視しない）" "$(fp_of 'A
b')" "$base"
ne "正規化: 引用マーカーは除去しない（外部本文をそのまま扱う）" "$(fp_of '> a
b')" "$base"
ne "正規化: リストマーカーは除去しない（外部本文をそのまま扱う）" "$(fp_of '- a
b')" "$base"

# 更新検知の本体: 本文が 1 文字でも変われば値が変わる
ne "更新検知: 本文の 1 文字変更で値が変わる" "$(fp_of 'a
c')" "$base"

# ===========================================================================
# 4. 境界値
# ===========================================================================

# 空本文（GitHub の Issue は本文が空でも成立する）→ 空文字列の sha256
# sha256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
eq "境界: 空入力は空文字列の sha256（エラーにしない）" "$(printf '' | bash "$SCRIPT")" "e3b0c44298fc"
eq "境界: 空白だけの入力は空入力と同値" "$(printf '  \n\t\n' | bash "$SCRIPT")" "e3b0c44298fc"

# マルチバイト（日本語）が壊れない
eq "境界: 日本語本文が決定的に処理される" \
   "$(printf '課題台帳の説明欄' | bash "$SCRIPT")" "$(printf '課題台帳の説明欄' | bash "$SCRIPT")"
ne "境界: 日本語本文の 1 文字変更で値が変わる" \
   "$(printf '課題台帳の説明欄' | bash "$SCRIPT")" "$(printf '課題台帳の説明蘭' | bash "$SCRIPT")"

# 入力は stdin 専用（gh の呼び出しを抱え込まない＝表面を増やすと別の同期問題が生まれる）。
# 受け付けるフラグは `--from-ledger-quote` の 1 つだけで、未知の引数は exit 2。
printf 'x' | bash "$SCRIPT" --unknown-option >/dev/null 2>&1
eq "未知の引数は exit 2（stdin 専用・表面を増やさない）" "$?" "2"
printf 'x' | bash "$SCRIPT" extra-positional >/dev/null 2>&1
eq "位置引数も exit 2" "$?" "2"

# ===========================================================================
# 5. 移行の照合（`--from-ledger-quote`）
#    旧 fp からの移行は「台帳の原文引用」と「取得した外部本文」を比較して初めて自己修復
#    できる。この比較を目視・LLM の推定でやると PR1 が断ったはずの穴が移行で復活するので、
#    **比較も同じ実装 1 本に通す**。台帳側だけブロック引用の剥がしが要る。
#
#    移行の窓は PR1 マージ後・説明欄の要約化（PR2）前の**一度きり**であり、そこで取りこぼした
#    エントリは二度と自己修復できない。ゆえに「比較できた／できない」を**判定できること**自体が
#    受入条件であり、以下は「一致を検出できる」と「不一致を見逃さない」の両方を固定する。
# ===========================================================================

if [ ! -f "$FIXTURES/issue-130-ledger-quote.txt" ]; then
  bad "移行照合: 台帳引用のフィクスチャが在る" "not found: $FIXTURES/issue-130-ledger-quote.txt"
else
  # 一致方向: 同じ本文を台帳の引用形（`> ` 前置き・空行は素の `>`）にしたものが、
  # 外部本文そのもののゴールデン値と一致する＝このエントリは「移行可」と判定できる。
  got="$(bash "$SCRIPT" --from-ledger-quote < "$FIXTURES/issue-130-ledger-quote.txt")"
  eq "移行照合: 台帳の原文引用が外部本文のゴールデン値と一致する（移行可）" "$got" "$EXPECTED_FP_130"
fi

if [ ! -f "$FIXTURES/issue-130-ledger-quote-masked.txt" ]; then
  bad "移行照合: マスキング済みフィクスチャが在る" "not found: $FIXTURES/issue-130-ledger-quote-masked.txt"
else
  # 不一致方向（比較不能の検出）: 1 行だけマスキングした引用は値が動く。
  # ここが動かない実装だと、マスキング済みエントリを「実質同一」と誤判定して fp を
  # 書き換え、外部が更新されても永久にスキップされるエントリを作る。
  masked="$(bash "$SCRIPT" --from-ledger-quote < "$FIXTURES/issue-130-ledger-quote-masked.txt")"
  ne "移行照合: マスキング済みの引用は一致しない（比較不能を見逃さない）" "$masked" "$EXPECTED_FP_130"
fi

# 引用の剥がし方（`>` の直後の空白 1 つまでを外す。空行は素の `>`）
eq "移行照合: \`> \` を剥がす" "$(printf '> a\n> b' | bash "$SCRIPT" --from-ledger-quote)" "$base"
eq "移行照合: 素の \`>\`（空の引用行）は空行になる" \
   "$(printf '> a\n>\n> b' | bash "$SCRIPT" --from-ledger-quote)" "$(fp_of 'a

b')"
eq "移行照合: \`>\` の直後の空白は 1 つだけ外す（2 つ目はインデントとして残る）" \
   "$(printf '> a\n>   b' | bash "$SCRIPT" --from-ledger-quote)" "$(fp_of 'a
  b')"
# 本文中の入れ子引用（`> > ...`）は 1 段だけ剥がす＝外部本文側の `> ...` が復元される
eq "移行照合: 入れ子の引用は 1 段だけ剥がす" \
   "$(printf '> a\n> > b' | bash "$SCRIPT" --from-ledger-quote)" "$(fp_of 'a
> b')"

# 引用欠落（説明欄にブロック引用が無い）= 空入力扱い。実本文と一致しないので比較不能。
empty_quote="$(printf '' | bash "$SCRIPT" --from-ledger-quote)"
eq "移行照合: 引用欠落は空入力と同値" "$empty_quote" "e3b0c44298fc"
ne "移行照合: 引用欠落は実本文と一致しない（比較不能）" "$empty_quote" "$EXPECTED_FP_130"

# `--from-ledger-quote` は引用の剥がし**以外**は素通しと同じ正規化であること
eq "移行照合: 剥がした後の正規化は素通しと同じ（CRLF）" \
   "$(printf '> a\r\n> b' | bash "$SCRIPT" --from-ledger-quote)" "$base"
eq "移行照合: 剥がした後の正規化は素通しと同じ（行末空白・前後 trim）" \
   "$(printf '> a  \n> b\n>\n' | bash "$SCRIPT" --from-ledger-quote)" "$base"
# 引用でない行（人間が引用の外に書いた行）はそのまま値に入る＝黙って落とさない。
# 落とす実装だと、引用外に書かれた注記の増減が検知されず「実質同一」と誤判定しうる。
eq "移行照合: 引用でない行はそのまま残す" \
   "$(printf '> a\n**note**' | bash "$SCRIPT" --from-ledger-quote)" "$(fp_of 'a
**note**')"
ne "移行照合: 引用でない行を黙って捨てない" \
   "$(printf '> a\n**note**' | bash "$SCRIPT" --from-ledger-quote)" "$(fp_of 'a')"

# ===========================================================================
# 6. 規定との一致 — 算式の正本がスクリプトを指していること
#    散文の算式が残っていると、読み手はそちらを手で再実装する（4 回再発した経路）。
# ===========================================================================

# SKILL 側はソース非依存（`repo-file` / `mcp-doc` / `mcp-chat` も対象）のため「外部ソース本文」、
# フォーマット契約側は実運用の主要形を名指しして「外部 Issue 本文」と書く。両方を固定する。
has "規定: SKILL.md が fp の入力を外部ソース本文と定めている" "$SKILL_MD" \
    "取得したての外部ソース本文"
has "規定: SKILL.md が算出をスクリプトに委ねている" "$SKILL_MD" \
    "scripts/ingest-fp.sh"
hasnt "規定: SKILL.md から人間記入欄を連結する旧算式が消えている" "$SKILL_MD" \
    "「説明・完了条件・緊急度」の値をこの順に改行 1 つで連結し"
hasnt "規定: SKILL.md から引用マーカー除去の旧正規化が消えている" "$SKILL_MD" \
    "引用マーカー（\`> \`）を除去"

has "規定: SKILL.md に PR2（説明の要約化）より前という順序依存がある" "$SKILL_MD" \
    "説明欄を要約に置き換えるより前に完了していなければならない"

has "規定: フォーマット契約が fp の入力を外部 Issue 本文と定めている" "$FORMAT_DOC" \
    "取得したての外部 Issue 本文"

# --- 移行完了条件・比較不能の扱い・PR2 の実施条件（CodeRabbit #133 指摘 1） ---
# 移行の窓は一度きりで、取りこぼしは「静かに」起きる（更新検知の不在は観測できない）。
# fail-closed であること——判定できないものを「移行済み」に読み替えないこと——を両ファイルで固定する。
has "移行: 台帳側から駆動すると明記している（取得不能を訪問漏れにしない）" "$SKILL_MD" \
    "移行は台帳側から駆動する"
has "移行: 比較不能の分類がある" "$SKILL_MD" "比較不能"
has "移行: 比較不能では人間記入欄も fp も更新しないと明記している" "$SKILL_MD" \
    "`fp` を書き換えず、人間記入欄も更新しない"
has "移行: 取得不能を移行未完了として扱うと明記している" "$SKILL_MD" "取得不能"
has "移行: fp を推測で更新しないと明記している" "$SKILL_MD" "推測で更新しない"
has "移行: 照合をスクリプトに通すと明記している（目視判定の禁止）" "$SKILL_MD" "--from-ledger-quote"
has "移行: 全件を個別に列挙するレポート規定がある" "$SKILL_MD" "件数だけの要約にしない"
has "移行: 移行完了の定義がある" "$SKILL_MD" "移行完了の定義"
has "移行: PR2 の実施条件（移行完了まで禁止）が SKILL.md にある" "$SKILL_MD" \
    "移行完了が確認されるまで、説明欄の要約化を行ってはならない"
has "移行: PR2 の実施条件（移行完了まで禁止）がフォーマット契約にもある" "$FORMAT_DOC" \
    "移行完了が確認されるまで、説明欄の要約化を行ってはならない"
has "移行: 比較不能を人間が解消する経路が示されている" "$SKILL_MD" "比較不能の解消"
hasnt "規定: フォーマット契約から「人間記入欄を正規化した指紋」が消えている" "$FORMAT_DOC" \
    "**人間記入欄**（説明・完了条件・緊急度）を正規化した指紋"

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
