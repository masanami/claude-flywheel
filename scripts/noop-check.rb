#!/usr/bin/ruby
# frozen_string_literal: true

# noop-check.rb — 「当周に外部状態の変化があったか」を機械的に判定する（読み取り専用）。
#
# run-cycle 手順6 が **journal 書き出し後・コミット前**に呼び、当周のサイクルコミットを
# 「打つ」か「次にコミットする周へ束ねる（保留）」かを決める（Issue #82）。記録（`.md` と
# `index.jsonl` の 1 周 1 件）は従来どおり毎周行い、**コミットの回数だけ**を減らす方式のため、
# スキーマ・1:1 対応・`--tail 1 --expect-cycle` の同一性証明・reflect / start-day の
# しきい値判定（`index.jsonl` の行数）はいずれも変わらない。
#
# 使い方:
#   scripts/noop-check.rb --cycle <YYYY-MM-DD-cycle[-N]> [--workspace <dir>]
#                         [--journal-dir <rel>] [--path <rel>]... [--notable <理由>]...
#
#   --cycle        当周のサイクル名（手順0の `cycle_start` で確定した journal ファイル名の
#                  basename。`YYYY-MM-DD-cycle` または `YYYY-MM-DD-cycle-N`）。必須
#   --workspace    エージェント repo のルート（既定: `.`）
#   --journal-dir  workspace からの journal ディレクトリの相対パス（既定: `journal`）
#   --path         「変化」を見る対象へ追加するパス（workspace からの相対。既定は
#                  challenge-ledger.md / challenge-archive.md / memory。複数回指定可）。
#                  **サイクルコミットの許可パスと一致させる**こと。`priority-policy.md` は
#                  サイクルコミットの対象外なので既定にも含めない
#   --notable      当周の特筆事項（機械では検出できず、かつ**本判定の時点で判明している**
#                  事象。1 件でも渡されたら no-op と判定しない）。渡す条件の列挙は
#                  run-cycle 手順6 が正本（heartbeat の exit 1/2・periodic-audit の起動など）。
#                  本判定より後に判明する事象（検算の exit 2・未終了 `*_start` の検出）は
#                  呼び出し側が「保留の取り消し条件」として後段で上書きする。複数回指定可
#
# exit code（3 値。判定不能を「変化なし」に丸めない）:
#   0 = no-op（当周のコミットを保留してよい）
#   1 = 変化あり（コミットせよ。stdout の `reason=` に根拠を列挙）
#   2 = 判定不能（stderr に理由。**呼び出し側は exit 1 と同じに扱う**＝コミットする）
#
#   **保留してよいのは exit 0 のときだけ**。本スクリプトの起動自体に失敗した場合
#   （ruby 未導入等で exit 126/127）も「判定不能」＝コミットする（contracts/README.md
#   §実行環境の前提と同じ縮退規律。ゲートが効かないときは従来どおりの毎周コミットに戻る）。
#
# stdout（exit 0/1/2 いずれでも出力する。本スクリプトの出力は違反リストではなく
# 「判断と、次に必要な数」であるため、exit 0 でも無出力にしない）:
#   decision=commit|defer      呼び出し側が取るべき行動（exit 2 でも commit を出す＝fail-closed）
#   pending_index_lines=<n>    index.jsonl の未コミット追記行数（当周分を含む）。
#                              コミットする周の `validate-artifact.rb journal-index --tail <n>`
#                              に渡す。判定できなかった場合は出力しない
#   pending_md=<n>             未コミットの journal `.md` の件数（当周分を含む）
#   pending_md_file=<path>     同上の各パス（workspace からの相対。n 行）
#   reason=<code>: <説明>      commit と判断した根拠（0 行以上）
#
# 「no-op」の機械的定義（**すべて**成り立つときだけ no-op。1 つでも欠ければコミット）:
#   1. 台帳・アーカイブ・memory（`--path` の対象）に未コミットの差分が無い（追跡・未追跡とも）
#   2. 当周の `index.jsonl` 行の `touched_issues` / `delegations` / `pr_urls` がすべて空
#   3. `pending_approvals` の (gate, issue) 集合が前周の行と一致する（新規発生・解消は変化）
#   4. 当周の `.md` の ①触った課題 ②委譲 ③PR・ブランチ URL ④承認待ちゲート一覧 に
#      `なし` で始まらない記載が無い（`index.jsonl` と `.md` の 1:1 の食い違いを取りこぼさ
#      ないため。理由を添えた `なし（…）` は「該当なし」の宣言として扱う）
#   5. 当周の runs.jsonl に `cycle_start` / `cycle_end` 以外のイベントが無い
#      （委譲・差し込み・`delegate_end` の事後補記が起きていない）
#   6. `--notable` が 1 件も渡されていない
#   7. 未コミットの journal `.md` が当周と同じ日付のものだけ（＝保留は当日内に限る。
#      日を跨いだ保留はフラッシュする＝無人放置の上限を「1 営業日 + 次の 1 周」に抑える）
#
#   `decisions`（判断と根拠 / `.md` の⑤）は**判定に使わない**: run-cycle は変化ゼロの周でも
#   必ず何らかの判断を書き残すため（実運用ワークスペースの 20/20 周で非空）「変化の信号」に
#   ならず、含めると本機能が一度も発火しない。`decisions` に載る事象のうち「変化」に当たる
#   ものは上記 1〜6 のいずれかが捕捉する（機械で捕捉できない事象は `--notable` で渡す）。

