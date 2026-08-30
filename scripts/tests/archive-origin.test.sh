#!/usr/bin/env bash
#
# archive-origin.test.sh — アーカイブ移動時の「原文の焼き込み」（run-cycle 手順4）の契約テスト。
# 規範の正本は skills/run-cycle/SKILL.md 手順4「原文の焼き込み」、形式の正本は
# docs/challenge-ledger-format.md §アーカイブ「原文のままの唯一の例外」（Issue #130 タスク3）。
#
# 実行: bash scripts/tests/archive-origin.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・/usr/bin/ruby（macOS 標準）。フレームワーク不使用。
#   - 書き込みはすべて mktemp の一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
# 検査の要:
#   - **散文の契約が消えたら落ちる**: 焼き込みは実装コードを持たない散文規定であり、
#     行を消しても他のどのテストも落ちない。定型文字列（追記の先頭行）を SKILL.md と
#     形式ドキュメントの**両方**に要求し、両者が同じ文字列を使っていることを固定する
#     （2 箇所に同じ規約を書いたまま片方だけ直る、を止める）。
#   - **異常系の出力契約を検査する**: 正常系（取得成功）だけを検査すると、取得失敗時に
#     何を書くか未定義のまま緑になる（散文仕様の空虚な真）。失敗時の 3 要素——移動を
#     実行する／失敗行を追記する／レポートへ個別に列挙する——の存在と、fail-closed 語彙の
#     **不在**（否定検査）を両方見る。
#   - **受理方向を実ファイルで固定する**: 成功形・失敗形の 2 形が実際に
#     scripts/validate-artifact.rb の archive 検査を通ることを、生成した実ファイルで確かめる。
#     「規定はあるがバリデータが弾く」という食い違いを出荷しない。
#   - **消費側の読み取り結果まで見る**: 追記が引用行として説明欄の値に結合され、かつ
#     **要約が値の先頭行に来る**ことを、消費側の読み取り規則を実装した抽出器で確認する。
#     形が受理されるだけでは「board で要約が最初に出る」は保証されない。
#   - **抽出器の自己検査を持つ**（(A)）。抽出器が壊れて常に空を返すと (C) は空虚に真になる。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

SKILL_MD="skills/run-cycle/SKILL.md"
FORMAT_DOC="docs/challenge-ledger-format.md"
STRATEGY_DOC="docs/ledger-load-strategy.md"
VALIDATOR="scripts/validate-artifact.rb"

# 追記の先頭行の定型（規範の識別子）。SKILL.md と形式ドキュメントの両方がこの形を使う。
SUCCESS_PREFIX='> （原文・'
FAILURE_PREFIX='> （原文の取得に失敗: '

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

has() { # has <名前> <ファイル> <文字列>
  if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "$2 に無い: $3"; fi
}

