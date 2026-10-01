#!/usr/bin/env ruby
# frozen_string_literal: true
#
# ledger-related-issues.rb — 課題台帳・アーカイブの分類欄 `関連Issue` を**既登録キー**として
# 列挙し、取り込み候補の外部キーと照合する（Issue #187）。
#
# ingest-challenges 手順2・4 が呼ぶ。手順4 の既登録判定は**取り込み元マーカーの照合が先**で、
# マーカーに無かった候補だけを本スクリプトへ渡し、`関連Issue` に一致したものを「束ね済み」
# としてスキップする（親要件の子チケット・複数 repo 横断の同一課題・完了済み課題に紐づいたまま
# 上流で OPEN の Issue を、毎周「キー未登録＝新規」と誤認して重複取り込みしないため）。
# **照合の規則（書式の揺れ・短縮形の owner 解決）の正本は本スクリプト**であり、SKILL.md には
# 再掲しない——再掲すると読み手が写しから手で照合を再実装し、実装と乖離する。
#
# 使い方:
#   scripts/ledger-related-issues.rb <challenge-ledger.md> [<challenge-archive*.md> ...]
#   scripts/ledger-related-issues.rb --match <key> [--match <key> ...] <file> [<file> ...]
#   scripts/ledger-related-issues.rb --list-columns | --list-exits
#
#   <file> は台帳とアーカイブを区別しない（どちらで一致しても扱いは同じ「束ね済み」。
#   どちらで一致したかは file 列で分かる）。アーカイブは年次分割を見越して glob で複数渡せる。
#   <key> は取り込み候補の外部キー。`<owner>/<repo>#<番号>` または `<repo>#<番号>`。
#
#   --list-columns  出力する列名を 1 行 1 件で出力して終了（exit 0）。列挙モード・照合モードの
#                   順に `<mode>\t<列名>` の形で出す。
#   --list-exits    本スクリプト自身が返す終了コードの**宣言**（0 / 1 / 2）。
#
# 出力（stdout・TSV・1 行目はヘッダ）:
#   列挙モード（--match なし）: `関連Issue` の要素を 1 行 1 件で投影する
#     key       正規化したキー。owner が決まれば `<owner>/<repo>#<番号>`、決まらなければ
#               `<repo>#<番号>`（下記「短縮形の owner 解決」）
#     file      読んだファイル（引数に渡した文字列のまま）
#     id        エントリの課題 ID（見出し `### [<id>]` の `<id>`）
#     written   台帳に書かれていた要素の文字列（正規化前）
#   照合モード（--match あり）: 渡したキーを 1 件ずつ、引数の順に判定する
#     query     渡したキー（そのまま）
#     result    `bundled` = いずれかのエントリの `関連Issue` に一致（一致したエントリごとに 1 行）
#               `unregistered` = どこにも一致しない（1 行。file / id / written は `-`）
#     file / id / written   一致したエントリ（列挙モードと同じ意味）
#
# 照合の規則:
#   - **要素の区切り**は `,`（全角の `，` `、` も受け付ける）。前後の空白は落とし、空要素は捨てる。
#   - **受け付ける要素の形**: `<owner>/<repo>#<番号>` / `<repo>#<番号>` / GitHub Issue の URL
#     （`https://github.com/<owner>/<repo>/issues/<番号>`）。`#` の前後の空白・番号の先頭ゼロは
#     吸収する。owner・repo は大文字小文字を区別しない（GitHub の名前解決と同じ）。
#   - **短縮形の owner 解決**は docs/challenge-ledger-format.md §関連リポジトリ・関連Issue・関連PR
#     の消費側規則に従う: 同エントリの `関連リポジトリ` に同名 `<repo>` があればその owner、
#     無ければ owner 不明（key は `<repo>#<番号>`）。
#   - **照合**: 番号と repo が一致し、かつ owner が「両方決まっていれば一致」「どちらかが不明なら
#     問わない」とき一致とする。github-issue ソースの外部キー（取り込み元マーカー）は
#     `<repo>#<番号>` で owner を持たないため、短縮形どうしの照合もこの規則で成立する。
#   - `関連Issue` のフィールド行がエントリ内に複数あれば、すべてを合わせて読む。
#
# **読めない値は fail-closed**: 上の形に当てはまらない要素（自由記述・プレースホルダ等）は
#   黙って捨てず、stderr に `<file>:<行>: [<id>] 読めない要素: <要素>` を列挙して exit 1 を返す。
#   stdout は読めた要素だけで**そのまま出す**。読めない要素に束ねられた Issue があるかもしれない
#   ため、**呼び出し側は exit 1 の周に `unregistered` を「新規」と読み替えない**（既定の扱いは
#   ingest-challenges 手順4）。
#
# **エントリ境界と除外は ledger-index.rb / validate-artifact.rb と同じ意味論**:
#   - エントリ境界は `^### \[` にマッチする行。最初の見出しより前（前文）は読まない
#   - ``` フェンス内の行は除外（台帳先頭の「記入例」はここで落ちる）
#   - 複数行 HTML コメントは除外。同一行で開閉するインラインコメントは行ごと対象のまま
#   両者の境界が一致すること（同じ入力から同じ ID 列が出ること）はテストが固定する。
#
# **ファイルを作らない**: 読み取り専用で、書き込み先は stdout / stderr だけ。
#
# 終了コード（ledger-deps.rb と同じ 3 値。検査不能を正常にも違反にも丸めない）:
#   0 = 全要素を読めた
#   1 = 読めない要素がある（stderr に列挙。stdout は読めた分だけ出す）
#   2 = 検査不能（引数不正・対象不在・読み取り不可・UTF-8 として解釈不能・--match の値の形が
#       不正）。stderr に理由。**呼び出し側は照合できなかったものとして扱う**（空の結果を
#       「束ね済みなし」と読み替えない）

