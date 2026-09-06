#!/usr/bin/env ruby
# frozen_string_literal: true
#
# ledger-deps.rb — 課題台帳の**依存グラフ**（分類欄の `依存` フィールド）を解決し、
# 違反（自己参照・存在しない ID・循環依存）と**起動可能集合**を出力する。
#
# run-cycle 手順2（着手順のトポロジカル制約）と手順3（起動対象の絞り込み）が呼ぶ。
# 規定の正本は docs/challenge-ledger-format.md §依存（先行課題）。
#
# 使い方:
#   scripts/ledger-deps.rb <challenge-ledger.md> [<challenge-archive*.md> ...]
#   scripts/ledger-deps.rb --list-columns | --list-exits
#
#   第 1 引数が**台帳**（現在状態。投影の対象）、第 2 引数以降が**アーカイブ**（完了エントリの
#   履歴。依存先の完了判定にだけ使い、行としては出力しない）。
#   アーカイブは**年次分割を見越して glob で複数渡せる**（`challenge-archive*.md`。
#   docs/challenge-ledger-format.md §アーカイブ の将来の年次分割方針と同じ範囲）。
#
#   --list-columns  出力する列名を 1 行 1 件で出力して終了（exit 0）。
#   --list-exits    本スクリプト自身が返す終了コードの**宣言**（0 / 1 / 2）。
#                   いずれもテストが「宣言」と「振る舞い」の一致を双方向で固定するために使う。
#
# **markdown を自分で読み直さない（本スクリプトの要）**:
#   入力は scripts/ledger-index.rb の投影（TSV）であり、本スクリプトは
#   `ledger-index.rb` を子プロセスとして起動してその出力だけを読む。台帳の markdown を
#   パースする実装を **3 本目**（validate-artifact.rb / ledger-index.rb に続く）にすると、
#   エントリ境界・フェンス除外の意味論が 3 通りに分岐する。列の位置はハードコードせず
#   **ヘッダ行の列名で引く**（列を足しても壊れない）。
#
# **ファイルを作らない**: 読み取り専用で、書き込み先は stdout / stderr だけ。
#   `contracts/cycle-commit-paths.txt` に足すパスも無い。
#
# 出力（stdout・TSV・5 列・1 行目はヘッダ）。**台帳のエントリを 1 行ずつ**投影する:
#   id         課題 ID
#   status     ステータス（台帳の値）
#   deps       依存（先行課題 ID のカンマ区切り）。空なら `-`
#   unmet      依存のうち**完了していないもの**のカンマ区切り。空なら `-`
#              （存在しない ID は fail-closed でここに入る＝「見つからない」を完了に読み替えない）
#   startable  `y` = run-cycle 手順3 の起動対象（**ステータスが `着手中` かつ unmet が空**）
#              `-` = それ以外。**循環に属するノードと、そこから到達可能な後続ノードは必ず `-`**
#
# 違反（stderr へ列挙）:
#   self-reference   自分の ID を自分の `依存` に書いている
#   missing          依存先の ID が台帳にもアーカイブにも無い
#   cycle            循環依存（`A → B → A` 等）。**検出・報告のみで自動解決しない**
#                    ——どの辺を落とすかは課題の中身の判断であり、機械が並べ替えて
#                    解消できるものではない（同 §循環依存は検出・報告のみ）
#
# 終了コード（validate-artifact.rb と同じ 3 値。検査不能を正常にも違反にも丸めない）:
#   0 = 違反なし
#   1 = 違反あり（stderr に列挙。stdout の投影は**そのまま出す**——違反があっても
#       「どこまで起動してよいか」は必要であり、fail-closed で startable=- に倒してある）
#   2 = 検査不能（引数不正・対象不在・読み取り不可・ledger-index.rb の起動失敗・
#       投影の形の破損）。stderr に理由。**呼び出し側は依存を解決できなかったものとして扱う**
#       （空の結果を「依存なし＝全件起動可」と読み替えない）

require "English"
require "rbconfig"

COLUMNS = %w[id status deps unmet startable].freeze
EXITS = [0, 1, 2].freeze

# 「完了」を表すステータス。**語彙の正本（contracts/ledger-status-vocabulary.tsv）の 1 語**を
# 指すリテラルであり、語彙の**列挙**ではない（列挙を複製すると必ずずれる。Issue #151）。
# アーカイブに載っているエントリは、ステータス値によらず完了として扱う
# （アーカイブ＝完了エントリの履歴。docs/challenge-ledger-format.md §アーカイブ）。
DONE_STATUS = "完了"

