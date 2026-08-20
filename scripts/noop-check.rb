#!/usr/bin/ruby
# frozen_string_literal: true

# noop-check.rb — 「当周に外部状態の変化があったか」を機械的に判定する（読み取り専用）。
#
# run-cycle 手順6 が **journal 書き出し後・コミット前**に呼び、当周のサイクルコミットを
# 「打つ」か「次にコミットする周へ束ねる（保留）」かを決める（Issue #82）。記録（`.md` と
# `index.jsonl` の 1 周 1 件）は従来どおり毎周行い、**コミットの回数だけ**を減らす方式のため、
# スキーマ・1:1 対応・`--expect-cycle` の同一性証明・reflect / start-day のしきい値判定
# （`index.jsonl` の行数）はいずれも変わらない。
#
# **最悪の失敗様式は「変化があったのに no-op と判定し、成果がコミットされずワーキングツリーに
# 滞留する」こと**（未追跡の保留 `.md` は `git clean -fd` 等で失われうる）。判定は一貫して
# fail-closed に倒す＝迷ったらコミットする。
#
# 使い方:
#   scripts/noop-check.rb --cycle <YYYY-MM-DD-cycle[-N]> [--workspace <dir>]
#                         [--anchor-after-line <n>] [--journal-dir <rel>]
#                         [--paths-file <path>] [--exclude <rel>]... [--notable <理由>]...
#
#   --cycle        当周のサイクル名（手順0の `cycle_start` で確定した journal ファイル名の
#                  basename。`YYYY-MM-DD-cycle` または `YYYY-MM-DD-cycle-N`）。必須
#   --workspace    エージェント repo のルート（既定: `.`）。**Git 作業ツリーのトップでなければ
#                  判定不能**（パス解決の曖昧さを持ち込まないため）
#   --anchor-after-line <n>
#                  当周の `cycle_start` を append する**直前**の runs.jsonl の行数（ファイル
#                  不在なら 0。手順0 が控えた値をそのまま渡す）。行 n より後にある当周名の
#                  `cycle_start` だけをアンカーとして採り、そこから**最初の一致**を使う。
#                  クラッシュ後のサイクル名再利用では同名の `cycle_start` が 2 本並びうるため、
#                  名前一致だけでは当周の範囲を特定できない（`validate-artifact.rb` の
#                  `--anchor-after-line` と同一の意味論・同一の失敗様式への対処）。
#                  **未指定で同名の `cycle_start` が 2 本以上ある場合は判定不能**にする
#                  （最後の一致を採ると 2 本に挟まれた委譲イベントが検査範囲から丸ごと漏れる）
#   --journal-dir  workspace からの journal ディレクトリの相対パス（既定: `journal`）
#   --paths-file   サイクルコミットのパス集合の正本（既定: 本スクリプトからの相対
#                  `../contracts/cycle-commit-paths.txt`。vendoring 先で層構成が変わる場合に指定）
#   --exclude      dirty でも判定に影響させないパスを**追加**する（正本ファイルの `[exclude]`
#                  に対する運用上の上乗せ。既知のノイズを宣言的に黙らせるため）。複数回指定可
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
#   `--help` も **exit 2** で返す（判定を一切行っていない経路が exit 0＝「保留可」を名乗らない）。
#   予期しない例外も rescue して exit 2 にする（Ruby 既定の exit 1 だと「変化あり」に化け、
#   `decision=`・`reason=` の無い出力を呼び出し側が根拠として転記することになるため）。
#
# stdout（exit 0/1/2 いずれでも出力する。本スクリプトの出力は違反リストではなく
# 「判断と、次に必要な数」であるため、exit 0 でも無出力にしない）:
#   decision=commit|defer      呼び出し側が取るべき行動（exit 2 でも commit を出す＝fail-closed）
#   commit_path=<path>         サイクルコミットの許可パス（正本ファイルの `[commit]` をそのまま
#                              出力。手順6 の `git add` / pathspec に使う）
#   pending_index_lines=<n>    index.jsonl の未コミット追記**レコード数**（空行を数えない＝
#                              バリデータの `--tail` と同じ規則。当周分を含む）。コミットする
#                              周の `validate-artifact.rb journal-index --tail <n>` に渡す。
#                              判定できなかった場合は出力しない
#   pending_cycles=<n>         未コミットの**新規**サイクル `.md` の件数（= pending_index_lines
#                              でなければ 1:1 対応の破れ＝判定不能）
#   pending_md=<n>             `pending_md_file=` の行数
#   pending_md_file=<path>     まとめコミット前に `journal-md` 検査を通すべき `.md`（新規＋
#                              append-only が破れた既存分。workspace からの相対）
#   reason=<code>: <説明>      commit と判断した根拠（0 行以上）
#
# 「no-op」の機械的定義（**すべて**成り立つときだけ no-op。1 つでも欠ければコミット）:
#   1. ワーキングツリーに未コミットの差分が無い（journal と `[exclude]` 宣言済みパスを除く。
#      **監視は許可パスの列挙ではなくツリー全体**＝新しいパスが黙って「変化なし」側へ落ちない）
#   2. 当周の `index.jsonl` 行の `touched_issues` / `delegations` / `pr_urls` がすべて空
#   3. `pending_approvals` の (gate, issue) 集合が前周の行と一致する（新規発生・解消は変化）
#   4. 当周の `.md` の ①触った課題 ②委譲 ③PR・ブランチ URL ④承認待ちゲート一覧 に
#      「該当なし」の宣言以外の記載が無い（`index.jsonl` と `.md` の 1:1 の食い違いを取り
#      こぼさないための裏取り）。**`.md` の構造が契約どおりでなければ判定不能**にする
#      （見出しのずれ・閉じない HTML コメントで対象セクションを見失うと、実記載があっても
#      全行が読み飛ばされて条件4が空虚に真になるため）
#   5. 当周の runs.jsonl に `cycle_start` / `cycle_end` 以外のイベントが無い
#      （委譲・差し込み・`delegate_end` の事後補記が起きていない）
#   6. `--notable` が 1 件も渡されていない
#   7. 未コミットの journal `.md` が当周と同じ日付のものだけ（＝保留は当日内に限る。
#      日を跨いだ保留はフラッシュする＝無人放置の上限を「当日 + 次の 1 周」に抑える）
#
#   `decisions`（判断と根拠 / `.md` の⑤）は**判定に使わない**: run-cycle は変化ゼロの周でも
#   必ず何らかの判断を書き残すため（実運用ワークスペースの 20/20 周で非空）「変化の信号」に
#   ならず、含めると本機能が一度も発火しない。`decisions` に載る事象のうち「変化」に当たる
#   ものは上記 1〜6 のいずれかが捕捉する（機械で捕捉できない事象は `--notable` で渡す）。