require "json"

EXIT_NOOP = 0
EXIT_CHANGED = 1
EXIT_UNCHECKABLE = 2

USAGE = "usage: #{$PROGRAM_NAME} --cycle <YYYY-MM-DD-cycle[-N]> [--workspace <dir>] [--journal-dir <rel>] [--path <rel>]... [--notable <理由>]..."

DEFAULT_PATHS = %w[challenge-ledger.md challenge-archive.md memory].freeze

# `.md` のうち「外部への働きかけ」を表すセクション（⑤判断と根拠は上記の理由で除外）。
ACTIVITY_SECTIONS = [
  "## 触った課題",
  "## 委譲",
  "## 作成した PR・ブランチの URL",
  "## 承認待ちゲート一覧",
].freeze

# journal ディレクトリに存在してよい非サイクルファイル（未コミットでも「変化」にしない）。
JOURNAL_META_FILES = %w[README.md cycle-template.md index.jsonl].freeze

CYCLE_NAME_RE = /\A([0-9]{4}-[0-9]{2}-[0-9]{2})-cycle(?:-([0-9]+))?\z/.freeze

# ---------------------------------------------------------------------------
# 出力バッファ（判定不能でも decision= を必ず出すため、最後にまとめて出す）
# ---------------------------------------------------------------------------

REASONS = []
UNCHECKABLE = []
PENDING_MD_FILES = []
PENDING_INDEX_LINES = [] # 0 or 1 要素（判定できたときだけ入れる）

def changed(code, msg)
  REASONS << "#{code}: #{msg}"
end

def uncheckable(msg)
  UNCHECKABLE << msg
end

def emit_and_exit
  status =
    if !UNCHECKABLE.empty?
      EXIT_UNCHECKABLE
    elsif !REASONS.empty?
      EXIT_CHANGED
    else
      EXIT_NOOP
    end
  puts(status == EXIT_NOOP ? "decision=defer" : "decision=commit")
  puts "pending_index_lines=#{PENDING_INDEX_LINES.first}" unless PENDING_INDEX_LINES.empty?
  puts "pending_md=#{PENDING_MD_FILES.size}"
  PENDING_MD_FILES.each { |p| puts "pending_md_file=#{p}" }
  REASONS.each { |r| puts "reason=#{r}" }
  UNCHECKABLE.each { |m| warn "noop-check: 判定不能: #{m}" }
  exit status
end

# ---------------------------------------------------------------------------
# git
# ---------------------------------------------------------------------------

# git を起動して stdout を返す。[出力, exitstatus]。起動自体に失敗したら [nil, nil]。
def git_capture(workspace, *args)
  out = nil
  IO.popen(["git", "-C", workspace, *args], "r", err: File::NULL) { |io| out = io.read }
  [out, $?.exitstatus]
rescue SystemCallError, IOError => e
  uncheckable("git を実行できません（#{e.class}: #{e.message}）")
  [nil, nil]
end

# `git status --porcelain -z` の出力を [[XY, path], ...] へ。R/C はコピー元を読み捨てる。
def parse_porcelain_z(raw)
  tokens = raw.split("\0")
  entries = []
  i = 0
  while i < tokens.size
    tok = tokens[i]
    i += 1
    next if tok.nil? || tok.empty?
    xy = tok[0, 2].to_s
    path = tok[3..-1].to_s
    entries << [xy, path]
    i += 1 if xy.start_with?("R", "C") # rename/copy は次トークンが元パス
  end
  entries
end

