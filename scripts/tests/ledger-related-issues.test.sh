#!/usr/bin/env bash
#
# ledger-related-issues.test.sh — scripts/ledger-related-issues.rb（`関連Issue` による束ね済み
# 判定）と、それを呼ぶ ingest-challenges SKILL.md 手順4 の構造不変条件のテスト（Issue #187）。
#
# 実行: bash scripts/tests/ledger-related-issues.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・ruby。テストフレームワーク不使用。
#   - すべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
#   R1 宣言          --list-exits / --list-columns が振る舞いと一致すること
#   R2 書式の揺れ    完全形・短縮形・URL・全角区切り・空白・先頭ゼロ・大文字小文字・複数行を読むこと
#   R3 owner 解決    短縮形は同エントリの `関連リポジトリ` の同名 repo から owner を決めること
#   R4 照合          owner が両方決まれば一致を要し、片方不明なら問わないこと
#   R5 除外          フェンス・複数行 HTML コメント・前文の値を読まないこと
#   R6 fail-closed   読めない要素を黙って捨てず exit 1 で列挙し、読めた分は出すこと
#   R7 検査不能      引数不正・対象不在・--match の値の形不正は exit 2
#   R8 境界の一致    同じ入力から ledger-index.rb と同じ ID 列が出ること（エントリ境界の意味論）
#   R9 SKILL.md      手順4 がスクリプトを呼び・マーカー照合を先に置き・照合規則を再掲しないこと
#                    （変異注入で検査が空虚でないことを確認する）

set -u
set -o pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ledger-related-issues.rb"
INDEX="$REPO_ROOT/scripts/ledger-index.rb"
SKILL_MD="$REPO_ROOT/skills/ingest-challenges/SKILL.md"
SOURCES_TPL="$REPO_ROOT/templates/challenge-sources.md"
FORMAT_DOC="$REPO_ROOT/docs/challenge-ledger-format.md"
VALID_FIXTURES="$REPO_ROOT/contracts/fixtures/ledger/valid"

PASS=0
FAIL=0

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ledger-related-issues.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

