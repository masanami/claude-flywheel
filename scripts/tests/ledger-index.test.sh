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
# T10 は別ドキュメント（docs/human-hold-representation.md §5）由来で、#116 の実装の前段として
# 足した（既に存在していた未固定の複製を塞ぐもので、語彙の増減とは独立に効く）。
# T11〜T13 も同 §5 由来で、#116 の本体（保留ステータス `人間対応待ち` の追加）と同時に足した。
#
#   T1 経路表の完全性   contracts/ledger-read-scope.tsv に全ステータスの行があること
#   T2 投影の全域性     出力行数 ＝ 台帳のエントリ数（^### \[・フェンス除外）
#   T3 受理方向         contracts/fixtures/ledger/valid/* の全正例を exit 0 で全件投影
#   T4 エントリ境界     隣接エントリを巻き込まないこと（変異注入で検出できることまで）
#   T5 否定検査         出力に引用行（^>）が 1 行も混ざらないこと
#   T6 sync-free        索引がファイルとして生成されないこと（正本は台帳 1 つ）
#   T7 語彙の一致       ステータス語彙が正本・記入例の遷移列・SKILL.md・経路表で一致（双方向）
#   T8 列の完全性       索引で足りると宣言した判定に要る列が出力に存在すること
#   T10 enum の一致     journal-index スキーマの touched_issues.to の enum と、その散文正本
#                       （templates/journal/README.md）の列挙が正本と一致（双方向）
#   T11 否定検査        保留ステータス（track=side）が SKILL.md 手順3 の対象条件に現れないこと
#   T12 語彙駆動        保留ステータスの経路表が index / index-then-full であること
#   T13 真理値表        (ステータス, 「人間の回答」の非空) と手順1 の前進が SKILL.md と一致

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
VOCAB_TSV="$REPO_ROOT/contracts/ledger-status-vocabulary.tsv"
SCHEMA_JSON="$REPO_ROOT/contracts/schemas/journal-index.schema.json"
SKILL_MD="$REPO_ROOT/skills/run-cycle/SKILL.md"
LEDGER_TEMPLATE="$REPO_ROOT/templates/challenge-ledger.md"
FORMAT_DOC="$REPO_ROOT/docs/challenge-ledger-format.md"
JOURNAL_README="$REPO_ROOT/templates/journal/README.md"
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
# 素材: 全ステータスを 1 件ずつ持つ台帳（記入例フェンス付き）。**語彙を増やしたらここも 1 件足す**
# （T4 の svc は a,b,c,… の順に振る＝列の値がエントリ順とずれていないかを一括で見るため）。
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
  make_entry "C-8" "人間対応待ち" "svc-h"  "o/r4"                  ""                                    "x" " "
} > "$LEDGER"

ENTRY_COUNT=8

# ===========================================================================
# T2 投影の全域性
# ===========================================================================
out="$(run "$LEDGER")"; rc=$?
eq "T2: 正常な台帳で exit 0" "$rc" "0"
body="$(printf '%s\n' "$out" | tail -n +2)"          # ヘッダ行を除く
eq "T2: 出力行数 = エントリ数（フェンス内の記入例を数えない）" \
   "$(printf '%s\n' "$body" | grep -c .)" "$ENTRY_COUNT"
eq "T2: ID が順序どおり全件そろう" \
   "$(printf '%s\n' "$body" | cut -f1 | tr '\n' ',')" "C-1,C-2,C-3,C-4,C-5,C-6,C-7,C-8,"
hasnt "T2: フェンス内の記入例 C-001 を拾わない" "$out" "C-001"

# 全域性の変異検査: 1 件消したら出力も 1 件減る（数え方が定数に固定されていないこと）
cp "$LEDGER" "$tmp/ledger.bak"                        # 復元用バックアップ（git checkout は使わない）
ruby -e '
  src, dst = ARGV
  lines = File.read(src, encoding: "UTF-8").split("\n", -1)
  s = lines.index { |l| l.start_with?("### [C-8]") }
  File.write(dst, (lines[0...s]).join("\n"))
