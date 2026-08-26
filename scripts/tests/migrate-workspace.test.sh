#!/usr/bin/env bash
#
# migrate-workspace.test.sh — scripts/migrate-workspace.rb のテスト。
#
# 実行: bash scripts/tests/migrate-workspace.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・/usr/bin/ruby（macOS 標準）。テストフレームワーク不使用。
#   - 書き込みはすべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
# 検査の要（Issue #88）— 台帳は**運用中のライブデータ**であり、機械編集が隣接エントリを
# 巻き添えにした事故の実績がある。固定すべき性質:
#   1. **受理方向**: 旧形式（実測 3 形）を移行するとフォーマット契約のバリデータを通る。
#   2. **非破壊（無言消失をしない）**: 削除は**既知テンプレート由来と証明できる行だけ**。
#      人間が書いた行・別セクション・注意書きが 1 行でも混じる範囲には手を出さず報告する。
#   3. **承認の保全**: 既存のチェック行が正規形でなくても、未チェック行を足して `[x]` を
#      実質無効化しない（判定不能なら承認欄に触れず報告する）。
#   4. **部分適用も残骸も残さない**: 検算が落ちたらワークスペースに一時ファイルを残さない。
#   5. **冪等・dry-run**: 2 回目は差分ゼロ。dry-run は 1 バイトも書かず、かつ `--apply` と
#      同じ検算（バリデータ前後比較）を通っていることを示す。
#   6. **検算が本当に効く**: 変換後の出力に故障を注入すると検算が止める（タウトロジーでない
#      ことを変異注入で示す。復元は cp バックアップから行い、`git checkout --` は使わない）。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/migrate-workspace.rb"
VALIDATOR="$REPO_ROOT/scripts/validate-artifact.rb"
FIXTURES="$TESTS_DIR/fixtures/migrate"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ $# -gt 1 ] && echo "       $2"; }

# assert_exit <名前> <期待exit> -- <migrate-workspace.rb の引数...>
assert_exit() {
  name="$1"; want="$2"; shift 2
  [ "$1" = "--" ] && shift
  out="$(/usr/bin/ruby "$SCRIPT" "$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass "$name"
  else
    fail "$name (exit: got=$got want=$want)" "$out"
  fi
}

# assert_out <名前> <期待部分文字列> -- <引数...>
assert_out() {
  name="$1"; want="$2"; shift 2
  [ "$1" = "--" ] && shift
  out="$(/usr/bin/ruby "$SCRIPT" "$@" 2>&1)"
  case "$out" in
    *"$want"*) pass "$name" ;;
    *) fail "$name" "期待した文言が出ない: ${want}" ;;
  esac
}

# assert_no_out <名前> <出てはいけない部分文字列> -- <引数...>
assert_no_out() {
  name="$1"; bad="$2"; shift 2
  [ "$1" = "--" ] && shift
  out="$(/usr/bin/ruby "$SCRIPT" "$@" 2>&1)"
  case "$out" in
    *"$bad"*) fail "$name" "出てはいけない文言が出た: ${bad}" ;;
    *) pass "$name" ;;
  esac
}

# assert_validator <名前> <type> <file> <期待exit>
assert_validator() {
  name="$1"; type="$2"; file="$3"; want="$4"
  out="$(/usr/bin/ruby "$VALIDATOR" "$type" "$file" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass "$name"
  else
    fail "$name (validator exit: got=$got want=$want)" "$out"
  fi
}

# assert_grep_count <名前> <パターン> <ファイル> <期待件数>
assert_grep_count() {
  name="$1"; pat="$2"; file="$3"; want="$4"
  got="$(grep -c "$pat" "$file" 2>/dev/null || true)"
  got="$(printf '%s' "$got" | tr -d ' ')"
  if [ "$got" = "$want" ]; then
    pass "$name"
  else
    fail "$name" "件数が違う: got=${got} want=${want}（パターン: ${pat}）"
  fi
}

# assert_has <名前> <パターン> <ファイル>
assert_has() {
  if grep -q "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1" "見つからない: $2"; fi
}

# assert_same <名前> <fileA> <fileB>
assert_same() {
  if cmp -s "$2" "$3"; then pass "$1"; else fail "$1" "$(diff "$2" "$3" | head -8)"; fi
}

