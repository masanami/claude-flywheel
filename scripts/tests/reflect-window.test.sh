#!/usr/bin/env bash
#
# reflect-window.test.sh — reflect の集計窓（「未処理」の判定）と、agent-memory が書き手に
# 見せる experience 雛形の構造不変条件テスト（Issue #137）。
#
# 実行: bash scripts/tests/reflect-window.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・ruby（frontmatter の読み取りと日付判定）。
#   - 読み取り専用。書き込みはしない。
#
# 何を壊れから守るか:
#   実ワークスペースで `reflected: 未処理` というリテラル値が書き込まれ、「フィールドの有無」で
#   判定する素直な実装がそれを「処理済み」に分類して、再発済みの bad を含む 5 件が reflect の
#   集計窓から永久に外れた（Issue #137）。除外は件数が減るだけで報告されず、自然に回復しない。
#   そこで 2 層で塞ぐ: ① 書き手に見せる雛形に書いてはいけない行を置かない（(B)(E)）
#   ② 判定を「日付として解釈できる値があるか」へ変え、読めない値は未処理へ倒す（(C)(D)）。
#
# 検査の要:
#   - **判定規則の正本は skills/reflect/SKILL.md 側に置き、テストはそこから取り出して使う**。
#     テスト側に 2 本目の規則（パターンの写し）を持たない（ずれても誰も気付かない）。
#   - **検出器の自己検査を持つ**（(A)）。grep も正規表現も「マッチなし」と「パターンが壊れて
#     いる」を区別しないため、既知の形を直接掛けて検出器が生きていることを毎回確認する。
#   - **走査対象・抽出結果が空でないことを確認する**（(A)(B)(E)）。0 件の「違反なし」を pass に
#     しない。
#   - **雛形の検査は「その見出しの下の yaml ブロック」に対して行う**。ファイル全体を grep する
#     と、散文側の正当な言及（「reflect だけが付与する」）まで違反として拾ってしまう。
#   - **禁止フィールドの走査は skills/ templates/ 全域の yaml ブロックに掛ける**（(E)）。雛形は
#     コピーされて増えるため、既知の 1 ファイルだけを見ると次の複製で静かに穴が開く。
#     除外のファイル名 allowlist は持たない（規約本文とは別に維持される第 2 のリストになる）。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

AGENT_MEMORY="skills/agent-memory/SKILL.md"
REFLECT="skills/reflect/SKILL.md"
FIXTURES="scripts/tests/fixtures/reflect-window"
RUBY="/usr/bin/ruby"
command -v "$RUBY" >/dev/null 2>&1 || RUBY="ruby"