' "$LEDGER" "$tmp/ledger-7.md"
eq "T2: エントリを 1 件削ると出力も 1 件減る（定数固定でない）" \
   "$(run "$tmp/ledger-7.md" | tail -n +2 | grep -c .)" "7"

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
# svc は a..h の順に振ってある。列の値がエントリ順とずれていないかを一括で見る。
eq "T4: 各行の svc が自エントリの値（隣接エントリの巻き込みなし）" \
   "$(printf '%s\n' "$body" | cut -f5 | tr '\n' ',')" "svc-a,svc-b,svc-c,svc-d,svc-e,svc-f,svc-g,svc-h,"
eq "T4: 各行の status が自エントリの値" \
   "$(printf '%s\n' "$body" | cut -f2 | tr '\n' ',')" \
   "未分類,分類済,計画承認待ち,着手中,検証中,完了確認待ち,完了,人間対応待ち,"

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
# T7 語彙の正本 ＋ T1 経路表の完全性 ＋ T10 スキーマの enum
#
# 語彙の正本は contracts/ledger-status-vocabulary.tsv（#116。それ以前はテンプレートの
# ステータス行の全角括弧内の `→` 連鎖が正本を兼ねており、**直列に並ばない状態（側道）を
# 表現できない**符号化だった）。連鎖は「主経路の記入例」として人間が読む面に残っており、
# ここでは**主経路の語彙と順序込みで一致すること**を固定する——記入例が嘘になったら落ちる。
#
# 閉じた語彙は「検査する箇所」ではなく「**全語を列挙する箇所**」に複製が潜む（enum・散文の
# 連鎖・表の行）。語 1 つの grep では全部は出ないので、列挙箇所を名指しで正本へ結線する。
# ===========================================================================

# ステータス行の `→` 連鎖を取り出す。テンプレートは `未分類（未分類 → … → 完了）`、
# 仕様書は `未分類 → … → 完了` と形が違うため、括弧があればその中・無ければ値全体を読む。
status_chain() {
  ruby -e '
    s = File.read(ARGV[0], encoding: "UTF-8")
    line = s[/^- ステータス:.*$/]
    abort "status line not found" unless line
    v = line.sub(/^- ステータス: */, "")
    v = $1 if v =~ /（([^）]*)）/
    print v.split("→").map(&:strip).join("\n")' "$1"
}

canon=""       # 語彙の正本（全ステータス・ファイル順）
canon_main=""  # 主経路のみ（order 昇順）＝記入例の `→` 連鎖と突き合わせる列
canon_n=0

if [ ! -f "$VOCAB_TSV" ]; then
  bad "T7: 語彙の正本 contracts/ledger-status-vocabulary.tsv が在る" "not found: $VOCAB_TSV"
