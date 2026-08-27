#!/usr/bin/env bash
#
# ledger-index.test.sh — scripts/ledger-index.rb（課題台帳の索引投影）のテスト。
#
# 実行: bash scripts/tests/ledger-index.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・ruby・git。テストフレームワーク不使用。
#   - すべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
# 本テストは docs/ledger-load-strategy.md §6 の T1〜T9 を実装する。**T1〜T8 は投影スクリプトより
# 先に書き、足した時点で落ちること**を確認してから実装した（§7 の決定）。T9 は PR #128 の
# レビューで見つかった「宣言した版と実測がずれる」事故を受けて後から足した。
#
#   T1 経路表の完全性   contracts/ledger-read-scope.tsv に 7 ステータス全ての行があること
#   T2 投影の全域性     出力行数 ＝ 台帳のエントリ数（^### \[・フェンス除外）
#   T3 受理方向         contracts/fixtures/ledger/valid/* の全正例を exit 0 で全件投影
#   T4 エントリ境界     隣接エントリを巻き込まないこと（変異注入で検出できることまで）
#   T5 否定検査         出力に引用行（^>）が 1 行も混ざらないこと
#   T6 sync-free        索引がファイルとして生成されないこと（正本は台帳 1 つ）
#   T7 語彙の一致       ステータス語彙が正本・SKILL.md・経路表で一致（双方向）
#   T8 列の完全性       索引で足りると宣言した判定に要る列が出力に存在すること

set -u
set -o pipefail

# 外部の Git 設定を遮断する（priority-policy-resolve.test.sh と同じ理由＝準備の失敗を
# 被検体の欠陥として報告しないため）。
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$TESTS_DIR/../ledger-index.rb"
SCOPE_TSV="$REPO_ROOT/contracts/ledger-read-scope.tsv"
SKILL_MD="$REPO_ROOT/skills/run-cycle/SKILL.md"
LEDGER_TEMPLATE="$REPO_ROOT/templates/challenge-ledger.md"
VALID_FIXTURES="$REPO_ROOT/contracts/fixtures/ledger/valid"