require "json"

EXIT_NOOP = 0
EXIT_CHANGED = 1
EXIT_UNCHECKABLE = 2

USAGE = "usage: #{$PROGRAM_NAME} --cycle <YYYY-MM-DD-cycle[-N]> [--workspace <dir>] [--anchor-after-line <n>] [--journal-dir <rel>] [--paths-file <path>] [--exclude <rel>]... [--notable <理由>]..."

# `.md` の定型 5 セクション（**contracts の journal-md 検査と同一の文字列**。片方だけ改名すると
# 条件4 が静かに素通しになるため、テストが両者の一致を固定している）。
JOURNAL_SECTIONS = [
  "## 触った課題",
  "## 委譲",
  "## 作成した PR・ブランチの URL",
  "## 承認待ちゲート一覧",
  "## 判断と根拠",
].freeze

# うち「外部への働きかけ」を表すセクション（⑤判断と根拠は上記の理由で判定に使わない）。
ACTIVITY_SECTIONS = JOURNAL_SECTIONS[0, 4].freeze

# journal ディレクトリに存在してよい非サイクルファイル（未コミットでも「変化」にしない）。
JOURNAL_META_FILES = %w[README.md cycle-template.md index.jsonl].freeze

CYCLE_NAME_RE = /\A([0-9]{4}-[0-9]{2}-[0-9]{2})-cycle(?:-([0-9]+))?\z/.freeze