ok()   { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; }
# 注意: 全角文字の直前の変数展開は bash 3.2 が誤るため、必ず ${var} のブレース形で書く。
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want=[$3] got=[$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "not found: $3" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly found: $3" ;; *) ok "$1" ;; esac; }

if [ ! -f "$SCRIPT" ]; then
  bad "被検体が存在する: scripts/ledger-related-issues.rb" "not found: $SCRIPT"
  printf '\npassed: %s / failed: %s\n' "$PASS" "$FAIL"
  exit 1
fi
[ -x "$SCRIPT" ] && ok "被検体に実行権がある" || bad "被検体に実行権がある" "chmod +x が要る"

# run <args...> — stdout を $out、stderr を $err、終了コードを $rc に入れる
run() { out="$("$SCRIPT" "$@" 2>"$tmp/stderr")"; rc=$?; err="$(cat "$tmp/stderr")"; }
# 照合モードの 1 クエリの result 列（複数行なら改行区切り）
result_of() { printf '%s\n' "$out" | awk -F '\t' -v q="$1" 'NR > 1 && $1 == q { print $2 }' | sort -u; }

# ---------------------------------------------------------------------------
# 素材
# ---------------------------------------------------------------------------
LEDGER="$tmp/challenge-ledger.md"
ARCHIVE="$tmp/challenge-archive.md"
cat > "$LEDGER" <<'EOF'
# 課題台帳

- 関連Issue: preamble/repo#1

```markdown
### [C-000] 記入例
- 関連Issue: fence/repo#2
```

### [C-001] 完全形と複数値
- 関連リポジトリ: masanami/claude-flywheel
- 関連Issue: masanami/claude-flywheel#187, Other-Owner/Repo-X#0042 ,  zene-corp/report-system # 171

### [C-002] 短縮形（owner 解決あり）と全角区切り・複数行
- 関連リポジトリ: masanami/claude-harness, zene-corp/api
- 関連Issue: claude-harness#276、api#9，
- 関連Issue: https://github.com/masanami/flywheel/issues/72

<!--
### [C-999] コメントアウトされたエントリ
- 関連Issue: comment/repo#3
-->

### [C-003] 短縮形（owner 不明）と空欄
- 関連Issue: board#5
- 関連Issue:
EOF

cat > "$ARCHIVE" <<'EOF'
# 課題アーカイブ

### [C-100] 完了済み課題に束ねたまま上流で OPEN
- 関連リポジトリ: zene-corp/report-system
- 関連Issue: report-system#300
EOF

# ---------------------------------------------------------------------------
# R1 宣言
# ---------------------------------------------------------------------------
echo "== R1 宣言 =="
run --list-exits
eq "R1: --list-exits は 0 1 2" "$(printf '%s' "$out" | tr '\n' ' ')" "0 1 2"
run --list-columns
list_cols="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "list" { printf "%s ", $2 }')"
match_cols="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "match" { printf "%s ", $2 }')"
run "$LEDGER"
eq "R1: 列挙モードのヘッダが宣言と一致" "$(printf '%s\n' "$out" | head -1 | tr '\t' ' ') " "${list_cols}"
run --match a/b#1 "$LEDGER"
eq "R1: 照合モードのヘッダが宣言と一致" "$(printf '%s\n' "$out" | head -1 | tr '\t' ' ') " "${match_cols}"

# ---------------------------------------------------------------------------
# R2〜R3 列挙
# ---------------------------------------------------------------------------
echo "== R2/R3 書式の揺れ・owner 解決 =="
run "$LEDGER" "$ARCHIVE"
eq "R2: 読めない要素が無ければ exit 0" "$rc" "0"
keys="$(printf '%s\n' "$out" | awk -F '\t' 'NR > 1 { print $3 " " $1 }')"
expected_keys="C-001 masanami/claude-flywheel#187
C-001 other-owner/repo-x#42
C-001 zene-corp/report-system#171
C-002 masanami/claude-harness#276
C-002 zene-corp/api#9
C-002 masanami/flywheel#72
C-003 board#5
C-100 zene-corp/report-system#300"
eq "R2/R3: 正規化したキーがエントリ順に全件出る" "$keys" "$expected_keys"
has "R2: written 列は正規化前の文字列を保つ" "$out" "Other-Owner/Repo-X#0042"
has "R2: file 列はアーカイブ側のパスを示す" "$out" "${ARCHIVE}	C-100"

# ---------------------------------------------------------------------------
# R4 照合
# ---------------------------------------------------------------------------
echo "== R4 照合 =="
run --match masanami/claude-flywheel#187 \
    --match zene-corp/report-system#171 \
    --match MASANAMI/Claude-Harness#276 \
    --match other/claude-harness#276 \
    --match anyone/board#5 \
    --match zene-corp/report-system#300 \
    --match masanami/claude-flywheel#188 \
    --match claude-harness#276 \
    --match masanami/flywheel#72 \
    "$LEDGER" "$ARCHIVE"
eq "R4: exit 0" "$rc" "0"
eq "R4: 完全形どうしの一致は bundled" "$(result_of masanami/claude-flywheel#187)" "bundled"
eq "R4: # 前後の空白を吸収して一致" "$(result_of zene-corp/report-system#171)" "bundled"
eq "R4: 大文字小文字を区別しない" "$(result_of MASANAMI/Claude-Harness#276)" "bundled"
eq "R4: owner が両方決まって食い違えば unregistered" "$(result_of other/claude-harness#276)" "unregistered"
eq "R4: 台帳側の owner が不明なら owner を問わない" "$(result_of anyone/board#5)" "bundled"
eq "R4: アーカイブ側の一致も bundled" "$(result_of zene-corp/report-system#300)" "bundled"
eq "R4: 番号違いは unregistered" "$(result_of masanami/claude-flywheel#188)" "unregistered"
eq "R4: 短縮形のクエリ（マーカーの外部キー形）も照合できる" "$(result_of claude-harness#276)" "bundled"
eq "R4: URL 形の要素とも一致" "$(result_of masanami/flywheel#72)" "bundled"
hit_line="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "zene-corp/report-system#300"')"
eq "R4: 一致行は束ねている側のファイル・ID・原文を返す" "$hit_line" "zene-corp/report-system#300	bundled	${ARCHIVE}	C-100	report-system#300"
miss_line="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "masanami/claude-flywheel#188"')"
eq "R4: unregistered は 1 行で file/id/written は -" "$miss_line" "masanami/claude-flywheel#188	unregistered	-	-	-"
order="$(printf '%s\n' "$out" | awk -F '\t' 'NR > 1 { print $1 }' | uniq | tr '\n' ' ')"
eq "R4: クエリは引数の順に出る" "$order" "masanami/claude-flywheel#187 zene-corp/report-system#171 MASANAMI/Claude-Harness#276 other/claude-harness#276 anyone/board#5 zene-corp/report-system#300 masanami/claude-flywheel#188 claude-harness#276 masanami/flywheel#72 "

# ---------------------------------------------------------------------------
# R5 除外
# ---------------------------------------------------------------------------
echo "== R5 除外 =="
run --match preamble/repo#1 --match fence/repo#2 --match comment/repo#3 "$LEDGER"
eq "R5: 前文の値は読まない" "$(result_of preamble/repo#1)" "unregistered"
eq "R5: フェンス内の値は読まない" "$(result_of fence/repo#2)" "unregistered"
eq "R5: 複数行 HTML コメント内の値は読まない" "$(result_of comment/repo#3)" "unregistered"

# ---------------------------------------------------------------------------
# R6 fail-closed
# ---------------------------------------------------------------------------
echo "== R6 fail-closed =="
BAD="$tmp/bad-ledger.md"
cat > "$BAD" <<'EOF'
### [C-010] 読めない要素を含む
- 関連Issue: masanami/claude-flywheel#1, #87 と #89, （未作成）
EOF
run --match masanami/claude-flywheel#1 --match masanami/claude-flywheel#87 "$BAD"
eq "R6: 読めない要素があれば exit 1" "$rc" "1"
has "R6: 読めない要素をファイル・行・ID 付きで列挙する" "$err" "${BAD}:2: [C-010] 読めない要素: #87 と #89"
has "R6: プレースホルダも読めない要素として列挙する" "$err" "読めない要素: （未作成）"
eq "R6: 読めた要素の照合結果はそのまま出す" "$(result_of masanami/claude-flywheel#1)" "bundled"
has "R6: stderr が unregistered を新規と読み替えないよう告げる" "$err" "unregistered を新規と読み替えない"

# ---------------------------------------------------------------------------
# R7 検査不能
# ---------------------------------------------------------------------------
echo "== R7 検査不能 =="
run
eq "R7: 対象ファイル無しは exit 2" "$rc" "2"
run "$tmp/no-such.md"
eq "R7: 対象不在は exit 2" "$rc" "2"
run "$LEDGER" "$tmp/challenge-archive*.md"
eq "R7: 展開されない glob（アーカイブ無し）も exit 2" "$rc" "2"
run --match "not a key" "$LEDGER"
eq "R7: --match の値の形不正は exit 2" "$rc" "2"
run --match
eq "R7: --match の値欠落は exit 2" "$rc" "2"
run --bogus "$LEDGER"
eq "R7: 不明なオプションは exit 2" "$rc" "2"
printf '### [C-1] x\n- 関連Issue: a/b#1\n\377\n' > "$tmp/binary.md"
run "$tmp/binary.md"
eq "R7: UTF-8 として解釈できなければ exit 2" "$rc" "2"

# ---------------------------------------------------------------------------
# R8 境界の一致（ledger-index.rb と同じ ID 列）
# ---------------------------------------------------------------------------
# 本スクリプトは `関連Issue` を持つエントリだけを出すため、全エントリへ `関連Issue` を 1 行
# 足した写しで比べる（写しは $tmp に作る。リポジトリの fixture は書き換えない）。
echo "== R8 境界の一致 =="
ids_related() { "$SCRIPT" "$1" 2>/dev/null | awk -F '\t' 'NR > 1 { print $3 }' | uniq; }
ids_index()   { "$INDEX" "$1" 2>/dev/null | awk -F '\t' 'NR > 1 { print $1 }'; }
with_ref() { awk '{ print } /^### \[/ && !f { print "- 関連Issue: probe/probe#1" }
                  /^```/ { f = !f }' "$1"; }
n=0
for src in "$LEDGER" "$VALID_FIXTURES"/*.md; do
  n=$((n + 1))
  probe="$tmp/probe-${n}.md"
  with_ref "$src" > "$probe"
  a="$(ids_related "$probe")"
  b="$(ids_index "$probe")"
  if [ -n "$b" ] && [ "$a" = "$b" ]; then
    ok "R8: ID 列が ledger-index.rb と一致: $(basename "$src")"
  else
    bad "R8: ID 列が ledger-index.rb と一致: $(basename "$src")" "related=[$(printf '%s' "$a" | tr '\n' ' ')] index=[$(printf '%s' "$b" | tr '\n' ' ')]"
  fi
done

# ---------------------------------------------------------------------------
# R9 SKILL.md の構造不変条件
# ---------------------------------------------------------------------------
echo "== R9 SKILL.md =="
# 手順4 の節（`### 4.` から次の `### ` の直前まで）を切り出す
step4_of() { awk '/^### 4\. /{ f = 1; print; next } f && /^### /{ exit } f' "$1"; }
step5_of() { awk '/^### 5\. /{ f = 1; print; next } f && (/^## / || /^### /) { exit } f' "$1"; }

# check_skill <SKILL.md> — 不変条件を 1 つでも破れば非 0（変異注入で再利用する）
check_skill() {
  local md="$1" s4 s5 marker_at related_at
  s4="$(step4_of "$md")"
  s5="$(step5_of "$md")"
  [ -n "$s4" ] || { echo "手順4 を切り出せない"; return 1; }
  case "$s4" in *'scripts/ledger-related-issues.rb'*) ;; *) echo "手順4 がスクリプトを呼ばない"; return 1 ;; esac
  case "$s4" in *'--match <owner>/<repo>#<番号>'*) ;; *) echo "手順4 が完全形のキーを渡さない"; return 1 ;; esac
  case "$s4" in *'challenge-archive*.md'*'ledger-related-issues'*|*'ledger-related-issues'*'challenge-archive*.md'*) ;; *) echo "照合対象にアーカイブが無い"; return 1 ;; esac
  # 順序: マーカー照合（1.）が `関連Issue` の照合（2.）より前にある
  marker_at="$(printf '%s\n' "$s4" | grep -n '取り込み元マーカーの外部キー照合を先に行う' | head -1 | cut -d: -f1)"
  related_at="$(printf '%s\n' "$s4" | grep -n 'マーカーに無かった候補だけ' | head -1 | cut -d: -f1)"
  [ -n "$marker_at" ] && [ -n "$related_at" ] && [ "$marker_at" -lt "$related_at" ] \
    || { echo "マーカー照合が先に来ていない (marker=${marker_at} related=${related_at})"; return 1; }
  # 束ね済みでは fp・人間記入欄・取り込み解除に触れない
  printf '%s\n' "$s4" | grep -F '束ね済み' | grep -F '`fp` の更新・人間記入欄の更新' | grep -qF '取り込み解除' \
    || { echo "束ね済みの不作為（fp・人間記入欄・取り込み解除）が書かれていない"; return 1; }
  # fail-closed: exit 1 / 2 で unregistered を新規にしない
  printf '%s\n' "$s4" | grep -F 'exit 1' | grep -qF '新規として追記しない' \
    || { echo "exit 1 の fail-closed が無い"; return 1; }
  printf '%s\n' "$s4" | grep -F 'exit 2' | grep -qF 'すべて追記しない' \
    || { echo "exit 2 の fail-closed が無い"; return 1; }
  # 報告に `束ね済み N`
  case "$s5" in *'束ね済み N'*) ;; *) echo "手順5 の報告に 束ね済み N が無い"; return 1 ;; esac
  # 否定検査: 照合規則（区切り・owner 解決・URL）を SKILL.md に再掲しない
  if grep -nE '全角の|同名 `?<repo>`?|github\.com/<owner>/<repo>/issues|大文字小文字を区別しない' "$md" >/dev/null; then
    echo "照合規則を SKILL.md に再掲している: $(grep -nE '全角の|同名 `?<repo>`?|github\.com/<owner>/<repo>/issues|大文字小文字を区別しない' "$md" | head -1)"
    return 1
  fi
  return 0
}

