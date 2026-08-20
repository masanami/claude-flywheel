# contracts — run-cycle 成果物のフォーマット契約

`run-cycle` が書き出す成果物の**フォーマット契約**（Issue [#91](https://github.com/masanami/claude-flywheel/issues/91)）。成果物の消費者は 2 者——**GitHub 上の人間**（Markdown のレンダリング）と**読み取り専用の観測プレーン**（例: [claude-flywheel-board](https://github.com/masanami/claude-flywheel-board) のパーサ）——であり、「書き込みは成功したが消費者にとって壊れている」型の事故を書き込み側の検算で止める。

契約は 3 点セット（board 等の消費者はこれを vendoring してパーサテストに使う。アプリ統合・実行時依存にはしない）と、**書き込み側だけが使うパス集合の正本 1 点**で構成する:

| 構成物 | 場所 | 役割 |
| --- | --- | --- |
| JSON Schema | [`schemas/`](./schemas/) | JSONL 成果物（`journal/index.jsonl`・`.flywheel/runs.jsonl`）の機械可読スキーマ |
| バリデータ | [`../scripts/validate-artifact.rb`](../scripts/validate-artifact.rb) | 全成果物の決定的検証（Markdown 検査＋スキーマの解釈実行） |
| ゴールデンフィクスチャ | [`fixtures/`](./fixtures/) | 正例（受理されるべき正規形）と誤例（実際に起きた事故の再現） |
| サイクルコミットのパス集合（**vendoring 対象外**。消費者は読まない） | [`cycle-commit-paths.txt`](./cycle-commit-paths.txt) | run-cycle 手順6 の許可パス（`git add` / pathspec）と [`../scripts/noop-check.rb`](../scripts/noop-check.rb) の dirty パス分類の**単一正本**。両者がずれると「許可パス内の変更が『変化なし』と判定される」事故になるため 1 箇所に置く（[#82](https://github.com/masanami/claude-flywheel/issues/82)） |

## 正本のレイヤリング

- **受理判定の正本は実行可能なシステム（バリデータ＋スキーマ）**。テンプレート（`templates/challenge-ledger.md`・`templates/journal/cycle-template.md`）自体がバリデータを通ることをテスト（`scripts/tests/validate-artifact.test.sh`）で固定する。
- **意味論の散文正本**は従来どおり各ドキュメント（`templates/journal/README.md`「index.jsonl のスキーマ」・`templates/runtime/README.md`「実行イベントログ（runs.jsonl）」・`docs/challenge-ledger-format.md`）。散文とスキーマの整合は、散文中のサンプル行をスキーマに通すテストで固定する。食い違いはバグであり、見つけたら両方を整合させる。

## バリデータの使い方

```bash
scripts/validate-artifact.rb <type> <file> [--schema-dir <dir>] [--tail <n>] [--expect-ids <id,...>] [--expect-cycle <cycle名>] [--anchor-after-line <n>] [--since-last-cycle-start]
```

| type | 対象ファイル | 検査内容 |
| --- | --- | --- |
| `ledger` | `challenge-ledger.md` | エントリ見出し直前の空行／必須フィールド行の存在／見出しとマーカーの整合／**分類欄の結合切れ**（インデント欠落 3 形＋ネスト項目群の途中の空行）／参照フィールド（関連リポジトリ・関連Issue・関連PR）の値の形 |
| `archive` | `challenge-archive.md` | `ledger` とほぼ同一（エントリを原文のまま移した同形式）。ただし**結合切れ・参照フィールドの値の形の 2 検査は行わない**——原文保存の履歴であり修復が禁じられているため（移行猶予。詳細は `docs/challenge-ledger-format.md` §複数行フィールドの記入形式） |
| `journal-md` | `journal/YYYY-MM-DD-cycle.md` | 定型 5 セクション（触った課題／委譲／PR・ブランチ URL／承認待ちゲート／判断と根拠）の存在・順序 |
| `journal-index` | `journal/index.jsonl` | `schemas/journal-index.schema.json` による行ごとの検証 |
| `runs` | `.flywheel/runs.jsonl` | `schemas/runs.schema.json` による行ごとの検証 |

- **cwd 非依存**: 対象は引数のパスで受け、スキーマはスクリプト位置から自己解決する（vendoring 先で層構成が変わる場合のみ `--schema-dir` で指定）。
- **append-only・原文保存の恒久記録は「当該操作の追記分だけ」を検証する**: `journal/index.jsonl`・`runs.jsonl` は既存行を書き換えない恒久記録、`challenge-archive.md` は「ステータス行以外は原文のまま」保存する履歴であり、いずれも契約導入前の不正な過去分が残っていることがある（過去分の正しさは正本が保証せず、「修復」は履歴・原文の書き換えになる）。全体検証だと過去分の違反で以後の全操作が恒久失敗するため、run-cycle 手順6 は `journal-index` に `--tail <当周を含む未コミット追記行数> --expect-cycle <当周のサイクル名>`（正本保証「1 周 1 行 append」に基づき、保留が無い通常の周は `--tail 1`。no-op 周のコミットを次の周へ束ねる運用〔[#82](https://github.com/masanami/claude-flywheel/issues/82)〕では、そのコミットに入る保留分まで範囲を広げる。行数は `scripts/noop-check.rb` の `pending_index_lines` が返す）、`runs` に `--since-last-cycle-start --expect-cycle <当周のサイクル名>`（1 周の追記行数が可変のため、当周の開始マーカーからの範囲指定）、`archive` に `--expect-ids <当周に移動した課題ID,...>` を使う。**過去分は「検証して正常」ではなく「対象外」**（読み替えない）。
  - 範囲限定モードは**追記の実在と同一性**も証明する（形と件数だけの検査では「追記が起きなかった」ケースで過去分を検証して exit 0 になり誤証明するため。**呼び出し側＝書き手だけが知る期待値を渡し、バリデータが証明する**設計）: `--tail n`＝末尾が非空レコードで終わり n 件以上存在すること／`--expect-cycle`＝journal-index では末尾レコードの `date`・`seq` がサイクル名から導いた当周の値と一致すること・runs では**そのサイクル名の `cycle_start` がアンカーに存在し、以降に同名の `cycle_end` も存在する**こと（前周の stale な start を受理せず、閉じられていない run も検出。クラッシュ後の同名再利用は `--anchor-after-line <追記前の行数>`＝起動ごとに一意な位置指定で区別する）／`--expect-ids`＝末尾 |ids| エントリの見出し ID 集合が期待と一致すること（台帳から削除したのにアーカイブへ追記しなかった「課題の消失」を検出）。
  - **期待値未指定時は従来の形・件数検証のみ**（同一性は証明しない）。期待値は書き手しか知らない情報のため、汎用の消費者・フィクスチャ検証では要求しない（運用ゲートの完全形は run-cycle 手順6 の呼び出し規定が正本）。契約全体の検証（vendoring 先のパーサテスト・フィクスチャ）は従来どおり全体が対象。**台帳（`challenge-ledger.md`）だけは現在状態のファイル**（修復が正規の運用・修復実績あり）のため全体を検証する。
- **exit code は 3 値**（検査不能を正常にも違反にも丸めない）:
  - `0` = 違反なし（何も出力しない）
  - `1` = 違反あり（stdout に `<file>:<行>: <内容>` を列挙。**コミットを止める fail-closed**）
  - `2` = 検査不能（対象不在・読み取り不可・引数不正・スキーマ欠損／破損／未対応キーワード等。stderr に理由。**警告してコミットは許可**）
- 呼び出し規定（書き込み後・コミット前に実行）は `skills/run-cycle/SKILL.md` 手順6。

## 検査項目は実際に事故った型に限定する（YAGNI）

網羅的リンタにはしない。各検査の由来:

| 検査 | 由来の事故（誤例フィクスチャ） |
| --- | --- |
| 台帳/アーカイブ: 見出し直前の空行 | 複数エントリの同時アーカイブで `"\n".join` 連結され見出しが直前の箇条書きに吸収（recurrence 3）→ `fixtures/ledger/invalid/heading-no-blank-line.md` |
| 台帳/アーカイブ: 必須フィールド行 | エントリの範囲削除が隣接エントリの備考行・空行を巻き添え削除 → `fixtures/ledger/invalid/missing-note-field.md` |
| 台帳/アーカイブ: マーカー整合 | 行番号演算の移動が隣接エントリのマーカーを破壊（`docs/challenge-ledger-format.md` §台帳を機械で編集するときの規律の awk 検算と同じ意味論）→ `fixtures/ledger/invalid/double-marker.md` |
| 台帳/アーカイブ: **分類欄の結合切れ**（インデント欠落の 3 形〔番号付き・`-`・`*`〕＋ネスト項目群の途中の空行。**分類欄のみ**） | タスク案の書き方が 3 エージェントで 3 通りに分岐し、2 つが board で欠落表示（`-`）になった（2026-08・Issue #87）。継続行がフィールド行と結びつかなくなると値ごと消える。**規定が「違反」と宣言する形を 1 つだけ検査して残りを素通しにしない**（規定と検査を 2 規則にしない） → `fixtures/ledger/invalid/task-plan-dedented.md`・`fixtures/ledger/invalid/continuation-break-variants.md`・`fixtures/ledger/invalid/task-plan-bold-heading.md`（旧テンプレートのワークスペースが発明した実形） |
| 台帳/アーカイブ: 参照フィールドの値の形 | `関連リポジトリ` / `関連Issue` / `関連PR` は消費側が `<owner>/<repo>` / `<repo>#<番号>` からリンクを組み立てる前提（Issue #89）。自由記述・URL・プレースホルダが入るとリンク化・機械集計が静かに壊れる（`touched_issues.to` の自由記述と同型）→ `fixtures/ledger/invalid/related-refs-freetext.md` |
| journal md: 定型 5 セクション | セクション欠落・順序崩れで board のセクション対応（index.jsonl と 1:1）が壊れる → `fixtures/journal-md/invalid/` |
| index.jsonl: `decisions` は array\<string\> | string で 3 周連続記入し board 表示を破壊（recurrence 3）→ `fixtures/journal-index/invalid/decisions-string.jsonl` |
| index.jsonl: `pending_approvals` の形 | 独自形式で書き board のチケット表示を破壊（2026-07-27）→ `fixtures/journal-index/invalid/pending-approvals-shape.jsonl` |
| index.jsonl: `touched_issues.to` は正規語彙のみ | 「分類済（着手可能）」等の自由記述で機械集計が不能に → `fixtures/journal-index/invalid/touched-to-freetext.jsonl` |
| runs.jsonl: イベント種別・必須フィールド | 対応付けキー欠落で観測プレーンがペアリング不能に → `fixtures/runs/invalid/` |

## 受理すべき正規形（生成側の状態空間）

バリデータは「生成側が作りうる形」の列挙から書いた（拒否方向だけでなく**受理方向のフィクスチャを必ず持つ**）。台帳エントリの生成者は 3 種:

| 生成者 | マーカー | 特徴 | 正例フィクスチャ |
| --- | --- | --- | --- |
| 手書き（記入例コピー） | なし（説明文のみの `- 取り込み元:` 行を含みうる） | 完了条件・緊急度が空欄でも正規 | `fixtures/ledger/valid/handwritten-and-ingested.md` |
| ingest-challenges | 取り込み元（`<!-- fp:... -->`） | 説明がブロック引用の複数行になりうる | 同上 |
| periodic-audit | 監査元（`<!-- audit:... afp:... -->`）・取り込み元行なし | 分類欄の多くが空欄 | `fixtures/ledger/valid/audit-entry.md` |

必須フィールド行はこの 3 者すべてに共通する行だけに限定している（人間記入欄／起票者・起票日／説明／分類欄／担当ポジション／優先度／ステータス／タスク案／承認＋チェックボックス 2 行／備考。完了条件・緊急度・関連サービス・**参照フィールド 3 種**・両マーカーは**必須にしない**）。記入例（フェンス内）と HTML コメント内は検査から除外する。

**タスク案・完了条件は 1 フィールドが複数の形を取りうる**（Issue #87 で複数行形式を正規形に決定）。生成側の状態空間と受理／違反の対応は `docs/challenge-ledger-format.md` §複数行フィールドの記入形式の表が正本で、要点は次のとおり:

| 形 | 例 | 判定 | 正例／誤例フィクスチャ |
| --- | --- | --- | --- |
| 複数行（フィールド行の値は空＋2 スペースのネスト箇条書き） | `- タスク案:` ＋ `  1. …` | **正規形** | `fixtures/ledger/valid/multiline-and-refs.md`（C-101） |
| 1 行（値をフィールド行に詰め込む） | `- タスク案: (1) … (2) …` | **受理**（既存台帳の後方互換） | 同 C-102 |
| 空（未記入＝計画前） | `- タスク案:` のみ | **受理** | 同 C-103 |
| 1 行値＋ネスト項目の併記 | `- タスク案: 概要` ＋ `  1. …` | **受理**（非推奨） | 同 C-104 |
| フィールド行を持たない独自形式 | `**タスク案（承認済み）**` ＋ 箇条書き | **違反**（必須フィールド行の欠落＋インデント欠落の二重検出） | `fixtures/ledger/invalid/task-plan-bold-heading.md`（実運用ワークスペースの実形） |
| ネスト項目のインデント欠落 | `- タスク案:` ＋ 行頭の `1. …` | **違反** | `fixtures/ledger/invalid/task-plan-dedented.md` |

**旧テンプレートで scaffold されたワークスペースは移行スクリプトで追従させる**: 形 E（太字見出しブロック）・必須フィールド行の欠落は「書き手が壊した」のではなく「テンプレート更新に追従できていない」型であり、[`scripts/migrate-workspace.rb`](../scripts/migrate-workspace.rb) が構造マイグレーションで解消する（`docs/challenge-ledger-format.md` §既存ワークスペースの移行。**移行の成否は本バリデータの exit で測る**）。ただし**機械が形を判別できないエントリ**（太字ブロックに項目以外の行が混じる・承認チェック行が正規形でない 等）は移行が手を出さず人間判断へ倒すため、移行後も違反が残ることがある。

**結合切れの検査範囲は分類欄のみ**（エージェントが書く領域）。人間記入欄は人間の自由記述と外部本文の転記（ブロック引用）が入るため、行頭の箇条書きを違反にしない——**規定側も「人間記入欄は機械検査の対象外」と明記**しており、散文と検査の範囲を一致させている。

**書き手がいつ形 A へ切り替えるかは別問題（順序制約）**: 受理は最初から形 A〜D すべてを通すが、**書き手（run-cycle 手順2・ingest-challenges 手順3）が形 A で書き始めるのは唯一の消費者（board）の追随後**とする（`docs/challenge-ledger-format.md` §移行フェーズが正本。現行 board はインデント行を捨てるため、先に切り替えると board のカード詳細が `-` 表示になり、Issue #87 の症状を拡大する）。**受理表の「規定上の値」列は消費者が実装すべき読み取り結果であって、現行 board の挙動ではない**。**旧い承認ラベル（`- [ ] 計画を承認（FR-13）`）も受理し続ける**（新表記は `（FR-13・承認対象＝タスク案）`。検出は前方一致）。journal は空の周（`- なし`）も正規（`fixtures/journal-md/valid/minimal.md`）。runs.jsonl は `title`/`skill` 無しの `delegate_start` や `abandoned` の `cycle_end` も正規（`fixtures/runs/valid/optional-fields.jsonl`）。

## スキーマはバリデータが直接解釈する

検証ロジックとスキーマファイルの二重管理（同じものを 2 規則で読むドリフト）を避けるため、バリデータは JSON Schema の**サブセットを直接解釈**する。サポートするキーワード:

- 検証: `type` `required` `properties` `additionalProperties` `items` `enum` `const` `pattern` `minLength` `minimum` `oneOf` `format`
- 注釈（検証に作用しない）: `$schema` `$id` `title` `description` `$comment` `examples`

`format` は本契約では**検証として作用させる**（対応値は `date-time` / `date` のみ。他の値は exit 2）。pattern の桁形状・値域検証だけでは `2026-02-31` のような「形は合うが暦日として存在しない」値を受理してしまうため、日時・日付フィールドは **pattern（値域。format を検証しない利用側バリデータ向けの防御）＋ format（暦日・時刻・オフセットの意味検証）の二層**で検証する。vendoring 先のバリデータが `format` を検証する場合（例: ajv + ajv-formats）は標準の意味で解釈すればよい。

**サポート外のキーワードがスキーマに現れたら exit 2（検査不能）**とする。黙って無視すると「検査したつもりで素通し」（検査不能の 0 件への丸め込み）になるため。スキーマを拡張する場合はバリデータのサポートも同時に広げること。

## 実装言語の選定根拠

`/usr/bin/ruby`（macOS 標準搭載・追加インストール不要。Command Line Tools も不要）。

- 日本語 Markdown の検査は bash 3.2 の罠（全角文字直前の変数展開・`${var/…}` の多バイト破壊）と macOS awk の多バイト等値比較問題に恒常的に露出する。Ruby の UTF-8 ネイティブ文字列でこれを回避する。
- JSONL のスキーマ検証には JSON パーサが必須（標準ライブラリ `json` で完結）。
- shebang は `#!/usr/bin/ruby` に固定する（`#!/usr/bin/env ruby` だと rbenv 等のユーザ環境の Ruby を拾いバージョンが揺れるため。決定的なバリデータには不適）。

### 実行環境の前提（契約の一部）

**コミットゲートの有効化には ruby（`/usr/bin/ruby`）が必要**。対象環境（macOS・WSL2・Linux）別の充足方法:

| 実行環境 | 充足方法 |
| --- | --- |
| macOS ホスト（`execution_mode: native`・既定） | OS 標準搭載（追加作業なし） |
| Linux / WSL2 ホスト（`native`） | 標準では未搭載のことが多い。`sudo apt-get install -y ruby`（Debian/Ubuntu 系。他ディストリビューションは相当のパッケージ）で導入する（Debian の ruby は `/usr/bin/ruby` を提供し shebang のパスが一致する） |
| コンテナ（`execution_mode: container`） | `templates/container/Dockerfile` が `ruby` パッケージを導入済み。**本契約の導入前に scaffold した `container/Dockerfile` を使っている場合は、テンプレートを取り込んでイメージを再ビルドすること** |

**ruby 未導入の環境ではバリデータの起動自体が失敗する**（インタプリタ不在＝exit 126/127 等、3 値契約のどれでもない exit）。run-cycle 手順6 はこれを **exit 2 と同じ「検査不能」として扱い、コミットは止めずに理由をサイクルレポートへ記載する**（縮退規則。ゲートは警告に縮退し、未定義動作・「違反なし」への読み替えにはしない）。ゲートを有効化するには上表の導入を行うこと。Dockerfile がこのランタイムを導入し続けることはテスト（`scripts/tests/validate-artifact.test.sh`）で固定している。

## 消費者（board 等）の vendoring 手順

**消費者が読むべき散文正本**（推測で実装しないための参照先。フォーマット変更はこの 3 節と本 README・フィクスチャが同時に更新される）:

| 読むもの | 何が書いてあるか |
| --- | --- |
| `docs/challenge-ledger-format.md` §複数行フィールドの記入形式 | タスク案・完了条件の**複数行形式**と、受理／違反の形の一覧。**同節「消費側（board 等）の読み取り規則」がパーサの契約**——フィールド値＝フィールド行の値＋直下に連続する**継続行**で、継続行は**インデント行**（ネスト項目）と**引用行（行頭 `>`）**の 2 種類（引用行は ingest-challenges が書く `- 説明:（原文引用）` 直下のブロック引用＝実運用の説明欄の主要形。値に含めないと説明が定型文字列としてしか読めない）。空行・いずれの継続行でもない行・次見出しで終端 |
| 同 §移行フェーズ | **書き手が形 A へ切り替える順序制約と切り替え条件**。board の追随（#151）が完了し、`fixtures/ledger/valid/multiline-and-refs.md` の C-101 から `taskPlan`・`completionCriteria` を取得できることが切り替えの条件（判定コマンドも記載） |
| 同 §関連リポジトリ・関連Issue・関連PR | 参照フィールド 3 種の値の形式・複数値のカンマ区切り・短縮形の owner 解決・リンク化は消費側の責務であること |
| 同 §FR-13 の承認対象 | 承認待ちカードで**何を前面に出すべきか**（承認対象＝タスク案。判断材料は タスク案／完了条件／関連リポジトリ） |

1. `schemas/` と `fixtures/` を消費者リポジトリのテストデータへコピーする（バリデータ本体のコピーは任意。パーサは自前実装でよい）。
2. パーサテストで固定する: **`fixtures/*/valid` を全件パースできる**こと（受理方向）／**`fixtures/*/invalid` をクラッシュせず異常として扱える**こと（拒否方向）。
3. 契約の更新はこのディレクトリの Git 履歴で追う（スキーマ変更＝契約変更。消費者はコピーを更新して追従する）。