LIST_COLUMNS = %w[key file id written].freeze
MATCH_COLUMNS = %w[query result file id written].freeze
EXITS = [0, 1, 2].freeze

PROGRAM = File.basename($PROGRAM_NAME)
USAGE = "usage: #{PROGRAM} [--match <key> ...] <challenge-ledger.md> [<challenge-archive*.md> ...]\n" \
        "       #{PROGRAM} --list-columns | --list-exits"

def uncheckable(msg)
  warn "#{PROGRAM}: #{msg}"
  exit 2
end

NAME = "[A-Za-z0-9._-]+"
REF_RE = %r{\A(?:(#{NAME})/)?(#{NAME})\s*\#\s*0*(\d+)\z}
URL_RE = %r{\Ahttps?://(?:www\.)?github\.com/(#{NAME})/(#{NAME})/issues/0*(\d+)/?\z}i
SEPARATOR_RE = /[,，、]/

# 要素 → [owner または nil, repo, 番号]（小文字化・番号は正規化した文字列）。読めなければ nil。
def parse_ref(elem)
  m = REF_RE.match(elem) || URL_RE.match(elem)
  return nil unless m
  num = m[3].sub(/\A0+(?=\d)/, "")
  num = "0" if num.empty?
  [m[1]&.downcase, m[2].downcase, num]
end

def format_key(owner, repo, num)
  owner ? "#{owner}/#{repo}##{num}" : "#{repo}##{num}"
end

# --- 引数 -------------------------------------------------------------------
files = []
queries = []
args = ARGV.dup
until args.empty?
  a = args.shift
  case a
  when "--list-columns"
    LIST_COLUMNS.each { |c| puts "list\t#{c}" }
    MATCH_COLUMNS.each { |c| puts "match\t#{c}" }
    exit 0
  when "--list-exits" then puts EXITS; exit 0
  when "--match"
    v = args.shift
    uncheckable("--match に値がありません\n#{USAGE}") if v.nil?
    q = parse_ref(v.strip)
    uncheckable("--match の値の形が不正です（`<owner>/<repo>#<番号>` または `<repo>#<番号>`）: #{v}") unless q
    queries << [v, q]
  when /\A--/ then uncheckable("不明なオプション: #{a}\n#{USAGE}")
  else files << a
  end
end
uncheckable("対象ファイルが指定されていません\n#{USAGE}") if files.empty?

# --- フェンス・HTML コメントの除外（ledger-index.rb / validate-artifact.rb の annotate_exclusions と同一）---
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
    [line, included]
  end
end

def read_lines(file)
  uncheckable("対象が存在しません: #{file}") unless File.exist?(file)
  uncheckable("対象がファイルではありません: #{file}") unless File.file?(file)
  uncheckable("読み取れません: #{file}") unless File.readable?(file)
  begin
    content = File.read(file, encoding: "UTF-8")
  rescue SystemCallError => e
    uncheckable("読み取りに失敗しました: #{file}（#{e.message}）")
  end
  uncheckable("UTF-8 として解釈できません: #{file}") unless content.valid_encoding?
  lines = content.split("\n", -1)
  lines.pop if lines.last == ""
  lines
end

# --- エントリへ分割し、`関連Issue` の要素を集める -----------------------------
refs = []       # [key_parts, file, id, written]
unreadable = [] # "file:lineno: [id] 読めない要素: elem"

files.each do |file|
  entries = [] # [id, [[lineno, text], ...]]
  annotate_exclusions(read_lines(file)).each_with_index do |(text, included), i|
    next unless included
    if (m = /\A### \[([^\]]*)\]/.match(text))
      entries << [m[1].strip, []]
    elsif !entries.empty?
      entries.last[1] << [i + 1, text]
    end
  end

  entries.each do |id, body|
    # 短縮形の owner 解決に使う `関連リポジトリ`（repo 名 → owner。小文字化）
    owners = {}
    body.each do |_, l|
      m = /\A- 関連リポジトリ:(.*)\z/.match(l)
      next unless m
      m[1].split(SEPARATOR_RE).map(&:strip).each do |r|
        o, n = r.split("/", 2)
        owners[n.downcase] ||= o.downcase if n && o && !o.empty? && !n.empty?
      end
    end

    body.each do |lineno, l|
      m = /\A- 関連Issue:(.*)\z/.match(l)
      next unless m
      m[1].split(SEPARATOR_RE).map(&:strip).reject(&:empty?).each do |elem|
        parts = parse_ref(elem)
        if parts.nil?
          unreadable << "#{file}:#{lineno}: [#{id}] 読めない要素: #{elem}"
          next
        end
        parts[0] ||= owners[parts[1]]
        refs << [parts, file, id, elem]
      end
    end
  end
end

# --- 出力 -------------------------------------------------------------------
def tsv(cells)
  cells.map { |c| c.to_s.gsub(/[\t\r\n]/, " ") }.join("\t")
end

if queries.empty?
  $stdout.puts LIST_COLUMNS.join("\t")
  refs.each { |parts, file, id, written| $stdout.puts tsv([format_key(*parts), file, id, written]) }
else
  $stdout.puts MATCH_COLUMNS.join("\t")
  queries.each do |raw, (qo, qr, qn)|
    hits = refs.select do |(o, r, n), _, _, _|
      r == qr && n == qn && (o.nil? || qo.nil? || o == qo)
    end
    if hits.empty?
      $stdout.puts tsv([raw, "unregistered", "-", "-", "-"])
    else
      hits.each { |_, file, id, written| $stdout.puts tsv([raw, "bundled", file, id, written]) }
    end
  end
end

unless unreadable.empty?
  unreadable.each { |u| warn "#{PROGRAM}: #{u}" }
  warn "#{PROGRAM}: 読めない要素が #{unreadable.size} 件あります。" \
       "これらに束ねた Issue を照合できないため、呼び出し側は unregistered を新規と読み替えないこと"
  exit 1
end
exit 0
