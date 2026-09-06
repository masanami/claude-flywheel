#!/usr/bin/env bash
#
# ledger-deps.test.sh — 課題台帳の依存フィールド（`依存`）と、それを解決する
# scripts/ledger-deps.rb の構造不変条件テスト（Issue #150 / FR-12）。
#
# 実行: bash scripts/tests/ledger-deps.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・ruby・grep・awk。テストフレームワーク不使用。
#   - すべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない（読み取り専用）。
#     **変異注入も SKILL.md の一時コピーに対して行う**——被検体そのものを書き換えると、
#     中断した瞬間にリポジトリへ変異が残る（復元は「後始末」であって防御ではない）。
#
# 検査の要:
#   - **空集合ケースを必ず対で置く**（(B)/(C)）。「依存がある行が正しく出る」だけを見ると、
#     全称条件（「依存先がすべて完了なら起動可」）が**依存ゼロで空虚に真**になる型を
#     見逃す。依存ゼロ・依存が全件完了・依存に未完了あり の 3 通りを必ず通す。
#   - **完了判定は台帳とアーカイブの両方**（(D)）。`完了` は即アーカイブで台帳に滞留しない
#     過渡ステータスなので、台帳だけを見る実装は**完了済みの先行課題を未完了と誤判定**する。
#     アーカイブを渡した場合／渡さなかった場合の差を実行で示す（散文の主張ではなく振る舞い）。
#   - **fail-closed の向きを固定する**（(E)）。存在しない ID・循環・重複はいずれも
#     「起動可」側へ倒れてはならない。**否定検査**として置く。
#   - **規定の位置まで固定する**（(G)/(H)）。SKILL.md 全文への grep は、同じ語が別の手順に
#     あるだけで空虚に真になるため、手順2 / 手順3 を切り出してから検査し、切り出し器自身を
#     自己検査する（spec-split-gate.test.sh と同じ流儀）。
#   - **フィールドのラベルは 規定・雛形・バリデータ・索引・解決器 の 5 面で一致**（(F)）。
#     どれか 1 つで改名すると、他が黙って値を拾えなくなる（board の `-` 表示と同型の事故）。
#   - **変異注入で「検査が効いていること」まで示す**（(I)）。規定の削除と、別の節への移設
#     （＝空虚性）の 2 種を入れ、どちらでも落ちることを確認する。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

DEPS="${TESTS_DIR}/../ledger-deps.rb"
INDEX="${TESTS_DIR}/../ledger-index.rb"
VALIDATOR="scripts/validate-artifact.rb"
MIGRATE="scripts/migrate-workspace.rb"
SKILL_MD="skills/run-cycle/SKILL.md"
FORMAT_DOC="docs/challenge-ledger-format.md"
LEDGER_TPL="templates/challenge-ledger.md"

PASS=0
FAIL=0
FAILED=""

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