# 「該当なし」の宣言と認める形: `なし` で始まり、続きに**数字も URL も含まない**もの。
# 実運用の journal は `- なし（台帳に課題エントリなし）` のように理由を括弧書きで添えるため
# 完全一致では本機能が一度も発火しない。一方で `- なし（C-035 は完了しアーカイブ済み）` /
# `- なし（既存 PR https://… に push）` / `- なし（FR-22 は解消）` のように**括弧の中へ実際の
# 変化を書く**形は取りこぼしになる。課題 ID・ゲート名・PR 番号・URL・session_id・日付は
# いずれも数字か `http` を含むため、この 2 つを禁じるだけでキーワード表を持たずに塞げる。
NONE_TAIL_FORBIDDEN = /[0-9０-９]|http/.freeze

# ---------------------------------------------------------------------------
# 出力バッファ（判定不能でも decision= を必ず出すため、最後にまとめて出す）
# ---------------------------------------------------------------------------

REASONS = []
UNCHECKABLE = []
COMMIT_PATHS = []
PENDING_MD_FILES = []   # まとめコミット前に journal-md 検査を通すべき .md（新規＋破れた既存）
NEW_CYCLE_MDS = []      # 未コミットの「新規」サイクル .md（1:1 の相手が index の追記行）
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
  COMMIT_PATHS.each { |p| puts "commit_path=#{p}" }
  puts "pending_index_lines=#{PENDING_INDEX_LINES.first}" unless PENDING_INDEX_LINES.empty?
  puts "pending_cycles=#{NEW_CYCLE_MDS.size}"
  puts "pending_md=#{PENDING_MD_FILES.size}"
  PENDING_MD_FILES.each { |p| puts "pending_md_file=#{p}" }
  REASONS.each { |r| puts "reason=#{r}" }
  UNCHECKABLE.each { |m| warn "noop-check: 判定不能: #{m}" }
  exit status
end

def die(msg)
  warn "noop-check: 判定不能: #{msg}"
  warn USAGE
  exit EXIT_UNCHECKABLE
end

# ---------------------------------------------------------------------------
# 入出力ユーティリティ
# ---------------------------------------------------------------------------

# UTF-8 として妥当なテキストだけを返す（不正バイトは「判定不能」。兄弟スクリプト
# validate-artifact.rb と同じ規律。放置すると strip/lstrip が ArgumentError を投げ、
# Ruby 既定の exit 1＝契約上の「変化あり」に化ける）。
def read_text_lines(path, label)
  content = File.binread(path)
  content.force_encoding(Encoding::UTF_8)
  unless content.valid_encoding?
    uncheckable("#{label} が UTF-8 として不正です: #{path}")
    return nil
  end
  content.lines
rescue SystemCallError => e
  uncheckable("#{label} を読み取れません（#{e.class}）: #{path}")
  nil
end

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

def under?(path, prefix)
  path == prefix || path.start_with?("#{prefix}/")
end

# サイクルコミットのパス集合の正本を読む。[commit 配列, exclude 配列] または nil。
def load_paths_file(path)
  lines = read_text_lines(path, "パス正本ファイル")
  return nil if lines.nil?
  section = nil
  commit = []
  exclude = []
  lines.each_with_index do |raw, i|
    line = raw.strip
    next if line.empty? || line.start_with?("#")
    case line
    when "[commit]"  then section = :commit
    when "[exclude]" then section = :exclude
    else
      if section.nil?
        uncheckable("パス正本ファイルの #{i + 1} 行目がセクション（[commit] / [exclude]）の外にあります: #{path}")
        return nil
      end
      (section == :commit ? commit : exclude) << line
    end
  end
  if commit.empty?
    uncheckable("パス正本ファイルの [commit] が空です: #{path}")
    return nil
  end
  [commit, exclude]
end

def parse_record(line)
  rec = JSON.parse(line)
  rec.is_a?(Hash) ? rec : nil
rescue JSON::ParserError
  nil
end

def approval_key_set(rec)
  list = rec["pending_approvals"]
  return nil unless list.is_a?(Array)
  keys = []
  list.each do |a|
    return nil unless a.is_a?(Hash)
    keys << [a["gate"], a["issue"]]
  end
  keys.sort_by { |k| k.map(&:to_s) }