def porcelain(workspace, paths)
  out, st = git_capture(workspace, "status", "--porcelain", "-z", "--untracked-files=all", "--", *paths)
  return nil if out.nil?
  unless st.zero?
    uncheckable("git status が失敗しました（exit #{st}。--workspace が Git 作業ツリーか確認）: #{workspace}")
    return nil
  end
  parse_porcelain_z(out)
end

# ---------------------------------------------------------------------------
# 引数解析
# ---------------------------------------------------------------------------

workspace = "."
journal_dir = "journal"
cycle = nil
extra_paths = []
notables = []

args = ARGV.dup
until args.empty?
  arg = args.shift
  case arg
  when "-h", "--help"
    puts USAGE
    exit EXIT_NOOP
  when "--workspace", "--journal-dir", "--cycle", "--path", "--notable"
    val = args.shift
    if val.nil? || val.empty? || val.start_with?("--")
      warn "noop-check: 判定不能: オプションに値がありません: #{arg}"
      warn USAGE
      exit EXIT_UNCHECKABLE
    end
    case arg
    when "--workspace"   then workspace = val
    when "--journal-dir" then journal_dir = val
    when "--cycle"       then cycle = val
    when "--path"        then extra_paths << val
    when "--notable"     then notables << val
    end
  else
    warn "noop-check: 判定不能: 不明な引数: #{arg}"
    warn USAGE
    exit EXIT_UNCHECKABLE
  end
end

if cycle.nil?
  warn "noop-check: 判定不能: --cycle は必須です"
  warn USAGE
  exit EXIT_UNCHECKABLE
end

m = CYCLE_NAME_RE.match(cycle)
if m.nil?
  warn "noop-check: 判定不能: --cycle はサイクル名（YYYY-MM-DD-cycle または YYYY-MM-DD-cycle-N）が必要です: #{cycle.inspect}"
  warn USAGE
  exit EXIT_UNCHECKABLE
end
cycle_date = m[1]
cycle_seq = m[2] ? m[2].to_i : 1

unless File.directory?(workspace)
  warn "noop-check: 判定不能: workspace ディレクトリが存在しません: #{workspace}"
  exit EXIT_UNCHECKABLE
end

_toplevel, top_st = git_capture(workspace, "rev-parse", "--show-toplevel")
if top_st.nil?
  emit_and_exit # git_capture が uncheckable を積んでいる
elsif !top_st.zero?
  uncheckable("Git 作業ツリーではありません（git rev-parse が exit #{top_st}）: #{workspace}")
  emit_and_exit
end

# ---------------------------------------------------------------------------
# 6. 特筆事項（--notable）
# ---------------------------------------------------------------------------

notables.each { |n| changed("notable", n) }

# ---------------------------------------------------------------------------
# 1. 台帳・アーカイブ・memory の差分
# ---------------------------------------------------------------------------

state_paths = DEFAULT_PATHS + extra_paths
state_entries = porcelain(workspace, state_paths)
if state_entries && !state_entries.empty?
  listed = state_entries.map { |xy, path| "#{xy.strip} #{path}" }.sort.join(", ")
  changed("state-dirty", "台帳・記憶に未コミットの差分があります: #{listed}")
end

# ---------------------------------------------------------------------------
# 7. 未コミットの journal（保留は当日内に限る）＋ index.jsonl の追記行数
# ---------------------------------------------------------------------------

journal_entries = porcelain(workspace, [journal_dir])
index_rel = File.join(journal_dir, "index.jsonl")
index_dirty = false

if journal_entries
  journal_entries.each do |xy, path|
    base = File.basename(path)
    if path == index_rel
      index_dirty = true
      next
    end
    next if JOURNAL_META_FILES.include?(base) && File.dirname(path) == journal_dir

    unless base.end_with?(".md") && CYCLE_NAME_RE.match(base.sub(/\.md\z/, ""))
      changed("journal-unknown-file", "journal に想定外の未コミットファイルがあります: #{xy.strip} #{path}")
      next
    end
    if xy.start_with?("?")
      PENDING_MD_FILES << path
    else
      # append-only（既存 .md は書き換えない）の破れ。保留せず必ずコミットへ回す。
      PENDING_MD_FILES << path
      changed("journal-md-modified", "既存の journal .md に未コミットの変更があります（append-only の破れ）: #{xy.strip} #{path}")
    end
  end
  PENDING_MD_FILES.sort!

  PENDING_MD_FILES.each do |path|
    d = CYCLE_NAME_RE.match(File.basename(path).sub(/\.md\z/, ""))[1]
    next if d == cycle_date
    changed("stale-batch", "当周（#{cycle_date}）と異なる日付の未コミット journal があります: #{path}")
  end