else
  ok "T7: 語彙の正本 contracts/ledger-status-vocabulary.tsv が在る"

  # 正本の自己整合。多バイトの列を扱うため awk ではなく ruby で読む（macOS awk の
  # 多バイト等値比較を避ける＝contracts/README.md の実装言語の選定根拠と同じ理由）。
  vocab_err="$(ruby -e '
    rows = File.readlines(ARGV[0], encoding: "UTF-8")
      .reject { |l| l.start_with?("#") || l.strip.empty? }
      .map { |l| l.chomp.split("\t") }
    errs = []
    errs << "データ行が 0 件" if rows.empty?
    errs << "列が 3 列でない行がある" if rows.any? { |r| r.size != 3 }
    st = rows.map { |r| r[0] }
    errs << "ステータスが重複している" if st.uniq.size != st.size
    bad_track = rows.map { |r| r[1] }.reject { |t| %w[main side].include?(t) }.uniq
    errs << "track が閉語彙（main / side）でない: #{bad_track.join(" ")}" unless bad_track.empty?
    main = rows.select { |r| r[1] == "main" }
    errs << "track=main の行が無い" if main.empty?
    ord = main.map { |r| r[2] }
    unless ord.all? { |o| o =~ /\A[0-9]+\z/ } && ord.map(&:to_i).sort == (1..main.size).to_a
      errs << "main の order が 1 始まりの連番でない: #{ord.join(",")}"
    end
    bad_side = rows.select { |r| r[1] == "side" }.map { |r| r[2] }.reject { |o| o == "-" }
    errs << "side の order が - でない: #{bad_side.join(",")}" unless bad_side.empty?
    print errs.join(" / ")' "$VOCAB_TSV" 2>&1)"
  eq "T7: 語彙の正本が自己整合（3 列・重複なし・track の閉語彙・main の order が連番）" \
     "$vocab_err" ""

  canon="$(grep -v '^#' "$VOCAB_TSV" | grep . | cut -f1)"
  canon_main="$(ruby -e '
    rows = File.readlines(ARGV[0], encoding: "UTF-8")
      .reject { |l| l.start_with?("#") || l.strip.empty? }
      .map { |l| l.chomp.split("\t") }
    print rows.select { |r| r[1] == "main" }.sort_by { |r| r[2].to_i }.map { |r| r[0] }.join("\n")' \
    "$VOCAB_TSV")"
  canon_n="$(printf '%s\n' "$canon" | grep -c .)"
  eq "T7: 語彙の正本が 8 値" "$canon_n" "8"
fi

# 空集合ガード: 正本が読めないと以下の包含検査はすべて空虚に真になる（0 件の照合は
# 「ずれが無い」と区別できない）。正本が空なら以降を pass にせず明示的に落とす。
if [ -z "$canon" ]; then
  bad "T1/T7/T10: 語彙の正本が非空（以降の一致検査が空虚に真にならないこと）" \
      "canon が 0 件のため経路表・記入例・SKILL.md・enum の照合を実行できない"
else
  ok "T1/T7/T10: 語彙の正本が非空（空集合ガード）"

  # -------------------------------------------------------------------------
  # T7: 記入例の `→` 連鎖 ＝ 主経路の語彙（**順序込み**・両方向）
  #     連鎖は人間が読む記入例であって正本ではない。side を連鎖へ並べると「必須の中間
  #     ステップ」という嘘になるため、比較対象は main だけ（並べたらこの検査が落ちる）。
  # -------------------------------------------------------------------------
  for f in "$LEDGER_TEMPLATE" "$FORMAT_DOC"; do
    if [ ! -f "$f" ]; then
      bad "T7: 記入例のステータス行を持つファイルが在る" "not found: $f"
      continue
    fi
    chain="$(status_chain "$f" 2>"$tmp/chain_err")"
    if [ -z "$chain" ]; then
      bad "T7: ${f##*/} からステータス行の遷移列を抽出できる" "$(cat "$tmp/chain_err")"
    else
      eq "T7: ${f##*/} の遷移列が主経路の語彙と順序込みで一致" "$chain" "$canon_main"
    fi
  done

  # -------------------------------------------------------------------------
  # T1: 経路表の完全性（side を含む全ステータスに行が要る）
  # -------------------------------------------------------------------------
  if [ ! -f "$SCOPE_TSV" ]; then
    bad "T1: 経路表 contracts/ledger-read-scope.tsv が在る" "not found: $SCOPE_TSV"
  else
    scope_rows="$(grep -v '^#' "$SCOPE_TSV" | grep -c .)"
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
  fi

  # -------------------------------------------------------------------------
  # T10: journal-index スキーマの enum ＝ 語彙の正本（双方向）
  #      この enum は語彙の複製でありながら、どのテストにも固定されていなかった
  #      （docs/human-hold-representation.md §2.2）。漏らすと台帳を書いた**後**・
  #      コミットの直前に手順6 の検算が fail-closed で止まり、原因が語彙の追加だと
  #      結びつきにくい。ここで書いた時点に落とす。
  # -------------------------------------------------------------------------
  if [ ! -f "$SCHEMA_JSON" ]; then
    bad "T10: contracts/schemas/journal-index.schema.json が在る" "not found: $SCHEMA_JSON"
  else
    enum_vals="$(ruby -rjson -e '
      s = JSON.parse(File.read(ARGV[0], encoding: "UTF-8"))
      e = s.dig("properties", "touched_issues", "items", "properties", "to", "enum")
      abort "touched_issues.to.enum not found" unless e.is_a?(Array)
      print e.join("\n")' "$SCHEMA_JSON" 2>"$tmp/enum_err")"
    if [ -z "$enum_vals" ]; then
      bad "T10: スキーマから touched_issues.to の enum を取り出せる" "$(cat "$tmp/enum_err")"
    else
      eq "T10: enum の件数が語彙の正本と一致" \
         "$(printf '%s\n' "$enum_vals" | grep -c .)" "$canon_n"

      miss_enum=""
      while IFS= read -r st; do
        [ -n "$st" ] || continue
        printf '%s\n' "$enum_vals" | grep -qx "$st" || miss_enum="${miss_enum}${st} "
      done <<EOF_CANON_ENUM