hasnt() { # hasnt <名前> <ファイル> <文字列>
  if grep -qF -- "$3" "$2"; then fail "$1" "$2 に在ってはならない: $3"; else pass "$1"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 一時ファイルは共有 /tmp の固定名を使わず mktemp の一意名にし、書き込み後に読み返して
# 自分が書いた内容であることを確認してから使う（他タスクの内容を読んで成功したように
# 見える事故を止める）。
verify_written() { # verify_written <path> <期待する含有文字列>
  [ -s "$1" ] || { echo "書き込みに失敗: $1 が空" >&2; exit 1; }
  grep -qF -- "$2" "$1" || { echo "書き込み内容が一致しない: $1" >&2; exit 1; }
}

# --- (0) 走査対象が実在し非空である（対象 0 件の「違反なし」を pass にしない） ---

for f in "$SKILL_MD" "$FORMAT_DOC" "$STRATEGY_DOC" "$VALIDATOR"; do
  if [ -s "$f" ]; then pass "(0) 対象が実在し非空: $f"; else fail "(0) 対象が実在し非空: $f" "無い/空"; fi
done

# --- 焼き込み節の切り出し（節の外の一般語で空虚に真にならないようにする） ---
# SKILL.md 手順4 の「原文の焼き込み」箇条書きから、次の兄弟箇条書き「移動の手順」の直前まで。

/usr/bin/ruby -e '
lines = File.readlines(ARGV[0])
b = lines.index { |l| l.include?("**原文の焼き込み") }
abort "SKILL.md に「原文の焼き込み」の箇条書きが無い" unless b
e = (b + 1...lines.size).find { |i| lines[i].include?("**移動の手順（2 ファイル更新のトランザクション）**") }
abort "焼き込み節の終端（「移動の手順」）が見つからない" unless e
File.write(ARGV[1], lines[b...e].join)
' "$SKILL_MD" "$tmp/burnin.md" 2>"$tmp/burnin.err"
if [ -s "$tmp/burnin.md" ]; then
  verify_written "$tmp/burnin.md" "原文の焼き込み"
  pass "(0) SKILL.md 手順4 から焼き込み節を切り出せる（$(grep -c . "$tmp/burnin.md") 行）"
  BURNIN="$tmp/burnin.md"
else
  fail "(0) SKILL.md 手順4 から焼き込み節を切り出せる" "$(cat "$tmp/burnin.err")"
  BURNIN="/dev/null"
fi

# --- (A) 抽出器の自己検査（消費側の読み取り規則 2 の実装） ---
# フィールド値 = フィールド行の値 ＋ 直下に連続する継続行（インデント行・引用行）。
# 空行・いずれの継続行でもない行・次見出しで終端。

cat > "$tmp/extract.rb" <<'RUBY'
# 消費側（board 等）の読み取り規則 2 を実装する: `- 説明:` の値と直下の継続行を \n で結合する。
path, want_id = ARGV[0], ARGV[1]
lines = File.readlines(path).map(&:chomp)
cur = nil
out = nil
collecting = false
lines.each do |l|
  if (m = l.match(/^### \[([^\]]+)\]/))
    cur = m[1]; collecting = false; next
  end
  if collecting
    if l =~ /^\s+\S/ || l =~ /^>/
      out << l.sub(/^ {1,2}/, ""); next
    else
      collecting = false
    end
  end
  if cur == want_id && (m = l.match(/^- 説明: ?(.*)$/))
    out = [m[1]]
    collecting = true
  end
end
abort "説明欄が見つからない: #{want_id}" unless out
puts out.reject(&:empty?).join("\n")
RUBY
verify_written "$tmp/extract.rb" "消費側（board 等）の読み取り規則 2"

cat > "$tmp/selfcheck.md" <<'EOF'
### [C-901] 抽出器の自己検査

**人間記入欄**
- 説明: 要約の行。
> 引用の 1 行目
> 引用の 2 行目
- 完了条件（任意）: 終端されること
EOF
verify_written "$tmp/selfcheck.md" "C-901"

got="$(/usr/bin/ruby "$tmp/extract.rb" "$tmp/selfcheck.md" C-901 2>&1)"
want="$(printf '要約の行。\n> 引用の 1 行目\n> 引用の 2 行目')"
if [ "$got" = "$want" ]; then
  pass "(A) 抽出器が引用行を説明欄の値へ結合し、次のフィールド行で終端する"
else
  fail "(A) 抽出器が引用行を説明欄の値へ結合し、次のフィールド行で終端する" "got=[$got]"
fi

got_empty="$(/usr/bin/ruby "$tmp/extract.rb" "$tmp/selfcheck.md" C-999 2>&1; echo "exit=$?")"
case "$got_empty" in
  *"exit=0"*) fail "(A) 抽出器は対象不在を成功にしない" "exit 0 で返った: $got_empty" ;;
  *) pass "(A) 抽出器は対象不在を成功にしない" ;;
esac

# --- (B) 受理方向: 成功形・失敗形の 2 形がアーカイブとして受理される ---

archive_entry() { # archive_entry <ID> <説明欄の継続行...>
  id="$1"; shift
  printf '### [%s] 焼き込みの受理テスト\n\n' "$id"
  printf '**人間記入欄**\n'
  printf -- '- 起票者 / 起票日: masanami / 2026-08-30\n'
  printf -- '- 説明: 台帳の説明欄を要約に置き換え、board のカード詳細を読めるようにする。\n'
  for l in "$@"; do printf '%s\n' "$l"; done
  printf -- '- 完了条件（任意）: PR がマージされること\n'
  printf -- '- 体感の緊急度（任意）: 中\n\n'
  printf '**分類欄（エージェントが記入）**\n'
  printf -- '- 担当ポジション: harness\n'
  printf -- '- 関連サービス:\n'
  printf -- '- 優先度: P1\n'
  printf -- '- ステータス: 完了\n'
  printf -- '- タスク案:\n'
  printf -- '  1. 説明欄を要約へ置き換える\n'
  printf -- '- 承認（人間がチェック）:\n'
  printf -- '  - [x] 計画を承認（FR-13・承認対象＝タスク案）\n'
  printf -- '  - [x] 完了を承認（FR-32）\n'
  printf -- '- 取り込み元: harness-repo-issues / claude-flywheel#130（取り込み: 2026-08-29）<!-- fp:2:0123456789ab -->\n'
  printf -- '- 備考:\n\n'
}

{
  printf '# 課題アーカイブ（Challenge Archive）\n\n'
  printf '> 焼き込みの 2 形（取得成功・取得失敗）。\n\n---\n\n'
  archive_entry C-801 \
    "${SUCCESS_PREFIX}harness-repo-issues / claude-flywheel#130 を 2026-08-30 に取得）" \
    '> ## 背景' \
    '> 課題台帳の `- 説明:` 欄は外部 Issue 本文の全文転記になっている。'
  archive_entry C-802 \
    "${FAILURE_PREFIX}上流 Issue が削除されている・2026-08-30）"
} > "$tmp/archive.md"
verify_written "$tmp/archive.md" "$SUCCESS_PREFIX"
verify_written "$tmp/archive.md" "$FAILURE_PREFIX"

out="$(/usr/bin/ruby "$VALIDATOR" archive "$tmp/archive.md" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  pass "(B) 焼き込みの 2 形（成功・失敗）が type=archive で受理される"
else
  fail "(B) 焼き込みの 2 形（成功・失敗）が type=archive で受理される" "exit=$rc / $out"
fi

out="$(/usr/bin/ruby "$VALIDATOR" archive "$tmp/archive.md" --expect-ids C-801,C-802 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  pass "(B) --expect-ids（移動漏れの検出）が焼き込み後のエントリでも通る"
else
  fail "(B) --expect-ids（移動漏れの検出）が焼き込み後のエントリでも通る" "exit=$rc / $out"
fi

# --- (C) 消費側の読み取り結果: 要約が値の先頭行に来て、原文がその下に結合される ---

got="$(/usr/bin/ruby "$tmp/extract.rb" "$tmp/archive.md" C-801 2>&1)"
first="$(printf '%s\n' "$got" | sed -n '1p')"
case "$first" in
  '- '*|'>'*) fail "(C) 取得成功形: 要約が説明欄の値の先頭行に来る" "先頭行が引用行: [$first]" ;;
  '') fail "(C) 取得成功形: 要約が説明欄の値の先頭行に来る" "値が空" ;;
  *) pass "(C) 取得成功形: 要約が説明欄の値の先頭行に来る" ;;
