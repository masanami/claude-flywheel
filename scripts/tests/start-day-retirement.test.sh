#!/usr/bin/env bash
#
# start-day-retirement.test.sh — start-day（セッション内 cron の定期便）廃止（Issue #165）の
# 構造不変条件テスト。「消した」ことと「残したものと参照が噛み合っている」ことを固定する。
#
# 実行: bash scripts/tests/start-day-retirement.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・ruby（JSON の読み取り）。
#   - 読み取り専用。書き込みはしない。
#
# 検査の要:
#   - **撤去の検査は実行時テキスト（skills/ templates/）に掛ける**。docs/ と scripts/ は
#     決定の経緯・廃止キーの案内として語を持つのが正当なため対象外にする（その列挙は PR 本文に残す）。
#   - **検出器の自己検査を持つ**（(A)）。grep は「マッチなし」と「パターンが壊れて検出できない」を
#     区別しないため、既知の違反形をパターンに直接掛けて検出器が生きていることを毎回確認する。
#   - **廃止キーの列挙は scripts/migrate-workspace.rb の CADENCE_RETIRED_KEYS から導く**。
#     テスト側に 2 本目のリストを持たない（ずれても誰も気付かない）。
#   - **cadence.json のキーと run-cycle の参照を両方向で突き合わせる**（(D)）。テンプレートにだけ
#     あるキーは誰も読まない設定になり、run-cycle にだけあるキーは scaffold 先で必ず既定へ縮退する。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

RUN_CYCLE="skills/run-cycle/SKILL.md"
CADENCE_TPL="templates/cadence.json"
MIGRATE="scripts/migrate-workspace.rb"
RUBY="/usr/bin/ruby"
command -v "$RUBY" >/dev/null 2>&1 || RUBY="ruby"

# 実行時テキストに残ってはならない語（定期便の仕組みそのものを指す語）。
RETIRED_RE='start-day|heartbeat-check|CronCreate|定期便|締めジョブ|セッション内 cron'
# `.flywheel/cadence.json` の `<key>` の形でキーを名指ししている箇所。
KEYREF_RE='cadence\.json` の `[A-Za-z_][A-Za-z0-9_.]*`'

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

echo "=== (A) 検出器の自己検査 ==="

for sample in '`/claude-flywheel:start-day` を実行する' 'セッション内 cron で起動' '締めジョブが走る' 'scripts/heartbeat-check.sh'; do
  if printf '%s\n' "$sample" | grep -qE -- "$RETIRED_RE"; then
    pass "(A) 撤去語の検出器が既知の違反形を拾う: ${sample}"
  else
    fail "(A) 撤去語の検出器が既知の違反形を拾う: ${sample}" "検出器が壊れている"
  fi
done
if printf '%s\n' '`/claude-flywheel:run-cycle` を実行する' | grep -qE -- "$RETIRED_RE"; then
  fail "(A) 撤去語の検出器が正当形を拾わない" "誤検出"
else
  pass "(A) 撤去語の検出器が正当形を拾わない"
fi
got="$(printf '%s\n' '`.flywheel/cadence.json` の `reflect.every_n_cycles`（既定 10）' | grep -oE -- "$KEYREF_RE")"
if [ "$got" = 'cadence.json` の `reflect.every_n_cycles`' ]; then
  pass "(A) キー参照の検出器が既知の形を拾う"
else
  fail "(A) キー参照の検出器が既知の形を拾う" "got=${got}"
fi

echo ""
echo "=== (B) 撤去対象が存在しない ==="

for path in skills/start-day scripts/heartbeat-check.sh scripts/tests/heartbeat-check.test.sh; do
  if [ -e "$path" ]; then
    fail "(B) 撤去済み: ${path}" "まだ存在する"
  else
    pass "(B) 撤去済み: ${path}"
  fi
done

echo ""
echo "=== (C) 実行時テキスト（skills/ templates/）に定期便の語が残っていない ==="

n_files="$(find skills templates -type f | grep -c .)"
if [ "$n_files" -ge 1 ]; then
  pass "(C) 走査対象が空でない（${n_files} ファイル）"
else
  fail "(C) 走査対象が空でない" "skills/ templates/ にファイルが無い"
fi
hits="$(grep -rnE -- "$RETIRED_RE" skills templates || true)"
if [ -z "$hits" ]; then
  pass "(C) skills/ templates/ に撤去語（${RETIRED_RE}）が無い"
else
  fail "(C) skills/ templates/ に撤去語（${RETIRED_RE}）が無い" "$(printf '%s' "$hits" | head -5)"
