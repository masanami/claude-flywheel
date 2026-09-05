#!/usr/bin/ruby
# frozen_string_literal: true

# migrate-workspace.rb — 既存ワークスペースを現行テンプレートの構造へ追従させる（Issue #88）。
#
# flywheel-init は「既存ファイルを上書きしない・不足分のみ補完」という冪等 scaffold のため、
# **scaffold 後にテンプレートが更新されても既存ワークスペースは追従できない**。実害として、
# `templates/challenge-ledger.md` に「タスク案」行と承認チェックボックス行が入った後（PR #39）、
# それ以前に scaffold された 2 エージェントが追従できず 3 エージェントで 3 通りのタスク案形式に
# 分岐し、観測プレーン（board）で承認対象が欠落表示（`-`）になった（Issue #87）。
#
# 本スクリプトは flywheel-init の**再実行＝差分適用（マイグレーション）**の決定的な部分を担う。
# スキル本文（散文）には手順だけを置き、判断と変換はここに寄せる（`validate-artifact.rb` と同じ方針）。
#
# 使い方:
#   scripts/migrate-workspace.rb [--workspace <dir>] [--templates-dir <dir>]
#                                [--apply] [--backup-dir <dir>]
#
#   --workspace      ワークスペースのルート（既定: .）
#   --templates-dir  テンプレートの置き場（既定: 本スクリプトからの相対 ../templates。
#                    vendoring 先で層構成が変わる場合に指定）
#   --apply          実際に書き込む。**省略時は dry-run**（何をどう変えるかを提示するだけで
#                    1 バイトも書かない）。ライブデータの構造変換のため既定を安全側に置く
#   --backup-dir     変更前ファイルのバックアップ先（既定: <workspace>/.flywheel/migration-backup/<timestamp>）。
#                    `--apply` 時のみ作成する。**既存ファイルは上書きしない**（世代を失わせない）
#
# exit code:
#   0 = 追従済み（変更不要）／`--apply` で適用完了
#   1 = 失敗（検算で違反を検出・書き込み失敗）。**部分適用も一時ファイルも残さない**
#   2 = 検査不能（引数不正・テンプレート/バリデータ不在・対象が UTF-8 として読めない 等）
#   3 = 要移行（dry-run で変更が必要）。`--apply` では返さない
#
# 自動適用の範囲（線引きの根拠は docs/challenge-ledger-format.md §既存ワークスペースの移行）:
#   - **自動適用するのは `challenge-ledger.md` / `challenge-archive.md` の構造変換だけ**。
#     この 2 つだけが「テンプレート由来の構造」と「運用中のライブデータ」が同居し、
#     ファイル単位の再生成が不可能＝構造マイグレーションでしか追従できない。
#   - それ以外（scaffold 済みドキュメント・設定）は**検出して提示するだけ**で書き換えない。
#     版マーカー（#118）は「どの版から生まれたか」を示すが、生成物の各行が「テンプレートの
#     更新分」なのか「利用先のカスタマイズ」なのかまでは判定できず、自動上書きは利用先の
#     編集を静かに壊すため。マーカーは**検出の網羅性を上げるためだけ**に使う。
#
# ## 非破壊の設計（台帳の機械編集は事故の実績があるため多重化する）
#
# **要**: 「削除してよい行」を**出所（provenance）で証明**する。範囲判定のヒューリスティックを
# 検算の期待値にも使うと、範囲を誤認したときに検算が**空虚に真**になる（誤って消した行が
# 「消す予定だった行」に化ける）。そこで削除は次の 2 つを両方満たす行だけに限る:
#
#   1. **既知テンプレート由来であること**（KNOWN_EXAMPLE_LINES＝現行テンプレートの記入例
#      ブロック ∪ 過去テンプレートの記入例ブロック〔本ファイル末尾の DATA〕に含まれる行）。
#      人間が書き足した行・別セクションは 1 行でも混じっていれば**削除せず人間判断へ倒す**。
#   2. エントリ本文の変更は、**計画した操作で説明できる差分**であること（多重集合で照合）。
#
# さらに:
#   3. **バリデータによる前後比較**: `validate-artifact.rb` を移行前・移行後（候補）に掛け、
#      **移行後の違反が移行前より増えていないこと**（多重集合の差）を要求する。dry-run でも実行する。
#   4. **一時ファイル方式**: 元ファイルを直接書き換えず、検算に通った候補だけを `rename` で置換
#      （docs/challenge-ledger-format.md §台帳を機械で編集するときの規律）。検算用の候補は
#      ワークスペース**外**（TMPDIR）に置き、置換用の一時ファイルは `ensure` で必ず後始末する。
#   5. **バックアップ**（`cp`）と**冪等**（2 回実行しても変化しない）。
#
# 実装言語は /usr/bin/ruby（macOS 標準搭載）。選定根拠と ruby 未導入環境の扱いは
# contracts/README.md §実装言語の選定根拠 / §実行環境の前提。

require "fileutils"
require "tmpdir"

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_UNCHECKABLE = 2
EXIT_PENDING = 3

USAGE = "usage: #{$PROGRAM_NAME} [--workspace <dir>] [--templates-dir <dir>] [--apply] [--backup-dir <dir>]"

def uncheckable(msg)
  warn "migrate-workspace: 検査不能: #{msg}"
  exit EXIT_UNCHECKABLE
end

def failed(msg)
  warn "migrate-workspace: 失敗: #{msg}"
  exit EXIT_FAILED
end

# ---------------------------------------------------------------------------
# 読み込み（改行コードを保存する）
# ---------------------------------------------------------------------------

# 戻り値: { lines: [改行・CR を含まない行], eol: "\n" | "\r\n", error: nil | 理由 }
# CRLF と LF が混在するファイルは**触らない**（どちらへ寄せても人間の意図を壊しうるため）。
def read_lines(file)
  begin
    content = File.read(file, encoding: "UTF-8")
  rescue SystemCallError => e
    uncheckable("読み取れません: #{file}（#{e.message}）")
  end
  uncheckable("UTF-8 として解釈できません: #{file}") unless content.valid_encoding?
  lines = content.split("\n", -1)
  lines.pop if lines.last == "" # 末尾改行によるダミー要素を除く
  crlf = lines.count { |l| l.end_with?("\r") }
  if crlf.zero?
    { lines: lines, eol: "\n", error: nil }
  elsif crlf == lines.size
    { lines: lines.map { |l| l[0..-2] }, eol: "\r\n", error: nil }
  else
    { lines: lines, eol: "\n",
      error: "改行コードが CRLF と LF で混在している（#{crlf}/#{lines.size} 行が CRLF）。" \
             "どちらへ寄せても人間の意図を壊しうるため移行しない。改行を揃えてから再実行すること" }
  end
end

# フェンス・複数行 HTML コメントを除外して「検査対象か」を各行に付ける。
# **`validate-artifact.rb` の annotate_exclusions と同じ意味論**（台帳のどこがデータで
# どこが記入例かの判定は 1 つでなければならない）。両者の一致は、移行後のファイルを
# 実際に `validate-artifact.rb` へ通す検算で固定する。
def annotate_exclusions(lines)
  in_fence = false
  in_comment = false
  lines.map do |line|
    included = true
    if in_comment
      included = false
      in_comment = false if line.include?("-->")
    elsif line =~ /^```/
      in_fence = !in_fence
      included = false
    elsif in_fence
      included = false
    else
      opens = line.rindex("<!--")
      in_comment = true if opens && !line.index("-->", opens)
      included = false if line.strip.start_with?("<!--") && in_comment
    end
    included
  end
end

ENTRY_HEADING_RE = /^### \[/.freeze

# フェンス（``` … ```）の内側／フェンス行そのものかどうか。記入例ブロックの検出では
# 「複数行 HTML コメントの開始行」も拾いたい（annotate_exclusions ではその行が除外側に
# 落ちる）ため、フェンス判定だけを別に持つ。
def fence_flags(lines)
  in_fence = false
  lines.map do |line|
    if line =~ /^```/
      in_fence = !in_fence
      true
    else
      in_fence
    end
  end
end

# 見出し行の位置（フェンス・コメント内を除く）。
def entry_heading_indexes(lines)
  included = annotate_exclusions(lines)
  (0...lines.size).select { |i| included[i] && lines[i] =~ ENTRY_HEADING_RE }
end

# ---------------------------------------------------------------------------
# 既知テンプレート（削除してよい行の出所）
# ---------------------------------------------------------------------------

# 過去テンプレートの記入例ブロックに現れた行（本ファイル末尾 DATA）。
# **テンプレートの記入例を変更したら、変更前の行をここへ追記すること**（追記漏れは
# `scripts/tests/migrate-workspace.test.sh` の「現行テンプレートの記入例行が既知集合に含まれる」
# テストが検出する）。この集合が「機械が削除してよい行」の唯一の根拠になる。
def legacy_example_lines
  @legacy_example_lines ||= begin
    body = DATA.read.split("\n", -1)
    body.map { |l| l.sub(/\r\z/, "") }.reject { |l| l.strip.empty? }
  end