msg="$(check_skill "$SKILL_MD")" && ok "R9: SKILL.md が不変条件を満たす" || bad "R9: SKILL.md が不変条件を満たす" "$msg"

# 変異注入（検査が空虚でないこと）。変異ごとに原本からコピーを作る（原本は書き換えない）。
mutate() { # mutate <名前> <ruby の置換式（ブロック形）>
  local m="$tmp/mut-$1.md"
  cp "$SKILL_MD" "$m"
  ruby -e 's = File.read(ARGV[0], encoding: "UTF-8"); s2 = eval(ARGV[1]); abort("変異が当たらない") if s2 == s; File.write(ARGV[0], s2)' "$m" "$2" \
    || { bad "R9 変異: $1" "変異の注入に失敗"; return; }
  if check_skill "$m" >/dev/null; then bad "R9 変異: $1 を検出できる" "check_skill が通ってしまった"
  else ok "R9 変異: $1 を検出できる"; fi
}
mutate "スクリプト呼び出しの削除" 's.sub("scripts/ledger-related-issues.rb") { "scripts/xxx.rb" }'
mutate "照合順の逆転" 's.sub("1. **取り込み元マーカーの外部キー照合を先に行う**") { "1. **（削除）**" }.sub("   - **exit 2**") { "   - 取り込み元マーカーの外部キー照合を先に行う\n   - **exit 2**" }'
mutate "束ね済みの不作為の削除" 's.sub("**`fp` の更新・人間記入欄の更新・下記") { "**下記" }'
mutate "exit 1 の fail-closed の削除" 's.sub("`unregistered` を**新規として追記しない**") { "`unregistered` を新規として扱う" }'
mutate "報告から束ね済み N を削除" 's.sub("スキップ N / 束ね済み N /") { "スキップ N /" }'
mutate "照合規則の再掲" 's.sub("#### assignee フィルタ") { "- 区切りは全角の読点も受け付ける\n\n#### assignee フィルタ" }'

# 手順2 の assignee フィルタが束ね済みを新規候補として扱わない（二重計上しない）
s2="$(awk '/^### 2\. /{ f = 1; print; next } f && /^### /{ exit } f' "$SKILL_MD")"
has "R9: 手順2 は束ね済みを assignee フィルタに掛けない" "$s2" '**`関連Issue` に一致した（束ね済みの）エントリも本フィルタに掛けず手順4へ渡す**'

# テンプレート・台帳フォーマット契約: 手書きの取り込み対象外が不要になった旨
tpl="$(cat "$SOURCES_TPL")"
has "R9: challenge-sources テンプレートが束ねた Issue の除外記述を不要と案内する" "$tpl" '手書きの取り込み対象外の記述は不要'
fmt="$(cat "$FORMAT_DOC")"
has "R9: 台帳フォーマット契約が関連Issue の照合キーとしての役割を書く" "$fmt" '**`関連Issue` は ingest の既登録判定の照合キーも兼ねる**'
has "R9: 台帳フォーマット契約の再取り込み判定に束ね済みがある" "$fmt" '「束ね済み」として計上'

printf '\npassed: %s / failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