$canon
EOF_CANON_ENUM
      eq "T10: 正本の全ステータスが enum に在る（漏らすと当該周のコミットが止まる）" \
         "$miss_enum" ""

      extra_enum=""
      while IFS= read -r v; do
        [ -n "$v" ] || continue
        printf '%s\n' "$canon" | grep -qx "$v" || extra_enum="${extra_enum}${v} "
      done <<EOF_ENUM
$enum_vals
EOF_ENUM
      eq "T10: enum の全値が正本の語彙に在る（退役した語が残らない）" "$extra_enum" ""
    fi
  fi

  # -------------------------------------------------------------------------
  # T7: SKILL.md（3 箇所目の列挙）との一致
  # -------------------------------------------------------------------------
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

  # -------------------------------------------------------------------------
  # T10（続き）: 散文正本（templates/journal/README.md）の列挙 ＝ 語彙の正本
  #   スキーマの enum には contracts/README.md が定める散文正本があり、そこにも同じ語彙が
  #   全語列挙されている。**閉じた語彙の複製は「検査する箇所」ではなく「列挙する箇所」に
  #   潜む**ため、enum だけを結線して散文を放置すると 2 本目のリストが黙ってずれる。
  # -------------------------------------------------------------------------
  if [ ! -f "$JOURNAL_README" ]; then
    bad "T10: templates/journal/README.md が在る" "not found: $JOURNAL_README"
  else
    doc_vals="$(ruby -e '
      s = File.read(ARGV[0], encoding: "UTF-8")
      m = s[/正規のステータス語彙のみ\*\*（`([^`]*)`）/, 1]
      abort "touched_issues.to の語彙列挙が見つからない" unless m
      print m.split("/").map(&:strip).reject(&:empty?).join("\n")' "$JOURNAL_README" 2>"$tmp/doc_err")"
    if [ -z "$doc_vals" ]; then
      bad "T10: 散文正本から touched_issues.to の語彙列挙を取り出せる" "$(cat "$tmp/doc_err")"
    else
      eq "T10: 散文正本の列挙の件数が語彙の正本と一致" \
         "$(printf '%s\n' "$doc_vals" | grep -c .)" "$canon_n"

      miss_doc=""
      while IFS= read -r st; do
        [ -n "$st" ] || continue
        printf '%s\n' "$doc_vals" | grep -qx "$st" || miss_doc="${miss_doc}${st} "
      done <<EOF_CANON_DOC
$canon
EOF_CANON_DOC
      eq "T10: 正本の全ステータスが散文正本の列挙に在る" "$miss_doc" ""

      extra_doc=""
      while IFS= read -r v; do
        [ -n "$v" ] || continue
        printf '%s\n' "$canon" | grep -qx "$v" || extra_doc="${extra_doc}${v} "
      done <<EOF_DOC
$doc_vals
EOF_DOC
      eq "T10: 散文正本の列挙に語彙外の値が無い" "$extra_doc" ""
    fi
  fi

  # ===========================================================================
  # T11 / T12 / T13 保留ステータス（track=side）と SKILL.md の保留規定の接続
  #
  # 由来: docs/human-hold-representation.md §5（#116）。散文仕様（SKILL.md）には型検査も
  # コンパイラも効かないため、**構造不変条件**（否定検査・語彙駆動・真理値表）で守る。
  #
  # 「保留ステータス」を **track=side の全値**として引く（語彙駆動＝将来 side が増えても
  # 自動で効く）。現在の side は「人間の入力待ちの保留」だけであり、この前提は語彙の正本
  # （contracts/ledger-status-vocabulary.tsv）のコメントに明記してある。**当てはまらない
  # side を足すと、ここが fail-closed で落ちて前提の見直しを促す**（黙って通らない）。
  # ===========================================================================
  canon_side="$(ruby -e '
    rows = File.readlines(ARGV[0], encoding: "UTF-8")
      .reject { |l| l.start_with?("#") || l.strip.empty? }
      .map { |l| l.chomp.split("\t") }
    print rows.select { |r| r[1] == "side" }.map { |r| r[0] }.join("\n")' "$VOCAB_TSV")"

  # 空集合ガード: side が 0 件だと T11〜T13 はすべて空虚に真になる。
  if [ -z "$canon_side" ]; then
    bad "T11/T12/T13: 保留ステータス（track=side）が 1 つ以上ある（空集合ガード）" \
        "side が 0 件のため以下の検査が空虚に真になる"
  else
    ok "T11/T12/T13: 保留ステータス（track=side）が 1 つ以上ある（空集合ガード）"
    printf '%s\n' "$canon_side" > "$tmp/side.txt"

    # -----------------------------------------------------------------------
    # T11 否定検査: 保留ステータスが手順3（実行・委譲）の**対象条件**に現れない。
    #   本 Issue の核心。対象条件に足すと、回答待ちの課題を毎周拾って再委譲する。
    # -----------------------------------------------------------------------
    step3_head="$(grep -m1 '^### 3\. ' "$SKILL_MD")"
    if [ -z "$step3_head" ]; then
      bad "T11: SKILL.md に手順3 の見出し（対象条件）が在る" "^### 3. で始まる行が無い"
    else
      # 空虚に真にならないこと: 対象条件がそもそもステータスを宣言している
      has "T11: 手順3 の対象条件がステータスを宣言している（空虚に真にならないこと）" \
          "$step3_head" "対象: ステータス"
      hit_t11=""
      while IFS= read -r st; do
        [ -n "$st" ] || continue
        case "$step3_head" in *"$st"*) hit_t11="${hit_t11}${st} " ;; esac
      done < "$tmp/side.txt"
      eq "T11: 保留ステータスが手順3 の対象条件に現れない（拾って再委譲しない）" "$hit_t11" ""
    fi

    # T11（対の肯定検査）: 手順3 の本文が「対象ではない」と名指しで除外している。
    # 見出しから語を消しただけで本文に規定が無い状態を「合格」にしないため。
    step3_body="$(awk '/^### 3\. /{f=1} /^### 4\. /{f=0} f' "$SKILL_MD")"
    miss_excl=""
    while IFS= read -r st; do
      [ -n "$st" ] || continue
      case "$step3_body" in
        *"$st"*) ;;
        *) miss_excl="${miss_excl}${st}(未言及) " ; continue ;;
      esac
      case "$step3_body" in
        *対象ではない*) ;;
        *) miss_excl="${miss_excl}${st}(除外規定なし) " ;;
      esac
    done < "$tmp/side.txt"
    eq "T11: 手順3 の本文が保留ステータスを名指しで対象外と規定している" "$miss_excl" ""

    # -----------------------------------------------------------------------
    # T12 語彙駆動: 保留ステータスの経路表の行が index / index-then-full であること。
    #   full にすると未回答の周に台帳本文を毎周開くことになり #122 の削減が打ち消される。
    #   （行の存在そのものは T1 が全ステータスについて固定している）
    # -----------------------------------------------------------------------
    if [ ! -f "$SCOPE_TSV" ]; then
      bad "T12: 経路表 contracts/ledger-read-scope.tsv が在る" "not found: $SCOPE_TSV"
    else
      bad_side_scope=""
      while IFS= read -r st; do
        [ -n "$st" ] || continue
        sc="$(grep "^${st}	" "$SCOPE_TSV" | head -1 | cut -f2)"
        case "$sc" in
          index|index-then-full) ;;
          "") bad_side_scope="${bad_side_scope}${st}=行なし " ;;
          *) bad_side_scope="${bad_side_scope}${st}=${sc} " ;;
        esac
      done < "$tmp/side.txt"
      eq "T12: 保留ステータスの読み込み範囲が index / index-then-full" "$bad_side_scope" ""
    fi

    # -----------------------------------------------------------------------
    # T13 真理値表: (ステータス, 「人間の回答」の非空) → 手順1 が前進させる／させない。
    #   SKILL.md 手順1 の表を機械で読み、意味と突き合わせる。**再保留した周**（前回の回答が
    #   残っていた場合を含む＝保留時にクリアするため空）の行を必ず含めることまで固定する。
    #   この行が落ちると、2 度目の保留で前回の回答のまま前進する退行が戻る（§3.1 (c)）。
    # -----------------------------------------------------------------------
    ruby -e '
      lines = File.readlines(ARGV[0], encoding: "UTF-8").map(&:chomp)
      hi = lines.index { |l| l =~ /\|\s*状況\s*\|\s*ステータス\s*\|/ && l.include?("手順1 の扱い") }
      abort "手順1 の真理値表のヘッダが見つからない" if hi.nil?
      out = []
      ((hi + 1)...lines.size).each do |i|
        l = lines[i].strip
        break unless l.start_with?("|")
        next if l =~ /\A\|[\s\-:|]+\|\z/
        cells = l.split("|").map(&:strip)
        cells.shift if cells.first.to_s.empty?
        next if cells.size < 5
        out << [cells[2].delete("`").strip, cells[3], cells[4], cells[1]].join("\t")
      end
      abort "真理値表のデータ行が 0 件" if out.empty?
      print out.join("\n")' "$SKILL_MD" > "$tmp/truth.tsv" 2>"$tmp/truth_err"
    if [ ! -s "$tmp/truth.tsv" ]; then
      bad "T13: SKILL.md 手順1 の真理値表を機械で読める" "$(cat "$tmp/truth_err")"
    else
      ok "T13: SKILL.md 手順1 の真理値表を機械で読める（$(grep -c . "$tmp/truth.tsv") 行）"

      # 表に造語が混ざらない（語彙駆動の双方向のうち「表 → 正本」の向き）
      bad_truth_st=""
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        tst="$(printf '%s\n' "$row" | cut -f1)"
        printf '%s\n' "$canon" | grep -qx "$tst" || bad_truth_st="${bad_truth_st}${tst} "
      done < "$tmp/truth.tsv"
      eq "T13: 真理値表のステータス語がすべて正本の語彙に在る" "$bad_truth_st" ""

      # 各保留ステータスについて、行の組み合わせと結論を数える
      summary="$(ruby -e '
        side = File.read(ARGV[0], encoding: "UTF-8").split("\n").reject { |x| x.strip.empty? }
        rows = File.read(ARGV[1], encoding: "UTF-8").split("\n").reject { |x| x.strip.empty? }
                   .map { |l| l.split("\t") }
        adv  = ->(v) { v.include?("前進") && !v.include?("前進しない") }
        stay = ->(v) { v.include?("前進しない") }
        print(side.map { |s|
          r = rows.select { |x| x[0] == s }
          [ s,
            r.size,
            r.count { |x| x[1] == "非空" && adv.call(x[2]) },
            r.count { |x| x[1] == "空"   && stay.call(x[2]) },
            r.count { |x| (x[1] == "空" && adv.call(x[2])) || (x[1] == "非空" && stay.call(x[2])) },
            r.count { |x| x[1] == "空" && stay.call(x[2]) && x[3].include?("再保留") },
          ].join("\t")
        }.join("\n"))' "$tmp/side.txt" "$tmp/truth.tsv")"

      while IFS= read -r line; do
        [ -n "$line" ] || continue
        st="$(printf '%s\n' "$line" | cut -f1)"
        n_all="$(printf '%s\n' "$line" | cut -f2)"
        n_adv="$(printf '%s\n' "$line" | cut -f3)"
        n_stay="$(printf '%s\n' "$line" | cut -f4)"
        n_bad="$(printf '%s\n' "$line" | cut -f5)"
        n_re="$(printf '%s\n' "$line" | cut -f6)"
        if [ "$n_all" -ge 1 ]; then ok "T13: ${st} の行が真理値表に在る"
        else bad "T13: ${st} の行が真理値表に在る" "0 行＝この保留ステータスの扱いが未定義"; fi
        if [ "$n_adv" -ge 1 ]; then ok "T13: ${st} ＋ 回答が非空 → 前進する"
        else bad "T13: ${st} ＋ 回答が非空 → 前進する" "該当行が無い（人間が答えても再開しない）"; fi
        if [ "$n_stay" -ge 1 ]; then ok "T13: ${st} ＋ 回答が空 → 前進しない"
        else bad "T13: ${st} ＋ 回答が空 → 前進しない" "該当行が無い（未回答のまま前進しうる）"; fi
        eq "T13: ${st} の真理値表に取り違えの行が無い（空で前進・非空で停止）" "$n_bad" "0"
        if [ "$n_re" -ge 1 ]; then ok "T13: ${st} の再保留した周（回答は必ず空・前進しない）が表に在る"
        else bad "T13: ${st} の再保留した周（回答は必ず空・前進しない）が表に在る" \
                 "該当行が無い＝2 度目の保留で前回の回答が残る退行を表が押さえていない"; fi
      done <<EOF_SUMMARY
