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
#                    `--apply` 時のみ作成する
#
# exit code:
#   0 = 追従済み（変更不要）／`--apply` で適用完了
#   1 = 失敗（検算で違反を検出・書き込み失敗）。**部分適用は残さない**（一時ファイルに書き、
#       検算に通ったものだけを置換する。元ファイルは検算失敗時に一度も書き換えられない）
#   2 = 検査不能（引数不正・テンプレート/バリデータ不在・対象が UTF-8 として読めない 等）
#   3 = 要移行（dry-run で変更が必要）。`--apply` では返さない
#
# 自動適用の範囲（線引きの根拠は docs/challenge-ledger-format.md §既存ワークスペースの移行）:
#   - **自動適用するのは `challenge-ledger.md` / `challenge-archive.md` の構造変換だけ**。
#     この 2 つだけが「テンプレート由来の構造」と「運用中のライブデータ」が同居し、
#     ファイル単位の再生成が不可能＝構造マイグレーションでしか追従できない。
#   - それ以外（scaffold 済みドキュメント・設定）は**検出して提示するだけ**で書き換えない。
#     テンプレート版マーカーを埋めていないため「テンプレートが更新された」と「利用先が
#     カスタマイズした」を機械が区別できず、自動上書きは利用先の編集を静かに壊すため。
#
# 非破壊の担保（台帳の機械編集は事故の実績があるため多重化する）:
#   1. **一時ファイル方式**: 元ファイルを直接書き換えない（docs/challenge-ledger-format.md
#      §台帳を機械で編集するときの規律）。検算に通った一時ファイルだけを `File.rename` で置換する。
#   2. **エントリ単位の差分検算**: 各エントリについて「消えた行」「増えた行」を多重集合で求め、
#      **計画した操作で説明できる行だけ**であることを要求する。操作対象外のエントリは
#      差分ゼロでなければ失敗にする（隣接エントリの巻き添えを構造的に検出する）。
#   3. **バリデータによる前後比較**: `validate-artifact.rb` を移行前・移行後の両方に掛け、
#      **移行後の違反集合が移行前の部分集合であること**（新しい違反を作っていないこと）を要求する。
#   4. **バックアップ**: 置換の直前に元ファイルを `--backup-dir` へコピーする。
#   5. **冪等**: 2 回目の実行は差分 0（バイト一致）になる。
#
# 実装言語は /usr/bin/ruby（macOS 標準搭載）。選定根拠と ruby 未導入環境の扱いは
# contracts/README.md §実装言語の選定根拠 / §実行環境の前提。

require "fileutils"

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
# 読み込み
# ---------------------------------------------------------------------------

def read_lines(file)
  content = File.read(file, encoding: "UTF-8")
  uncheckable("UTF-8 として解釈できません: #{file}") unless content.valid_encoding?
  lines = content.split("\n", -1)
  lines.pop if lines.last == "" # 末尾改行によるダミー要素を除く
  lines
rescue SystemCallError => e
  uncheckable("読み取れません: #{file}（#{e.message}）")
end

# フェンス・複数行 HTML コメントを除外して「検査対象か」を各行に付ける。
# **`validate-artifact.rb` の annotate_exclusions と同じ意味論**（台帳のどこがデータで
# どこが記入例かの判定は 1 つでなければならない）。両者の一致は、移行後のファイルを
# 実際に `validate-artifact.rb` へ通す検算（§非破壊の担保 3）で固定する。
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
# エントリの構造マイグレーション
# ---------------------------------------------------------------------------

CLASSIFY_HEADING_RE = /^\*\*分類欄/.freeze
HUMAN_HEADING_RE = /^\*\*人間記入欄/.freeze
BOLD_TASK_PLAN_RE = /^\*\*タスク案/.freeze