end

# 「該当なし」の宣言か（上記 NONE_TAIL_FORBIDDEN のコメント参照）。
def none_declaration?(body)
  return false unless body.start_with?("なし")
  !NONE_TAIL_FORBIDDEN.match?(body[2..-1].to_s)
end

# ---------------------------------------------------------------------------
# 引数解析
# ---------------------------------------------------------------------------

workspace = "."
journal_dir = "journal"
paths_file = File.expand_path("../contracts/cycle-commit-paths.txt", __dir__)
cycle = nil
anchor_after = nil
extra_excludes = []
notables = []

args = ARGV.dup
until args.empty?
  arg = args.shift
  case arg
  when "-h", "--help"
    # 判定を行っていない経路が exit 0（=「保留可」）を名乗らないよう、ヘルプも exit 2。
    puts USAGE
    exit EXIT_UNCHECKABLE
  when "--workspace", "--journal-dir", "--cycle", "--paths-file", "--exclude", "--notable", "--anchor-after-line"
    val = args.shift
    die("オプションに値がありません: #{arg}") if val.nil? || val.empty? || val.start_with?("--")
    case arg
    when "--workspace"         then workspace = val
    when "--journal-dir"       then journal_dir = val
    when "--cycle"             then cycle = val
    when "--paths-file"        then paths_file = val
    when "--exclude"           then extra_excludes << val
    when "--notable"           then notables << val
    when "--anchor-after-line"
      die("--anchor-after-line は 0 以上の整数が必要です: #{val.inspect}") unless val =~ /\A[0-9]+\z/
      anchor_after = val.to_i
    end
  else
    die("不明な引数: #{arg}")
  end
end

die("--cycle は必須です") if cycle.nil?

m = CYCLE_NAME_RE.match(cycle)
die("--cycle はサイクル名（YYYY-MM-DD-cycle または YYYY-MM-DD-cycle-N）が必要です: #{cycle.inspect}") if m.nil?
cycle_date = m[1]
cycle_seq = m[2] ? m[2].to_i : 1

die("workspace ディレクトリが存在しません: #{workspace}") unless File.directory?(workspace)

# ---------------------------------------------------------------------------
# 判定本体（予期しない例外も 3 値 exit の外へ出さない）
# ---------------------------------------------------------------------------