end

# テンプレートから記入例ブロック（マーカーコメント〜末尾の `---`）を切り出す。
def canonical_example_block(template_path)
  uncheckable("テンプレートがありません: #{template_path}") unless File.exist?(template_path)
  r = read_lines(template_path)
  uncheckable("テンプレートの改行コードが混在しています: #{template_path}") if r[:error]
  lines = r[:lines]
  start = lines.index { |l| l.start_with?(EXAMPLE_MARKER_PREFIX) }
  uncheckable("テンプレートに記入例のマーカー（`#{EXAMPLE_MARKER_PREFIX}…`）がありません: #{template_path}") if start.nil?
  last = nil
  (start...lines.size).each { |i| last = i if lines[i] == "---" }
  uncheckable("テンプレートの記入例ブロックの終端（`---`）が見つかりません: #{template_path}") if last.nil?
  lines[start..last]
end

EXAMPLE_MARKER_PREFIX = "<!-- 新しい課題は"
EXAMPLE_HEADING_LINE = "## 記入例（コピーして使う）"
EXAMPLE_COMMENT_OPEN = "<!-- 記入例（コピーして使う）"

# ---------------------------------------------------------------------------
# エントリの構造マイグレーション
# ---------------------------------------------------------------------------

CLASSIFY_HEADING_RE = /^\*\*分類欄/.freeze
HUMAN_HEADING_RE = /^\*\*人間記入欄/.freeze
BOLD_TASK_PLAN_RE = /^\*\*タスク案/.freeze

# 分類欄フィールドの正規順序（templates/challenge-ledger.md の記入例と同じ並び）。
# 欠落フィールドの挿入位置はこの順序から決める（**既存行は並べ替えない**＝差分を最小にし、
# 「触るべきでない行を触らない」を守るため）。
# `人間への問い` / `人間の回答`（保留プロトコル・#116）は**順序を知るためだけ**にここへ置く。
# 保留に入ったエントリにしか現れない任意フィールドなので、下の挿入対象には入れない
# （空の欄を全エントリへ足しても埋まらず、台帳を太らせるだけ）。
CLASSIFY_FIELD_ORDER = [
  "担当ポジション", "関連サービス", "関連リポジトリ", "関連Issue", "関連PR",
  "優先度", "ステータス", "人間への問い", "人間の回答", "タスク案",
  "承認（人間がチェック）", "取り込み元", "備考"
].freeze

# 欠落していたら補う必須フィールド行（バリデータの LEDGER_REQUIRED_LINES のうち**分類欄側**）。
# 人間記入欄のフィールド（起票者 / 説明）は**機械が捏造しない**（欠落は報告に留める）。
REQUIRED_CLASSIFY_INSERTS = [
  ["担当ポジション", ["- 担当ポジション:"]],
  ["優先度", ["- 優先度:"]],
  ["ステータス", ["- ステータス:"]],
  ["タスク案", ["- タスク案:"]],
  ["承認（人間がチェック）", ["- 承認（人間がチェック）:",
                             "  - [ ] 計画を承認（FR-13・承認対象＝タスク案）",
                             "  - [ ] 完了を承認（FR-32）"]],
  ["備考", ["- 備考:"]],
].freeze

# 台帳のみ補う任意フィールド（参照フィールド。docs/challenge-ledger-format.md
# §関連リポジトリ・関連Issue・関連PR が「既存ワークスペースへの行追加は #88 の対象」と定める）。
# **アーカイブには追加しない**: 参照フィールドは run-cycle が計画時・PR 作成時に埋める欄であり、
# 完了済みエントリの履歴に空行を足しても埋まらない（原文保存の履歴を無駄に書き換えない）。
LEDGER_ONLY_INSERTS = [
  ["関連リポジトリ", ["- 関連リポジトリ:"]],
  ["関連Issue", ["- 関連Issue:"]],
  ["関連PR", ["- 関連PR:"]],
].freeze

# 承認チェックボックス。**strict** は正規形（消費側・バリデータが同定に使う形）、
# **loose** は「人間が書いた承認チェックらしき行」を広く拾うための検出用。
# loose に一致するが strict に一致しない行があるエントリでは、機械は**何も足さない**
# （足すと未チェック行が並んで既存の `[x]` が実質無効化されるため。承認の状態を変えうる
# 操作は必ず人間へ見せる＝ docs/challenge-ledger-format.md §承認プロトコル §真正性）。
APPROVAL_BOXES = [
  ["計画を承認", /^ {2}- \[[ xX]\] 計画を承認/, /\A\s*[-*+]\s*\[[ xX]\]\s*計画/,
   "  - [ ] 計画を承認（FR-13・承認対象＝タスク案）"],
  ["完了を承認", /^ {2}- \[[ xX]\] 完了を承認/, /\A\s*[-*+]\s*\[[ xX]\]\s*完了/,
   "  - [ ] 完了を承認（FR-32）"],
].freeze

def field_line_re(label)
  /^- #{Regexp.escape(label)}:/
end

# 多重集合（行 → 出現回数）。**空行は数えない**: 空行の位置の正しさ（見出し直前の空行・
# 分類欄のネスト項目の途中の空行）はバリデータが専門に検査するため、こちらは
# 「内容の行が保存されているか」に絞る。
def multiset(lines)
  lines.each_with_object(Hash.new(0)) do |l, h|
    next if l.strip.empty?
    h[l] += 1
  end
end

def multiset_diff(a, b)
  ma = a.is_a?(Hash) ? a : multiset(a)
  mb = b.is_a?(Hash) ? b : multiset(b)
  out = Hash.new(0)
  ma.each { |k, v| d = v - mb[k]; out[k] = d if d > 0 }
  out
end

def multiset_merge(a, b)
  out = a.dup
  b.each { |k, v| out[k] = out[k].to_i + v }
  out
end

def fmt_ms(ms)
  return "なし" if ms.empty?
  ms.map { |k, v| "#{k[0, 40]}×#{v}" }.join(" / ")
end

# 本文を「人間記入欄 / 分類欄 / いずれでもない」に区分する（**位置関係を仮定しない**。
# 分類欄が先・人間記入欄が後という構成でも人間の欄を機械が触らないため）。
# フェンス・HTML コメントの中（記入例のサンプル）は区分の切り替えに使わない。
def section_flags(body, inc = nil)
  inc ||= annotate_exclusions(body)
  cur = nil
  body.each_with_index.map do |l, i|
    if inc[i]
      cur = :human if l =~ HUMAN_HEADING_RE
      cur = :classify if l =~ CLASSIFY_HEADING_RE
    end
    cur
  end
end

# 本文中の「実データの行」だけを対象にした存在判定・計数（記入例のサンプル行を実フィールドと
# 誤認しないため。台帳末尾の記入例が最終エントリの本文に含まれる形が実在する）。
def any_line?(body, re, inc = nil)
  inc ||= annotate_exclusions(body)
  body.each_with_index.any? { |l, i| inc[i] && l =~ re }
end

def count_lines(body, re, inc = nil)
  inc ||= annotate_exclusions(body)
  body.each_with_index.count { |l, i| inc[i] && l =~ re }
end

def find_line_index(body, re, inc = nil)
  inc ||= annotate_exclusions(body)
  body.each_index.find { |i| inc[i] && body[i] =~ re }
end

# フィールド行に続く継続行（インデント行・引用行）の末尾位置を返す（上限つき）。
def field_block_end(lines, idx, limit)
  j = idx
  while j + 1 <= limit
    nxt = lines[j + 1]
    break unless nxt =~ /^[ \t]+\S/ || nxt.start_with?(">")
    j += 1
  end
  j
end

# 分類欄見出し直後の**連続するフィールド行の並び**の末尾位置（挿入位置の探索範囲）。
# 空行・フィールドでも継続行でもない行（記入例の残骸・太字見出し等）で打ち切る。
def classify_field_run_end(lines, ci)
  last = ci
  i = ci + 1
  while i < lines.size
    l = lines[i]
    break if l.strip.empty?
    if l =~ /^- [^:]+:/ || l =~ /^[ \t]+\S/ || l.start_with?(">")
      last = i
      i += 1
    else
      break
    end
  end
  last
end

# 正規順序に照らした挿入位置（**分類欄の連続フィールド並びの中**に限る）。
def classify_insert_position(lines, ci, label)
  want = CLASSIFY_FIELD_ORDER.index(label)
  run_end = classify_field_run_end(lines, ci)
  at = ci + 1
  (ci + 1..run_end).each do |i|
    m = /^- ([^:]+):/.match(lines[i])
    next unless m
    pos = CLASSIFY_FIELD_ORDER.index(m[1])
    next if pos.nil? || pos >= want
    at = field_block_end(lines, i, run_end) + 1
  end
  at
