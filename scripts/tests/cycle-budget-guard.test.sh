#!/usr/bin/env bash
#
# cycle-budget-guard.test.sh — run-cycle 手順3 の「サイクル全体の予算上限（`cycle_budget_usd`）を
# 起動前に評価する」規定と「枠超過の周内への伝播」の構造不変条件テスト（Issue #148）。
#
# 実行: bash scripts/tests/cycle-budget-guard.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・awk・/usr/bin/ruby。読み取り専用。
#
# 検査の要:
#   - **検査は手順3 の節を切り出してから**行う。SKILL.md 全文への grep は、同じ語が手順2 や
#     docs にあるだけで空虚に真になる（PR #143 / #146 / #147 で実測）。
#   - **抽出器を自己検査する**（(A)）。切り出しが壊れて全文が返ると以降がすべて空虚に真になる
#     ため、手順3 固有のアンカーが在ること**と**手順2 / 手順6 固有のアンカーが無いことの両方を見る。
#   - **「規定が手順3 に在る」は出現回数の一致で固定する**（全文の出現回数 == 手順3 内の出現回数）。
#     規定を別の節や docs へ移しただけでは通らない＝位置まで固定される（空虚性検査）。
#   - **fail-closed 経路の出力を定義しているかを見る**（(B)）。抑止したときに何をレポートへ出すかが
#     未定義だと、規定は「起動しない」だけで観測不能になる。
#   - **空集合ケースを必ず含める**（(B)）。委譲 0 件の周で評価を飛ばすと条件は空虚に真になり、
#     「単一委譲だけでサイクル上限を超える」ケースを取りこぼす。
#   - **3 値すべてを検査する**（(C)）。枠超過判定は exit 0/1/2 の 3 値であり、伝播するのは exit 0
#     だけ。「exit 0 で伝播する」だけを見ると exit 1/2 の側が無検査になる。
#   - **安全機構が判定式に接続されているかを見る**（(D)）。設定値の実在・既定値リテラルの同一性・
#     既消費額の記録先・既存ワークスペースの追従検出まで辿り、「書いてあるが効いていない」を落とす。
#   - **否定検査を対で置く**（(B)(D)）。緩い旧記述（「上限なし」への縮退・版マーカー §7 の
#     「無し（既知の穴）」）が残っていないことを見る。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

SKILL_MD="skills/run-cycle/SKILL.md"
CADENCE_TPL="templates/cadence.json"
MIGRATE_RB="scripts/migrate-workspace.rb"
MARKER_DOC="docs/template-version-marker.md"
DOCS_README="docs/README.md"

# 規範文（手順3 に逐語で在ることを固定する）。
BUDGET_RULE='**【費用ガード】サイクル全体の予算上限を起動前に評価する**'
BUDGET_FORMULA='当周の既消費額 ＋ これから起動する分の `--max-budget-usd` > `cycle_budget_usd`'
EMPTY_CASE='当周まだ 1 件も起動していない周でも評価を飛ばさない'
PROPAGATE_RULE='枠超過を 1 件でも観測した周は、その周の残りの委譲を起動しない'
PROPAGATE_ONLY0='伝播させるのは exit 0（枠超過）のときだけ'

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
count_of() { printf '%s\n' "$1" | grep -cF -- "$2" | tr -d ' '; }
nonempty() { if [ -n "$1" ]; then echo true; else echo false; fi; }

step2="$(awk '/^### 2\. /{f=1} /^### 3\. /{f=0} f' "${SKILL_MD}")"
step3="$(awk '/^### 3\. /{f=1} /^### 4\. /{f=0} f' "${SKILL_MD}")"
step6="$(awk '/^### 6\. /{f=1} /^## 出力$/{f=0} f' "${SKILL_MD}")"
whole="$(cat "${SKILL_MD}")"

echo "=== (A) 抽出器の自己検査（手順3 / 手順6 を取り違えていない） ==="