esac
case "$got" in
  *"$SUCCESS_PREFIX"*) pass "(C) 取得成功形: 原文の引用が同じ値へ結合される" ;;
  *) fail "(C) 取得成功形: 原文の引用が同じ値へ結合される" "got=[$got]" ;;
esac

got="$(/usr/bin/ruby "$tmp/extract.rb" "$tmp/archive.md" C-802 2>&1)"
first="$(printf '%s\n' "$got" | sed -n '1p')"
case "$first" in
  '>'*|'') fail "(C) 取得失敗形: 要約が説明欄の値の先頭行に来る" "先頭行: [$first]" ;;
  *) pass "(C) 取得失敗形: 要約が説明欄の値の先頭行に来る" ;;
esac
case "$got" in
  *"$FAILURE_PREFIX"*) pass "(C) 取得失敗形: 失敗の事実が同じ値へ結合され消費側から見える" ;;
  *) fail "(C) 取得失敗形: 失敗の事実が同じ値へ結合され消費側から見える" "got=[$got]" ;;
esac

# --- (D) 規範が実行時テキストに在り、形式ドキュメントと同じ定型を使う（2 面の一致） ---

has "(D) SKILL.md 手順4 に焼き込みの規範が在る" "$BURNIN" "原文の焼き込み"
has "(D) SKILL.md: 取得はトランザクションより前" "$BURNIN" '`.flywheel/ledger-tx.json` を書く**前**'
has "(D) SKILL.md: 対象は説明欄にブロック引用が無いエントリだけ" "$BURNIN" "ブロック引用"
has "(D) SKILL.md: 要約行を消さない" "$BURNIN" "要約行を消さず"
has "(D) SKILL.md: 取得方式はソース種別を名指ししない" "$BURNIN" "ソース種別を名指ししない"
has "(D) SKILL.md: --dry-run パリティ" "$BURNIN" '`--dry-run` 時は取得も追記も行わない'
has "(D) SKILL.md: 追記行を囲まない" "$BURNIN" '`<details>`'
has "(D) SKILL.md に取得成功の定型" "$BURNIN" "$SUCCESS_PREFIX"
has "(D) SKILL.md に取得失敗の定型" "$BURNIN" "$FAILURE_PREFIX"
has "(D) 形式ドキュメントに取得成功の定型（SKILL.md と同一文字列）" "$FORMAT_DOC" "$SUCCESS_PREFIX"
has "(D) 形式ドキュメントに取得失敗の定型（SKILL.md と同一文字列）" "$FORMAT_DOC" "$FAILURE_PREFIX"
has "(D) 形式ドキュメントが原文保存の例外として宣言している" "$FORMAT_DOC" "原文のままの唯一の例外"
has "(D) 即アーカイブの規定が例外の所在を指している" "$SKILL_MD" "「原文のまま」の唯一の例外は下記"