# run-cycle 手順3 の対象ステータス。同上（1 語のリテラル）。
IN_PROGRESS_STATUS = "着手中"

PROGRAM = File.basename($PROGRAM_NAME)
USAGE = "usage: #{PROGRAM} <challenge-ledger.md> [<challenge-archive*.md> ...]\n" \
        "       #{PROGRAM} --list-columns | --list-exits"

EXIT_OK = 0
EXIT_VIOLATION = 1
EXIT_UNCHECKABLE = 2

def uncheckable(msg)
  warn "#{PROGRAM}: #{msg}"
  exit EXIT_UNCHECKABLE
end

INDEX_SCRIPT = File.join(__dir__, "ledger-index.rb")

# ledger-index.rb を起動して投影（TSV）を読み、`[{列名 => 値}, ...]` を返す。
# **列の位置ではなくヘッダ行の列名で引く**（列が増えても壊れない）。
def project(file)
  uncheckable("索引スクリプトが見つかりません: #{INDEX_SCRIPT}") unless File.file?(INDEX_SCRIPT)
  out = nil
  begin
    out = IO.popen([RbConfig.ruby, INDEX_SCRIPT, file], "r", &:read).to_s.force_encoding("UTF-8")
  rescue SystemCallError => e
    uncheckable("索引スクリプトを起動できません: #{INDEX_SCRIPT}（#{e.message}）")
  end
  unless $CHILD_STATUS.exitstatus.zero?
    uncheckable("索引を取得できません（#{File.basename(INDEX_SCRIPT)} exit #{$CHILD_STATUS.exitstatus}）: #{file}")
  end
  rows = out.to_s.split("\n", -1)
  rows.pop while !rows.empty? && rows.last.empty?
  uncheckable("索引の出力が空です（ヘッダ行が無い）: #{file}") if rows.empty?
  header = rows.shift.split("\t", -1)
  %w[id status deps].each do |need|
    uncheckable("索引に列 `#{need}` がありません（#{File.basename(INDEX_SCRIPT)} の列定義を確認）: #{file}") unless header.include?(need)
  end
  rows.map do |line|
    cells = line.split("\t", -1)
    Hash[header.each_with_index.map { |name, i| [name, cells[i].to_s] }]
  end
end

# `依存` の値（カンマ区切り）を ID の配列へ。空要素は落とす（`A, , B` を空 ID にしない）。
def parse_deps(value)
  value.to_s.split(",").map(&:strip).reject(&:empty?)
end

# --- 引数 -------------------------------------------------------------------
files = []
ARGV.each do |a|
  case a
  when "--list-columns" then puts COLUMNS; exit EXIT_OK
  when "--list-exits"   then puts EXITS;   exit EXIT_OK
  when /\A--/           then uncheckable("不明なオプション: #{a}\n#{USAGE}")
  else files << a
  end
end
uncheckable("対象ファイルが指定されていません\n#{USAGE}") if files.empty?
files.each do |f|
  uncheckable("対象が存在しません: #{f}") unless File.exist?(f)
  uncheckable("対象がファイルではありません: #{f}") unless File.file?(f)
  uncheckable("読み取れません: #{f}") unless File.readable?(f)
end

ledger_file = files.first
archive_files = files.drop(1)

# --- 投影の取得 -------------------------------------------------------------
ledger_rows = project(ledger_file)
archive_ids = {}
archive_files.each do |f|
  project(f).each { |r| archive_ids[r["id"]] = f unless r["id"].empty? }
end

violations = []

# 台帳側の ID 重複（見出し破損・二重登録）。**依存の解決が非決定になる**ため検査不能ではなく
# 違反として報告し、以降は最初の 1 件を採る（構造の破損そのものの検出は validate-artifact.rb）。
seen = {}
ledger_rows.each do |r|
  id = r["id"]
  next if id.empty?
  if seen.key?(id)
    violations << "duplicate: 課題 ID `#{id}` が台帳に 2 回以上あります（依存の解決が一意に定まりません）"
  else
    seen[id] = r
  end
end
entries = seen

# 台帳とアーカイブの両方に同じ ID がある場合は **fail-closed で未完了側へ倒す**
# （アトミック移動〔削除＋追記を 1 コミット〕が途中で壊れた形。完了と読み替えない）。
both = entries.keys.select { |id| archive_ids.key?(id) }
both.each do |id|
  violations << "duplicate: 課題 ID `#{id}` が台帳とアーカイブの両方にあります" \
                "（#{archive_ids[id]}。アトミック移動の破損。未完了として扱います）"