# 分類欄フィールドの正規順序（templates/challenge-ledger.md の記入例と同じ並び）。
# 欠落フィールドの挿入位置はこの順序から決める（**既存行は並べ替えない**＝差分を最小にし、
# 「触るべきでない行を触らない」を守るため）。
CLASSIFY_FIELD_ORDER = [
  "担当ポジション", "関連サービス", "関連リポジトリ", "関連Issue", "関連PR",
  "優先度", "ステータス", "タスク案", "承認（人間がチェック）", "取り込み元", "監査元", "備考"
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

def field_line_re(label)
  /^- #{Regexp.escape(label)}:/
end

# 多重集合（行 → 出現回数）
#
# **空行は数えない**: 空行の位置の正しさ（見出し直前の空行・分類欄のネスト項目の途中の空行）は
# バリデータ（検算 3）が専門に検査するため、こちらは「内容の行が保存されているか」に絞る。
def multiset(lines)
  lines.each_with_object(Hash.new(0)) do |l, h|
    next if l.strip.empty?
    h[l] += 1
  end
end

def multiset_diff(a, b)
  ma = multiset(a)
  mb = multiset(b)
  out = Hash.new(0)
  ma.each { |k, v| d = v - mb[k]; out[k] = d if d > 0 }
  out
end

# フィールド行に続く継続行（インデント行・引用行）の末尾位置を返す。
def field_block_end(lines, idx)
  j = idx
  while j + 1 < lines.size
    nxt = lines[j + 1]
    break unless nxt =~ /^[ \t]+\S/ || nxt.start_with?(">")
    j += 1
  end
  j
end

# 1 エントリ分の変換。戻り値は変換後の body と、検算に使う「計画した差分」。
#
#   { body:, ops: [説明], removed: [期待して消える行], added: [期待して増える行], manual: [人間判断] }
def migrate_entry(heading, body, kind)
  ops = []
  removed = []
  added = []
  manual = []
  work = body.dup
  label = heading[/\A### \[([^\]]*)\]/, 1] || heading[0, 40]

  ci = work.index { |l| l =~ CLASSIFY_HEADING_RE }
  if ci.nil?
    manual << "#{label}: 分類欄（`**分類欄…**`）が見つからないため自動変換を行わない"
    return { body: work, ops: ops, removed: removed, added: added, manual: manual }
  end

  # (1) 旧ラベル `- 承認:` を現行の `- 承認（人間がチェック）:` へ改名する。
  #     チェック状態（`[x]`）は直下のネスト行にあり、この改名では一切触れない。
  #     **分類欄より後ろだけを対象にする**（人間記入欄は人間の領域＝機械が触らない）。
  work.each_index do |i|
    next if i <= ci
    m = /^- 承認:(.*)$/.match(work[i])
    next unless m
    renamed = "- 承認（人間がチェック）:#{m[1]}"
    removed << work[i]
    added << renamed
    work[i] = renamed
    ops << "#{label}: 承認ラベルを現行化（`- 承認:` → `- 承認（人間がチェック）:`）"
  end

  # (2) 形 E（フィールド行を持たない太字見出しブロック）を `- タスク案:` ＋ネスト項目へ正規化する。
  task_items = nil
  task_provenance = nil
  if work.none? { |l| l =~ field_line_re("タスク案") }
    # 分類欄より後ろだけを探す（実測形では備考行の後ろに置かれている）。
    bi = ((ci + 1)...work.size).find { |i| work[i] =~ BOLD_TASK_PLAN_RE }
    if bi
      items = []
      j = bi + 1
      while j < work.size
        l = work[j]
        break if l.strip.empty?
        break if l =~ ENTRY_HEADING_RE || l =~ /^\*\*/ || l =~ /^- / || l.start_with?("<!--")
        items << l
        j += 1
      end
      if items.empty? || items.none? { |l| l =~ /^\d+[.)]\s/ }
        manual << "#{label}: 太字見出しのタスク案ブロックの直下に番号付きリストが見つからないため自動変換を行わない（#{work[bi][0, 40]}）"
      elsif work[bi].include?("-->")
        # 見出し文言をそのまま HTML コメントへ収められない（コメントの境界を壊す）。
        manual << "#{label}: 太字見出しに `-->` を含むため自動変換を行わない（#{work[bi][0, 40]}）"
      else
        task_items = items.map { |l| "  #{l}" }
        task_provenance = "<!-- 移行前の記載（#88）: #{work[bi]} -->"
        removed.concat(work[bi..j - 1])
        # 直前の空行も一緒に落とす（ブロックだけ消すと空行が 2 つ並ぶため）。
        drop_from = bi
        if bi > 0 && work[bi - 1].strip.empty?
          drop_from = bi - 1
          removed << work[bi - 1]
        end
        work.slice!(drop_from, j - drop_from)
        ops << "#{label}: 太字見出しのタスク案ブロックを `- タスク案:` ＋ネスト項目へ変換（#{items.size} 項目）"
        ci = work.index { |l| l =~ CLASSIFY_HEADING_RE }
      end
    end
  end

  # (3) 欠落している分類欄フィールド行を正規順序の位置へ挿入する。
  inserts = REQUIRED_CLASSIFY_INSERTS.dup
  inserts += LEDGER_ONLY_INSERTS if kind == "ledger"
  inserts = inserts.sort_by { |lbl, _| CLASSIFY_FIELD_ORDER.index(lbl) }

  inserted_approval = false
  inserts.each do |lbl, template_lines|
    next if work.any? { |l| l =~ field_line_re(lbl) }
    inserted_approval = true if lbl == "承認（人間がチェック）"
    new_lines = template_lines.dup
    if lbl == "タスク案" && task_items
      new_lines = [task_provenance, "- タスク案:"] + task_items
    end
    at = classify_insert_position(work, ci, lbl)
    work.insert(at, *new_lines)
    added.concat(new_lines)
    ops << if lbl == "タスク案" && task_items
             "#{label}: `- タスク案:` 行を分類欄へ挿入（変換したネスト項目つき）"
           else
             "#{label}: 欠落フィールド行を挿入: #{lbl}"
           end
    ci = work.index { |l| l =~ CLASSIFY_HEADING_RE }
  end

  # (3b) 承認フィールドはあるがチェックボックス行が欠けている場合の補完。
  ai = work.index { |l| l =~ field_line_re("承認（人間がチェック）") }
  if ai
    [["計画を承認", "  - [ ] 計画を承認（FR-13・承認対象＝タスク案）"],
     ["完了を承認", "  - [ ] 完了を承認（FR-32）"]].each do |name, line|
      next if work.any? { |l| l =~ /^ {2}- \[[ xX]\] #{Regexp.escape(name)}/ }
      at = field_block_end(work, ai) + 1
      work.insert(at, line)
      added << line
      ops << "#{label}: 承認チェックボックス行を補完: #{name}"
      ai = work.index { |l| l =~ field_line_re("承認（人間がチェック）") }
    end
  end

  # (4) 機械で決められないもの（人間判断へ倒す）
  # 承認は**機械が代筆してはならない**（承認プロトコルの真正性。docs/challenge-ledger-format.md
  # §承認プロトコル）。旧形式では承認事実が見出し文言（`**タスク案（FR-13・承認済み …）**`）や
  # 「アーカイブ済み＝完了承認を経ている」という文脈にしか無いことがあるが、**移行では常に
  # 未チェックで新設し、チェックは人間に委ねる**。付けなかった事実はここで必ず報告する。
  if inserted_approval && work.none? { |l| l =~ /^ {2}- \[[xX]\] 計画を承認/ }
    status = (work.find { |l| l =~ /^- ステータス:/ } || "- ステータス:").sub(/^- ステータス:\s*/, "").strip
    src = task_provenance ? "旧見出しの文言（#{task_provenance}）" : "ステータス「#{status.empty? ? '（空欄）' : status}」"
    manual << "#{label}: 承認チェックボックスを**未チェックで新設**した（過去の承認の手がかり: #{src}）。" \
              "**`[x]` は自動で付けない**——人間が内容を確認してチェックすること"
  end
  REQUIRED_CLASSIFY_INSERTS.each do |lbl, _|
    c = work.count { |l| l =~ field_line_re(lbl) }
    manual << "#{label}: 「#{lbl}」行が #{c} 回出現している（見出し破損・記入例の残骸の可能性。自動では直さない）" if c > 1
  end
  unless work.any? { |l| l =~ HUMAN_HEADING_RE }
    manual << "#{label}: 人間記入欄（`**人間記入欄**`）が無い（機械は人間の欄を捏造しない）"
  end

  { body: work, ops: ops, removed: removed, added: added, manual: manual }
end

# 正規順序に照らした挿入位置（分類欄の中）。
# 直前に来るべきフィールドの**ブロック末尾（継続行を含む）**の次に挿入する。
# 該当が無ければ分類欄見出しの直後。
def classify_insert_position(lines, classify_idx, label)
  want = CLASSIFY_FIELD_ORDER.index(label)
  at = classify_idx + 1
  (classify_idx + 1...lines.size).each do |i|
    m = /^- ([^:]+):/.match(lines[i])
    next unless m
    pos = CLASSIFY_FIELD_ORDER.index(m[1])
    next if pos.nil? || pos >= want
    at = field_block_end(lines, i) + 1
  end
  at
end

# ---------------------------------------------------------------------------
# 記入例ブロックの現行化（台帳のみ）
# ---------------------------------------------------------------------------

EXAMPLE_MARKER_RE = /^<!-- 新しい課題は/.freeze
EXAMPLE_HEADING_RE = /^## 記入例/.freeze
EXAMPLE_COMMENT_RE = /^<!-- 記入例/.freeze

# テンプレートから記入例ブロック（マーカーコメント〜末尾の `---`）を切り出す。
def canonical_example_block(template_path)
  uncheckable("テンプレートがありません: #{template_path}") unless File.exist?(template_path)
  lines = read_lines(template_path)
  start = lines.index { |l| l =~ EXAMPLE_MARKER_RE }
  uncheckable("テンプレートに記入例のマーカー（`<!-- 新しい課題は…`）がありません: #{template_path}") if start.nil?
  last = nil
  (start...lines.size).each { |i| last = i if lines[i] == "---" }
  uncheckable("テンプレートの記入例ブロックの終端（`---`）が見つかりません: #{template_path}") if last.nil?
  lines[start..last]
end

# 既存ファイル内の記入例ブロックの範囲（[start, end] の配列。マーカー行と本体を別々に返す）。
# 実在する 3 形すべてを扱う:
#   - `## 記入例（コピーして使う）` ＋ フェンス（現行・Emma 形）
#   - `<!-- 記入例（コピーして使う）` … `-->`（旧・Rupert 形。入れ子コメントで途中閉じしていてもよい）
#   - マーカーコメント行（`<!-- 新しい課題は…`）が本体と離れた位置にある形
def find_example_regions(lines)
  included = annotate_exclusions(lines)
  fenced = fence_flags(lines)
  regions = []
  i = 0
  while i < lines.size
    if !fenced[i] && lines[i] =~ EXAMPLE_MARKER_RE
      regions << [i, i]
      i += 1
      next
    end
    if !fenced[i] && (lines[i] =~ EXAMPLE_HEADING_RE || lines[i] =~ EXAMPLE_COMMENT_RE)
      j = i
      k = i + 1
      while k < lines.size
        break if included[k] && (lines[k] =~ ENTRY_HEADING_RE || lines[k] =~ /^## /)
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
def migrate_example_block(lines, canonical)
  ops = []
  manual = []
  regions = find_example_regions(lines)
  included = annotate_exclusions(lines)

  # 安全ガード: 記入例と判定した範囲に**実エントリ**が紛れていたら手を出さない（削除範囲の
  # 誤認は課題の消失に直結する）。旧形式では記入例が閉じられていない HTML コメントに
  # なっていることがあり、その場合は後続の実エントリまでコメント内＝「検査対象外」に
  # 落ちるため、`included` だけを根拠にしない。記入例の見出しは必ずプレースホルダ
  # （`### [C-001] <タイトル>`）であり、かつ 1 エントリ分しか無いことを併せて要求する。
  regions.each do |s, e|
    heads = (s..e).select { |i| lines[i] =~ ENTRY_HEADING_RE }
    bad = heads.find { |i| lines[i] !~ /</ }
    bad ||= heads[1] if heads.size > 1
    bad ||= (s..e).find { |i| included[i] && (lines[i] =~ ENTRY_HEADING_RE || lines[i] =~ HUMAN_HEADING_RE) }
    next if bad.nil?
    manual << "記入例ブロックと判定した範囲（#{s + 1}〜#{e + 1} 行）に実エントリらしい行があるため、" \
              "記入例の現行化を行わない（記入例の閉じ忘れ等。人間が範囲を直してから再実行する）: #{lines[bad][0, 40]}"
    return { lines: lines, ops: ops, manual: manual, dropped: [] }
  end

  kept = []
  drop = regions.each_with_object({}) { |(s, e), h| (s..e).each { |i| h[i] = true } }
  (0...lines.size).each { |i| kept << lines[i] unless drop[i] }

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
  { lines: rebuilt, ops: ops, manual: manual, dropped: regions }
end

# ---------------------------------------------------------------------------
# ファイル単位の移行（台帳・アーカイブ）
# ---------------------------------------------------------------------------

# テスト専用の故障注入。検算（§非破壊の担保 2）が本当に部分適用を止めることを固定するために
# 使う。運用では設定しない（未設定なら何もしない）。
FAULT = ENV["MIGRATE_WORKSPACE_INJECT_FAULT"]

def inject_fault!(lines)
  case FAULT
  when nil, ""
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
    # 記入例ブロック（前文）側の行を 1 行落とす。エントリ検算の範囲外なので、
    # 記入例段の検算（検算 2a）だけが検出できる。
    i = lines.index { |l| l =~ /^- 担当ポジション:/ }
    lines.delete_at(i) if i
    lines
  when "move-blank-into-nest"
    # 同一エントリ内での**空行の移動**（多重集合は不変＝検算 2 をすり抜ける）。
    # ネスト項目の直前に空行が入ると分類欄の結合切れになり、検算 3（バリデータの
    # 前後比較）だけが検出できる。層が独立に効いていることを固定するための注入。
    k = lines.index { |l| l =~ /^ {2}\d+[.)] / }
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

def migrate_file(path, kind, canonical)
  lines = read_lines(path)
  ops = []
  manual = []

  base = lines
  dropped = []
  if kind == "ledger"
    r = migrate_example_block(lines, canonical)
    base = r[:lines]
    dropped = r[:dropped]
    ops.concat(r[:ops])
    manual.concat(r[:manual])
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

  # --- 検算 (2): 元ファイルから独立に再計算した期待値と突き合わせる ---
  #
  # 記入例ブロックの差し替えとエントリ変換という 2 種類の変更が混ざらないよう、
  # **記入例ブロックを両側から取り除いた像**（orig_wo / final_wo）を作ってから比較する。
  # 期待値は new_lines ではなく**元ファイル `lines`** から計算するため、変換後に加えられた
  # 変更（バグ・故障注入）は検出される。
  orig_wo = strip_ranges(lines, dropped)
  final_wo = new_lines
  if kind == "ledger"
    at = find_subsequence(new_lines, canonical)
    if at.nil?
      errors = ["記入例ブロックが現行テンプレートどおりに挿入されていない（検算できないため適用しない）"]
      return { path: path, kind: kind, before: lines, after: new_lines, ops: ops, manual: manual, errors: errors }
    end
    final_wo = new_lines[0, at] + (new_lines[(at + canonical.size)..-1] || [])
  end

  errors = verify_preamble(orig_wo, final_wo)
  errors.concat(verify_entries(orig_wo, final_wo, plans))

  { path: path, kind: kind, before: lines, after: new_lines, ops: ops, manual: manual, errors: errors }
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

# 最初のエントリ見出しより前（前文）が保存されていること。空行の増減は許容する
# （記入例ブロックの前後で空行を正規化するため）。
def verify_preamble(before, after)
  a = entry_heading_indexes(before).first || before.size
  b = entry_heading_indexes(after).first || after.size
  pre_a = before[0, a].reject { |l| l.strip.empty? }
  pre_b = after[0, b].reject { |l| l.strip.empty? }
  return [] if pre_a == pre_b
  ["前文（最初のエントリ見出しより前）が計画外に変化した: " \
   "消えた行=#{fmt_ms(multiset_diff(pre_a, pre_b))} / 増えた行=#{fmt_ms(multiset_diff(pre_b, pre_a))}"]
end

# 見出しで切ったエントリ（行番号演算ではなく見出しパターンで切る）。
def split_entries(lines)
  idxs = entry_heading_indexes(lines)
  idxs.each_with_index.map do |at, n|
    stop = idxs[n + 1] || lines.size
    { at: at, heading: lines[at], body: lines[(at + 1)...stop] }
  end
end

def verify_entries(before, after, plans)
  errors = []
  a = split_entries(before)
  b = split_entries(after)
  if a.map { |e| e[:heading] } != b.map { |e| e[:heading] }
    errors << "エントリ見出しの並びが変化した（移行はエントリの追加・削除・並べ替えを行わない）: " \
              "移行前 #{a.size} 件 / 移行後 #{b.size} 件"
    return errors
  end
  a.each_with_index do |ent, i|
    plan = plans[i]
    actual_removed = multiset_diff(ent[:body], b[i][:body])
    actual_added = multiset_diff(b[i][:body], ent[:body])
    expect_removed = multiset_diff(plan[:removed], plan[:added])
    expect_added = multiset_diff(plan[:added], plan[:removed])
    if actual_removed != expect_removed
      errors << "#{ent[:heading][0, 50]}: 計画外の行が消えている/消えるはずの行が残っている: " \
                "実際=#{fmt_ms(actual_removed)} 期待=#{fmt_ms(expect_removed)}"
    end
    if actual_added != expect_added
      errors << "#{ent[:heading][0, 50]}: 計画外の行が増えている/増えるはずの行が無い: " \
                "実際=#{fmt_ms(actual_added)} 期待=#{fmt_ms(expect_added)}"
    end
  end
  errors
end

def fmt_ms(ms)
  return "なし" if ms.empty?
  ms.map { |k, v| "#{k.strip.empty? ? '(空行)' : k[0, 40]}×#{v}" }.join(" / ")
end

# ---------------------------------------------------------------------------
# バリデータによる前後比較（検算 3）
# ---------------------------------------------------------------------------

def validator_path
  File.expand_path("validate-artifact.rb", __dir__)
end

# 違反メッセージの集合を返す（行番号は移行でずれるため落とす）。nil は検査不能。
def validator_violations(kind, file)
  out = IO.popen(["/usr/bin/ruby", validator_path, kind, file], err: File::NULL, &:read)
  case $?.exitstatus
  when 0 then []
  when 1 then out.split("\n").map { |l| l.sub(/\A#{Regexp.escape(file)}:\d+: /, "") }.sort
  else nil
  end
rescue SystemCallError => e
  uncheckable("バリデータを起動できません: #{validator_path}（#{e.message}）")
end

# ---------------------------------------------------------------------------
# scaffold 追従レポート（検出のみ・書き換えない）
# ---------------------------------------------------------------------------

# テンプレートとの差分を報告する「純粋なコピー物」。利用先固有の記入欄を持たないため
# 差分＝テンプレート更新の可能性が高いが、カスタマイズと区別できないので**自動再生成はしない**。
DOC_COPIES = {
  "runtime/README.md" => "runtime/README.md",
  "journal/README.md" => "journal/README.md",
  "journal/cycle-template.md" => "journal/cycle-template.md",
  "container/Dockerfile" => "container/Dockerfile",
  "container/compose.yml" => "container/compose.yml",
}.freeze

# 生成されるべき scaffold 物（skills/flywheel-init/SKILL.md のツリー。任意の
# challenge-sources.md は含めない）。不足は flywheel-init の scaffold 手順が埋める。
SCAFFOLD_PATHS = [
  "CLAUDE.md", "challenge-ledger.md", "priority-policy.md", "repos.tsv",
  ".claude/settings.json", ".flywheel/cadence.json", ".gitignore",
  "positions", "memory", "journal", "runtime", "container"
].freeze

def scaffold_report(ws, templates)
  notes = []

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
    body = File.read(gitignore, encoding: "UTF-8")
    lines = body.split("\n")
    notes << "`.gitignore`: `.flywheel/*` の行が無い（`.flywheel/` 丸ごと ignore だと cadence.json を追跡できない）" unless lines.include?(".flywheel/*")
    notes << "`.gitignore`: `!.flywheel/cadence.json` の行が無い（cadence.json は運用設定として Git 追跡する）" unless lines.include?("!.flywheel/cadence.json")
    notes << "`.gitignore`: 旧形式の `.flywheel/`（ディレクトリ丸ごと ignore）が残っている（`.flywheel/*` ＋ unignore へ置き換える）" if lines.include?(".flywheel/")
    notes << "`.gitignore`: `container/.env` の行が無い（ホスト固有のため追跡しない）" unless lines.include?("container/.env")
  end

  settings = File.join(ws, ".claude/settings.json")
  if File.exist?(settings)
    body = File.read(settings, encoding: "UTF-8")
    notes << "`.claude/settings.json`: `Bash(claude -p:*)` の allow が無い（自走委譲が分類器でブロックされる）" unless body.include?("Bash(claude -p:*)")
  end

  dockerfile = File.join(ws, "container/Dockerfile")
  if File.exist?(dockerfile)
    body = File.read(dockerfile, encoding: "UTF-8")
    notes << "`container/Dockerfile`: ruby を導入していない（コミットゲート＝validate-artifact.rb が起動できない。contracts/README.md §実行環境の前提）" unless body =~ /\bruby\b/
  end

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

targets = [["challenge-ledger.md", "ledger"], ["challenge-archive.md", "archive"]]
results = []
missing = []
targets.each do |name, kind|
  path = File.join(ws, name)
  if File.exist?(path)
    results << migrate_file(path, kind, canonical)
  else
    missing << name
  end
end

changed = results.select { |r| r[:before] != r[:after] }
errors = results.flat_map { |r| r[:errors].map { |e| "#{r[:path]}: #{e}" } }
manual = results.flat_map { |r| r[:manual] }
notes = scaffold_report(ws, templates)

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
  failed("構造の差分検算に失敗したため 1 バイトも書き込んでいません（#{errors.size} 件）")
end

if changed.empty?
  puts
  puts "変更はありません（現行テンプレートに追従済み）。"
  exit EXIT_OK
end

unless apply
  puts
  puts "dry-run（既定）です。適用するには --apply を付けて再実行してください。"
  exit EXIT_PENDING
end

# --- 適用: 一時ファイル → 検算 → バックアップ → 置換 ---

staged = []
begin
  changed.each do |r|
    tmp = "#{r[:path]}.migrate-tmp"
    File.open(tmp, "w:UTF-8") { |f| f.write("#{r[:after].join("\n")}\n") }
    staged << [r, tmp]
  end

  staged.each do |r, tmp|
    before_v = validator_violations(r[:kind], r[:path])
    after_v = validator_violations(r[:kind], tmp)
    if before_v.nil? || after_v.nil?
      failed("バリデータが検査不能を返したため適用しません: #{r[:path]}（`#{validator_path} #{r[:kind]} <file>` を手で実行して原因を確認）")
    end
    introduced = after_v - before_v
    unless introduced.empty?
      puts "== バリデータ検算エラー（適用しない）: #{r[:path]}"
      introduced.each { |v| puts "  - #{v}" }
      failed("移行後に新しい違反が出たため 1 バイトも書き込んでいません: #{r[:path]}")
    end
    r[:validator] = [before_v.size, after_v.size]
  end

  backup_dir ||= File.join(ws, ".flywheel", "migration-backup", Time.now.strftime("%Y%m%d-%H%M%S"))
  FileUtils.mkdir_p(backup_dir)
  staged.each do |r, _|
    FileUtils.cp(r[:path], File.join(backup_dir, File.basename(r[:path])))
  end

  staged.each { |r, tmp| File.rename(tmp, r[:path]) }
rescue SystemCallError => e
  staged.each { |_, tmp| File.unlink(tmp) if File.exist?(tmp) }
  failed("書き込みに失敗しました（一時ファイルは削除済み・元ファイルは無傷）: #{e.message}")
end

puts
puts "== 適用しました"
puts "  バックアップ: #{backup_dir}"
changed.each do |r|
  b, a = r[:validator]
  puts "  - #{r[:path]}: バリデータ違反 #{b} 件 → #{a} 件"
end
puts "  ※ 変更内容は `git diff` で確認し、コミットは人間/エージェントが行ってください。"
exit EXIT_OK