end

# 1 エントリ分の変換。戻り値は変換後の body と、検算に使う「計画した差分」。
def migrate_entry(heading, body, kind)
  ops = []
  removed = []
  added = []
  manual = []
  work = body.dup
  label = heading[/\A### \[([^\]]*)\]/, 1] || heading[0, 40]

  # 判定はすべて**実データの行**に限る（フェンス・HTML コメント内の記入例サンプルを
  # 実フィールドと誤認すると、存在するはずの行を「無い」と誤判定して二重に足してしまう）。
  ci = find_line_index(work, CLASSIFY_HEADING_RE)
  if ci.nil?
    manual << "#{label}: 分類欄（`**分類欄…**`）が見つからないため自動変換を行わない"
    return { body: work, ops: ops, removed: removed, added: added, manual: manual }
  end

  # (1) 旧ラベル `- 承認:` を現行の `- 承認（人間がチェック）:` へ改名する。
  #     チェック状態（`[x]`）は直下のネスト行にあり、この改名では一切触れない。
  #     **分類欄セクションの実データ行だけ**を対象にする（人間記入欄の自由記述を書き換えない）。
  inc = annotate_exclusions(work)
  sections = section_flags(work, inc)
  work.each_index do |i|
    next unless inc[i] && sections[i] == :classify
    m = /^- 承認:(.*)$/.match(work[i])
    next unless m
    if any_line?(work, field_line_re("承認（人間がチェック）"))
      manual << "#{label}: `- 承認:` と `- 承認（人間がチェック）:` が同居しているため改名しない（人間が整理すること）"
      next
    end
    renamed = "- 承認（人間がチェック）:#{m[1]}"
    removed << work[i]
    added << renamed
    work[i] = renamed
    ops << "#{label}: 承認ラベルを現行化（`- 承認:` → `- 承認（人間がチェック）:`）"
  end

  # (2) 形 E（フィールド行を持たない太字見出しブロック）を `- タスク案:` ＋ネスト項目へ正規化する。
  #     **収集はブロックの全項目を尽くすことを要求**し、尽くせない形（項目以外の行が混じる）は
  #     **一切変換しない**（部分変換を「変換した」と報告すると、承認対象の中身が欠落する）。
  task_items = nil
  task_provenance = nil
  bold_unconverted = false
  unless any_line?(work, field_line_re("タスク案"))
    inc = annotate_exclusions(work)
    sections = section_flags(work, inc)
    bi = (0...work.size).find { |i| inc[i] && sections[i] == :classify && work[i] =~ BOLD_TASK_PLAN_RE }
    if bi
      last = work.size - 1
      last -= 1 while last > bi && work[last].strip.empty?
      body_lines = ((bi + 1)..last).map { |i| work[i] }
      non_blank = body_lines.reject { |l| l.strip.empty? }
      stray = non_blank.reject { |l| l =~ /^\d+[.)]\s/ || l =~ /^[ \t]+\S/ }
      if non_blank.empty? || non_blank.none? { |l| l =~ /^\d+[.)]\s/ }
        bold_unconverted = true
        manual << "#{label}: 太字見出しのタスク案ブロックの直下に番号付きリストが見つからないため変換しない（#{work[bi][0, 40]}）"
      elsif !stray.empty?
        bold_unconverted = true
        manual << "#{label}: 太字見出しのタスク案ブロックに項目以外の行が混じっており、どこまでがタスク案か機械では決められないため**一切変換しない**" \
                  "（該当: #{stray.first[0, 40]}）。人間がブロックを整理してから再実行すること"
      elsif work[bi].include?("-->")
        bold_unconverted = true
        manual << "#{label}: 太字見出しに `-->` を含むため変換しない（HTML コメントとして保全できない）: #{work[bi][0, 40]}"
      else
        task_items = non_blank.map { |l| "  #{l}" }
        task_provenance = "<!-- 移行前の記載（#88）: #{work[bi]} -->"
        removed.concat(work[bi..last])
        drop_from = bi
        drop_from = bi - 1 if bi > 0 && work[bi - 1].strip.empty?
        work.slice!(drop_from, last - drop_from + 1)
        ops << "#{label}: 太字見出しのタスク案ブロックを `- タスク案:` ＋ネスト項目へ変換（#{task_items.size} 項目）"
        ci = find_line_index(work, CLASSIFY_HEADING_RE)
      end
    end
  end

  # (2b) 承認チェック行の状態を調べる。loose に一致するが strict でない行があれば
  #      **承認まわりには一切手を出さない**（重複追加による `[x]` の無効化を禁止する）。
  approval_ambiguous = []
  APPROVAL_BOXES.each do |name, strict, loose, _|
    next if any_line?(work, strict)
    inc2 = annotate_exclusions(work)
    hit = work.each_index.find { |i| inc2[i] && work[i] =~ loose }
    approval_ambiguous << [name, work[hit]] if hit
  end
  approval_ambiguous.each do |name, hit|
    manual << "#{label}: 「#{name}」のチェック行が正規形（行頭に半角スペース 2 個＋`- [ ] #{name}…`）でないため" \
              "**承認欄には一切手を出さない**（未チェック行を足すと既存のチェックが実質無効化されるため）。該当行: #{hit.strip[0, 40]}"
  end

  # (3) 欠落している分類欄フィールド行を正規順序の位置へ挿入する。
  inserts = REQUIRED_CLASSIFY_INSERTS.dup
  inserts += LEDGER_ONLY_INSERTS if kind == "ledger"
  inserts = inserts.sort_by { |lbl, _| CLASSIFY_FIELD_ORDER.index(lbl) }

  inserted_approval = false
  inserts.each do |lbl, template_lines|
    next if any_line?(work, field_line_re(lbl))
    # 変換できなかった太字ブロックが残っている間は空の `- タスク案:` を足さない
    # （実体は下のブロックにあるのに「未記入」と読める行を作らない）。
    next if lbl == "タスク案" && bold_unconverted
    # 承認の形が判定できないエントリには足さない（(2b)）。
    next if lbl == "承認（人間がチェック）" && !approval_ambiguous.empty?
    inserted_approval = true if lbl == "承認（人間がチェック）"
    new_lines = template_lines.dup
    new_lines = [task_provenance, "- タスク案:"] + task_items if lbl == "タスク案" && task_items
    at = classify_insert_position(work, ci, lbl)
    work.insert(at, *new_lines)
    added.concat(new_lines)
    ops << if lbl == "タスク案" && task_items
             "#{label}: `- タスク案:` 行を分類欄へ挿入（変換したネスト項目つき）"
           else
             "#{label}: 欠落フィールド行を挿入: #{lbl}"
           end
    ci = find_line_index(work, CLASSIFY_HEADING_RE)
  end

  # (3b) 承認フィールドはあるがチェックボックス行が欠けている場合の補完
  #      （形が判定できるエントリに限る）。
  ai = find_line_index(work, field_line_re("承認（人間がチェック）"))
  if ai && approval_ambiguous.empty?
    APPROVAL_BOXES.each do |name, strict, _, line|
      next if any_line?(work, strict)
      run_end = classify_field_run_end(work, find_line_index(work, CLASSIFY_HEADING_RE))
      at = field_block_end(work, ai, run_end) + 1
      work.insert(at, line)
      added << line
      inserted_approval = true
      ops << "#{label}: 承認チェックボックス行を補完: #{name}"
      ai = find_line_index(work, field_line_re("承認（人間がチェック）"))
    end
  end

  # (4) 機械で決められないもの（人間判断へ倒す）
  # 承認は**機械が代筆してはならない**（承認プロトコルの真正性）。旧形式では承認事実が
  # 見出し文言（`**タスク案（FR-13・承認済み …）**`）や「アーカイブ済み＝完了承認を経ている」
  # という文脈にしか無いことがあるが、**移行では常に未チェックで新設し、チェックは人間に委ねる**。
  if inserted_approval && !any_line?(work, /^ {2}- \[[xX]\] 計画を承認/)
    status = (work.find { |l| l =~ /^- ステータス:/ } || "- ステータス:").sub(/^- ステータス:\s*/, "").strip
    src = task_provenance ? "旧見出しの文言（#{task_provenance}）" : "ステータス「#{status.empty? ? '（空欄）' : status}」"
    manual << "#{label}: 承認チェックボックスを**未チェックで新設**した（過去の承認の手がかり: #{src}）。" \
              "**`[x]` は自動で付けない**——人間が内容を確認してチェックすること"
  end
  REQUIRED_CLASSIFY_INSERTS.each do |lbl, _|
    c = count_lines(work, field_line_re(lbl))
    manual << "#{label}: 「#{lbl}」行が #{c} 回出現している（見出し破損・記入例の残骸の可能性。自動では直さない）" if c > 1
  end
  unless any_line?(work, HUMAN_HEADING_RE)
    manual << "#{label}: 人間記入欄（`**人間記入欄**`）が無い（機械は人間の欄を捏造しない）"
  end

  { body: work, ops: ops, removed: removed, added: added, manual: manual }