assert_eq "(A) 手順3 の節を切り出せた（空でない）" "true" "$(nonempty "${step3}")"
assert_eq "(A) 手順6 の節を切り出せた（空でない）" "true" "$(nonempty "${step6}")"
assert_eq "(A) 手順2 の節を切り出せた（空でない）" "true" "$(nonempty "${step2}")"
has   "(A) 手順3 に手順3 固有のアンカーがある" "${step3}" '【費用ガード】委譲コマンドには必ず'
hasnt "(A) 手順3 に手順2 固有のアンカーが混ざっていない（全文を返していない）" "${step3}" \
  '- 目標 → タスクに分解し'
hasnt "(A) 手順3 に手順6 固有のアンカーが混ざっていない" "${step3}" '### 6. 報告・コミット'
has   "(A) 手順6 に手順6 固有のアンカーがある" "${step6}" 'サイクルジャーナルへ書き出す'
hasnt "(A) 手順6 に手順3 固有のアンカーが混ざっていない" "${step6}" '【費用ガード】委譲コマンドには必ず'

echo ""
echo "=== (B) 手順3: サイクル全体の予算上限を起動前に評価する ==="

has "(B) 手順3 に起動前評価の規定がある" "${step3}" "${BUDGET_RULE}"
has "(B) 上限の置き場所は cadence.json の cycle_budget_usd" "${step3}" \
  '上限は `.flywheel/cadence.json` の `cycle_budget_usd`'
has "(B) 既定値がリテラルで書かれている" "${step3}" '**既定 `300` USD**'
has "(B) 不在・不正は既定へ補正して続行する（安全側）" "${step3}" \
  '**ファイル・フィールドが無い、または不正（数値でない・0 以下）な場合は既定値へ補正して続行**'
has "(B) 補正した事実をサイクルレポートに出す" "${step3}" '既定値使用の旨をサイクルレポートに含める'
# 否定検査（緩い側＝無制限への縮退が許容されていないこと。肯定検査と向きを揃えない）
has "(B) 不在を「上限なし」へ縮退させないと明記されている" "${step3}" \
  '**不在を「上限なし」へ縮退させない**'
hasnt "(B) 上限なしで起動してよいと読める記述が無い（1）" "${step3}" '上限なしで起動'
hasnt "(B) 上限なしで起動してよいと読める記述が無い（2）" "${step3}" 'サイクル予算の評価を省略してよい'

# 評価式そのものを逐語で固定する（式が消えると規定は「上限がある」だけの宣言になる）
has "(B) 評価式が逐語で書かれている" "${step3}" "${BUDGET_FORMULA}"
has "(B) 超過時は起動しない（判定の帰結が定義されている）" "${step3}" 'なら**その委譲を起動しない**'
has "(B) 既消費額の定義がある（total_cost_usd の総和）" "${step3}" \
  '当周に起動した各委譲の返り値 `total_cost_usd` の総和'
has "(B) --resume 分も既消費額に加える" "${step3}" '`--resume` した分も各起動分を加える'

# **空集合ケース**（vacuous truth 対策）: 委譲 0 件の周でも評価する
has "(B) 委譲 0 件の周でも評価を飛ばさない" "${step3}" "${EMPTY_CASE}"
has "(B) 0 件の周は既消費額 0 を代入して同じ式を評価する" "${step3}" '既消費額に `0` を代入して同じ式を評価する'
has "(B) 単一委譲だけで上限を超えるケースをここで止める" "${step3}" \
  '「承認済みの単一委譲だけでサイクル上限を超える」ケース'

# **fail-closed 経路の出力契約**（抑止したときに何が観測されるか）
has "(B) 抑止時に delegate_start を記録しない（未終了 start を残さない）" "${step3}" \
  '起動していないので `delegate_start` は**記録しない**'
has "(B) 抑止した課題はステータスを進めず次周へ送る" "${step3}" '課題のステータスは**進めずそのまま次周へ送り**'
has "(B) 抑止の報告先は次アクション" "${step3}" 'サイクルレポートの**次アクション**に次を明記する'
has "(B) 抑止時の出力① 課題 ID と要求上限" "${step3}" '① 抑止した課題 ID とその `--max-budget-usd`'
has "(B) 抑止時の出力② 当周の既消費額" "${step3}" '② 当周の既消費額'
has "(B) 抑止時の出力③ 適用した上限と既定補正の有無" "${step3}" \
  '③ 適用した `cycle_budget_usd`（既定へ補正した場合はその旨）'