end

index_abs = File.join(workspace, index_rel)
if !File.file?(index_abs)
  uncheckable("index.jsonl が見つかりません（当周の追記が行われていない可能性）: #{index_abs}")
elsif !File.readable?(index_abs)
  uncheckable("index.jsonl を読み取れません（権限不足の可能性）: #{index_abs}")
end

index_lines = []
if File.file?(index_abs) && File.readable?(index_abs)
  begin
    index_lines = File.readlines(index_abs, encoding: "UTF-8").reject { |l| l.strip.empty? }
  rescue SystemCallError => e
    uncheckable("index.jsonl を読み取れません（#{e.class}）: #{index_abs}")
  end
end

# 未コミット追記行数: 未追跡なら全行、追跡済みなら git diff の追加行数。
if journal_entries
  tracked_out, tracked_st = git_capture(workspace, "ls-files", "--error-unmatch", "--", index_rel)
  if tracked_st.nil?
    # git_capture が uncheckable 済み
  elsif !tracked_st.zero? || tracked_out.to_s.strip.empty?
    PENDING_INDEX_LINES << index_lines.size # 未追跡＝全行が未コミット
  else
    numstat, nst = git_capture(workspace, "diff", "HEAD", "--numstat", "--", index_rel)
    if nst.nil?
      # uncheckable 済み
    elsif !nst.zero?
      uncheckable("git diff HEAD --numstat が失敗しました（exit #{nst}）: #{index_rel}")
    else
      row = numstat.to_s.lines.map(&:strip).reject(&:empty?).first
      if row.nil?
        PENDING_INDEX_LINES << 0 unless index_dirty
      else
        added, deleted = row.split("\t", 3)[0, 2]
        if added == "-" || deleted == "-"
          uncheckable("index.jsonl がバイナリ扱いで追記行数を数えられません: #{index_rel}")
        elsif deleted.to_i.positive?
          uncheckable("index.jsonl に削除行があります（append-only 違反の疑い。#{deleted} 行削除）: #{index_rel}")
        else
          PENDING_INDEX_LINES << added.to_i
        end
      end
    end
  end
end

if !PENDING_INDEX_LINES.empty? && PENDING_INDEX_LINES.first < 1
  PENDING_INDEX_LINES.clear
  uncheckable("index.jsonl に当周の未コミット追記行がありません（1 周 1 行 append の欠落を確認）: #{index_rel}")
end

# ---------------------------------------------------------------------------
# 2/3. 当周の index.jsonl 行の内容・承認待ち集合の変化
# ---------------------------------------------------------------------------

def parse_record(line)
  rec = JSON.parse(line)
  rec.is_a?(Hash) ? rec : nil
rescue JSON::ParserError
  nil
end

def approval_key_set(rec)
  list = rec["pending_approvals"]
  return nil unless list.is_a?(Array)
  keys = list.map do |a|
    return nil unless a.is_a?(Hash)
    [a["gate"], a["issue"]]
  end
  keys.sort_by { |k| k.map(&:to_s) }
end

unless index_lines.empty?
  current = parse_record(index_lines.last)
  if current.nil?
    uncheckable("index.jsonl の末尾行を JSON として解析できません: #{index_rel}")
  elsif current["date"] != cycle_date || current["seq"] != cycle_seq
    uncheckable("index.jsonl の末尾行が当周の行ではありません（期待: date=#{cycle_date} seq=#{cycle_seq} / 実際: date=#{current['date'].inspect} seq=#{current['seq'].inspect}）")
  else
    %w[touched_issues delegations pr_urls].each do |field|
      value = current[field]
      if !value.is_a?(Array)
        uncheckable("index.jsonl の当周行の #{field} が配列ではありません（スキーマ違反）: #{value.inspect}")
      elsif !value.empty?
        changed("journal-activity", "当周の #{field} が空ではありません（#{value.size} 件）")
      end
    end

    current_keys = approval_key_set(current)
    if current_keys.nil?
      uncheckable("index.jsonl の当周行の pending_approvals の形が不正です（スキーマ違反）")
    elsif index_lines.size < 2
      changed("approval-set-changed", "比較対象の前周行がありません（承認待ち #{current_keys.size} 件）") unless current_keys.empty?
    else
      previous = parse_record(index_lines[-2])
      previous_keys = previous ? approval_key_set(previous) : nil
      if previous_keys.nil?
        uncheckable("index.jsonl の前周行の pending_approvals を読めず、承認待ちの変化を判定できません")
      elsif previous_keys != current_keys
        changed("approval-set-changed", "承認待ちゲートの集合が前周から変化しています（前周 #{previous_keys.size} 件 → 当周 #{current_keys.size} 件）")
      end
    end
  end