end

# --- 完了判定 ---------------------------------------------------------------
# docs/challenge-ledger-format.md §「完了」の判定は台帳とアーカイブの両方を見る の表と同じ:
#   アーカイブにある → 完了 / 台帳でステータスが `完了` → 完了 / それ以外・不明 → 未完了
def done?(id, entries, archive_ids, both)
  return false if both.include?(id)          # 両方に在る＝破損。未完了へ倒す
  return true  if archive_ids.key?(id)
  e = entries[id]
  !e.nil? && e["status"] == DONE_STATUS
end

known = ->(id) { entries.key?(id) || archive_ids.key?(id) }

# --- 辺の検査（自己参照・存在しない ID）------------------------------------
deps_of = {}
entries.each do |id, r|
  ds = parse_deps(r["deps"])
  ds.each do |d|
    if d == id
      violations << "self-reference: `#{id}` が自分自身を `依存` に挙げています"
    elsif !known.call(d)
      violations << "missing: `#{id}` の依存先 `#{d}` が台帳にもアーカイブにもありません" \
                    "（未完了として扱います）"
    end
  end
  deps_of[id] = ds
end

# --- 循環検出（台帳内の辺だけで閉路になりうる）------------------------------
# アーカイブ済み（完了）のノードは辺を持たない終端として扱う——アーカイブは原文保存の履歴で
# あり、そこから台帳へ戻る辺を辿ると「完了済みの課題が未完了の課題をブロックする」という
# 到達不能な状態を作る。閉路は**台帳エントリ間の辺**の上で探す。
# 反復（再帰でない）DFS＝深い依存鎖でも SystemStackError にならない。
WHITE = 0
GRAY = 1
BLACK = 2
color = Hash.new(WHITE)
in_cycle = {}
cycles = []

entries.each_key do |root|
  next unless color[root] == WHITE
  color[root] = GRAY
  stack = [[root, 0]]
  path = [root]
  on_path = { root => true }
  until stack.empty?
    node, i = stack.last
    nexts = deps_of[node] || []
    if i < nexts.size
      stack[-1] = [node, i + 1]
      d = nexts[i]
      next unless entries.key?(d) # アーカイブ済み・不明な ID は辺を辿らない
      if on_path[d]
        cycles << path[path.index(d)..-1]
        cycles.last.each { |n| in_cycle[n] = true }
      elsif color[d] == WHITE
        color[d] = GRAY
        path.push(d)
        on_path[d] = true
        stack.push([d, 0])
      end
    else
      color[node] = BLACK
      on_path.delete(node)
      path.pop
      stack.pop
    end
  end
end

cycles.uniq { |c| c.sort }.each do |c|
  violations << "cycle: 循環依存です（#{(c + [c.first]).join(' → ')}）。" \
                "**自動解決しません**——どの辺を落とすかは課題の中身の判断です"
end

# 循環に属するノードから**到達可能な後続**（＝そのノードを依存に持つ側）も起動可能でない。
# 後続方向へ辿るため、逆辺を作って伝播させる。
reverse = Hash.new { |h, k| h[k] = [] }
entries.each_key { |id| (deps_of[id] || []).each { |d| reverse[d] << id if entries.key?(d) } }
blocked = {}
queue = in_cycle.keys.dup
queue.each { |n| blocked[n] = true }
until queue.empty?
  n = queue.shift
  reverse[n].each do |succ|
    next if blocked[succ]
    blocked[succ] = true
    queue << succ
  end
end

# --- 投影 -------------------------------------------------------------------
$stdout.puts COLUMNS.join("\t")
ledger_rows.each do |r|
  id = r["id"]
  ds = parse_deps(r["deps"])
  unmet = ds.reject { |d| done?(d, entries, archive_ids, both) }
  # 循環に属する／循環から到達可能なノードは、unmet が空に見えても起動可能にしない。
  startable = (r["status"] == IN_PROGRESS_STATUS && unmet.empty? && !blocked[id] && !both.include?(id)) ? "y" : "-"
  $stdout.puts [
    id,
    r["status"],
    ds.empty? ? "-" : ds.join(","),
    unmet.empty? ? "-" : unmet.join(","),
    startable,
  ].join("\t")
end

unless violations.empty?
  violations.each { |v| warn "#{PROGRAM}: #{v}" }
  exit EXIT_VIOLATION
end
exit EXIT_OK