has "(B) 増額はエージェントが行わない（人間が cadence.json を書き換える）" "${step3}" \
  '増額は人間が `cadence.json` を書き換えて行う（エージェントは書き換えない）'

# 例外（照合のための報告のみの再取得）が既存規定と同じ向きで倒れている
has "(B) 例外は報告のみの再取得だけ" "${step3}" \
  '**例外は【委譲結果の照合】のための「報告のみの再取得」だけ**'
has "(B) 例外分の消費も既消費額へ加える（取りこぼさない）" "${step3}" '消費は既消費額へ加える'

# 位置の固定: 全文と手順3 で出現回数が一致する＝別の節や docs へ移しただけでは通らない
assert_eq "(B) 起動前評価の規定が手順3 にちょうど 1 回ある" "1" "$(count_of "${step3}" "${BUDGET_RULE}")"
assert_eq "(B) 起動前評価の規定は手順3 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step3}" "${BUDGET_RULE}")" "$(count_of "${whole}" "${BUDGET_RULE}")"
assert_eq "(B) 評価式が手順3 にちょうど 1 回ある" "1" "$(count_of "${step3}" "${BUDGET_FORMULA}")"
assert_eq "(B) 評価式は手順3 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step3}" "${BUDGET_FORMULA}")" "$(count_of "${whole}" "${BUDGET_FORMULA}")"
assert_eq "(B) 空集合ケースの規定は手順3 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step3}" "${EMPTY_CASE}")" "$(count_of "${whole}" "${EMPTY_CASE}")"

echo ""
echo "=== (C) 手順3: 枠超過の周内への伝播（exit 0/1/2 の 3 値をすべて見る） ==="

has "(C) 手順3 に伝播の規定がある" "${step3}" "${PROPAGATE_RULE}"
has "(C) 未起動の課題はステータスを進めず次周へ送る" "${step3}" \
  '**未起動の課題はステータスを進めずそのまま次周へ送り**'
has "(C) 抑止した課題 ID を次アクションへ出す" "${step3}" '`report=` の行とあわせて抑止した課題 ID を出す'
has "(C) 起動済みの分は打ち切らず合流させてから閉じる" "${step3}" \
  '**既に起動済みの分は打ち切らず合流させてから閉じる**'
has "(C) 合流の内容が定義されている（受領→照合→delegate_end）" "${step3}" \
  '返り値の受領 →【委譲結果の照合】→ `delegate_end`'
has "(C) サイクル自体は止めない" "${step3}" 'サイクル自体は止めず手順4以降へ進む'

# 真理値表: 3 値それぞれの扱いが書かれていること（exit 0 だけを見ると 1/2 が無検査になる）
has "(C) exit 0（枠超過）のときだけ伝播する" "${step3}" "${PROPAGATE_ONLY0}"
has "(C) exit 1・exit 2 では伝播しない（両方が名指しされている）" "${step3}" \
  '**exit 1（枠超過ではない）・exit 2（検査不能）では伝播しない**'
has "(C) 判定不能の倒し方が伝播にも同じ向きで適用されている" "${step3}" \
  '**同じ非対称を伝播にも同じ向きで適用する**'
# 既存の 3 値契約（伝播の前提）が消えていないこと＝規定が宙に浮かない
has "(C) 前提となる quota-check.sh の 3 値契約が手順3 に残っている" "${step3}" \
  'exit code は 3 値: **exit 0**＝枠超過'
has "(C) 前提となる判定器の呼び出しが手順3 に残っている" "${step3}" 'scripts/quota-check.sh" --result-file'