PASS=0
FAIL=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ok()   { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; }
# 注意: 全角文字の直前の変数展開は bash 3.2 が誤るため、必ず ${var} のブレース形で書く。
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want=[$3] got=[$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "not found: $3" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpectedly found: $3" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
# 前提: 被検体が存在すること（存在しなければ以降は意味が無いので即終了）
# ---------------------------------------------------------------------------
if [ ! -f "$SCRIPT" ]; then
  bad "被検体が存在する: scripts/ledger-index.rb" "not found: $SCRIPT"
  printf '\npassed: %s / failed: %s\n' "$PASS" "$FAIL"
  exit 1
fi
[ -x "$SCRIPT" ] && ok "被検体に実行権がある" || bad "被検体に実行権がある" "chmod +x が要る"

run() { "$SCRIPT" "$@" 2>"$tmp/stderr"; }

# ---------------------------------------------------------------------------
# 素材: 7 ステータスを 1 件ずつ持つ台帳（記入例フェンス付き）
# ---------------------------------------------------------------------------
make_entry() { # $1=id $2=status $3=svc $4=repos $5=ingested(y/-) $6=approvals(例 "x ")
  local id="$1" st="$2" svc="$3" repos="$4" ing="$5" ap1="$6" ap2="$7"
  cat <<ENTRY

### [${id}] ${id} のタイトル

**人間記入欄**
- 起票者 / 起票日: tester / 2026-08-2${id##*-}
- 説明:（原文引用）
> ## 外部本文の見出し
>
> 引用の本文。ここは索引に出てはならない。
- 完了条件（任意）: 何かが完了する
- 体感の緊急度（任意）: 中

**分類欄（エージェントが記入）**
- 担当ポジション: harness
- 関連サービス: ${svc}
- 関連リポジトリ: ${repos}
- 関連Issue:
- 関連PR:
- 優先度: P1
- ステータス: ${st}
- タスク案: 何かをする
- 承認（人間がチェック）:
  - [${ap1}] 計画を承認（FR-13）
  - [${ap2}] 完了を承認（FR-32）
- 取り込み元: ${ing}
- 備考: 備考の本文
ENTRY
}

LEDGER="$tmp/challenge-ledger.md"
{
  cat <<'HEAD'
# 課題台帳（Challenge Ledger）

> テスト用の台帳。

---

## 記入例（コピーして使う）

```markdown
### [C-001] <タイトル>

**人間記入欄**
- 起票者 / 起票日: <name> / <YYYY-MM-DD>
- 説明: <背景>

**分類欄（エージェントが記入）**
- 担当ポジション:
- ステータス: 未分類（未分類 → 分類済 → 計画承認待ち → 着手中 → 検証中 → 完了確認待ち → 完了）
- 備考:
```

---
HEAD
  # C-1 のステータスは**遷移説明つき**（実台帳の未分類エントリの形）。索引が `（…）` を
  # 落とすことを固定する（落とさない実装は status 列が長文になり索引の意味を失う）。
  make_entry "C-1" "未分類（未分類 → 分類済 → 計画承認待ち → 着手中 → 検証中 → 完了確認待ち → 完了）" "svc-a"  ""                      ""                                    " " " "
  make_entry "C-2" "分類済"       "svc-b"  "o/r1"                  "src / o/r1#7（取り込み: 2026-08-20）" " " " "
  make_entry "C-3" "計画承認待ち" "svc-c"  "o/r1, o/r2"            ""                                    "x" " "
  make_entry "C-4" "着手中"       "svc-d"  "o/r2"                  "src / o/r2#8（取り込み: 2026-08-21）" "x" " "
  make_entry "C-5" "検証中"       "svc-e"  "o/r3"                  ""                                    "x" " "
  make_entry "C-6" "完了確認待ち" "svc-f"  "o/r3"                  ""                                    "x" "x"
  make_entry "C-7" "完了"         "svc-g"  "o/r4"                  ""                                    "x" "x"
} > "$LEDGER"

ENTRY_COUNT=7

# ===========================================================================
# T2 投影の全域性
# ===========================================================================
out="$(run "$LEDGER")"; rc=$?
eq "T2: 正常な台帳で exit 0" "$rc" "0"
body="$(printf '%s\n' "$out" | tail -n +2)"          # ヘッダ行を除く
eq "T2: 出力行数 = エントリ数（フェンス内の記入例を数えない）" \
   "$(printf '%s\n' "$body" | grep -c .)" "$ENTRY_COUNT"
eq "T2: ID が順序どおり全件そろう" \
   "$(printf '%s\n' "$body" | cut -f1 | tr '\n' ',')" "C-1,C-2,C-3,C-4,C-5,C-6,C-7,"
hasnt "T2: フェンス内の記入例 C-001 を拾わない" "$out" "C-001"

# 全域性の変異検査: 1 件消したら出力も 1 件減る（数え方が定数に固定されていないこと）
cp "$LEDGER" "$tmp/ledger.bak"                        # 復元用バックアップ（git checkout は使わない）
ruby -e '
  src, dst = ARGV
  lines = File.read(src, encoding: "UTF-8").split("\n", -1)
  s = lines.index { |l| l.start_with?("### [C-7]") }
  File.write(dst, (lines[0...s]).join("\n"))
' "$LEDGER" "$tmp/ledger-6.md"
eq "T2: エントリを 1 件削ると出力も 1 件減る（定数固定でない）" \
   "$(run "$tmp/ledger-6.md" | tail -n +2 | grep -c .)" "6"

# ===========================================================================
# T5 否定検査: 引用行が混ざらない
# ===========================================================================
hasnt "T5: 出力に引用マーカー（>）が現れない" "$out" ">"
hasnt "T5: 引用本文が漏れていない" "$out" "索引に出てはならない"
hasnt "T5: 説明フィールドの値が漏れていない" "$out" "原文引用"
hasnt "T5: 備考が漏れていない" "$out" "備考の本文"
hasnt "T5: 完了条件が漏れていない" "$out" "何かが完了する"
hasnt "T5: タスク案が漏れていない" "$out" "何かをする"

# ===========================================================================
# T8 列の完全性: 索引で足りると宣言した判定に要る列が出力に在る
# ===========================================================================
header="$(printf '%s\n' "$out" | head -1)"
eq "T8: ヘッダの列が仕様どおり（§3.2 の 10 列）" "$header" \
   "$(printf 'id\tstatus\tprio\tpos\tsvc\topened\trepos\tapprovals\tingested\ttitle')"
for col in id status prio pos svc opened repos approvals ingested title; do
  has "T8: 列 ${col} が在る" "$header" "$col"
done
row3="$(printf '%s\n' "$body" | awk -F'\t' '$1=="C-3"')"
eq "T8: svc 列に関連サービスが入る（domain-bootstrap の着手順判定）" \
   "$(printf '%s\n' "$row3" | cut -f5)" "svc-c"
eq "T8: repos 列に関連リポジトリが入る（improvement-first の束ね判定）" \
   "$(printf '%s\n' "$row3" | cut -f7)" "o/r1, o/r2"
eq "T8: opened 列に起票日が入る（normal の同一優先度内の順序）" \
   "$(printf '%s\n' "$row3" | cut -f6)" "2026-08-23"
eq "T8: approvals 列が 2 文字（1-f の承認検出）" \
   "$(printf '%s\n' "$row3" | cut -f8)" "x-"
eq "T8: ingested 列は取り込み元の有無だけ（2-d。値そのものは載せない）" \
   "$(printf '%s\n' "$body" | awk -F'\t' '$1=="C-2"' | cut -f9)" "y"
eq "T8: 取り込み元が空なら ingested=-" \
   "$(printf '%s\n' "$row3" | cut -f9)" "-"
hasnt "T8: 取り込み元の値そのものは載らない" "$out" "取り込み: 2026-08-20"
eq "T8: status 列にステータスが入る（括弧内の遷移説明は落とす）" \
   "$(printf '%s\n' "$row3" | cut -f2)" "計画承認待ち"
eq "T8: 遷移説明つきのステータス行から遷移説明を落とす" \
   "$(printf '%s\n' "$body" | awk -F'\t' '$1=="C-1"' | cut -f2)" "未分類"
hasnt "T8: status 列に遷移説明が漏れない" "$out" "→"

# ===========================================================================
# T4 エントリ境界: 隣接エントリを巻き込まない（変異注入で検出できることまで）
# ===========================================================================
# 正常系: 各行の値が「そのエントリ自身の」値であること（隣の値が混ざらない）
mix=0
i=1
while [ $i -le $ENTRY_COUNT ]; do
  r="$(printf '%s\n' "$body" | awk -F'\t' -v id="C-$i" '$1==id')"
  [ "$(printf '%s\n' "$r" | cut -f5)" = "svc-$(printf '\\x%02x' $((0x60 + i)) | printf '%b' "$(cat)")" ] || true
  i=$((i + 1))
done
# svc は a..g の順に振ってある。列の値がエントリ順とずれていないかを一括で見る。
eq "T4: 各行の svc が自エントリの値（隣接エントリの巻き込みなし）" \
   "$(printf '%s\n' "$body" | cut -f5 | tr '\n' ',')" "svc-a,svc-b,svc-c,svc-d,svc-e,svc-f,svc-g,"
eq "T4: 各行の status が自エントリの値" \
   "$(printf '%s\n' "$body" | cut -f2 | tr '\n' ',')" \
   "未分類,分類済,計画承認待ち,着手中,検証中,完了確認待ち,完了,"

# 変異注入 (a): 見出しを `## [C-4]` へ降格させると、C-4 の本文が C-3 に吸収される。
# 投影がこれを「7 件そろっている」と報告してはならない（件数が減る＝検出できる）。
ruby -e '
  src, dst = ARGV
  s = File.read(src, encoding: "UTF-8")
  File.write(dst, s.sub("### [C-4]", "## [C-4]"))
' "$LEDGER" "$tmp/mutant-demoted.md"
mut="$(run "$tmp/mutant-demoted.md" | tail -n +2 | grep -c .)"
if [ "$mut" != "$ENTRY_COUNT" ]; then
  ok "T4[変異]: 見出し降格を検出できる（件数が ${ENTRY_COUNT} → ${mut}）"
else
  bad "T4[変異]: 見出し降格を検出できる" "件数が変わらず ${mut} のまま＝境界検査が効いていない"
fi
hasnt "T4[変異]: 降格した見出しの行が出力に現れない" "$(run "$tmp/mutant-demoted.md")" "C-4"
# 降格で C-3 が C-4 の本文を吸収した状態でも、C-3 の行は**自分の値**を保つこと。
# 「最後に見つけたフィールド行を採る」実装だと隣の値へ化ける（[ledger-range-delete-bug] の同型）。
dem3="$(run "$tmp/mutant-demoted.md" | tail -n +2 | awk -F'\t' '$1=="C-3"')"
eq "T4[変異]: 吸収されても C-3 の status は自分の値（隣へ化けない）" \
   "$(printf '%s\n' "$dem3" | cut -f2)" "計画承認待ち"
eq "T4[変異]: 吸収されても C-3 の svc は自分の値" \
   "$(printf '%s\n' "$dem3" | cut -f5)" "svc-c"
eq "T4[変異]: 吸収されても C-3 の approvals は自分の値" \
   "$(printf '%s\n' "$dem3" | cut -f8)" "x-"

# 変異注入 (b): C-3 の分類欄を丸ごと削ると、C-3 の行は隣（C-4）の値を拾ってはならない。
ruby -e '
  src, dst = ARGV
  lines = File.read(src, encoding: "UTF-8").split("\n", -1)
  s = lines.index { |l| l.start_with?("### [C-3]") }
  e = lines.index { |l| l.start_with?("### [C-4]") }
  cls = (s...e).find { |i| lines[i].start_with?("**分類欄") }
  File.write(dst, (lines[0...cls] + lines[e..-1]).join("\n"))
' "$LEDGER" "$tmp/mutant-stripped.md"
strip_row="$(run "$tmp/mutant-stripped.md" | tail -n +2 | awk -F'\t' '$1=="C-3"')"
eq "T4[変異]: 分類欄を失った C-3 も 1 行として現れる（黙って消えない）" \
   "$(printf '%s\n' "$strip_row" | cut -f1)" "C-3"
eq "T4[変異]: C-3 の status は空（隣の C-4 の値を拾わない）" \
   "$(printf '%s\n' "$strip_row" | cut -f2)" ""
eq "T4[変異]: C-3 の svc は空（隣の C-4 の値を拾わない）" \
   "$(printf '%s\n' "$strip_row" | cut -f5)" ""
eq "T4[変異]: 件数は ${ENTRY_COUNT} 件のまま" \
   "$(run "$tmp/mutant-stripped.md" | tail -n +2 | grep -c .)" "$ENTRY_COUNT"

# 変異注入の復元（バックアップからの上書き。git checkout は使わない）
cp "$tmp/ledger.bak" "$LEDGER"
eq "T4: 変異注入の後、素材の台帳がバックアップから復元されている" \
   "$(run "$LEDGER" | tail -n +2 | grep -c .)" "$ENTRY_COUNT"

# ===========================================================================
# T3 受理方向: 配布している正例フィクスチャをすべて受理する
# ===========================================================================
if [ -d "$VALID_FIXTURES" ]; then
  n_fx=0
  for fx in "$VALID_FIXTURES"/*.md; do
    [ -f "$fx" ] || continue
    n_fx=$((n_fx + 1))
    name="$(basename "$fx")"
    fx_out="$(run "$fx")"; fx_rc=$?
    eq "T3: 正例 ${name} を exit 0 で受理" "$fx_rc" "0"
    # フィクスチャの実エントリ数（フェンス除外）を独立に数え、全件出ることを確かめる
    want="$(ruby -e '
      inf = false; n = 0
      File.read(ARGV[0], encoding: "UTF-8").each_line do |l|
        if l.start_with?("```") then inf = !inf; next end
        next if inf
        n += 1 if l.start_with?("### [")
      end
      print n' "$fx")"
    eq "T3: 正例 ${name} の全 ${want} エントリを投影" \
       "$(printf '%s\n' "$fx_out" | tail -n +2 | grep -c .)" "$want"
    hasnt "T3: 正例 ${name} の出力に引用行が混ざらない" "$fx_out" ">"
  done
  [ "$n_fx" -gt 0 ] && ok "T3: 正例フィクスチャを ${n_fx} 件検査した" \
    || bad "T3: 正例フィクスチャを検査した" "0 件しか見つからない（空集合ガード）"
else
  bad "T3: 正例フィクスチャのディレクトリが在る" "not found: $VALID_FIXTURES"
fi

# 受理方向（テンプレート）: 配布している台帳の雛形は記入例だけ＝エントリ 0 件でも exit 0
tpl_out="$(run "$LEDGER_TEMPLATE")"; tpl_rc=$?
eq "T3: 配布テンプレート challenge-ledger.md を exit 0 で受理" "$tpl_rc" "0"
eq "T3: 配布テンプレートは実エントリ 0 件（記入例はフェンス内）" \
   "$(printf '%s\n' "$tpl_out" | tail -n +2 | grep -c .)" "0"
eq "T3: エントリ 0 件でもヘッダ行は出る（呼び出し側の解析を一様にする）" \
   "$(printf '%s\n' "$tpl_out" | head -1 | cut -f1)" "id"

# ===========================================================================
# T1 経路表の完全性 ＋ T7 語彙の一致
# ===========================================================================
if [ ! -f "$SCOPE_TSV" ]; then
  bad "T1: 経路表 contracts/ledger-read-scope.tsv が在る" "not found: $SCOPE_TSV"
else
  scope_rows="$(grep -v '^#' "$SCOPE_TSV" | grep -c .)"
  # 語彙の正本 = templates/challenge-ledger.md のステータス行の遷移列
  canon="$(ruby -e '
    s = File.read(ARGV[0], encoding: "UTF-8")
    m = s[/^- ステータス: *[^（\n]*（([^）]*)）/, 1]
    abort "status line not found" unless m
    print m.split("→").map(&:strip).join("\n")' "$LEDGER_TEMPLATE")"
  canon_n="$(printf '%s\n' "$canon" | grep -c .)"
  eq "T7: 語彙の正本（テンプレートのステータス行）が 7 値" "$canon_n" "7"
  eq "T1: 経路表の行数 = ステータス数（行の無いステータスが無い）" "$scope_rows" "$canon_n"

  # 双方向: 正本の各値に行が在る / 経路表の各行が正本に在る
  miss_row=""; miss_canon=""
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    grep -q "^${st}	" "$SCOPE_TSV" || miss_row="${miss_row}${st} "
  done <<EOF_CANON
$canon
EOF_CANON
  eq "T1: 正本の全ステータスに経路表の行が在る" "$miss_row" ""

  while IFS= read -r st; do
    [ -n "$st" ] || continue
    printf '%s\n' "$canon" | grep -qx "$st" || miss_canon="${miss_canon}${st} "
  done <<EOF_ROWS
$(grep -v '^#' "$SCOPE_TSV" | grep . | cut -f1)
EOF_ROWS
  eq "T7: 経路表の全ステータスが正本の語彙に在る（造語が混ざらない）" "$miss_canon" ""

  # scope の閉語彙
  bad_scope="$(grep -v '^#' "$SCOPE_TSV" | grep . | cut -f2 \
    | grep -vx -e index -e full -e index-then-full | tr '\n' ' ')"
  eq "T1: scope 列が閉語彙（index / full / index-then-full）" "$bad_scope" ""

  # 空集合ガード: 3 値それぞれが少なくとも 1 行で使われている（表が退化していない）
  for sc in index full index-then-full; do
    c="$(grep -v '^#' "$SCOPE_TSV" | grep . | cut -f2 | grep -cx "$sc")"
    if [ "$c" -ge 1 ]; then ok "T1: scope=${sc} の行が在る"
    else bad "T1: scope=${sc} の行が在る" "0 行＝閉語彙が実際には使われていない"; fi
  done

  # T7: 正本の各ステータスが SKILL.md にも現れる（3 箇所目のずれを検出）
  miss_skill=""
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    grep -q "$st" "$SKILL_MD" || miss_skill="${miss_skill}${st} "
  done <<EOF_SK
$canon
EOF_SK
  eq "T7: 正本の全ステータスが SKILL.md に現れる" "$miss_skill" ""

  # T7: SKILL.md の「対象: ステータス「X」」に出る語が正本に在る
  bad_head="$(grep -o '対象: ステータス「[^」]*」' "$SKILL_MD" \
    | sed 's/対象: ステータス「//; s/」//' | sort -u \
    | while IFS= read -r h; do printf '%s\n' "$canon" | grep -qx "$h" || printf '%s ' "$h"; done)"
  eq "T7: SKILL.md の手順見出しのステータス語が正本に在る" "$bad_head" ""

  # T1: SKILL.md が経路表を正本として指していること（散文へ二重に書き写さない）
  has "T1: SKILL.md が経路表ファイルを参照している" \
      "$(cat "$SKILL_MD")" "contracts/ledger-read-scope.tsv"
  has "T1: SKILL.md が投影スクリプトを呼んでいる" \
      "$(cat "$SKILL_MD")" "scripts/ledger-index.rb"
fi

# ===========================================================================
# T6 sync-free: 索引をファイルとして作らない（正本は台帳 1 つ）
# ===========================================================================
work="$tmp/sync-free"
mkdir -p "$work"
cp "$LEDGER" "$work/challenge-ledger.md"
before="$(ls -A "$work" | sort | tr '\n' ',')"
( cd "$work" && "$SCRIPT" challenge-ledger.md >/dev/null 2>&1 )
after="$(ls -A "$work" | sort | tr '\n' ',')"
eq "T6: 実行してもディレクトリに新しいファイルが増えない" "$after" "$before"
eq "T6: 台帳自体が書き換わらない" \
   "$(cmp -s "$LEDGER" "$work/challenge-ledger.md" && echo same || echo changed)" "same"
hasnt "T6: 許可パスの正本に索引ファイルが現れない" \
      "$(cat "$REPO_ROOT/contracts/cycle-commit-paths.txt")" "ledger-index"
# 索引を保存した生成物がリポジトリに追跡されていないこと（索引ファイル化への漂流の検出）
eq "T6: 索引の生成物がリポジトリに追跡されていない" \
   "$(cd "$REPO_ROOT" && git ls-files | grep -c -E '(^|/)(ledger-)?index\.(tsv|txt)$')" "0"
# 経路表の**データ行**はステータス→範囲の対応だけで、ファイルパスを持たない
# （経路表が第二の生成物を指し始めたら二重正本化の兆候）
eq "T6: 経路表のデータ行がファイルパスを含まない" \
   "$(grep -v '^#' "$SCOPE_TSV" | grep . | grep -c -E '\.(md|tsv|txt|jsonl?)([[:space:]]|$)')" "0"

# 読み取り専用であること: 書き込み不可のディレクトリでも投影できる
ro="$tmp/ro"; mkdir -p "$ro"; cp "$LEDGER" "$ro/l.md"; chmod 555 "$ro"
( cd "$ro" && "$SCRIPT" l.md >/dev/null 2>&1 )
eq "T6: 書き込めないディレクトリでも投影できる（読み取り専用）" "$?" "0"
chmod 755 "$ro"

# ===========================================================================
# 異常系の出力契約（3 値の exit code）
# ===========================================================================
eq "異常系: 引数なしは exit 2（検査不能）" "$(run >/dev/null 2>&1; echo $?)" "2"
eq "異常系: 不在ファイルは exit 2" "$(run "$tmp/nope.md" >/dev/null 2>&1; echo $?)" "2"
[ -s "$tmp/stderr" ] && ok "異常系: exit 2 のとき stderr に理由が出る" \
  || bad "異常系: exit 2 のとき stderr に理由が出る" "stderr が空"
eq "異常系: 不明なオプションは exit 2" \
   "$(run "$LEDGER" --nope >/dev/null 2>&1; echo $?)" "2"

# 宣言と振る舞いの一致（priority-policy-resolve.sh の --list-exits に倣う）
declared="$(run --list-exits | sort | tr '\n' ',')"
eq "宣言: --list-exits が 0/2 を宣言する" "$declared" "0,2,"
eq "宣言: --list-columns が出力ヘッダと一致する" \
   "$(run --list-columns | tr '\n' '\t' | sed 's/\t$//')" "$header"

# TSV の頑健性: 値にタブが混ざっても列がずれない
ruby -e '
  src, dst = ARGV
  s = File.read(src, encoding: "UTF-8")
  File.write(dst, s.sub("- 関連サービス: svc-a", "- 関連サービス: svc\ta"))
' "$LEDGER" "$tmp/tabby.md"
eq "頑健性: 値にタブが混ざっても列数がずれない" \
   "$(run "$tmp/tabby.md" | tail -n +2 | head -1 | awk -F'\t' '{print NF}')" "10"
eq "頑健性: タブは空白へ正規化する（詰めて別語にしない）" \
   "$(run "$tmp/tabby.md" | tail -n +2 | head -1 | cut -f5)" "svc a"

# ===========================================================================
# T9 実測表の自己整合: docs/ledger-load-strategy.md §1.2 が「宣言した版」で測られているか
# ===========================================================================
# なぜここに置くか: この doc は本機能の設計記録であり、本スイートは既に SKILL.md・
# テンプレート・contracts を読んでいる。1 ドキュメントのために 10 個目のスイートを
# 増やすより、機能の契約と同じ場所で守るほうが見落としにくい。
#
# なぜ**バイト**で照合するか: tok は tiktoken（本リポジトリの依存に無い）が要るが、
# バイト数はトークナイザ非依存で `git show | wc -c` だけで検算できる。実際に起きた事故
# （§1.1 が `5024ec8` を宣言しているのに §1.2 には別の版の値が入っていた）は
# バイト列でも同じようにずれるため、これで検出できる。
#
# ワークスペース側のファイル（`aa0ac68` の台帳等）は別リポジトリにあり本リポジトリからは
# 参照できない。**照合できるのは本リポジトリ由来の行＝ SKILL.md だけ**であり、残りは
# 表の内部整合（行の合計＝小計・小計−台帳＝派生定数・§5 の before＝§1.2 の小計）で守る。
DOC="$REPO_ROOT/docs/ledger-load-strategy.md"
if [ ! -f "$DOC" ]; then
  bad "T9: 設計記録 docs/ledger-load-strategy.md が在る" "not found: $DOC"
else
  # §1.1 の版の表が SKILL.md に対して宣言している SHA
  declared="$(ruby -e '
    s = File.read(ARGV[0], encoding: "UTF-8")
    m = s[/^\| `skills\/run-cycle\/SKILL\.md`[^|]*\|[^`]*`([0-9a-f]{7,40})`/, 1]
    print m.to_s' "$DOC")"
  if [ -z "$declared" ]; then
    bad "T9: §1.1 が SKILL.md の測定版を SHA で宣言している" "版の表から SHA を取り出せない"
  else
    ok "T9: §1.1 が SKILL.md の測定版を SHA で宣言している（${declared}）"
    if ( cd "$REPO_ROOT" && git cat-file -e "${declared}^{commit}" 2>/dev/null ); then
      actual="$(cd "$REPO_ROOT" && git show "${declared}^{commit}:skills/run-cycle/SKILL.md" | wc -c | tr -d ' ')"
      stated="$(ruby -e '
        s = File.read(ARGV[0], encoding: "UTF-8")
        sec = s[/### 1\.2 .*?(?=### 1\.3 )/m].to_s
        row = sec.lines.find { |l| l.include?("skills/run-cycle/SKILL.md") }
        print row.to_s.split("|")[3].to_s.gsub(/[^0-9]/, "")' "$DOC")"
      eq "T9: §1.2 の SKILL.md のバイト数が宣言した版の実測と一致する" "$stated" "$actual"
    else
      bad "T9: 宣言された SHA が解決できる" "この環境に ${declared} が無く検算できない（浅いクローン等）"
    fi
  fi

  # 表の内部整合（バイト・tok とも）: 各行の合計 = 小計セル
  ruby -e '
    doc = File.read(ARGV[0], encoding: "UTF-8")
    sec = doc[/### 1\.2 .*?(?=### 1\.3 )/m].to_s
    n = ->(x) { x.to_s.gsub(/[^0-9]/, "") }
    sb = st = nil; b = t = 0
    sec.lines.each do |l|
      next unless l.start_with?("|")
      next if l.include?("---") || l.include?("区分")
      c = l.split("|")
      if l.include?("小計") then sb, st = n.(c[3]).to_i, n.(c[4]).to_i
      else
        next if n.(c[3]).empty? || n.(c[4]).empty?
        b += n.(c[3]).to_i; t += n.(c[4]).to_i
      end
    end
    # 派生定数と §5 の before
    ledger = doc[/\*\*台帳以外の固定文脈 ＝ ([\d,]+) − ([\d,]+) ＝ ([\d,]+) tok\*\*/]
    m = Regexp.last_match
    before5 = doc[/\| \*\*before\*\*（全文ロード） \|[^|]*\|[^|]*\| \*\*([\d,]+)\*\* \|/, 1]
    puts "rows_b=#{b} rows_t=#{t} sub_b=#{sb} sub_t=#{st}"
    puts "const_from=#{m ? m[1].delete(",") : ""} const_sub=#{m ? m[2].delete(",") : ""} const_val=#{m ? m[3].delete(",") : ""}"
    puts "before5=#{before5.to_s.delete(",")}"
  ' "$DOC" > "$tmp/tbl.txt"
  . "$tmp/tbl.txt"
  eq "T9: §1.2 の各行のバイトの合計 = 小計セル" "$rows_b" "$sub_b"
  eq "T9: §1.2 の各行の tok の合計 = 小計セル" "$rows_t" "$sub_t"
  eq "T9: 派生定数の引かれる数 = §1.2 の tok 小計" "$const_from" "$sub_t"
  eq "T9: 派生定数の値 = 小計 − 台帳（算術が成り立つ）" \
     "$const_val" "$((const_from - const_sub))"
  # 実際に起きたずれ: §5 の before が §1.2 の小計と食い違っていた
  eq "T9: §5 の before（固定文脈）= §1.2 の tok 小計" "$before5" "$sub_t"
fi

printf '\npassed: %s / failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