end

# ---------------------------------------------------------------------------
# 記入例ブロックの現行化（台帳のみ）
# ---------------------------------------------------------------------------

# 既存ファイル内の記入例ブロックの範囲（[start, end] の配列）。
# **アンカーは完全一致**（前方一致にすると `## 記入例の運用メモ` のような人間のセクションを
# 巻き込む）。実在する 3 形すべてを扱う:
#   - `## 記入例（コピーして使う）` ＋ フェンス
#   - `<!-- 記入例（コピーして使う）` … `-->`（入れ子コメントで途中閉じしていてもよい）
#   - マーカーコメント行（`<!-- 新しい課題は…`。既知テンプレートに現れた文言に限る）
def find_example_regions(lines, known)
  included = annotate_exclusions(lines)
  fenced = fence_flags(lines)
  regions = []
  i = 0
  while i < lines.size
    line = lines[i]
    if !fenced[i] && line.start_with?(EXAMPLE_MARKER_PREFIX) && known.include?(line)
      regions << [i, i]
      i += 1
      next
    end
    if !fenced[i] && (line == EXAMPLE_HEADING_LINE || line == EXAMPLE_COMMENT_OPEN)
      j = i
      k = i + 1
      while k < lines.size
        break if included[k] && (lines[k] =~ ENTRY_HEADING_RE || lines[k].start_with?("## "))
        j = k
        k += 1
      end
      j -= 1 while j > i && lines[j].strip.empty?
      regions << [i, j]
      i = j + 1
      next
    end
    i += 1
  end
  regions
end

# 記入例ブロックの現行化。台帳（ledger）専用。
#   { lines:, ops:, manual:, dropped: 実際に削除した範囲 }
def migrate_example_block(lines, canonical, known)
  ops = []
  manual = []
  regions = find_example_regions(lines, known)
  included = annotate_exclusions(lines)

  # 安全ガード 1: 記入例と判定した範囲に**実エントリ**が紛れていたら手を出さない。
  regions.each do |s, e|
    heads = (s..e).select { |i| lines[i] =~ ENTRY_HEADING_RE }
    bad = heads.find { |i| lines[i] !~ /</ }
    bad ||= heads[1] if heads.size > 1
    bad ||= (s..e).find { |i| included[i] && (lines[i] =~ ENTRY_HEADING_RE || lines[i] =~ HUMAN_HEADING_RE) }
    next if bad.nil?
    manual << "記入例ブロックと判定した範囲（#{s + 1}〜#{e + 1} 行）に実エントリらしい行があるため、" \
              "記入例の現行化を行わない（記入例の閉じ忘れ等。人間が範囲を直してから再実行する）: #{lines[bad][0, 40]}"
    return { lines: lines, ops: ops, manual: manual, dropped: [], applied: false }
  end

  # 安全ガード 2（**削除の出所を証明する**）: 削除しようとする行がすべて既知テンプレート由来
  # であること。人間が書き足した行・別セクションが 1 行でも混じっていたら削除しない。
  regions.each do |s, e|
    unknown = (s..e).select { |i| !lines[i].strip.empty? && !known.include?(lines[i]) }
    next if unknown.empty?
    shown = unknown.first(3).map { |i| "#{i + 1} 行目: #{lines[i][0, 50]}" }.join(" / ")
    manual << "記入例ブロック（#{s + 1}〜#{e + 1} 行）に既知テンプレートに無い行が #{unknown.size} 行あるため、" \
              "記入例の現行化を行わない（人間が書き足した内容を機械が消さないため。人間が現行テンプレートの" \
              "記入例へ差し替えるか、独自の記述を別の見出しへ移してから再実行する）: #{shown}"
    return { lines: lines, ops: ops, manual: manual, dropped: [], applied: false }
  end

  drop = regions.each_with_object({}) { |(s, e), h| (s..e).each { |i| h[i] = true } }
  kept = (0...lines.size).reject { |i| drop[i] }.map { |i| lines[i] }

  # 挿入位置: 前文の区切り（最初の `---`）の直後。無ければ最初のエントリ見出しの直前。
  kept_included = annotate_exclusions(kept)
  hr = (0...kept.size).find { |i| kept_included[i] && kept[i] == "---" }
  anchor =
    if hr
      hr + 1
    else
      first_entry = (0...kept.size).find { |i| kept_included[i] && kept[i] =~ ENTRY_HEADING_RE }
      first_entry || kept.size
    end

  head = kept[0, anchor]
  tail = kept[anchor..-1] || []
  head.pop while !head.empty? && head.last.strip.empty?
  tail.shift while !tail.empty? && tail.first.strip.empty?

  rebuilt = head + [""] + canonical
  rebuilt += [""] + tail unless tail.empty?

  unless rebuilt == lines
    ops << if regions.empty?
             "記入例ブロックを現行テンプレートから追加した"
           else
             "記入例ブロックを現行テンプレートへ差し替えた"
           end
  end
  { lines: rebuilt, ops: ops, manual: manual, dropped: regions,
    applied: !(regions.empty? && rebuilt == lines) }
end

# ---------------------------------------------------------------------------
# ファイル単位の移行（台帳・アーカイブ）
# ---------------------------------------------------------------------------

# テスト専用の故障注入。検算が本当に部分適用を止めることを固定するために使う。
# 運用では設定しない（未設定なら何もしない）。
FAULT = ENV["MIGRATE_WORKSPACE_INJECT_FAULT"]

def inject_fault!(lines)
  case FAULT
  when nil, ""
    lines
  when "marker-always-current", "marker-skip-heading-delta"
    # 版マーカー検査側で解釈する故障。行は変えない（scaffold 追従レポートは書き込みを伴わない）。
    lines
  when "fail-after-stage"
    # 行は変えない。置換直前（一時ファイル作成後）に中断させ、`ensure` の後始末を固定する。
    lines
  when "drop-note"
    # エントリ本文の「触るべきでない行」を 1 行落とす（巻き添え削除の再現）。
    i = (0...lines.size).to_a.reverse.find { |n| lines[n] =~ /^- 備考:/ }
    lines.delete_at(i) if i
    lines
  when "uncheck-approval"
    lines.map { |l| l.sub(/^( {2}- \[)[xX](\] .*)$/, '\1 \2') }
  when "drop-entry"
    i = entry_heading_indexes(lines).first
    lines.delete_at(i) if i
    lines
  when "drop-preamble-line"
    # 記入例ブロック（前文）側の行を 1 行落とす。
    i = lines.index { |l| l =~ /^- 担当ポジション:/ }
    lines.delete_at(i) if i
    lines
  when "steal-human-line"
    # **記入例ブロックの範囲を誤認して人間の行を消した**状況の再現（出所の検証だけが検出できる）。
    i = lines.index { |l| l.start_with?("> ") && !l.include?("記入形式") }
    lines.delete_at(i) if i
    lines
  when "move-blank-into-nest"
    # 同一エントリ内での**空行の移動**（多重集合は不変＝差分検算をすり抜ける）。
    # ネスト項目の直前に空行が入ると分類欄の結合切れになり、バリデータ前後比較だけが検出できる。
    # 対象は**実データの行**に限る（記入例ブロックにもネスト項目があるため。記入例側を崩すと
    # 「記入例ブロックが現行テンプレートどおりでない」検査が先に落ち、再現したい経路を通らない）。
    k = find_line_index(lines, /^ {2}\d+[.)] /)
    return lines if k.nil?
    h = (0...k).to_a.reverse.find { |i| lines[i] =~ ENTRY_HEADING_RE } || 0
    b = ((h + 1)...k).find { |i| lines[i].strip.empty? }
    return lines if b.nil?
    lines.delete_at(b)
    lines.insert(k - 1, "")
    lines
  else
    uncheckable("未知の故障注入: #{FAULT}")
  end
end

def strip_ranges(lines, ranges)
  drop = ranges.each_with_object({}) { |(s, e), h| (s..e).each { |i| h[i] = true } }
  (0...lines.size).reject { |i| drop[i] }.map { |i| lines[i] }
end

# `needle` が `haystack` の連続部分列として現れる先頭位置（無ければ nil）。
def find_subsequence(haystack, needle)
  return nil if needle.empty?
  (0..(haystack.size - needle.size)).each do |i|
    return i if haystack[i, needle.size] == needle
  end
  nil