end

# ---------------------------------------------------------------------------
# 4. 当周の .md の ①〜④ に「なし」以外の記載が無いこと
# ---------------------------------------------------------------------------

md_abs = File.join(workspace, journal_dir, "#{cycle}.md")
if !File.file?(md_abs)
  uncheckable("当周の journal .md が見つかりません: #{md_abs}")
elsif !File.readable?(md_abs)
  uncheckable("当周の journal .md を読み取れません（権限不足の可能性）: #{md_abs}")
else
  begin
    md_lines = File.readlines(md_abs, encoding: "UTF-8")
  rescue SystemCallError => e
    md_lines = nil
    uncheckable("当周の journal .md を読み取れません（#{e.class}）: #{md_abs}")
  end

  if md_lines
    section = nil
    in_comment = false
    md_lines.each_with_index do |raw, idx|
      line = raw.rstrip
      # HTML コメント（雛形の説明文）は検査対象外。
      if in_comment
        in_comment = false if line.include?("-->")
        next
      end
      if line.lstrip.start_with?("<!--")
        in_comment = true unless line.include?("-->")
        next
      end
      if line.start_with?("#")
        section = line.start_with?("## ") ? line : nil
        next
      end
      next if section.nil? || !ACTIVITY_SECTIONS.include?(section)
      next if line.strip.empty?

      body = line.sub(/\A\s*[-*+]\s*/, "").strip.delete("`").strip
      # 「なし」で始まる行は明示的な「該当なし」の宣言とみなす（実運用の journal は
      # `- なし（台帳に課題エントリなし）` のように理由を括弧書きで添える。完全一致だけを
      # 通すと、本当に no-op の周でも常に「変化あり」になり本機能が発火しない）。
      # ①〜④に書かれる実際の記録（課題 ID・repo 名・URL・ゲート名）が「なし」で始まる
      # ことはないため、前方一致で十分に安全側を保てる。
      next if body.empty? || body.start_with?("なし")
      changed("journal-md-content", "#{section} に記載があります（#{md_abs}:#{idx + 1}）: #{body}")
    end
  end
end

# ---------------------------------------------------------------------------
# 5. 当周の runs.jsonl に cycle_start / cycle_end 以外のイベントが無いこと
# ---------------------------------------------------------------------------

runs_abs = File.join(workspace, ".flywheel", "runs.jsonl")
if !File.file?(runs_abs)
  uncheckable("runs.jsonl が見つかりません（--workspace の指定を確認。当周に委譲・差し込みが無かったことを確認できない）: #{runs_abs}")
elsif !File.readable?(runs_abs)
  uncheckable("runs.jsonl を読み取れません（権限不足の可能性）: #{runs_abs}")
else
  runs_lines = nil
  begin
    runs_lines = File.readlines(runs_abs, encoding: "UTF-8")
  rescue SystemCallError => e
    uncheckable("runs.jsonl を読み取れません（#{e.class}）: #{runs_abs}")
  end

  if runs_lines
    anchor = nil
    runs_lines.each_with_index do |line, idx|
      anchor = idx if line.include?('"event":"cycle_start"')
    end
    if anchor.nil?
      uncheckable("runs.jsonl に cycle_start がなく当周の開始点を特定できません: #{runs_abs}")
    else
      anchor_rec = parse_record(runs_lines[anchor])
      if anchor_rec.nil? || anchor_rec["cycle"] != cycle
        uncheckable("runs.jsonl の最後の cycle_start が当周（#{cycle}）のものではありません（行 #{anchor + 1}）: #{runs_abs}")
      else
        runs_lines.each_with_index do |line, idx|
          next if idx <= anchor
          next if line.strip.empty?
          rec = parse_record(line)
          if rec.nil?
            changed("run-events", "runs.jsonl の当周範囲に解析できない行があります（行 #{idx + 1}）")
            next
          end
          event = rec["event"].to_s
          next if %w[cycle_start cycle_end].include?(event)
          changed("run-events", "当周に #{event} が記録されています（行 #{idx + 1}）")
        end
      end
    end
  end
end

emit_and_exit