# assert_no_deletions <名前> <移行前ファイル> <移行後ファイル> [<消えてよい行のパターン>]
# 「移行前にあって移行後に無い**非空行**」を検出する（無言消失の検査）。
assert_no_deletions() {
  name="$1"; before="$2"; after="$3"; allow="${4:-}"
  gone="$(diff "$before" "$after" | grep '^<' | sed 's/^< //' | grep -v '^[[:space:]]*$' || true)"
  [ -n "$allow" ] && gone="$(printf '%s\n' "$gone" | grep -v "$allow" || true)"
  gone="$(printf '%s' "$gone" | grep -v '^$' || true)"
  if [ -z "$gone" ]; then
    pass "$name"
  else
    fail "$name" "消えた行: $(printf '%s' "$gone" | head -4 | tr '\n' '|')"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ワークスペースを組み立てる: mkws <名前> [<台帳フィクスチャ>] [<アーカイブフィクスチャ>]
mkws() {
  ws="$tmp/$1"
  rm -rf "$ws"
  mkdir -p "$ws"
  [ $# -ge 2 ] && [ -n "$2" ] && cp "$FIXTURES/$2" "$ws/challenge-ledger.md"
  [ $# -ge 3 ] && [ -n "$3" ] && cp "$FIXTURES/$3" "$ws/challenge-archive.md"
  echo "$ws"
}

# ---------------------------------------------------------------------------
# 1. dry-run（既定）は 1 バイトも書かない／検算も済ませている
# ---------------------------------------------------------------------------

ws="$(mkws dryrun legacy-bold-heading-ledger.md legacy-missing-fields-archive.md)"
cp "$ws/challenge-ledger.md" "$tmp/dryrun-ledger.orig"
cp "$ws/challenge-archive.md" "$tmp/dryrun-archive.orig"
assert_exit "dry-run（要移行）は exit 3" 3 -- --workspace "$ws"
assert_same "dry-run は台帳を書き換えない" "$tmp/dryrun-ledger.orig" "$ws/challenge-ledger.md"
assert_same "dry-run はアーカイブを書き換えない" "$tmp/dryrun-archive.orig" "$ws/challenge-archive.md"
assert_out "dry-run は適用方法を案内する" "--apply を付けて再実行" -- --workspace "$ws"
assert_out "dry-run でもバリデータ前後比較の結果を提示する" "検算（バリデータの前後比較・dry-run でも実行）" -- --workspace "$ws"
if [ -e "$ws/challenge-ledger.md.migrate-tmp" ]; then
  fail "dry-run は一時ファイルを作らない"
else
  pass "dry-run は一時ファイルを作らない"
fi

# ---------------------------------------------------------------------------
# 2. 受理方向: 旧形式（太字見出しブロック形）を移行するとバリデータを通る
# ---------------------------------------------------------------------------

ws="$(mkws bold legacy-bold-heading-ledger.md legacy-missing-fields-archive.md)"
assert_validator "移行前: 旧テンプレート台帳はバリデータ違反" ledger "$ws/challenge-ledger.md" 1
assert_validator "移行前: 旧テンプレートアーカイブはバリデータ違反" archive "$ws/challenge-archive.md" 1
assert_exit "--apply は exit 0" 0 -- --workspace "$ws" --apply --backup-dir "$tmp/backup-bold"
assert_validator "移行後: 台帳がバリデータを通る" ledger "$ws/challenge-ledger.md" 0
assert_validator "移行後: アーカイブがバリデータを通る" archive "$ws/challenge-archive.md" 0

# 非破壊: 承認チェック・備考・取り込み元マーカー・タスク案本文の保存
assert_grep_count "承認済みチェックの [x] が保存される" '^  - \[x\] 計画を承認' "$ws/challenge-ledger.md" 1
assert_grep_count "移行がチェックを捏造しない（チェック済み行は移行前と同数の 1 行）" '^  - \[x\]' "$ws/challenge-ledger.md" 1
assert_has "備考の本文が保存される" '承認済みチェックと取り込み元マーカーは移行で失われてはならない' "$ws/challenge-ledger.md"
assert_has "取り込み元マーカーが原文のまま残る" 'shared-repo / issue-70（取り込み: 2026-07-27）<!-- fp:b3bed2c644e5 -->' "$ws/challenge-ledger.md"
assert_has "タスク案の本文が 2 スペースのネスト項目として保存される" '^  1\. 子セッションへ委譲して実装する' "$ws/challenge-ledger.md"
assert_has "タスク案の 3 項目目も保存される" '^  3\. 既定ブランチへの昇格マージは FR-22' "$ws/challenge-ledger.md"
assert_grep_count "旧形式の太字見出しブロックは残らない" '^\*\*タスク案' "$ws/challenge-ledger.md" 0
assert_has "旧見出しの文言は HTML コメントとして保全される" '<!-- 移行前の記載（#88）: \*\*タスク案（FR-13・承認済み 2026-07-27 対話承認）\*\* -->' "$ws/challenge-ledger.md"
assert_has "旧ラベルの承認行が現行ラベルへ改名される" '^- 承認（人間がチェック）:' "$ws/challenge-ledger.md"

# 台帳には参照フィールドを補うが、アーカイブ（原文保存の履歴）には補わない
assert_grep_count "台帳に参照フィールド行を補う（記入例 1 + エントリ 2）" '^- 関連リポジトリ:' "$ws/challenge-ledger.md" 3
assert_grep_count "アーカイブには参照フィールドを補わない" '^- 関連リポジトリ:' "$ws/challenge-archive.md" 0

# 承認を機械が代筆しないことの報告
ws2="$(mkws bold2 legacy-bold-heading-ledger.md)"
assert_out "承認を捏造せず人間判断として報告する" "承認チェックボックスを**未チェックで新設**した" -- --workspace "$ws2"

# ---------------------------------------------------------------------------
# 3. 冪等: 2 回目の実行は差分ゼロ
# ---------------------------------------------------------------------------

cp "$ws/challenge-ledger.md" "$tmp/idem-ledger.once"
cp "$ws/challenge-archive.md" "$tmp/idem-archive.once"
assert_exit "2 回目の dry-run は exit 0（変更なし）" 0 -- --workspace "$ws"
assert_out "2 回目は追従済みと報告する" "変更はありません" -- --workspace "$ws"
assert_exit "2 回目の --apply も exit 0" 0 -- --workspace "$ws" --apply
assert_same "2 回目でも台帳はバイト一致（冪等）" "$tmp/idem-ledger.once" "$ws/challenge-ledger.md"
assert_same "2 回目でもアーカイブはバイト一致（冪等）" "$tmp/idem-archive.once" "$ws/challenge-archive.md"

# ---------------------------------------------------------------------------
# 4. バックアップ（変更前の原本が残る／世代を失わない）
# ---------------------------------------------------------------------------

assert_same "バックアップは移行前の台帳と一致する" "$FIXTURES/legacy-bold-heading-ledger.md" "$tmp/backup-bold/challenge-ledger.md"
assert_same "バックアップは移行前のアーカイブと一致する" "$FIXTURES/legacy-missing-fields-archive.md" "$tmp/backup-bold/challenge-archive.md"

ws="$(mkws backupclash legacy-bold-heading-ledger.md)"
cp "$ws/challenge-ledger.md" "$tmp/backupclash.orig"
mkdir -p "$tmp/backup-clash"
: > "$tmp/backup-clash/challenge-ledger.md"
assert_exit "バックアップ先に同名ファイルがあれば失敗する（世代を上書きしない）" 1 -- --workspace "$ws" --apply --backup-dir "$tmp/backup-clash"
assert_same "バックアップ衝突時は台帳を書き換えない" "$tmp/backupclash.orig" "$ws/challenge-ledger.md"

# ---------------------------------------------------------------------------
# 5. 記入例フェンス形（旧テンプレートのまま）は現行化される
# ---------------------------------------------------------------------------

ws="$(mkws fenced legacy-fenced-example-ledger.md)"
cp "$ws/challenge-ledger.md" "$tmp/fenced.orig"
assert_exit "フェンス形の旧記入例を持つ台帳を移行できる" 0 -- --workspace "$ws" --apply --backup-dir "$tmp/backup-fenced"
assert_validator "移行後もバリデータを通る" ledger "$ws/challenge-ledger.md" 0
assert_has "現行の記入例（承認対象＝タスク案）へ差し替わる" '計画を承認（FR-13・承認対象＝タスク案）' "$ws/challenge-ledger.md"
assert_has "エントリのタスク案本文は変わらない" '^- タスク案: 規定を確定してから実装する' "$ws/challenge-ledger.md"
assert_grep_count "エントリの承認チェックは変わらない" '^  - \[x\] 計画を承認（FR-13）$' "$ws/challenge-ledger.md" 1
assert_no_deletions "旧テンプレート由来の行以外は 1 行も消えない" "$tmp/fenced.orig" "$ws/challenge-ledger.md" \
  '^\(- 完了条件（任意）: <こうなれば完了>\|- タスク案: （run-cycle の計画ステップが記入）\|  - \[ \] 計画を承認（FR-13）\)$'

# ---------------------------------------------------------------------------
# 6. **無言消失をしない**: 人間が書いた行を含む範囲には手を出さない
# ---------------------------------------------------------------------------

# (a) 記入例の直後に人間が書いた別セクションがある（見出しの前方一致で巻き込んだ欠陥）
ws="$(mkws humansection human-section-ledger.md)"
cp "$ws/challenge-ledger.md" "$tmp/humansection.orig"
assert_exit "人間のセクションがある台帳も移行できる" 0 -- --workspace "$ws" --apply
assert_has "人間が書いたセクション見出しが残る" '^## 記入例の運用メモ' "$ws/challenge-ledger.md"
assert_has "人間が書いた本文が残る（1）" '起票は共有ソースに書くこと' "$ws/challenge-ledger.md"
assert_has "人間が書いた本文が残る（2）" '台帳の編集規律はプラグインの docs を読むこと' "$ws/challenge-ledger.md"
assert_has "記入例そのものは現行化される" '計画を承認（FR-13・承認対象＝タスク案）' "$ws/challenge-ledger.md"
ws3="$(mkws humansection2 human-section-ledger.md)"
assert_no_out "人間のセクションを記入例の一部と誤認しない" "既知テンプレートに無い行が" -- --workspace "$ws3"
assert_no_deletions "既知テンプレート由来の行以外は 1 行も消えない" "$tmp/humansection.orig" "$ws/challenge-ledger.md" \
  '^\(- 完了条件（任意）: <こうなれば完了>\|- タスク案: （run-cycle の計画ステップが記入）\|  - \[ \] 計画を承認（FR-13）\)$'

# (b) 記入例ブロック自体に人間が書き足した行がある（実測: 運用注意コメント＋独自フェンス）
ws="$(mkws humanexample legacy-nested-list-ledger.md)"
cp "$ws/challenge-ledger.md" "$tmp/humanexample.orig"
assert_out "記入例に未知の行があれば現行化せず報告する" "既知テンプレートに無い行が" -- --workspace "$ws"
assert_exit "その場合もエントリ側の移行は進む" 0 -- --workspace "$ws" --apply
assert_has "人間が書いた注意書きが残る" 'ゴーストカードが出る' "$ws/challenge-ledger.md"
assert_no_deletions "記入例に手を出さない（1 行も消えない）" "$tmp/humanexample.orig" "$ws/challenge-ledger.md"
assert_has "エントリ側の参照フィールドは補われる" '^- 関連リポジトリ:' "$ws/challenge-ledger.md"

# (c) 記入例コメントの閉じ忘れで実エントリを飲み込む範囲
ws="$(mkws broken broken-example-comment-ledger.md)"
cp "$ws/challenge-ledger.md" "$tmp/broken.orig"
assert_out "閉じ忘れの記入例範囲は人間判断として報告する" "実エントリらしい行があるため" -- --workspace "$ws"
/usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply >/dev/null 2>&1
assert_same "閉じ忘れの台帳は 1 行も書き換えない" "$tmp/broken.orig" "$ws/challenge-ledger.md"

# ---------------------------------------------------------------------------
# 7. すでに現行構造を満たすエントリは 1 行も変えない
# ---------------------------------------------------------------------------

ws="$(mkws untouched "" legacy-missing-fields-archive.md)"
/usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply >/dev/null 2>&1
if grep -A9 '^### \[C-403\]' "$ws/challenge-archive.md" | grep -q '^- 担当ポジション: harness'; then
  pass "現行構造のエントリ（C-403）は保持される"
else
  fail "現行構造のエントリ（C-403）は保持される"
fi
assert_grep_count "現行構造のエントリに承認行を重複させない" '^- 承認（人間がチェック）:' "$ws/challenge-archive.md" 3
assert_has "引用行（外部本文の転記）は触らない" '^> 外部 Issue の本文をブロック引用で転記した説明。' "$ws/challenge-archive.md"

# ---------------------------------------------------------------------------
# 8. テンプレート自体が移行の不動点である／既知集合がテンプレートに追随している
# ---------------------------------------------------------------------------

ws="$(mkws template)"
cp "$REPO_ROOT/templates/challenge-ledger.md" "$ws/challenge-ledger.md"
assert_exit "テンプレートは移行の不動点（exit 0）" 0 -- --workspace "$ws"
assert_out "テンプレートは追従済みと報告される" "変更はありません" -- --workspace "$ws"

# 現行テンプレートの記入例が、そのまま「既知テンプレート由来」として扱えること。
# （テンプレートを更新したときに DATA への追記を忘れると、次のテンプレート更新時に
#   旧行が未知になって移行が止まる。ここで気付けるようにする）
ws="$(mkws knownset)"
cp "$REPO_ROOT/templates/challenge-ledger.md" "$ws/challenge-ledger.md"
printf '\n### [C-999] ダミー\n\n**人間記入欄**\n- 起票者 / 起票日: x / 2026-08-01\n- 説明: x\n\n**分類欄（エージェントが記入）**\n- 担当ポジション: harness\n- 優先度: P1\n- ステータス: 分類済\n- タスク案:\n- 承認（人間がチェック）:\n  - [ ] 計画を承認（FR-13・承認対象＝タスク案）\n  - [ ] 完了を承認（FR-32）\n- 備考:\n' >> "$ws/challenge-ledger.md"
assert_no_out "現行テンプレートの記入例が未知行として弾かれない" "既知テンプレートに無い行が" -- --workspace "$ws"

# ---------------------------------------------------------------------------
# 9. 形 E の変換は**全項目を尽くす**（部分変換を成功と報告しない）
# ---------------------------------------------------------------------------

ws="$(mkws stray "" task-plan-stray-archive.md)"
cp "$ws/challenge-archive.md" "$tmp/stray.orig"
assert_exit "項目の途中に空行があるブロックも移行できる" 0 -- --workspace "$ws" --apply
assert_has "空行を挟んだ 1 項目目が保存される" '^  1\. 一つ目のタスク' "$ws/challenge-archive.md"
assert_has "空行を挟んだ 2 項目目が保存される" '^  2\. 二つ目のタスク（空行のあとに続く）' "$ws/challenge-archive.md"
assert_has "空行を挟んだ 3 項目目が保存される" '^  3\. 三つ目のタスク' "$ws/challenge-archive.md"
assert_grep_count "取り残された孤児の番号行が無い" '^[0-9]\+\. ' "$ws/challenge-archive.md" 2
assert_has "注記行が続くブロックは変換されず注記も残る" '^※ 補足: この注記はタスクではない' "$ws/challenge-archive.md"
assert_has "変換しなかったブロックの見出しも残る" '^\*\*タスク案（FR-13・承認済み 2026-08-01）\*\*' "$ws/challenge-archive.md"
assert_no_deletions "変換できないブロックの行は 1 行も消えない" "$tmp/stray.orig" "$ws/challenge-archive.md" \
  '^\(\*\*タスク案（FR-13・承認済み 2026-08-01）\*\*\|1\. 一つ目のタスク\|2\. 二つ目のタスク（空行のあとに続く）\|3\. 三つ目のタスク\)$'

ws="$(mkws stray2 "" task-plan-stray-archive.md)"
assert_out "変換しない理由を人間判断として報告する" "どこまでがタスク案か機械では決められないため" -- --workspace "$ws"

# 記入例の残骸が続くエントリも同様（部分変換しない）
ws="$(mkws remnant "" legacy-example-remnant-archive.md)"
assert_out "備考行の重複を人間判断として報告する" "「備考」行が 2 回出現している" -- --workspace "$ws"
assert_exit "残骸があっても他のエントリは移行できる" 0 -- --workspace "$ws" --apply
assert_has "残骸を挟まないエントリのタスク案は変換される" '^  1\. 足場を生成する' "$ws/challenge-archive.md"
assert_has "残骸が続くエントリのタスク案は変換しない（原文のまま）" '^1\. 子セッションへ委譲して実装する' "$ws/challenge-archive.md"

# ---------------------------------------------------------------------------
# 10. 承認の保全: 正規形でないチェック行があるエントリには手を出さない
# ---------------------------------------------------------------------------

ws="$(mkws approval "" approval-nonstandard-archive.md)"
cp "$ws/challenge-archive.md" "$tmp/approval.orig"
assert_out "4 スペースのチェック行を検出して報告する" "「計画を承認」のチェック行が正規形" -- --workspace "$ws"
assert_out "承認欄に手を出さない旨を報告する" "**承認欄には一切手を出さない**" -- --workspace "$ws"
/usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply >/dev/null 2>&1
assert_same "正規形でないチェック行があるエントリは 1 行も変えない" "$tmp/approval.orig" "$ws/challenge-archive.md"
assert_grep_count "未チェック行を足さない（[ ] 計画を承認 は 0 行）" '\[ \] 計画を承認' "$ws/challenge-archive.md" 0
assert_grep_count "既存のチェック済み行がそのまま残る" '^ *- \[x\] ' "$ws/challenge-archive.md" 4

# ---------------------------------------------------------------------------
# 11. 人間記入欄は位置に関係なく触らない（分類欄が先・人間記入欄が後）
# ---------------------------------------------------------------------------

ws="$(mkws classifyfirst "" classify-first-archive.md)"
cp "$ws/challenge-archive.md" "$tmp/classifyfirst.orig"
assert_exit "分類欄が先の構成でも移行できる" 0 -- --workspace "$ws" --apply
assert_has "人間記入欄の自由記述（- 承認: …）が原文のまま残る" '^- 承認: 2026-07-01 に口頭で承認済み（人間の自由記述であって承認チェックではない）$' "$ws/challenge-archive.md"
assert_grep_count "人間記入欄にチェックボックスを注入しない" '^  - \[ \] 計画を承認' "$ws/challenge-archive.md" 1
if grep -A4 '^\*\*分類欄' "$ws/challenge-archive.md" | grep -q '^- 承認（人間がチェック）:'; then
  pass "承認欄は分類欄の側へ追加される"
else
  # 分類欄ブロック内（担当ポジション〜備考の連続並び）に入っていればよい
  if awk '/^\*\*分類欄/{f=1} /^\*\*人間記入欄/{f=0} f && /^- 承認（人間がチェック）:/{found=1} END{exit !found}' "$ws/challenge-archive.md"; then
    pass "承認欄は分類欄の側へ追加される"
  else
    fail "承認欄は分類欄の側へ追加される"
  fi
fi

# 記入例の残骸がエントリ末尾にあっても、挿入は分類欄の並びの中に入る
ws="$(mkws insertpos "" legacy-example-remnant-archive.md)"
/usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply >/dev/null 2>&1
if awk '/^### \[C-502\]/{e=1} e && /^\*\*分類欄/{f=1} e && /^$/{f=0} f && /^- 承認（人間がチェック）:/{found=1} END{exit !found}' "$ws/challenge-archive.md"; then
  pass "残骸があっても承認欄は分類欄の連続並びの中へ挿入される"
else
  fail "残骸があっても承認欄は分類欄の連続並びの中へ挿入される"
fi

# ---------------------------------------------------------------------------
# 12. 改行コード: CRLF は保存し、混在ファイルには手を出さない
# ---------------------------------------------------------------------------

ws="$(mkws crlf)"
/usr/bin/ruby -e 'File.write(ARGV[1], File.read(ARGV[0], encoding: "UTF-8").gsub("\n", "\r\n"))' \
  "$FIXTURES/legacy-bold-heading-ledger.md" "$ws/challenge-ledger.md"
assert_exit "CRLF の台帳を移行できる" 0 -- --workspace "$ws" --apply
if /usr/bin/ruby -e 'l = File.read(ARGV[0], encoding: "UTF-8").split("\n", -1); l.pop if l.last == ""; exit(l.all? { |x| x.end_with?("\r") } ? 0 : 1)' "$ws/challenge-ledger.md"; then
  pass "CRLF が全行で保存される（改行コードを混ぜない）"
else
  fail "CRLF が全行で保存される（改行コードを混ぜない）"
fi
assert_exit "CRLF ファイルでも 2 回目は変更なし（冪等）" 0 -- --workspace "$ws"

ws="$(mkws mixedeol)"
/usr/bin/ruby -e 'l = File.read(ARGV[0], encoding: "UTF-8").split("\n", -1); l = l.each_with_index.map { |x, i| i.even? ? x + "\r" : x }; File.write(ARGV[1], l.join("\n"))' \
  "$FIXTURES/legacy-bold-heading-ledger.md" "$ws/challenge-ledger.md"
cp "$ws/challenge-ledger.md" "$tmp/mixedeol.orig"
assert_out "改行コード混在は理由を添えて報告する" "改行コードが CRLF と LF で混在している" -- --workspace "$ws"
/usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply >/dev/null 2>&1
assert_same "改行コード混在のファイルは 1 バイトも書き換えない" "$tmp/mixedeol.orig" "$ws/challenge-ledger.md"

# ---------------------------------------------------------------------------
# 13. 変異注入: 検算が本当に止める（タウトロジーでないことの確認）
# ---------------------------------------------------------------------------

for fault in drop-note uncheck-approval drop-entry drop-preamble-line steal-human-line move-blank-into-nest; do
  ws="$(mkws "fault-$fault" legacy-bold-heading-ledger.md)"
  cp "$ws/challenge-ledger.md" "$tmp/fault.orig"
  out="$(MIGRATE_WORKSPACE_INJECT_FAULT="$fault" /usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply 2>&1)"
  got=$?
  # bash 3.2 は全角文字直前の変数展開でブレース必須（${fault}）
  if [ "$got" -eq 1 ]; then
    pass "変異注入（${fault}）を検算が検出して失敗する"
  else
    fail "変異注入（${fault}）を検算が検出して失敗する (exit: got=$got want=1)" "$out"
  fi
  assert_same "変異注入（${fault}）で部分適用を残さない" "$tmp/fault.orig" "$ws/challenge-ledger.md"
  if [ -e "$ws/challenge-ledger.md.migrate-tmp" ] || [ -e "$ws/.flywheel/migration-backup" ]; then
    fail "変異注入（${fault}）は一時ファイル・バックアップを残さない" "$(ls -a "$ws")"
  else
    pass "変異注入（${fault}）は一時ファイル・バックアップを残さない"
  fi
  # dry-run でも同じ検算に掛かる（「dry-run は通ったのに --apply で失敗」を無くす）
  ws2="$(mkws "faultdry-$fault" legacy-bold-heading-ledger.md)"
  MIGRATE_WORKSPACE_INJECT_FAULT="$fault" /usr/bin/ruby "$SCRIPT" --workspace "$ws2" >/dev/null 2>&1
  if [ $? -eq 1 ]; then
    pass "変異注入（${fault}）は dry-run でも検出される"
  else
    fail "変異注入（${fault}）は dry-run でも検出される"
  fi
  rm -f "$tmp/fault.orig"
done

# 置換の直前で中断しても、ワークスペースに一時ファイルを残さない
ws="$(mkws stageleak legacy-bold-heading-ledger.md legacy-missing-fields-archive.md)"
cp "$ws/challenge-ledger.md" "$tmp/stageleak.orig"
export MIGRATE_WORKSPACE_INJECT_FAULT=fail-after-stage
assert_exit "置換直前の中断は exit 1" 1 -- --workspace "$ws" --apply --backup-dir "$tmp/backup-stageleak"
unset MIGRATE_WORKSPACE_INJECT_FAULT
assert_same "置換直前に中断しても元ファイルは無傷" "$tmp/stageleak.orig" "$ws/challenge-ledger.md"
if ls "$ws"/*.migrate-tmp >/dev/null 2>&1; then
  fail "置換直前に中断しても一時ファイルを残さない" "$(ls "$ws")"
else
  pass "置換直前に中断しても一時ファイルを残さない"
fi

# 違反の前後比較は**多重集合**（同一文言の違反が増えたことを見逃さない）。
# この台帳は移行前から同じ文言の違反を 1 件持つため、集合の差では増加が見えない。
ws="$(mkws multiset duplicate-violation-ledger.md)"
cp "$ws/challenge-ledger.md" "$tmp/multiset.orig"
assert_exit "同一文言の違反が既にある台帳も通常は移行できる" 3 -- --workspace "$ws"
export MIGRATE_WORKSPACE_INJECT_FAULT=move-blank-into-nest
assert_exit "同一文言の違反が 1 件増える変異を検出する" 1 -- --workspace "$ws" --apply
assert_out "増えた違反を件数つきで報告する" "移行後に増えた違反（×1）" -- --workspace "$ws"
unset MIGRATE_WORKSPACE_INJECT_FAULT
assert_same "その場合も台帳を書き換えない" "$tmp/multiset.orig" "$ws/challenge-ledger.md"

# ---------------------------------------------------------------------------
# 14. scaffold 追従レポート（検出のみ・書き換えない）
# ---------------------------------------------------------------------------

ws="$(mkws scaffold)"
mkdir -p "$ws/.claude" "$ws/container"
printf '%s\n' '.flywheel/' > "$ws/.gitignore"
printf '%s\n' '{"permissions":{"allow":[]}}' > "$ws/.claude/settings.json"
printf '%s\n' 'FROM debian:stable-slim' > "$ws/container/Dockerfile"
cp "$ws/.gitignore" "$tmp/scaffold-gitignore.orig"
assert_out "旧形式の .gitignore を検出する" '（ディレクトリ丸ごと ignore）が残っている' -- --workspace "$ws"
assert_out "cadence.json の unignore 欠落を検出する" 'cadence.json は運用設定として Git 追跡する' -- --workspace "$ws"
assert_out "container/.env の ignore 欠落を検出する" 'ホスト固有のため追跡しない' -- --workspace "$ws"
assert_out "移行一時ファイルの ignore 欠落を検出する" '移行の一時ファイルが万一残っても' -- --workspace "$ws"
assert_out "settings.json の allow 欠落を検出する" 'の allow が無い（自走委譲が分類器でブロックされる）' -- --workspace "$ws"
assert_out "Dockerfile の ruby 未導入を検出する" 'ruby を導入していない' -- --workspace "$ws"
assert_out "不足している scaffold 物を検出する" '不足: CLAUDE.md' -- --workspace "$ws"
/usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply >/dev/null 2>&1
assert_same "scaffold 追従レポートは検出のみで書き換えない" "$tmp/scaffold-gitignore.orig" "$ws/.gitignore"

# 意思決定の主体（#107）: 旧 1 軸の CLAUDE.md ・§接続ツールの無いポジションを検出する
ws="$(mkws decision)"
mkdir -p "$ws/positions"
printf '%s\n' '## 意思決定の主体（課題のスコープで所在が分岐する）' '- 単一 repo 完結の課題（子が意思決定者）' > "$ws/CLAUDE.md"
printf '%s\n' '# ポジション: sample' '## 4. 権限（Human-in-the-loop）' > "$ws/positions/sample.md"
cp "$ws/CLAUDE.md" "$tmp/decision-claude.orig"
cp "$ws/positions/sample.md" "$tmp/decision-position.orig"
assert_out "旧 1 軸の CLAUDE.md を検出する" '§意思決定の主体が旧 1 軸' -- --workspace "$ws"
assert_out "§接続ツールの無いポジションを検出する" '対話前提スキルの対話相手が未宣言' -- --workspace "$ws"
/usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply >/dev/null 2>&1
assert_same "旧 1 軸の CLAUDE.md を書き換えない（検出のみ）" "$tmp/decision-claude.orig" "$ws/CLAUDE.md"
assert_same "ポジションを書き換えない（検出のみ）" "$tmp/decision-position.orig" "$ws/positions/sample.md"

# 2 軸へ追従済み・§接続ツールを持つポジションでは報告しない（誤検出しない）
ws="$(mkws decisionok)"
mkdir -p "$ws/positions"
cp "$REPO_ROOT/templates/CLAUDE.md" "$ws/CLAUDE.md"
cp "$REPO_ROOT/templates/position.md" "$ws/positions/sample.md"
assert_no_out "2 軸へ追従済みの CLAUDE.md は報告しない" '§意思決定の主体が旧 1 軸' -- --workspace "$ws"
assert_no_out "§接続ツールを持つポジションは報告しない" '対話前提スキルの対話相手が未宣言' -- --workspace "$ws"
assert_no_out "テンプレート準拠のポジションは宣言項目の欠落を報告しない" '§接続ツールに宣言項目が無い' -- --workspace "$ws"

# 偽陰性の回帰: 判定は**節単位**で行う。無関係な本文に語が出るだけでは警告を抑制させない
# （文書全体の部分一致だと、旧 1 軸のまま・宣言項目なしのワークスペースが「追従済み」に化ける）。
ws="$(mkws decisionfalseneg)"
mkdir -p "$ws/positions"
printf '%s\n' \
  '# ベースライン' \
  '' \
  '## 用語メモ' \
  '' \
  '- 「スキルの性質」という言い回しをここで使っている（意思決定の主体の節とは無関係）。' \
  '' \
  '## 意思決定の主体（課題のスコープで所在が分岐する）' \
  '' \
  '- 単一 repo 完結の課題（子が意思決定者）' > "$ws/CLAUDE.md"
printf '%s\n' \
  '# ポジション: sample' \
  '' \
  '## 4. 権限（Human-in-the-loop）' \
  '' \
  '- 実作業は接続ツールへ委譲する（見出しではなく本文中の言及）。' > "$ws/positions/sample.md"
assert_out "節の外の「スキルの性質」では旧 1 軸の CLAUDE.md を見逃さない" '§意思決定の主体が旧 1 軸' -- --workspace "$ws"
assert_out "本文中の「接続ツール」では §接続ツールの欠落を見逃さない" '対話前提スキルの対話相手が未宣言' -- --workspace "$ws"

# §接続ツールの見出しはあっても、宣言項目が欠けていれば未宣言として報告する
ws="$(mkws decisionitems)"
mkdir -p "$ws/positions"
printf '%s\n' \
  '# ポジション: sample' \
  '' \
  '## 5. 接続ツール（実作業の委譲先）' \
  '' \
  '- **開発フロー（接続ツール）**: `claude-harness`' \
  '' \
  '## 6. 関係' \
  '' \
  '- **対話前提スキルの対話相手**: この節は §接続ツールの外なので宣言として数えない。' > "$ws/positions/sample.md"
assert_out "§接続ツールの宣言項目の欠落を検出する" '§接続ツールに宣言項目が無い' -- --workspace "$ws"
assert_out "欠落している宣言項目を名指しで報告する" '欠けている宣言項目: 対話前提スキルの対話相手' -- --workspace "$ws"

ws="$(mkws docdrift)"
mkdir -p "$ws/runtime"
printf '%s\n' '# 旧い runtime/README.md' > "$ws/runtime/README.md"
assert_out "ドキュメント類のテンプレート差分を検出する" 'テンプレートと差分あり: runtime/README.md' -- --workspace "$ws"

# ---------------------------------------------------------------------------
# 15. 検査不能（exit 2）: 引数不正・対象不在を「変更なし」にも「失敗」にも丸めない
# ---------------------------------------------------------------------------

assert_exit "存在しないワークスペースは exit 2" 2 -- --workspace "$tmp/no-such-dir"
assert_exit "存在しないテンプレートディレクトリは exit 2" 2 -- --workspace "$tmp" --templates-dir "$tmp/no-such-templates"
assert_exit "不明なオプションは exit 2" 2 -- --workspace "$tmp" --bogus
assert_exit "--workspace に値が無いと exit 2" 2 -- --workspace
assert_exit "--backup-dir に値が無いと exit 2" 2 -- --workspace "$tmp" --backup-dir

ws="$(mkws empty)"
assert_exit "台帳が無いワークスペースは exit 0" 0 -- --workspace "$ws"
assert_out "台帳が無いことを報告する" "初回 scaffold が必要" -- --workspace "$ws"

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