# --- (E) 異常系の出力契約（正常系だけ定義して緑になる穴を塞ぐ） ---

has "(E) 取得失敗時も移動を実行する（fail-open）" "$BURNIN" "**移動は実行する**（fail-open）"
has "(E) 取得失敗時に追記する 1 行が定義されている" "$BURNIN" "の 1 行だけを追記"
has "(E) 取得失敗をサイクルレポートへ個別に列挙する" "$BURNIN" "個別に列挙"
has "(E) 失敗理由の語彙が列挙されている（何を失敗と呼ぶかが未定義でない）" "$BURNIN" "アクセス方式が未定義"
has "(E) fail-open を選んだ理由がインラインに在る（fail-closed へ倒し直されない）" "$BURNIN" "ここで移動を止めてはならない"

# 否定検査: 失敗時に移動を止める（fail-closed）語彙が焼き込み節に混入していないこと。
# 規定が両向きに読めると、実行時に安全側と称して倒され livelock が再生産される。
for w in '移動を保留' '移動しない' '移動を中止' 'fail-closed'; do
  hasnt "(E) 否定検査: 焼き込み節に fail-closed 語彙が無い: ${w}" "$BURNIN" "$w"
done

# --- (F) #122 の確定済み採否を覆していないことが追える（採否は変更しない） ---

has "(F) 戦略ドキュメント §3.3 (f) に案 (iv) の追記が在る" "$STRATEGY_DOC" "この懸念は #130 の案 (iv) で保たれた"
has "(F) 追記が採否を変えないと明言している" "$STRATEGY_DOC" "§7 の採否（案 3 は不採用）は変わらない"
has "(F) §7 の案 3 の行が不採用のまま" "$STRATEGY_DOC" "| **3. 原文引用の置き場所** | **不採用** |"

echo ""
echo "=== summary === pass: ${PASS}, fail: ${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  echo "failed:"
  for t in ${FAILED+"${FAILED[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