fi
# scripts/ の実コード（コメント行を除く）が撤去したスクリプトを呼んでいない。
raw_calls="$(grep -rn --include='*.sh' --include='*.rb' -e 'heartbeat-check' scripts || true)"
calls="$(printf '%s\n' "$raw_calls" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v -- 'start-day-retirement.test.sh' | grep . || true)"
# 空虚に真にならないよう、コメント行としての言及（validate-artifact.rb の経緯コメント）は拾えていること。
if printf '%s\n' "$raw_calls" | grep -q -- 'scripts/validate-artifact.rb:'; then
  pass "(C) heartbeat-check の走査が scripts/ の既知の言及（経緯コメント）を拾う"
else
  fail "(C) heartbeat-check の走査が scripts/ の既知の言及（経緯コメント）を拾う" "走査が壊れている"
fi
if [ -z "$calls" ]; then
  pass "(C) scripts/ の実コードが heartbeat-check を呼んでいない"
else
  fail "(C) scripts/ の実コードが heartbeat-check を呼んでいない" "$(printf '%s' "$calls" | head -5)"
fi

echo ""
echo "=== (D) cadence.json のテンプレートと run-cycle の参照が一致する ==="

tpl_keys="$("$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0])).keys' "$CADENCE_TPL" 2>/dev/null)"
if [ -n "$tpl_keys" ]; then
  pass "(D) templates/cadence.json のキーを読めた（$(printf '%s' "$tpl_keys" | tr '\n' ' ')）"
else
  fail "(D) templates/cadence.json のキーを読めた" "JSON として読めないかキーが無い"
fi
# run-cycle が名指ししているキーのトップレベル名
ref_keys="$(grep -oE -- "$KEYREF_RE" "$RUN_CYCLE" | sed -E 's/.*`([A-Za-z0-9_]+)[.`].*/\1/' | sort -u)"
for k in $tpl_keys; do
  if printf '%s\n' "$ref_keys" | grep -qx -- "$k"; then
    pass "(D) テンプレートのキー ${k} を run-cycle が参照している"
  else
    fail "(D) テンプレートのキー ${k} を run-cycle が参照している" "誰も読まない設定になっている"
  fi
done
if [ -z "$ref_keys" ]; then
  fail "(D) run-cycle のキー参照を抽出できた" "0 件（検出器か本文の形が変わった）"
fi
for k in $ref_keys; do
  if printf '%s\n' "$tpl_keys" | grep -qx -- "$k"; then
    pass "(D) run-cycle が参照するキー ${k} がテンプレートにある"
  else
    fail "(D) run-cycle が参照するキー ${k} がテンプレートにある" "scaffold 先で必ず既定へ縮退する"
  fi
done
# reflect はネストしたキーまで一致させる（トップレベルだけ一致しても値を読めない）
if "$RUBY" -rjson -e 'n = JSON.parse(File.read(ARGV[0])).dig("reflect", "every_n_cycles"); exit(n.is_a?(Integer) && n > 0 ? 0 : 1)' "$CADENCE_TPL" 2>/dev/null; then
  pass "(D) templates/cadence.json の reflect.every_n_cycles が正の整数"
else
  fail "(D) templates/cadence.json の reflect.every_n_cycles が正の整数"
fi

echo ""
echo "=== (E) 廃止キーが実行時テキストに残っていない（列挙は migrate-workspace.rb から導く） ==="

retired="$("$RUBY" -e '
  src = File.read(ARGV[0], encoding: "UTF-8")
  body = src[/^CADENCE_RETIRED_KEYS = %w\[\n(.*?)^\]\.freeze$/m, 1].to_s
  puts body.split
' "$MIGRATE" 2>/dev/null)"
n_retired="$(printf '%s\n' "$retired" | grep -c .)"
if [ "$n_retired" -ge 1 ]; then
  pass "(E) CADENCE_RETIRED_KEYS を抽出できた（${n_retired} 件）"
else
  fail "(E) CADENCE_RETIRED_KEYS を抽出できた" "0 件（列挙が空か形が変わった）"
fi
for k in $retired; do
  # キー名は識別子として現れる形（`key` / "key" / key.）だけを拾う。`audit` のような一般語が
  # 散文に出ても誤検出しないよう、コード表記に限る。
  hit="$(grep -rnE -- "[\`\"]${k}[\`\".]" skills templates || true)"
  if [ -z "$hit" ]; then
    pass "(E) 廃止キー ${k} が skills/ templates/ に無い"
  else
    fail "(E) 廃止キー ${k} が skills/ templates/ に無い" "$(printf '%s' "$hit" | head -3)"
  fi
done

echo ""
echo "pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed: %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0