assert_eq "(C) 伝播の規定が手順3 にちょうど 1 回ある" "1" "$(count_of "${step3}" "${PROPAGATE_RULE}")"
assert_eq "(C) 伝播の規定は手順3 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step3}" "${PROPAGATE_RULE}")" "$(count_of "${whole}" "${PROPAGATE_RULE}")"
assert_eq "(C) exit 0 限定の規定は手順3 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step3}" "${PROPAGATE_ONLY0}")" "$(count_of "${whole}" "${PROPAGATE_ONLY0}")"

echo ""
echo "=== (D) 安全機構の接続（設定・既定値・記録先・既存ワークスペースの追従） ==="

# D-1. 設定キーがテンプレートに実在する（規定が読む先が無ければ常に既定へ倒れる）
assert_eq "(D) templates/cadence.json が読める" "true" "$(if [ -r "${CADENCE_TPL}" ]; then echo true; else echo false; fi)"
tpl_budget="$(/usr/bin/ruby -rjson -e 'v = JSON.parse(File.read(ARGV[0]))["cycle_budget_usd"]; print(v.nil? ? "" : v)' "${CADENCE_TPL}" 2>/dev/null)"
assert_eq "(D) templates/cadence.json に cycle_budget_usd がある" "true" "$(nonempty "${tpl_budget}")"

# D-2. **同一性の検証**（一般形だけ見ない）: SKILL.md の既定値リテラルとテンプレートの値が一致する。
#      片方だけ変えると「宣言した値と縮退値が食い違う」状態が黙って成立する。
skill_budget="$(printf '%s\n' "${step3}" | grep -oE '\*\*既定 `[0-9]+` USD\*\*' | head -1 | grep -oE '[0-9]+')"
assert_eq "(D) SKILL.md の既定値リテラルを取り出せた" "true" "$(nonempty "${skill_budget}")"
assert_eq "(D) SKILL.md の既定値とテンプレートの値が一致する" "${tpl_budget}" "${skill_budget}"

# D-3. 既消費額の**記録先**が手順6 に定義されている（入力が記録されないと起動前評価は動かない）
has "(D) 手順6 の journal ② に当周の合計消費を書く規定がある" "${step6}" \
  '**あわせて②の末尾に、当周の全委譲の合計消費（サイクル予算の既消費額）と適用した `cycle_budget_usd` を 1 行で書く**'
has "(D) 手順3 が記録先として journal ② を指している" "${step3}" '記録先は step 6 の journal ②'

# D-4. 既存ワークスペースの追従検出（JSON は版マーカーの対象外＝内容ベース検出が唯一の経路）
migrate="$(cat "${MIGRATE_RB}")"
has "(D) migrate-workspace.rb の列挙に cycle_budget_usd がある" "${migrate}" '["cycle_budget_usd",'
has "(D) 列挙は既定へ縮退するキーの集合として定義されている" "${migrate}" 'CADENCE_FALLBACK_KEYS = ['
has "(D) 検出器が scaffold 追従レポートへ接続されている" "${migrate}" 'notes.concat(cadence_notes(ws))'

# D-5. **否定検査**: 版マーカー §7 の「既知の穴」という旧記述が残っていないこと
marker_doc="$(cat "${MARKER_DOC}")"
hasnt "(D) 版マーカー §7 に「無し（既知の穴）」の旧記述が残っていない" "${marker_doc}" \
  '| `.flywheel/cadence.json` | 同上 | **無し（既知の穴）** |'
has "(D) 版マーカー §7 が内容ベース検出を現在の検出として記載している" "${marker_doc}" \
  '| `.flywheel/cadence.json` | 同上 | **内容ベース検出**'

# D-6. 利用先が設定を知る導線（docs の cadence.json キー列挙）
has "(D) docs/README.md の cadence.json 説明に cycle_budget_usd がある" "$(cat "${DOCS_README}")" \
  'サイクル全体の予算上限 `cycle_budget_usd`'

echo ""
echo "=== summary === pass: ${PASS}, fail: ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  echo "failed:"
  for t in ${FAILED+"${FAILED[@]}"}; do echo "  - ${t}"; done
  exit 1
fi
exit 0