end

# 見出しで切ったエントリ（行番号演算ではなく見出しパターンで切る）。
def split_entries(lines)
  idxs = entry_heading_indexes(lines)
  idxs.each_with_index.map do |at, n|
    stop = idxs[n + 1] || lines.size
    { at: at, heading: lines[at], body: lines[(at + 1)...stop] }
  end
end

def migrate_file(path, kind, canonical, known)
  r = read_lines(path)
  if r[:error]
    return { path: path, kind: kind, before: r[:lines], after: r[:lines], eol: r[:eol],
             ops: [], manual: ["#{File.basename(path)}: #{r[:error]}"], errors: [] }
  end
  lines = r[:lines]
  ops = []
  manual = []

  base = lines
  dropped = []
  example_applied = false
  if kind == "ledger"
    ex = migrate_example_block(lines, canonical, known)
    base = ex[:lines]
    dropped = ex[:dropped]
    example_applied = ex[:applied]
    ops.concat(ex[:ops])
    manual.concat(ex[:manual])
  end

  base_entries = split_entries(base)
  new_lines = []
  new_lines.concat(base[0, base_entries.empty? ? base.size : base_entries.first[:at]])
  plans = []
  base_entries.each do |ent|
    plan = migrate_entry(ent[:heading], ent[:body], kind)
    plans << plan
    ops.concat(plan[:ops])
    manual.concat(plan[:manual])
    new_lines << ent[:heading]
    new_lines.concat(plan[:body])
  end

  new_lines = inject_fault!(new_lines) if FAULT && !FAULT.empty?

  errors = verify(lines, new_lines, plans, dropped, canonical, known, example_applied)

  { path: path, kind: kind, before: lines, after: new_lines, eol: r[:eol],
    ops: ops, manual: manual, errors: errors }
end

# ---------------------------------------------------------------------------
# 検算（元ファイルから独立に再計算した期待値と突き合わせる）
# ---------------------------------------------------------------------------

def verify(orig, final, plans, dropped, canonical, known, example_applied)
  errors = []

  # (a) **出所の検証**: 記入例の差し替えで消えた行は、すべて既知テンプレート由来でなければ
  #     ならない。範囲判定のヒューリスティックを期待値に使わない唯一の防波堤。
  dropped_lines = dropped.flat_map { |s, e| (s..e).map { |i| orig[i] } }
  unproven = dropped_lines.reject { |l| l.strip.empty? || known.include?(l) }
  unless unproven.empty?
    errors << "記入例として削除した行に既知テンプレート由来でない行がある（削除範囲の誤認）: #{unproven.first(3).map { |l| l[0, 40] }.join(' / ')}"
  end

  # (b) **全行の多重集合照合**: 消えた行・増えた行の総体が「計画した操作」で説明できること。
  #     削除範囲を両側から除外しないので、範囲誤認・想定外の欠落がここに現れる。
  plan_removed = plans.each_with_object(Hash.new(0)) { |p, h| multiset(p[:removed]).each { |k, v| h[k] += v } }
  plan_added = plans.each_with_object(Hash.new(0)) { |p, h| multiset(p[:added]).each { |k, v| h[k] += v } }
  expect_removed = multiset_merge(plan_removed, multiset(dropped_lines))
  canonical_added = example_applied ? multiset(canonical) : Hash.new(0)
  expect_added = multiset_merge(plan_added, canonical_added)
  # 実際には出入りが相殺される行があるため、両方向を打ち消してから比べる。
  actual_removed = multiset_diff(orig, final)
  actual_added = multiset_diff(final, orig)
  net_removed = multiset_diff(expect_removed, expect_added)
  net_added = multiset_diff(expect_added, expect_removed)
  if actual_removed != net_removed
    errors << "計画外の行が消えている/消えるはずの行が残っている（ファイル全体）: " \
              "実際=#{fmt_ms(multiset_diff(actual_removed, net_removed))} 期待にあって実際に無い=#{fmt_ms(multiset_diff(net_removed, actual_removed))}"
  end
  if actual_added != net_added
    errors << "計画外の行が増えている/増えるはずの行が無い（ファイル全体）: " \
              "実際=#{fmt_ms(multiset_diff(actual_added, net_added))} 期待にあって実際に無い=#{fmt_ms(multiset_diff(net_added, actual_added))}"
  end

  # (c) **エントリ単位の照合**（誤りの局在を出す）。記入例ブロックを両側から取り除いた像で比べる。
  orig_wo = strip_ranges(orig, dropped)
  final_wo = final
  if example_applied
    at = find_subsequence(final, canonical)
    if at.nil?
      errors << "記入例ブロックが現行テンプレートどおりに挿入されていない（検算できないため適用しない）"
      return errors
    end
    final_wo = final[0, at] + (final[(at + canonical.size)..-1] || [])
  end
  a = split_entries(orig_wo)
  b = split_entries(final_wo)
  if a.map { |e| e[:heading] } != b.map { |e| e[:heading] }
    errors << "エントリ見出しの並びが変化した（移行はエントリの追加・削除・並べ替えを行わない）: " \
              "移行前 #{a.size} 件 / 移行後 #{b.size} 件"
    return errors
  end
  a.each_with_index do |ent, i|
    plan = plans[i]
    actual_rm = multiset_diff(ent[:body], b[i][:body])
    actual_ad = multiset_diff(b[i][:body], ent[:body])
    expect_rm = multiset_diff(plan[:removed], plan[:added])
    expect_ad = multiset_diff(plan[:added], plan[:removed])
    if actual_rm != expect_rm
      errors << "#{ent[:heading][0, 50]}: 計画外の行が消えている/消えるはずの行が残っている: " \
                "実際=#{fmt_ms(actual_rm)} 期待=#{fmt_ms(expect_rm)}"
    end
    if actual_ad != expect_ad
      errors << "#{ent[:heading][0, 50]}: 計画外の行が増えている/増えるはずの行が無い: " \
                "実際=#{fmt_ms(actual_ad)} 期待=#{fmt_ms(expect_ad)}"
    end
  end
  errors
end

# ---------------------------------------------------------------------------
# バリデータによる前後比較
# ---------------------------------------------------------------------------

def validator_path
  File.expand_path("validate-artifact.rb", __dir__)
end

