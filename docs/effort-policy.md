# スキルの reasoning effort の方針

> claude-flywheel の各スキルが frontmatter の `effort` で指定する reasoning effort（思考の深さ）の対応表と理由（[#184](https://github.com/masanami/claude-flywheel/issues/184)。2026-09-26 にオーナーが決定）。
> 形は claude-harness の `docs/customization.md` §7 に揃える。

## 1. 背景

- 以前はどのスキルにも `effort` の指定が無く、セッションの設定をそのまま使っていた。
- Opus 5.5 で既定値が `high` から `medium` に変わったため、run-cycle や reflect の effort が利用者の環境によって変わってしまう。
- そこで **effort はスキル側で決めて固定する**。

## 2. 効き方

- frontmatter の `effort` は、そのスキルの実行時に**セッションの設定より優先**される。
- 値は `low` / `medium` / `high` / `xhigh` を使う（`max` はセッション専用のため frontmatter では使わない）。
- 書式は claude-harness の `plugin/skills/*/SKILL.md` と同じで、`effort:` の直前に理由を `# effort: <理由>` のコメントで書く。

```yaml
# effort: 分類・計画・委譲結果の照合・承認の提示など、判断を含む工程が多いため high。
effort: high
```

## 3. 対応表

*表: スキルごとの effort と理由（frontmatter の値と一致させる）*

| スキル | effort | 理由 |
| --- | --- | --- |
| [run-cycle](../skills/run-cycle/SKILL.md) | `high` | 分類・計画・委譲結果の照合・承認の提示など、判断を含む工程が多いため |
| [reflect](../skills/reflect/SKILL.md) | `high` | 記録の集計から改修を提案するため、深い検討が要る |
| [bootstrap-domain-map](../skills/bootstrap-domain-map/SKILL.md) | `medium` | 探索と地図の作成 |
| [ingest-challenges](../skills/ingest-challenges/SKILL.md) | `low` | 定型の取り込み（fp や照合はスクリプトが担う） |
| [agent-memory](../skills/agent-memory/SKILL.md) | `low` | 定型の処理 |
| [adhoc](../skills/adhoc/SKILL.md) | `low` | 定型の処理（記録の開始と終了） |
| [flywheel-init](../skills/flywheel-init/SKILL.md) | `low` | 定型の処理 |

frontmatter の値との一致は次のコマンドで確かめる。

```bash
git grep -n "^effort:" -- skills/
```

## 4. 委譲コマンドでは effort を指定しない

- run-cycle などが起動する委譲コマンド（`claude -p`）には **effort を指定しない**。
- 子セッションの effort は、子で呼ばれたスキル（claude-harness 側など）の frontmatter に任せる。深い検討が要るかどうかは呼ばれるスキルごとに違い、その判断はスキルの持ち主の側にあるため。
- このため、委譲コマンドの例文（[run-cycle](../skills/run-cycle/SKILL.md) 手順3 など）にも effort の指定を入れない。

## 5. 変更するとき

- 値を変えるときは、スキルの frontmatter（`effort:` と `# effort:` のコメント）と本書の §3 の表を同じ変更でそろえる。
- スキルを足したときは、本書の §3 に行を足し、frontmatter に `effort:` を付ける。