pass() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED="${FAILED}
  - $1"
  printf 'FAIL - %s\n' "$1"
  [ $# -ge 2 ] && printf '       %s\n' "$2"
  return 0
}
# 注意: 全角文字の直前の変数展開は bash 3.2 が誤るため、必ず ${var} のブレース形で書く。
eq()    { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$3] got=[$2]"; fi; }
has()   { if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "見つからない: $3"; fi; }
hasnt() { if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1" "見つかった: $3"; else pass "$1"; fi; }

# ---------------------------------------------------------------------------
# 前提
# ---------------------------------------------------------------------------
if [ ! -f "${DEPS}" ]; then
  fail "被検体が存在する: scripts/ledger-deps.rb" "not found: ${DEPS}"
  printf '\npassed: %s / failed: %s\n' "${PASS}" "${FAIL}"
  exit 1
fi
if [ -x "${DEPS}" ]; then pass "被検体に実行権がある"; else fail "被検体に実行権がある" "chmod +x が要る"; fi

# 変異注入の漏れ検出用に、被検体（SKILL.md）の元本を控える（(I) で バイト比較する）。
cp "${SKILL_MD}" "${tmp}/skill.orig"

# 素材の生成。`$8` が `依存` の値（省略＝空欄＝独立）。
entry() {
  cat <<ENTRY

### [$1] $1 のタイトル

**人間記入欄**
- 起票者 / 起票日: tester / 2026-09-06
- 説明: テスト用エントリ。

**分類欄（エージェントが記入）**
- 担当ポジション: harness
- 関連サービス:
- 関連リポジトリ:
- 関連Issue:
- 関連PR:
- 依存: ${2:-}
- 優先度: P1
- ステータス: $3
- タスク案:
- 承認（人間がチェック）:
  - [ ] 計画を承認（FR-13・承認対象＝タスク案）
  - [ ] 完了を承認（FR-32）
- 備考:
ENTRY
}

LEDGER="${tmp}/challenge-ledger.md"
ARCHIVE="${tmp}/challenge-archive.md"
{
  printf '# 課題台帳（Challenge Ledger）\n\n> テスト用。\n'
  entry "C-1" ""            "着手中"        # 依存ゼロ（空集合ケース）
  entry "C-2" "C-ARC"       "着手中"        # 依存がアーカイブ済み＝完了
  entry "C-3" "C-1"         "着手中"        # 依存が未完了（台帳に着手中で在る）
  entry "C-4" "C-DONE"      "着手中"        # 依存が台帳内で `完了`（アーカイブ前の一瞬）
  entry "C-5" "C-ARC, C-1"  "着手中"        # 依存の一部だけ完了（全称条件の否定側）
  entry "C-6" "C-404"       "着手中"        # 存在しない ID
  entry "C-7" "C-7"         "着手中"        # 自己参照
  entry "C-8" "C-9"         "着手中"        # 循環（C-8 → C-9 → C-8）
  entry "C-9" "C-8"         "着手中"
  entry "C-10" "C-8"        "着手中"        # 循環から到達可能な後続
  entry "C-11" ""           "分類済"        # 依存ゼロだが `着手中` でない
  entry "C-DONE" ""         "完了"
} > "${LEDGER}"
{
  printf '# 課題アーカイブ\n\n> テスト用。\n'
  entry "C-ARC" "" "完了"
} > "${ARCHIVE}"

run_deps() { "${DEPS}" "$@" 2>"${tmp}/stderr"; }
# 投影から 1 課題の 1 列を引く。列は**ヘッダの列名**で引く（位置をハードコードしない）。
cell() { # $1=projection $2=id $3=column
  printf '%s\n' "$1" | awk -F'\t' -v id="$2" -v col="$3" '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == col) c = i; next }
    $1 == id { print $c }'
}

echo "=== (A) 3 値の終了コードと宣言の一致 ==="
eq "(A) --list-exits の宣言は 0 / 1 / 2" "$("${DEPS}" --list-exits | tr '\n' ' ')" "0 1 2 "
eq "(A) --list-columns の宣言と投影のヘッダが一致する（双方向）" \
   "$("${DEPS}" --list-columns | tr '\n' '\t' | sed 's/\t$//')" \
   "$(run_deps "${LEDGER}" "${ARCHIVE}" | head -1)"
"${DEPS}" "${tmp}/does-not-exist.md" >/dev/null 2>&1
eq "(A) 対象不在は exit 2（検査不能。0 件と読み替えない）" "$?" "2"
"${DEPS}" --bogus >/dev/null 2>&1
eq "(A) 不明なオプションは exit 2" "$?" "2"

echo ""
echo "=== (B) 空集合ケース: 依存ゼロの課題は起動可能（全称条件が空虚に真になる型を潰す）==="
proj="$(run_deps "${LEDGER}" "${ARCHIVE}")"
rc_all=$?
eq "(B) 依存ゼロ・`着手中` は startable=y" "$(cell "${proj}" C-1 startable)" "y"
eq "(B) 依存ゼロの deps 列は `-`（空を表す）" "$(cell "${proj}" C-1 deps)" "-"
eq "(B) 依存ゼロの unmet 列は `-`" "$(cell "${proj}" C-1 unmet)" "-"
# 対の否定検査: 「依存ゼロなら常に y」ではない（ステータスの条件が効いている）
eq "(B) 依存ゼロでも `着手中` でなければ startable=-（ステータス条件が効いている）" \
   "$(cell "${proj}" C-11 startable)" "-"
# 依存を **1 件も持たない台帳**でも投影が成立し、全件が判定される（空グラフの回帰）
{ printf '# 台帳\n'; entry "C-A" "" "着手中"; entry "C-B" "" "分類済"; } > "${tmp}/empty-deps.md"
empty_proj="$(run_deps "${tmp}/empty-deps.md")"
eq "(B) 依存が 1 件も無い台帳でも exit 0" "$?" "0"
eq "(B) 依存が 1 件も無い台帳でも全件が投影される" \
   "$(printf '%s\n' "${empty_proj}" | tail -n +2 | grep -c .)" "2"
eq "(B) 依存が 1 件も無い台帳の `着手中` は startable=y" "$(cell "${empty_proj}" C-A startable)" "y"

echo ""
echo "=== (C) 全称条件: 依存先が**すべて**完了のときだけ起動可能 ==="
eq "(C) 依存先が全件完了（アーカイブ済み）なら startable=y" "$(cell "${proj}" C-2 startable)" "y"
eq "(C) 依存先が未完了なら startable=-" "$(cell "${proj}" C-3 startable)" "-"
eq "(C) 依存先が未完了なら unmet にその ID が入る" "$(cell "${proj}" C-3 unmet)" "C-1"
eq "(C) 依存先の**一部だけ**完了では起動しない（存在量化に退化していない）" \
   "$(cell "${proj}" C-5 startable)" "-"
eq "(C) 一部だけ完了のとき unmet は未完了ぶんだけ（完了ぶんが混ざらない）" \
   "$(cell "${proj}" C-5 unmet)" "C-1"

echo ""
echo "=== (D) 完了判定は台帳とアーカイブの両方を見る ==="
eq "(D) 台帳でステータスが `完了` の依存先は完了扱い" "$(cell "${proj}" C-4 startable)" "y"
eq "(D) アーカイブにある依存先は完了扱い" "$(cell "${proj}" C-2 startable)" "y"
# 変異: アーカイブを渡さないと、アーカイブ済みの先行課題が「存在しない ID」に落ちる。
# ＝台帳だけを見る実装では判定できないことを、振る舞いで示す。
noarc="$(run_deps "${LEDGER}")"
eq "(D)[対照] アーカイブを渡さないと同じ課題が startable=- になる（台帳だけでは判定不能）" \
   "$(cell "${noarc}" C-2 startable)" "-"
has "(D)[対照] そのとき missing として報告される" "$(cat "${tmp}/stderr")" "missing"

echo ""
echo "=== (E) fail-closed: 未完了・不明・循環はすべて「起動しない」側へ倒れる ==="
eq "(E) 存在しない ID を持つ課題は startable=-" "$(cell "${proj}" C-6 startable)" "-"
eq "(E) 存在しない ID は unmet に入る（「見つからない」を完了に読み替えない）" \
   "$(cell "${proj}" C-6 unmet)" "C-404"
eq "(E) 自己参照の課題は startable=-" "$(cell "${proj}" C-7 startable)" "-"
eq "(E) 循環に属する課題は startable=-" "$(cell "${proj}" C-8 startable)" "-"
eq "(E) 循環から到達可能な後続の課題も startable=-" "$(cell "${proj}" C-10 startable)" "-"
eq "(E) 違反がある台帳の exit code は 1（違反あり）" "${rc_all}" "1"
err="$(cat "${tmp}/stderr")"
has "(E) 自己参照を self-reference として報告する" "${err}" "self-reference"
has "(E) 存在しない ID を missing として報告する" "${err}" "missing"
has "(E) 循環を cycle として報告する" "${err}" "cycle"
has "(E) 循環の報告に閉路のノードが並ぶ" "${err}" "C-8 → C-9 → C-8"
has "(E) 自動解決しないことを報告に明記する" "${err}" "自動解決しません"
# 否定検査: 違反があっても投影自体は出す（「どこまで起動してよいか」は必要）
eq "(E) 違反があっても投影は出る（違反 = 何も返さない、ではない）" \
   "$(printf '%s\n' "${proj}" | tail -n +2 | grep -c .)" "12"
# 否定検査: 違反があっても、健全な課題まで巻き添えで止めない
eq "(E) 違反があっても無関係な健全な課題は startable=y のまま" "$(cell "${proj}" C-1 startable)" "y"

echo ""
echo "=== (F) `依存` のラベルが 規定・雛形・バリデータ・索引・解決器 で一致する ==="
has "(F) 規定（docs）に `- 依存:` がある" "$(cat "${FORMAT_DOC}")" "- 依存:"
has "(F) 雛形（templates）に `- 依存:` がある" "$(cat "${LEDGER_TPL}")" "- 依存:"
has "(F) バリデータが `- 依存:` を検査対象にしている" "$(cat "${VALIDATOR}")" "- 依存:"
has "(F) 索引（ledger-index.rb）が `依存` を投影する" "$(cat "${INDEX}")" 'field(body, "依存")'
has "(F) 移行スクリプトが `- 依存:` を補完対象にしている" "$(cat "${MIGRATE}")" '"- 依存:"'
has "(F) 索引の列に deps がある（解決器の入力）" "$("${INDEX}" --list-columns)" "deps"
# 解決器は索引の列名で引く（位置ではない）ことを、索引側の列名との一致で固定する。
has "(F) 解決器が索引の deps 列を要求する" "$(cat "${DEPS}")" 'id status deps'

echo ""
echo "=== (G) 抽出器の自己検査（手順2 / 手順3 を取り違えていない） ==="
step2="$(awk '/^### 2\. /{f=1} /^### 3\. /{f=0} f' "${SKILL_MD}")"
step3="$(awk '/^### 3\. /{f=1} /^### 4\. /{f=0} f' "${SKILL_MD}")"
whole="$(cat "${SKILL_MD}")"
eq "(G) 手順2 を切り出せた（空でない）" "$(if [ -n "${step2}" ]; then echo true; else echo false; fi)" "true"
eq "(G) 手順3 を切り出せた（空でない）" "$(if [ -n "${step3}" ]; then echo true; else echo false; fi)" "true"
has   "(G) 手順2 に手順2 固有のアンカーがある" "${step2}" '- 目標 → タスクに分解し'
hasnt "(G) 手順2 に手順3 固有のアンカーが混ざっていない（全文を返していない）" "${step2}" \
  '【費用ガード】委譲コマンドには必ず'
has   "(G) 手順3 に手順3 固有のアンカーがある" "${step3}" '【費用ガード】委譲コマンドには必ず'
hasnt "(G) 手順3 に手順2 固有のアンカーが混ざっていない" "${step3}" '- 目標 → タスクに分解し'

echo ""
echo "=== (H) 規定の位置: 着手順の制約は手順2・起動の絞り込みは手順3 ==="
TOPO='着手順は `依存` を満たす順序（トポロジカル順）に制約する'
GATE='起動対象は「`着手中` かつ依存先がすべて `完了`」の課題に限る'
has "(H) 手順2 に着手順のトポロジカル制約がある" "${step2}" "${TOPO}"
has "(H) 手順3 に起動の絞り込みがある" "${step3}" "${GATE}"
# 位置の固定: 全文の出現回数と手順内の出現回数が一致する＝別の節へ移しただけでは通らない。
eq "(H) 着手順の制約は手順2 にちょうど 1 回" \
   "$(printf '%s\n' "${step2}" | grep -cF -- "${TOPO}" | tr -d ' ')" "1"
eq "(H) 着手順の制約が手順2 の外に無い（全文の出現回数と一致）" \
   "$(printf '%s\n' "${step2}" | grep -cF -- "${TOPO}" | tr -d ' ')" \
   "$(printf '%s\n' "${whole}" | grep -cF -- "${TOPO}" | tr -d ' ')"
eq "(H) 起動の絞り込みは手順3 にちょうど 1 回" \
   "$(printf '%s\n' "${step3}" | grep -cF -- "${GATE}" | tr -d ' ')" "1"
eq "(H) 起動の絞り込みが手順3 の外に無い（全文の出現回数と一致）" \
   "$(printf '%s\n' "${step3}" | grep -cF -- "${GATE}" | tr -d ' ')" \
   "$(printf '%s\n' "${whole}" | grep -cF -- "${GATE}" | tr -d ' ')"
has "(H) 手順2 が台帳とアーカイブの両方を渡すことを規定する" "${step2}" 'challenge-archive*.md'
has "(H) 手順2 が exit 2 を fail-closed で扱う（依存なしと読み替えない）" "${step2}" \
  '空の結果を「依存なし＝全件起動可」と読み替えない'
has "(H) 手順2 が循環を自動解決しないと明記する" "${step2}" '循環依存は自動解決しない'
has "(H) 手順3 が startable 列で絞ることを規定する" "${step3}" '`startable` 列が `y` の課題だけ'
# 否定検査: 手順3 の**対象条件（見出し）** は `着手中` のままで、依存を条件に足していない
# （足すと保留ステータスを足したときと同型の症状＝対象集合の定義が 2 箇所に散る）。
head3="$(printf '%s\n' "${step3}" | head -1)"
hasnt "(H) 手順3 の見出しの対象条件に依存を足していない（絞り込みは本文で行う）" "${head3}" '依存'
has "(H) 手順3 の見出しの対象条件は `着手中` のまま" "${head3}" '着手中'

echo ""
echo "=== (I) 変異注入: 検査が効いていることを 2 種で示す ==="
# **変異は被検体そのものではなく一時コピーへ入れる**（中断してもリポジトリに変異が残らない）。
# 変異ごとに元本から取り直す（1 つのコピーを使い回すと 2 つ目の変異が 1 つ目に積み上がる）。
extract3() { awk '/^### 3\. /{f=1} /^### 4\. /{f=0} f' "$1"; }

# 変異 1: 規定の削除。手順3 の依存ゲート行を消す。
cp "${SKILL_MD}" "${tmp}/mutant-deleted.md"
ruby -e '
  path, gate = ARGV
  s = File.read(path, encoding: "UTF-8")
  File.write(path, s.lines.reject { |l| l.include?(gate) }.join)
' "${tmp}/mutant-deleted.md" "${GATE}"
hasnt "(I) 変異1（削除）: 手順3 から依存ゲートが消えることを検査が捉える" \
  "$(extract3 "${tmp}/mutant-deleted.md")" "${GATE}"
has "(I)[対照] 変異なしでは手順3 に依存ゲートが在る" "$(extract3 "${SKILL_MD}")" "${GATE}"

# 変異 2: 別の節への**移設**（空虚性の検査）。全文 grep なら通ってしまう形を作り、
# 位置を固定した検査（H）が落ちることを示す。**これが本命**。
cp "${SKILL_MD}" "${tmp}/mutant-moved.md"
ruby -e '
  path, gate = ARGV
  s = File.read(path, encoding: "UTF-8")
  line = s.lines.find { |l| l.include?(gate) }
  raise "gate line not found" unless line
  s = s.sub(line, "")
  # 手順4 の見出し直後へ移す（全文には残るが手順3 からは消える）。
  s = s.sub(/^(### 4\. .*\n)/) { "#{$1}#{line}" }
  File.write(path, s)
' "${tmp}/mutant-moved.md" "${GATE}"
n3="$(extract3 "${tmp}/mutant-moved.md" | grep -cF -- "${GATE}" | tr -d ' ')"
nw="$(grep -cF -- "${GATE}" "${tmp}/mutant-moved.md" | tr -d ' ')"
eq "(I) 変異2（移設）: 全文には残る（素朴な全文 grep なら通ってしまう）" "${nw}" "1"
eq "(I) 変異2（移設）: 手順3 からは消える（位置を固定した検査は落ちる）" "${n3}" "0"
if [ "${n3}" != "${nw}" ]; then
  pass "(I) 変異2（移設）: 位置の一致検査（H）が不一致を検出する"
else
  fail "(I) 変異2（移設）: 位置の一致検査（H）が不一致を検出する" "n3=${n3} nw=${nw}"
fi

# 被検体が変異していないこと（一時コピーへ入れた変異が漏れていない）を明示的に確認する。
# **git の作業ツリー状態に依存させない**（未コミット差分があるとスキップになる形は、
# 開発中＝いちばん漏れやすい局面でだけ検査が消える）。スイート開始時に控えたコピーと
# バイト比較する。
if cmp -s "${SKILL_MD}" "${tmp}/skill.orig"; then
  pass "(I) 変異注入後もリポジトリの SKILL.md は無変更（変異は一時コピーに閉じている）"
else
  fail "(I) 変異注入後もリポジトリの SKILL.md は無変更（変異は一時コピーに閉じている）" \
    "被検体が書き換わっている"
fi

echo ""
echo "=== summary === pass: ${PASS}, fail: ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  printf 'failed:%s\n' "${FAILED}"
  exit 1
fi
exit 0