# reflect が「集計済み」と認める値の形。**正本は $REFLECT 本文**にあり、ここでは取り出すだけ。
EXTRACT_RE_RB='
  src = File.read(ARGV[0], encoding: "UTF-8")
  # 判定を定義している行に置かれた、アンカー付きのパターン（`^...$`）を 1 つだけ取り出す。
  print src[/`(\^[^`\n]+\$)`/, 1].to_s
'

# 与えた値が「処理済み」か「未処理」かを、取り出したパターン＋実在日付の 2 段で判定する。
# nil（フィールドそのものが無い）と空文字は未処理へ倒す（fail-closed）。
CLASSIFY_RB='
  require "date"
  re = Regexp.new(ARGV[0])
  src = File.read(ARGV[1], encoding: "UTF-8")
  fm = src[/\A---[ \t]*\n(.*?)^---[ \t]*\n/m, 1].to_s
  # `\s*` は改行を食うので使わない。値は 1 行の範囲だけを見る。
  raw = fm[/^[ \t]*reflected:[ \t]*(.*)$/, 1]
  value = raw.to_s.strip
  processed = !raw.nil? && !value.empty? && re.match?(value)
  if processed
    begin
      Date.strptime(value, "%Y-%m-%d")
    rescue ArgumentError, TypeError
      processed = false
    end
  end
  puts(processed ? "processed" : "unprocessed")
'

# 見出し直下の yaml ブロックを取り出す（見出しからファイル末尾・次の同位見出しまでの範囲）。
EXTRACT_BLOCK_RB='
  src = File.read(ARGV[0], encoding: "UTF-8")
  heading = ARGV[1]
  section = src[/^#{Regexp.escape(heading)}[ \t]*$(.*?)(?=^#{"#" * heading[/\A#+/].length}[ \t]|\z)/m, 1].to_s
  # フェンスは字下げされていることがある（リスト項目内）。行頭固定にすると静かに取りこぼす。
  print section[/^[ \t]*```yaml[ \t]*\n(.*?)^[ \t]*```[ \t]*$/m, 1].to_s
'

# skills/ templates/ 全域の yaml ブロック内で、禁止フィールドを書いている行を列挙する。
SCAN_BLOCKS_RB='
  banned = /^[ \t]*(reflected|applied_as)[ \t]*:/
  scanned = 0
  ARGV.each do |path|
    src = File.read(path, encoding: "UTF-8") rescue next
    next unless src.valid_encoding?
    # 字下げされたフェンス（リスト項目内）も走査対象にする。行頭固定にすると、
    # 雛形を箇条書きの中へ移すだけで検査を抜けられる。
    src.scan(/^[ \t]*```(?:yaml|yml)[ \t]*\n(.*?)^[ \t]*```[ \t]*$/m) do |(block)|
      scanned += 1
      block.each_line.with_index(1) do |line, i|
        puts "#{path}: #{line.strip}" if line =~ banned
      end
    end
  end
  warn "scanned_blocks=#{scanned}"
'

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

echo "=== (A) 正本からの取り出しと検出器の自己検査 ==="

WINDOW_RE="$("$RUBY" -e "$EXTRACT_RE_RB" "$REFLECT" 2>/dev/null)"
if [ -n "$WINDOW_RE" ]; then
  pass "(A) ${REFLECT} から集計窓の判定パターンを取り出せた（${WINDOW_RE}）"
else
  fail "(A) ${REFLECT} から集計窓の判定パターンを取り出せた" \
       "判定パターン（\`^...\$\`）が本文に無いか形が変わった。テストは正本からしか規則を取らない"
fi

if [ -n "$WINDOW_RE" ]; then
  if "$RUBY" -e 'exit(Regexp.new(ARGV[0]).match?("2026-08-31") ? 0 : 1)' "$WINDOW_RE" 2>/dev/null; then
    pass "(A) 取り出したパターンが実在日付 2026-08-31 を拾う"
  else
    fail "(A) 取り出したパターンが実在日付 2026-08-31 を拾う" "パターンが壊れている: ${WINDOW_RE}"
  fi
  for bad in '未処理' '<YYYY-MM-DD>' 'yes' '2026-8-31'; do
    if "$RUBY" -e 'exit(Regexp.new(ARGV[0]).match?(ARGV[1]) ? 0 : 1)' "$WINDOW_RE" "$bad" 2>/dev/null; then
      fail "(A) 取り出したパターンが日付でない値を拾わない: ${bad}" "誤って処理済みと判定される"
    else
      pass "(A) 取り出したパターンが日付でない値を拾わない: ${bad}"
    fi
  done
fi

n_fix="$(find "$FIXTURES" -type f -name '*.md' 2>/dev/null | grep -c . || true)"
if [ "${n_fix:-0}" -ge 6 ]; then
  pass "(A) フィクスチャが存在する（${n_fix} 件）"
else
  fail "(A) フィクスチャが存在する" "${FIXTURES} に .md が ${n_fix:-0} 件しかない"
fi

echo ""
echo "=== (B) agent-memory の experience 雛形に、書いてはいけない行が無い ==="

BLOCK="$("$RUBY" -e "$EXTRACT_BLOCK_RB" "$AGENT_MEMORY" '### experience 型の追加フィールド（自己改善ループ用）' 2>/dev/null)"
# 抽出の自己検査: 雛形として当然あるべきフィールドが取れていること（空虚に真にしない）。
block_ok=1
for f in 'type: experience' 'outcome:' 'target:' 'signal:' 'confidence:'; do
  if printf '%s\n' "$BLOCK" | grep -q -- "$f"; then
    pass "(B) 雛形ブロックの抽出が生きている: ${f} を含む"
  else
    block_ok=0
    fail "(B) 雛形ブロックの抽出が生きている: ${f} を含む" "見出しか yaml ブロックの形が変わった"
  fi
done

if [ "$block_ok" -eq 1 ]; then
  for banned in 'reflected' 'applied_as'; do
    hit="$(printf '%s\n' "$BLOCK" | grep -nE "^[ \t]*${banned}[ \t]*:" || true)"
    if [ -z "$hit" ]; then
      pass "(B) 雛形ブロックに ${banned} の行が無い"
    else
      fail "(B) 雛形ブロックに ${banned} の行が無い" "$hit"
    fi
  done
fi

# 散文側は残す（誰が付けるのかが読めなくなるため）。
if grep -q 'reflect スキルだけが付与' "$AGENT_MEMORY"; then
  pass "(B) 散文に「reflect スキルだけが付与」が残っている"
else
  fail "(B) 散文に「reflect スキルだけが付与」が残っている" "所在の説明が消えた"
fi
# ブロック直下に「書かない」旨の注記がある（行が消えた理由が雛形の隣で読める）。
if grep -qE '`reflected` / `applied_as` は(この雛形に)?書かない' "$AGENT_MEMORY"; then
  pass "(B) 雛形の隣に「この 2 つは書かない」注記がある"
else
  fail "(B) 雛形の隣に「この 2 つは書かない」注記がある" "行を消しただけでは、次に書き足される"
fi

echo ""
echo "=== (C) 集計窓の判定（3 つの実害ケースを含む） ==="

classify() {
  "$RUBY" -e "$CLASSIFY_RB" "$WINDOW_RE" "$1" 2>/dev/null
}

# フィクスチャ名 期待値
CASES="experience-literal-mishandled.md:unprocessed
experience-empty-value.md:unprocessed
experience-placeholder.md:unprocessed
experience-missing-field.md:unprocessed
experience-invalid-date.md:unprocessed
experience-processed.md:processed"

if [ -z "$WINDOW_RE" ]; then
  fail "(C) 判定ケースを実行できた" "判定パターンを正本から取り出せていないため全ケース未実行"
else
  # パイプで while を回すとサブシェルになり PASS/FAIL の集計が親へ戻らないため、
  # `for` で回す（$CASES の各要素に空白は含まれない）。
  for line in $CASES; do
    name="${line%%:*}"; want="${line##*:}"
    got="$(classify "${FIXTURES}/${name}")"
    if [ "$got" = "$want" ]; then
      pass "(C) ${name} → ${got}"
    else
      fail "(C) ${name} の判定" "want=${want} got=${got}"
    fi
  done
fi

echo ""
echo "=== (D) 判定の定義が「フィールドの有無」に戻っていない ==="

# 旧定義（有無で判定）の言い回しが実行時テキストに残っていないこと。
stale="$(grep -rnE '`?(metadata\.)?reflected`? (が付いていない|の有無)' skills templates || true)"
# 検出器の自己検査（既知の旧定義形を拾えること）。
for sample in '省略時は**未処理＝`metadata.reflected` が付いていない** experience 全部' 'reflect の集計窓の既定「未処理」は `reflected` の有無で判定する'; do
  if printf '%s\n' "$sample" | grep -qE '`?(metadata\.)?reflected`? (が付いていない|の有無)'; then
    pass "(D) 旧定義の検出器が既知の形を拾う"
  else
    fail "(D) 旧定義の検出器が既知の形を拾う" "検出器が壊れている: ${sample}"
  fi
done
if [ -z "$stale" ]; then
  pass "(D) skills/ templates/ に「有無で判定」の旧定義が残っていない"
else
  fail "(D) skills/ templates/ に「有無で判定」の旧定義が残っていない" "$(printf '%s' "$stale" | head -5)"
fi

# fail-closed の向き（読めない値は未処理）が本文に明記されていること。
if grep -q 'fail-closed' "$REFLECT"; then
  pass "(D) ${REFLECT} に fail-closed の明記がある"
else
  fail "(D) ${REFLECT} に fail-closed の明記がある" "倒す向きが読み取れない"
fi
for word in '未処理' '空' 'プレースホルダ'; do
  if grep -q -- "$word" "$REFLECT"; then
    pass "(D) ${REFLECT} が未処理へ倒す値の形を挙げている: ${word}"
  else
    fail "(D) ${REFLECT} が未処理へ倒す値の形を挙げている: ${word}" "実害ケースが読み手に伝わらない"
  fi
done
# 既存ワークスペースへの影響（次回 reflect で拾われること）が本文から追えること。
if grep -qE '既存|移行' "$REFLECT"; then
  pass "(D) ${REFLECT} に既存ワークスペースへの影響の記述がある"
else
  fail "(D) ${REFLECT} に既存ワークスペースへの影響の記述がある" "件数が増える理由が追えない"
fi

echo ""
echo "=== (E) skills/ templates/ 全域の yaml ブロックに禁止フィールドが無い ==="

mapfile_files="$(find skills templates -type f 2>/dev/null)"
n_files="$(printf '%s\n' "$mapfile_files" | grep -c . || true)"
if [ "${n_files:-0}" -ge 1 ]; then
  pass "(E) 走査対象が空でない（${n_files} ファイル）"
else
  fail "(E) 走査対象が空でない" "skills/ templates/ にファイルが無い"
fi

scan_err="$(mktemp -t reflect-window-scan)"
# shellcheck disable=SC2086
hits="$("$RUBY" -e "$SCAN_BLOCKS_RB" $mapfile_files 2>"$scan_err")"
scanned="$(grep -oE 'scanned_blocks=[0-9]+' "$scan_err" | tail -1 | cut -d= -f2)"
rm -f "$scan_err"
if [ "${scanned:-0}" -ge 1 ]; then
  pass "(E) yaml ブロックを走査できた（${scanned} ブロック）"
else
  fail "(E) yaml ブロックを走査できた" "0 ブロック（フェンスの形か走査が壊れている）"
fi
# 走査の自己検査: 既知の違反形を同じ走査に掛けて拾えること。
probe_dir="$(mktemp -d -t reflect-window-probe)"
probe="${probe_dir}/probe.md"
printf '%s\n' '```yaml' 'metadata:' '  reflected: <YYYY-MM-DD>' '  applied_as: <Issue>' '```' > "$probe"
probe_hits="$("$RUBY" -e "$SCAN_BLOCKS_RB" "$probe" 2>/dev/null | grep -c . || true)"
rm -rf "$probe_dir"
if [ "${probe_hits:-0}" -eq 2 ]; then
  pass "(E) 走査が既知の違反形（reflected / applied_as の 2 行）を拾う"
else
  fail "(E) 走査が既知の違反形（reflected / applied_as の 2 行）を拾う" "hits=${probe_hits}"
fi
if [ -z "$hits" ]; then
  pass "(E) skills/ templates/ の yaml ブロックに reflected / applied_as の行が無い"
else
  fail "(E) skills/ templates/ の yaml ブロックに reflected / applied_as の行が無い" "$(printf '%s' "$hits" | head -5)"
fi

echo ""
echo "pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed: %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0
