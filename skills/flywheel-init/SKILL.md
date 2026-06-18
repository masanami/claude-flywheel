---
name: flywheel-init
description: claude-flywheel を導入したワークスペースに、運用状態（課題台帳・positions・memory・runtime）を初期化（scaffold）する。Triggers on：「flywheel をセットアップ」「flywheel-init」「自走環境を初期化」。プラグイン導入後に最初に一度だけ実行する。
---

# flywheel-init

claude-flywheel プラグインを導入した**利用先ワークスペース**に、運用状態（live state）を scaffold するスキル。

> claude-flywheel は **プラグイン（機械）** と **状態（利用先で生成）** を分離している。本スキルは後者を作る。
> プラグイン本体（スキル/テンプレート）は更新で入れ替わるため、**状態は利用先ワークスペースに置く**。

## 前提

- claude-flywheel がプラグインとして導入済み。
- カレントが、状態を置きたいワークスペース（Git リポジトリ推奨）であること。

## 生成するもの（利用先ワークスペース直下）

```
<workspace>/
├── challenge-ledger.md       # 課題台帳（テンプレートから生成）
├── positions/                # ポジション定義（最初は空。bootstrap で生成）
├── memory/                   # エージェント記憶（最初は空。運用で蓄積）
└── runtime/                  # 自律実行ランタイム設定（テンプレートから生成）
```

## 手順

1. カレントワークスペースを確認する（既存ファイルを上書きしない。あれば差分を提示して承認を得る）。
2. プラグインの `templates/` を雛形に、上記を生成する:
   - `templates/challenge-ledger.md` → `challenge-ledger.md`
   - `templates/runtime/README.md` → `runtime/README.md`
   - `positions/`・`memory/` は空ディレクトリ（`.gitkeep`）で作成。
3. 次の一手を案内する:
   - ドメインが未知なら [bootstrap-domain-map](../bootstrap-domain-map/SKILL.md) を実行して `positions/`・`memory/` を生成。
   - 既にドメインが分かっていれば `templates/position.md` を雛形に `positions/<domain>.md` を作成。
4. 生成物を Git コミットする（秘密情報は含めない）。

## 注意

- **状態はプラグイン内に作らない**（プラグインは配布物・読み取り専用扱い）。必ず利用先ワークスペースに作る。
- 再実行時は既存状態を尊重し、不足分のみ補う（冪等）。