$summary
EOF_SUMMARY

      # 表が依存している「保留に入るときのクリア」が規定として在ること。
      # これが落ちると表の前提（再保留の周は回答が空）が成り立たない。
      hold_rule="$(ruby -e '
        lines = File.readlines(ARGV[0], encoding: "UTF-8").map(&:chomp)
        s = lines.index { |l| l =~ /\A\s*-\s\*\*【保留の記録】/ }
        abort "【保留の記録】の規定（箇条書きの定義行）が見つからない" if s.nil?
        e = ((s + 1)...lines.size).find { |i| lines[i] =~ /\A\s*-\s\*\*【/ } || lines.size
        print lines[s...e].join("\n")' "$SKILL_MD" 2>"$tmp/hold_err")"
      if [ -z "$hold_rule" ]; then
        bad "T13: 保留の規定（保留の記録）が SKILL.md に在る" "$(cat "$tmp/hold_err")"
      else
        ok "T13: 保留の規定（保留の記録）が SKILL.md に在る"
        has "T13: 保留の規定が不可分の 1 操作だと明記している" "$hold_rule" "不可分"
        miss_hold=""
        while IFS= read -r st; do
          [ -n "$st" ] || continue
          case "$hold_rule" in *"$st"*) ;; *) miss_hold="${miss_hold}${st} " ;; esac
        done < "$tmp/side.txt"
        eq "T13: 保留の規定が遷移先の保留ステータスを名指ししている" "$miss_hold" ""
        has "T13: 保留の規定が問いの上書きを含む" "$hold_rule" "人間への問い"
        has "T13: 保留の規定が上書きだと明記している" "$hold_rule" "上書き"
        has "T13: 保留の規定が回答欄を名指ししている" "$hold_rule" "人間の回答"
        has "T13: 保留の規定が回答のクリアを含む（これが落ちると再保留で前回の回答が残る）" \
            "$hold_rule" "空にする"
      fi
    fi
  fi
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