# 違反メッセージの多重集合を返す（行番号は移行でずれるため落とす）。nil は検査不能。
def validator_violations(kind, file)
  out = IO.popen(["/usr/bin/ruby", validator_path, kind, file], err: File::NULL, &:read)
  case $?.exitstatus
  when 0 then Hash.new(0)
  when 1 then multiset(out.split("\n").map { |l| l.sub(/\A#{Regexp.escape(file)}:\d+: /, "") })
  else nil
  end
rescue SystemCallError => e
  uncheckable("バリデータを起動できません: #{validator_path}（#{e.message}）")
end

# 移行後の候補（まだ書いていない内容）をワークスペース外の一時ファイルで検証し、
# **移行前より違反が増えていないこと**を多重集合で確認する。dry-run でも実行する。
def validator_check(result)
  before = validator_violations(result[:kind], result[:path])
  after = nil
  Dir.mktmpdir("flywheel-migrate") do |dir|
    cand = File.join(dir, File.basename(result[:path]))
    File.open(cand, "w:UTF-8") { |f| f.write(result[:after].join(result[:eol]) + result[:eol]) }
    after = validator_violations(result[:kind], cand)
  end
  if before.nil? || after.nil?
    return { errors: ["バリデータが検査不能を返した（`#{validator_path} #{result[:kind]} <file>` を手で実行して原因を確認）"],
             before: nil, after: nil }
  end
  introduced = multiset_diff(after, before)
  errors = introduced.empty? ? [] : introduced.map { |k, v| "移行後に増えた違反（×#{v}）: #{k}" }
  { errors: errors, before: before.values.inject(0) { |s, v| s + v }, after: after.values.inject(0) { |s, v| s + v } }
end

# ---------------------------------------------------------------------------
# scaffold 追従レポート（検出のみ・書き換えない）
# ---------------------------------------------------------------------------

DOC_COPIES = {
  "runtime/README.md" => "runtime/README.md",
  "journal/README.md" => "journal/README.md",
  "journal/cycle-template.md" => "journal/cycle-template.md",
  "container/Dockerfile" => "container/Dockerfile",
  "container/compose.yml" => "container/compose.yml",
}.freeze

SCAFFOLD_PATHS = [
  "CLAUDE.md", "challenge-ledger.md", "priority-policy.md", "repos.tsv",
  ".claude/settings.json", ".flywheel/cadence.json", ".gitignore",
  "positions", "memory", "journal", "runtime", "container"
].freeze

# ポジション §接続ツール（実作業の委譲先）の必須宣言項目（`templates/position.md` の正本）。
POSITION_TOOL_ITEMS = [
  "対話前提スキルの対話相手",
  "子に意思決定を委譲してよいスキル",
  "人間へ上げる問いの種類",
].freeze

# 見出しが `title_re` にマッチする節の本文（見出し行を含み、同レベル以上の次の見出しの手前まで）
# を**すべて**返す（無ければ空配列）。「文書のどこかに語がある」ではなく「その節にあるか」を
# 判定するための土台。
#
# **返す本文からはフェンス（``` … ```）・HTML コメントの中身を除く**（見出し判定だけでなく
# 中身の照合にも同じ除外を効かせる）。テンプレートは記入例を提示する形を採るため、除外しないと
# 雛形をコピーしただけの未記入ポジションが「宣言済み」に化ける（偽陰性）。
#
# **最初に一致した見出しで一意化しない**: 同じ語を含む無関係な小見出しが前方にあると
# 後方の本物の節へ到達できず、宣言済みのワークスペースを未宣言と誤報する（偽陽性）。
# 実運用のポジションに §3 配下の `### 接続ツール（…）` と §5 の `## 接続ツール（…）` が
# 併存する形が実在した。節番号は利用先でずれるため見出し番号にも依存できない。そこで
# **候補をすべて返し、呼び出し側は「いずれかが要件を満たせば追従済み」と判定する**
# （見出しレベルの浅さ等で「正しい節」を推測すると、推測を外した分がそのまま誤報になる。
# 検査の目的は「宣言がどこかの §… にあるか」であって節の同一性の確定ではない）。
def markdown_sections(body, title_re)
  lines = body.split("\n", -1)
  inc = annotate_exclusions(lines)
  levels = lines.each_with_index.map do |line, i|
    marks = inc[i] ? line[/\A\#+(?=[ \t])/] : nil
    marks&.length
  end
  starts = (0...lines.size).select { |i| levels[i] && lines[i] =~ title_re }
  starts.map do |start|
    finish = ((start + 1)...lines.size).find { |i| levels[i] && levels[i] <= levels[start] }
    (start...(finish || lines.size)).select { |i| inc[i] }.map { |i| lines[i] }.join("\n")
  end
end

# ---------------------------------------------------------------------------
# テンプレート版マーカー（flywheel-template）
#
# 決定の正本は docs/template-version-marker.md（Issue #118）。要旨:
#   - scaffold 生成物の 1 行目に `<!-- flywheel-template: <name>@<version> -->` を刻む。
#     マーカーは**生成物と同じファイル**に乗るので、コピー・移動に随伴する。
#   - **正本はテンプレート側のマーカー 1 本だけ**。「現行版はいくつか」を書いた表を別に
#     持たない（2 本目のリストは必ずずれる＝ PR #96 の教訓）。ここでは `templates/` 配下の
#     Markdown を走査して版表をその場で作る。
#   - 版マーカーは**検出のためだけ**に使う。自動適用の範囲は広げない（本スクリプトは
#     scaffold 生成物を 1 バイトも書き換えない）。
#   - マーカー単独では誤報する（人間が手で追従してもマーカーは古いまま残る）。重要項目は
#     内容ベースの検出器を**併用**する（下の §意思決定の主体 / §接続ツール）。
#
# 対象は Markdown のみ。JSON にコメント構文が無く、全種類で統一した行内マーカーは原理的に
# 置けないため（対象外の生成物とその現在の検出手段は docs/template-version-marker.md §7）。

MARKER_RE = /\A<!--\s*flywheel-template:\s*([^\s@]+)@([^\s@]+)\s*-->\s*\z/.freeze

# マーカーを探す範囲（先頭 n 行）。ファイル全体を走査すると、マーカーを引用した本文
# （docs・記入例）を実マーカーと誤認しうるため、位置を先頭に限る。
MARKER_SCAN_LINES = 5

# テンプレート → ワークスペースの配置先。**対応表に無い Markdown テンプレートは実行時に
# 通知する**（載せ忘れを「静かな取りこぼし」ではなく「通知」として出す）。
#   :file … 単一ファイル（存在しなければ検査しない＝不足は SCAFFOLD_PATHS 側の責務）
#   :glob … 0..N 件（bootstrap 前は 0 件が正常）
TEMPLATE_TARGETS = [
  ["CLAUDE.md", "CLAUDE.md", :file],
  ["challenge-ledger.md", "challenge-ledger.md", :file],
  ["priority-policy.md", "priority-policy.md", :file],
  ["challenge-sources.md", "challenge-sources.md", :file],
  ["position.md", "positions/*.md", :glob],
  ["journal/README.md", "journal/README.md", :file],
  ["journal/cycle-template.md", "journal/cycle-template.md", :file],
  ["runtime/README.md", "runtime/README.md", :file],
].freeze

# 戻り値: [:ok, name, version] / [:none] / [:broken, 該当行]
# 「マーカーらしき行はあるが形が違う」を [:none] に丸めない（形式不正を「未導入」と
# 読み替えると、壊れたマーカーが静かに放置される）。
def read_marker(path)
  head = File.open(path, "r:UTF-8") { |f| f.first(MARKER_SCAN_LINES) || [] }
  head = head.map { |l| l.sub(/\r?\n\z/, "") }
  head.each do |line|
    m = MARKER_RE.match(line)
    return [:ok, m[1], m[2]] if m
  end
  broken = head.find { |l| l.include?("flywheel-template") }
  broken ? [:broken, broken.strip] : [:none]
rescue SystemCallError, ArgumentError
  [:none]
end

# semver（`<major>.<minor>.<patch>`）を整数配列にする。**3 要素ちょうど、かつ各要素が
# 正規形（`0` または `[1-9]\d*`）のものだけを受理する**（それ以外は nil ＝形式不正）。
# 2 つの軸のどちらを緩めても、**形式不正であるべきマーカーが「追従済み」として黙殺される**:
#   - 要素数を可変にして欠けた分を 0 で補うと `@0.20` が `@0.20.0` と一致する
#   - 先頭ゼロを許すと `to_i` が正規化してしまい `@00.20.0` が `@0.20.0` と一致する
#     （`@01.02.03` は `@1.2.3` に化け、テンプレートより新しいと誤報する）
# 版の値はプラグインの `version`（`.claude-plugin/plugin.json`）であり、一貫してこの形。
# prerelease（`-rc1` 等）は現に使っておらず、優先順位規則が要るため受理しない。
def semver(v)
  return nil unless v =~ /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/
  v.split(".").map(&:to_i)
end

# a <=> b（どちらかが semver でなければ nil）。要素数は 3 で揃うため配列比較で足りる。
def semver_cmp(a, b)
  pa = semver(a)
  pb = semver(b)
  return nil if pa.nil? || pb.nil?
  pa <=> pb
end

# 見出しの正規化。利用先は見出しに**連番**と**補足の丸括弧**を足す（実運用の
# positions/*.md は `## 5. 接続ツール（実作業の委譲先）` の形）。落とさずに比較すると
# 追従済みの生成物が毎回「見出しが無い」と報告される。
def normalize_heading(line)
  t = line.sub(/\A\#+[ \t]+/, "").strip
  t = t.sub(/\A\d+[.)]\s*/, "")
  t = t.sub(/（[^（）]*）\s*\z/, "")
  t = t.sub(/\([^()]*\)\s*\z/, "")
  t.strip
end

# `##` 見出しの正規化済み一覧（フェンス・HTML コメントの中は数えない）。
# プレースホルダ（`<…>`）を含む見出しは、利用先で必ず書き換わるため比較から外す。
def h2_headings(body)
  lines = body.split("\n", -1)
  inc = annotate_exclusions(lines)
  out = []
  lines.each_with_index do |line, i|
    next unless inc[i] && line =~ /\A\#\#[ \t]+/
    h = normalize_heading(line)
    next if h.empty? || h.include?("<")
    out << h
  end
  out
end

def read_body(path)
  File.read(path, encoding: "UTF-8")
rescue SystemCallError
  nil
end

# テンプレート側の版表（正本）。戻り値: [表, テンプレート側の通知]
#   表: name => { version:, path:, rel: }
def template_marker_table(templates)
  table = {}
  notes = []
  mapped = TEMPLATE_TARGETS.map { |rel, _, _| rel }
  Dir.glob(File.join(templates, "**", "*.md")).sort.each do |path|
    rel = path.sub(/\A#{Regexp.escape(templates)}\/?/, "")
    kind, name, version = read_marker(path)
    if kind != :ok
      notes << "版マーカー: テンプレート #{rel} に版マーカーが無い（追従を検出できない）。" \
               "1 行目へ `<!-- flywheel-template: #{rel}@<版> -->` を追記する"
      next
    end
    unless mapped.include?(rel)
      notes << "版マーカー: テンプレート #{rel} の配置先が未定義（追従検査の対象外）。" \
               "migrate-workspace.rb の TEMPLATE_TARGETS に追記する"
    end
    table[name] = { version: version, path: path, rel: rel }
  end
  [table, notes]
end

# ワークスペース側の突き合わせ。**検出のみ**（1 バイトも書き換えない）。
# `content_ok` は内容ベースの検出器が「重要項目は追従済み」と判定した生成物の相対パス集合
# （マーカーが古いだけの既知の偽陽性を、人間が「マーカー行だけ直せばよい」と読める形にする）。
def marker_notes(ws, templates, content_ok)
  return [] if FAULT == "marker-always-current"

  table, notes = template_marker_table(templates)

  TEMPLATE_TARGETS.each do |tpl_rel, dest, kind|
    entry = table.values.find { |e| e[:rel] == tpl_rel }
    next if entry.nil? # テンプレート側の欠落は上で通知済み
    tv = entry[:version]
    tpl_body = read_body(entry[:path])

    paths = kind == :glob ? Dir.glob(File.join(ws, dest)).sort : [File.join(ws, dest)]
    paths.each do |path|
      next unless File.exist?(path)
      rel = path.sub(/\A#{Regexp.escape(ws)}\/?/, "")
      state, _name, wv = read_marker(path)

      stale =
        case state
        when :ok
          cmp = semver_cmp(wv, tv)
          if cmp.nil?
            notes << "版マーカー: #{rel} の版マーカーの形式が不正（版が semver でない: @#{wv}）。" \
                     "マーカー導入前の世代と同じ扱いで報告する"
            true
          elsif cmp < 0
            notes << "版マーカー: #{rel} はテンプレートに追従していない" \
                     "（テンプレート #{tpl_rel}@#{tv} / 生成物は @#{wv}）。" \
                     "`<plugin>/templates/#{tpl_rel}` と突き合わせて手で追従し、マーカーの版を上げる"
            true
          elsif cmp > 0
            notes << "版マーカー: #{rel} の版がテンプレートより新しい" \
                     "（生成物 @#{wv} / テンプレート #{tpl_rel}@#{tv}）。プラグインが古い可能性がある"
            false
          else
            false
          end
        when :broken
          notes << "版マーカー: #{rel} の版マーカーの形式が不正（#{_name}）。" \
                   "マーカー導入前の世代と同じ扱いで報告する"
          true
        else
          notes << "版マーカー: #{rel} に版マーカーが無い（マーカー導入前に scaffold された世代）。" \
                   "テンプレート #{tpl_rel}@#{tv} と内容を突き合わせ、追従したうえで、" \
                   "1 行目に <!-- flywheel-template: #{tpl_rel}@#{tv} --> を追記する"
          true
        end

      next unless stale
      notes << "版マーカー: #{rel} — 重要項目の内容チェックでは追従済み（マーカー行の版を上げれば足りる可能性がある）" if content_ok.include?(rel)
      next if FAULT == "marker-skip-heading-delta"
      next if tpl_body.nil?
      body = read_body(path)
      next if body.nil?
      missing = h2_headings(tpl_body) - h2_headings(body)
      next if missing.empty?
      notes << "版マーカー: #{rel} — テンプレートにあって見当たらない見出し" \
               "（参考・利用先が見出しを改名していると出る）: #{missing.join(' / ')}"
    end
  end

  notes
end

def scaffold_report(ws, templates)
  notes = []
  # 内容ベースの検出器が「重要項目は追従済み」と判定した生成物（版マーカーの既知の偽陽性と協調させる）
  content_ok = []

  SCAFFOLD_PATHS.each do |rel|
    path = File.join(ws, rel)
    notes << "不足: #{rel}（flywheel-init の scaffold 手順で生成する）" unless File.exist?(path)
  end

  DOC_COPIES.each do |rel, tpl|
    path = File.join(ws, rel)
    tpl_path = File.join(templates, tpl)
    next unless File.exist?(path) && File.exist?(tpl_path)
    next if File.read(path, encoding: "UTF-8") == File.read(tpl_path, encoding: "UTF-8")
    notes << "テンプレートと差分あり: #{rel}（自動上書きしない。`diff #{rel} <plugin>/templates/#{tpl}` で確認し、" \
             "利用先のカスタマイズでなければテンプレート側を取り込む）"
  end

  gitignore = File.join(ws, ".gitignore")
  if File.exist?(gitignore)
    lines = File.read(gitignore, encoding: "UTF-8").split("\n").map { |l| l.sub(/\r\z/, "") }
    notes << "`.gitignore`: `.flywheel/*` の行が無い（`.flywheel/` 丸ごと ignore だと cadence.json を追跡できない）" unless lines.include?(".flywheel/*")
    notes << "`.gitignore`: `!.flywheel/cadence.json` の行が無い（cadence.json は運用設定として Git 追跡する）" unless lines.include?("!.flywheel/cadence.json")
    notes << "`.gitignore`: 旧形式の `.flywheel/`（ディレクトリ丸ごと ignore）が残っている（`.flywheel/*` ＋ unignore へ置き換える）" if lines.include?(".flywheel/")
    notes << "`.gitignore`: `container/.env` の行が無い（ホスト固有のため追跡しない）" unless lines.include?("container/.env")
    notes << "`.gitignore`: `*.migrate-tmp` の行が無い（移行の一時ファイルが万一残ってもコミットされないようにする）" unless lines.include?("*.migrate-tmp")
  end

  settings = File.join(ws, ".claude/settings.json")
  if File.exist?(settings)
    body = File.read(settings, encoding: "UTF-8")
    notes << "`.claude/settings.json`: `Bash(claude -p:*)` の allow が無い（自走委譲が分類器でブロックされる）" unless body.include?("Bash(claude -p:*)")
  end

  # 意思決定の主体（#107）: 旧 1 軸（課題のスコープだけ）の CLAUDE.md は、対話前提スキルでも
  # 単一 repo 完結なら子が決めてよい、と読める。書き換えはせず検出して報告する。
  # **判定は節単位で行う**: 文書全体の部分一致だと、無関係な本文に「スキルの性質」があるだけで
  # 旧 1 軸の節が「追従済み」に化ける（偽陰性 = 旧動作が残ったまま報告されない）。
  claude_md = File.join(ws, "CLAUDE.md")
  if File.exist?(claude_md)
    sections = markdown_sections(File.read(claude_md, encoding: "UTF-8"), /意思決定の主体/)
    if sections.any? { |sec| sec.include?("スキルの性質") }
      content_ok << "CLAUDE.md"
    elsif !sections.empty?
      notes << "`CLAUDE.md`: §意思決定の主体が旧 1 軸（課題のスコープのみ）のまま（対話前提スキルでも単一 repo なら子が決める、と読める）。" \
               "`<plugin>/templates/CLAUDE.md` の 2 軸（スキルの性質 × 課題のスコープ）へ手で追従する"
    end
  end

  # ポジションの §接続ツール（#107）: 対話前提スキルの対話相手の宣言場所。
  # 未宣言でも run-cycle は安全側（親がユーザー役）に倒れるため、ブロックではなく報告に留める。
  # ここも**見出しと宣言項目を構造的に**見る（本文中に「接続ツール」の語があるだけの
  # ポジションを「宣言済み」と誤認しない。値が `未宣言` であることは宣言項目の欠落と区別する
  # ＝ flywheel-init / bootstrap-domain-map が許す正規の状態であり、移行対象ではない）。
  Dir.glob(File.join(ws, "positions", "*.md")).sort.each do |path|
    sections = markdown_sections(File.read(path, encoding: "UTF-8"), /接続ツール/)
    if sections.empty?
      notes << "`positions/#{File.basename(path)}`: §接続ツール（実作業の委譲先）が無い＝対話前提スキルの対話相手が未宣言" \
               "（run-cycle は未宣言を安全側＝親がユーザー役として扱う）。`<plugin>/templates/position.md` の §接続ツール を追記する"
      next
    end
    # いずれかの候補節が 3 項目を揃えていれば追従済み。揃っていなければ、最も惜しい候補
    # （欠落の少ないもの）の欠落を報告する＝人が直すべき節を指せるようにする。
    missing = sections.map { |s| POSITION_TOOL_ITEMS.reject { |label| s.include?(label) } }.min_by(&:size)
    if missing.empty?
      # marker_notes はワークスペース相対パスで照合する（固定値を積むと協調ノートが
      # 黙って発火しなくなる）。
      content_ok << path.sub(/\A#{Regexp.escape(ws)}\/?/, "")
      next
    end
    notes << "`positions/#{File.basename(path)}`: §接続ツールに宣言項目が無い（欠けている宣言項目: #{missing.join(' / ')}）" \
             "＝ run-cycle は宣言なしを安全側（親がユーザー役）として扱う。`<plugin>/templates/position.md` の §接続ツール を参照して追記する" \
             "（確定していない項目は `未宣言` と記入する＝推測で埋めない）"
  end

  dockerfile = File.join(ws, "container/Dockerfile")
  if File.exist?(dockerfile)
    body = File.read(dockerfile, encoding: "UTF-8")
    notes << "`container/Dockerfile`: ruby を導入していない（コミットゲート＝validate-artifact.rb が起動できない。contracts/README.md §実行環境の前提）" unless body =~ /^\s*(RUN|ARG|ENV)?.*\bruby\b/
  end

  notes.concat(marker_notes(ws, templates, content_ok))

  notes
end

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

args = ARGV.dup
ws = "."
templates = File.expand_path("../templates", __dir__)
apply = false
backup_dir = nil

until args.empty?
  arg = args.shift
  case arg
  when "--workspace"
    ws = args.shift
    uncheckable("--workspace に値がありません\n#{USAGE}") if ws.nil? || ws.empty? || ws.start_with?("--")
  when "--templates-dir"
    templates = args.shift
    uncheckable("--templates-dir に値がありません\n#{USAGE}") if templates.nil? || templates.empty? || templates.start_with?("--")
  when "--backup-dir"
    backup_dir = args.shift
    uncheckable("--backup-dir に値がありません\n#{USAGE}") if backup_dir.nil? || backup_dir.empty? || backup_dir.start_with?("--")
  when "--apply"
    apply = true
  when "-h", "--help"
    puts USAGE
    exit EXIT_OK
  else
    uncheckable("不明な引数: #{arg}\n#{USAGE}")
  end
end

uncheckable("ワークスペースがありません: #{ws}") unless File.directory?(ws)
uncheckable("テンプレートのディレクトリがありません: #{templates}") unless File.directory?(templates)
uncheckable("バリデータがありません（検算できないため適用しない）: #{validator_path}") unless File.exist?(validator_path)

canonical = canonical_example_block(File.join(templates, "challenge-ledger.md"))
known = {}
(legacy_example_lines + canonical).each { |l| known[l] = true unless l.strip.empty? }

targets = [["challenge-ledger.md", "ledger"], ["challenge-archive.md", "archive"]]
results = []
missing = []
targets.each do |name, kind|
  path = File.join(ws, name)
  if File.exist?(path)
    results << migrate_file(path, kind, canonical, known)
  else
    missing << name
  end
end

changed = results.select { |r| r[:before] != r[:after] }
errors = results.flat_map { |r| r[:errors].map { |e| "#{r[:path]}: #{e}" } }
manual = results.flat_map { |r| r[:manual] }
notes = scaffold_report(ws, templates)

# バリデータ前後比較は dry-run でも実行する（「dry-run が通ったのに --apply で失敗」を無くす）。
changed.each do |r|
  next unless r[:errors].empty?
  check = validator_check(r)
  r[:validator] = [check[:before], check[:after]]
  errors.concat(check[:errors].map { |e| "#{r[:path]}: #{e}" })
end

puts "== 台帳・アーカイブの構造マイグレーション（自動適用の対象）"
if results.empty?
  puts "  対象ファイルがありません（#{missing.join(' / ')} が未生成＝初回 scaffold が必要）"
else
  missing.each { |m| puts "  - #{m}: 未生成（この移行の対象外）" }
  results.each do |r|
    if r[:before] == r[:after]
      puts "  - #{r[:path]}: 追従済み（変更なし）"
    else
      puts "  - #{r[:path]}: #{r[:ops].size} 件の変更"
      r[:ops].each { |o| puts "      * #{o}" }
    end
  end
end

unless manual.empty?
  puts
  puts "== 人間判断が必要（自動では直さない）"
  manual.each { |m| puts "  - #{m}" }
end

unless notes.empty?
  puts
  puts "== scaffold 追従レポート（検出のみ・本スクリプトは書き換えない）"
  notes.each { |n| puts "  - #{n}" }
end

unless errors.empty?
  puts
  puts "== 検算エラー（適用しない）"
  errors.each { |e| puts "  - #{e}" }
  failed("検算に失敗したため適用しません（#{errors.size} 件）。元ファイルは書き換えていません")
end

if changed.empty?
  puts
  puts "変更はありません（現行テンプレートに追従済み）。"
  exit EXIT_OK
end

puts
puts "== 検算（バリデータの前後比較・dry-run でも実行）"
changed.each do |r|
  b, a = r[:validator]
  puts "  - #{r[:path]}: 違反 #{b} 件 → #{a} 件（増加なし）"
end

unless apply
  puts
  puts "dry-run（既定）です。適用するには --apply を付けて再実行してください。"
  exit EXIT_PENDING
end

# --- 適用: バックアップ → 一時ファイル → rename（一時ファイルは ensure で必ず後始末） ---

if backup_dir.nil?
  base = File.join(ws, ".flywheel", "migration-backup")
  stamp = Time.now.strftime("%Y%m%d-%H%M%S")
  backup_dir = File.join(base, stamp)
  n = 2
  while File.exist?(backup_dir)
    backup_dir = File.join(base, "#{stamp}-#{n}")
    n += 1
  end
end

staged = []
begin
  changed.each do |r|
    dest = File.join(backup_dir, File.basename(r[:path]))
    failed("バックアップ先に同名ファイルが既にあります（世代を失わないため上書きしません）: #{dest}") if File.exist?(dest)
  end
  FileUtils.mkdir_p(backup_dir)
  changed.each { |r| FileUtils.cp(r[:path], File.join(backup_dir, File.basename(r[:path]))) }

  changed.each do |r|
    tmp = "#{r[:path]}.migrate-tmp"
    staged << tmp
    File.open(tmp, "w:UTF-8") { |f| f.write(r[:after].join(r[:eol]) + r[:eol]) }
  end
  failed("故障注入（テスト専用）: 一時ファイル作成後に中断した") if FAULT == "fail-after-stage"
  changed.each_with_index { |r, i| File.rename(staged[i], r[:path]) }
rescue SystemCallError => e
  failed("書き込みに失敗しました（元ファイルは無傷です）: #{e.message}")
ensure
  # `failed` は SystemExit を投げる（SystemCallError では捕まらない）。どの経路で抜けても
  # ワークスペースに一時ファイルを残さない。
  staged.each { |t| File.unlink(t) if File.exist?(t) }
end

puts
puts "== 適用しました"
puts "  バックアップ: #{backup_dir}"
changed.each { |r| puts "  - #{r[:path]}" }
puts "  ※ 変更内容は `git diff` で確認し、コミットは人間/エージェントが行ってください。"
exit EXIT_OK

__END__
<!-- 新しい課題は下に追記。テンプレートは docs/templates/challenge-ledger-format.md -->
<!-- 新しい課題は下に追記。テンプレートは claude-flywheel の docs/challenge-ledger-format.md -->
<!-- 新しい課題は下に追記。記入例（下記コメント）をコピーして使う -->
<!-- 記入例（コピーして使う）
### [C-001] <タイトル>
**人間記入欄**
- 起票者 / 起票日: <name> / <YYYY-MM-DD>
- 説明: <背景・困っていること・期待する状態>
- 完了条件（任意）: <こうなれば完了>
- 体感の緊急度（任意）: 高 | 中 | 低
**分類欄（エージェントが記入）**
**分類欄（オーケストレーターが記入）**
- 担当ポジション:
- 関連サービス:
- 優先度: P0 | P1 | P2
- ステータス: 未分類
- 取り込み元:  <!-- 外部ソースから取り込んだ場合のみ。ingest-challenges が付与。手書き課題は空でよい -->
- 備考:
- 分類: 単一ドメイン | 横断 | 要相談
- 関連ドメイン:
- 担当:
- 分解（横断時のみ）:
- 判定根拠:
-->
## 記入例（コピーして使う）
```markdown
- ステータス: 未分類（未分類 → 分類済 → 計画承認待ち → 着手中 → 検証中 → 完了確認待ち → 完了）
- タスク案: （run-cycle の計画ステップが記入）
- 承認（人間がチェック）:
  - [ ] 計画を承認（FR-13）
  - [ ] 完了を承認（FR-32）
- 取り込み元: （外部ソースから取り込んだ場合のみ ingest-challenges が付与。手書き課題は空でよい）
```
> **人間の承認方法**: ステータスが `計画承認待ち` / `完了確認待ち` になったら、上の「承認」行の該当チェックボックスを `[x]` にするだけ（GitHub のモバイル / Web でタップするとその場でコミットされる）。ステータスの前進はエージェントが次サイクルで代行する。差し戻しはチェックを付けず、理由を人間記入欄か備考に書く。
---