begin
  toplevel, top_st = git_capture(workspace, "rev-parse", "--show-toplevel")
  if top_st.nil?
    emit_and_exit # git_capture が uncheckable を積んでいる
  elsif !top_st.zero?
    uncheckable("Git 作業ツリーではありません（git rev-parse が exit #{top_st}）: #{workspace}")
    emit_and_exit
  elsif !File.identical?(toplevel.to_s.strip, workspace)
    # porcelain のパスは repo ルート相対。workspace がサブディレクトリだと本スクリプトの
    # 相対パス解決（journal / paths-file の分類）とずれるため、トップ以外は受け付けない。
    uncheckable("--workspace が Git 作業ツリーのトップではありません（トップ: #{toplevel.to_s.strip}）: #{workspace}")
    emit_and_exit
  end

  paths = load_paths_file(paths_file)
  emit_and_exit if paths.nil?
  commit_paths, exclude_paths = paths
  COMMIT_PATHS.concat(commit_paths)
  exclude_paths += extra_excludes

  # ---- 6. 特筆事項（--notable）----

  notables.each { |n| changed("notable", n) }

  # ---- 1. ワーキングツリー全体の未コミット差分 ----
  #
  # 許可パスの列挙を監視範囲にすると、列挙から漏れたパス（positions/・repos.tsv・CLAUDE.md 等）
  # の変更が黙って「変化なし」側へ落ちる。ツリー全体を見て「分類できないパスも変化として扱う」
  # ことで、パス集合がずれても fail-closed の側に倒れる。

  status_out, status_st = git_capture(workspace, "status", "--porcelain", "-z", "--untracked-files=all")
  emit_and_exit if status_out.nil?
  unless status_st.zero?
    uncheckable("git status が失敗しました（exit #{status_st}）: #{workspace}")
    emit_and_exit
  end
  entries = parse_porcelain_z(status_out)

  journal_entries = []
  in_scope = []
  out_of_scope = []
  entries.each do |xy, path|
    if under?(path, journal_dir)
      journal_entries << [xy, path]
      next
    end
    next if exclude_paths.any? { |e| under?(path, e) }
    if commit_paths.any? { |c| under?(path, c) }
      in_scope << "#{xy.strip} #{path}"
    else
      out_of_scope << "#{xy.strip} #{path}"
    end
  end

  unless in_scope.empty?
    changed("state-dirty", "サイクルコミットの許可パスに未コミットの差分があります: #{in_scope.sort.join(', ')}")
  end
  unless out_of_scope.empty?
    changed("out-of-scope-dirty",
            "サイクルコミットの対象外のパスに未コミットの差分があります（人間の作業中か、#{paths_file} の見直しが必要）: #{out_of_scope.sort.join(', ')}")
  end

  # ---- 7. 未コミットの journal（保留は当日内に限る）----

  index_rel = File.join(journal_dir, "index.jsonl")
  journal_entries.each do |xy, path|
    base = File.basename(path)
    next if path == index_rel
    next if JOURNAL_META_FILES.include?(base) && File.dirname(path) == journal_dir

    unless base.end_with?(".md") && CYCLE_NAME_RE.match(base.sub(/\.md\z/, ""))
      changed("journal-unknown-file", "journal に想定外の未コミットファイルがあります: #{xy.strip} #{path}")
      next
    end
    PENDING_MD_FILES << path
    if xy.start_with?("?")
      NEW_CYCLE_MDS << path
    else
      # append-only（既存 .md は書き換えない）の破れ。保留せず必ずコミットへ回し、
      # まとめコミット前の journal-md 検査対象にも載せる。
      changed("journal-md-modified", "既存の journal .md に未コミットの変更があります（append-only の破れ）: #{xy.strip} #{path}")
    end
  end
  PENDING_MD_FILES.sort!
  NEW_CYCLE_MDS.sort!

  NEW_CYCLE_MDS.each do |path|
    d = CYCLE_NAME_RE.match(File.basename(path).sub(/\.md\z/, ""))[1]
    next if d == cycle_date
    changed("stale-batch", "当周（#{cycle_date}）と異なる日付の未コミット journal があります: #{path}")
  end

  # ---- index.jsonl の未コミット追記レコード数 ----
  #
  # バリデータの `--tail n` は**非空レコード**基準で数える。物理追加行数（git diff --numstat）
  # で数えると、保留区間に空行が混ざったときに `--tail` が既コミット行まで遡り、契約導入前の
  # 不正行に当たってまとめコミットが恒久的に失敗する（`--tail` の範囲限定はまさにその恒久失敗
  # を避けるための機構）。同じ規則＝「現在の非空レコード数 − HEAD の非空レコード数」で数える。

  index_abs = File.join(workspace, index_rel)
  current_lines = nil
  if !File.file?(index_abs)
    uncheckable("index.jsonl が見つかりません（当周の追記が行われていない可能性）: #{index_abs}")
  else
    current_lines = read_text_lines(index_abs, "index.jsonl")
  end
  index_records = current_lines ? current_lines.reject { |l| l.strip.empty? } : []

  if current_lines
    tracked_out, tracked_st = git_capture(workspace, "ls-files", "--error-unmatch", "--", index_rel)
    if tracked_st.nil?
      # git_capture が uncheckable 済み
    elsif !tracked_st.zero? || tracked_out.to_s.strip.empty?
      PENDING_INDEX_LINES << index_records.size # 未追跡＝全レコードが未コミット
    else
      head_out, head_st = git_capture(workspace, "show", "HEAD:./#{index_rel}")
      if head_st.nil?
        # uncheckable 済み
      elsif !head_st.zero?
        uncheckable("HEAD の index.jsonl を取得できません（git show が exit #{head_st}）: #{index_rel}")
      else
        head_out.force_encoding(Encoding::UTF_8)
        if !head_out.valid_encoding?
          uncheckable("HEAD の index.jsonl が UTF-8 として不正です: #{index_rel}")
        else
          head_lines = head_out.lines
          # append-only の不変条項: HEAD の内容は現在の内容の**前方一致**でなければならない。
          # （numstat の削除行数チェックより強い＝途中行の書き換えも検出する）
          if head_lines.size > current_lines.size || current_lines[0, head_lines.size] != head_lines
            uncheckable("index.jsonl が append-only ではありません（HEAD の内容が現在の内容の先頭と一致しません）: #{index_rel}")
          else
            PENDING_INDEX_LINES << (index_records.size - head_lines.reject { |l| l.strip.empty? }.size)
          end
        end
      end
    end
  end

  if !PENDING_INDEX_LINES.empty? && PENDING_INDEX_LINES.first < 1
    PENDING_INDEX_LINES.clear
    uncheckable("index.jsonl に当周の未コミット追記レコードがありません（1 周 1 行 append の欠落を確認）: #{index_rel}")
  end

  # ---- 保留分の 1:1 対応（`.md` 1 件 ↔ index 1 レコード）----

  if !PENDING_INDEX_LINES.empty? && PENDING_INDEX_LINES.first != NEW_CYCLE_MDS.size
    uncheckable("保留分の 1:1 対応が崩れています（index の未コミット追記 #{PENDING_INDEX_LINES.first} レコード / 新規 journal .md #{NEW_CYCLE_MDS.size} 件）。保留中の .md の消失〔git clean 等〕や append の重複を確認")
  end

  # ---- 2/3. 当周の index.jsonl 行の内容・承認待ち集合の変化 ----

  unless index_records.empty?
    current = parse_record(index_records.last)
    if current.nil?
      uncheckable("index.jsonl の末尾レコードを JSON として解析できません: #{index_rel}")
    elsif current["date"] != cycle_date || current["seq"] != cycle_seq
      uncheckable("index.jsonl の末尾レコードが当周の行ではありません（期待: date=#{cycle_date} seq=#{cycle_seq} / 実際: date=#{current['date'].inspect} seq=#{current['seq'].inspect}）")
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
      elsif index_records.size < 2
        changed("approval-set-changed", "比較対象の前周行がありません（承認待ち #{current_keys.size} 件）") unless current_keys.empty?
      else
        previous = parse_record(index_records[-2])
        previous_keys = previous ? approval_key_set(previous) : nil
        if previous_keys.nil?
          uncheckable("index.jsonl の前周行の pending_approvals を読めず、承認待ちの変化を判定できません")
        elsif previous_keys != current_keys
          changed("approval-set-changed", "承認待ちゲートの集合が前周から変化しています（前周 #{previous_keys.size} 件 → 当周 #{current_keys.size} 件）")
        end
      end
    end
  end

  # ---- 4. 当周の .md の構造検査 ＋ ①〜④ の記載 ----
  #
  # 構造検査を先に行い、契約どおりでなければ**判定不能**にする。`.md` の契約適合を検証するのは
  # 手順6 の検算（本判定より後）であり、見出しのずれ・閉じない HTML コメントで対象セクションを
  # 見失うと、実記載があっても全行が読み飛ばされて条件4が空虚に真になるため。

  md_abs = File.join(workspace, journal_dir, "#{cycle}.md")
  if !File.file?(md_abs)
    uncheckable("当周の journal .md が見つかりません: #{md_abs}")
  else
    md_lines = read_text_lines(md_abs, "当周の journal .md")
    if md_lines
      headings = []   # [lineno, 見出し, セクション本文の行]
      body_of = {}
      section = nil
      in_comment = false
      unterminated_comment_at = nil
      md_lines.each_with_index do |raw, idx|
        line = raw.rstrip
        if in_comment
          if line.include?("-->")
            in_comment = false
            unterminated_comment_at = nil
          end
          next
        end
        if line.lstrip.start_with?("<!--")
          unless line.include?("-->")
            in_comment = true
            unterminated_comment_at = idx + 1
          end
          next
        end
        if line.start_with?("#")
          if line.start_with?("## ")
            section = line
            headings << [idx + 1, line]
            body_of[line] = []
          else
            section = nil
          end
          next
        end
        body_of[section] << [idx + 1, line] if section && body_of.key?(section)
      end

      titles = headings.map { |_, h| h }
      if unterminated_comment_at
        uncheckable("当周の journal .md に閉じていない HTML コメントがあります（#{md_abs}:#{unterminated_comment_at}）。以降のセクションを読み取れず条件4を判定できない")
      elsif (JOURNAL_SECTIONS - titles).any?
        uncheckable("当周の journal .md に定型セクションがありません: #{(JOURNAL_SECTIONS - titles).join('・')}（#{md_abs}）。契約適合は手順6 の journal-md 検算で確認すること")
      elsif (titles - JOURNAL_SECTIONS).any?
        uncheckable("当周の journal .md に定型 5 セクションに無い見出しがあります: #{(titles - JOURNAL_SECTIONS).join('・')}（#{md_abs}）")
      elsif titles.uniq != titles
        uncheckable("当周の journal .md に定型セクションの重複があります（#{md_abs}）")
      else
        ACTIVITY_SECTIONS.each do |sec|
          body_of[sec].each do |lineno, line|
            next if line.strip.empty?
            body = line.sub(/\A\s*[-*+]\s*/, "").strip.delete("`").strip
            next if body.empty? || none_declaration?(body)
            changed("journal-md-content", "#{sec} に記載があります（#{md_abs}:#{lineno}）: #{body}")
          end
        end
      end
    end
  end

  # ---- 5. 当周の runs.jsonl に cycle_start / cycle_end 以外のイベントが無いこと ----

  runs_abs = File.join(workspace, ".flywheel", "runs.jsonl")
  if !File.file?(runs_abs)
    uncheckable("runs.jsonl が見つかりません（--workspace の指定を確認。当周に委譲・差し込みが無かったことを確認できない）: #{runs_abs}")
  else
    runs_lines = read_text_lines(runs_abs, "runs.jsonl")
    if runs_lines
      if anchor_after && runs_lines.size < anchor_after
        uncheckable("--anchor-after-line #{anchor_after} に対し runs.jsonl が #{runs_lines.size} 行しかありません（append-only の前提が破れています）: #{runs_abs}")
      else
        # 当周名の cycle_start を集める。位置アンカー指定時は「その行より後の**最初の**一致」。
        # 未指定で複数一致するなら当周の範囲を特定できない（最後の一致を採ると 2 本の
        # cycle_start に挟まれた委譲イベントが検査範囲から丸ごと漏れる）。
        matches = []
        runs_lines.each_with_index do |line, idx|
          next if anchor_after && idx < anchor_after
          next unless line.include?('"event":"cycle_start"')
          rec = parse_record(line)
          matches << idx if rec && rec["cycle"] == cycle
        end
        if matches.empty?
          where = anchor_after ? "行 #{anchor_after} より後に" : ""
          uncheckable("runs.jsonl に#{where}当周（#{cycle}）の cycle_start が見つかりません: #{runs_abs}")
        elsif matches.size > 1 && anchor_after.nil?
          uncheckable("runs.jsonl に当周（#{cycle}）の cycle_start が #{matches.size} 本あります（行 #{matches.map { |i| i + 1 }.join(', ')}）。--anchor-after-line で当周の位置を指定しないと、2 本に挟まれた委譲イベントが検査範囲から漏れる")
        else
          anchor = matches.first
          runs_lines.each_with_index do |line, idx|
            next if idx <= anchor
            next if line.strip.empty?
            rec = parse_record(line)
            if rec.nil?
              changed("run-events", "runs.jsonl の当周範囲に解析できない行があります（行 #{idx + 1}）")
              next
            end
            event = rec["event"].to_s
            if event == "cycle_start"
              # 別の周（あるいは同名の再起動）が始まっている＝当周の範囲を確定できない。
              uncheckable("runs.jsonl の当周範囲に別の cycle_start があります（行 #{idx + 1}・cycle=#{rec['cycle'].inspect}）")
              next
            end
            next if event == "cycle_end"
            changed("run-events", "当周に #{event} が記録されています（行 #{idx + 1}）")
          end
        end
      end
    end
  end
rescue StandardError => e
  uncheckable("予期しない例外（#{e.class}: #{e.message}）: #{e.backtrace ? e.backtrace.first : '-'}")
end

emit_and_exit
