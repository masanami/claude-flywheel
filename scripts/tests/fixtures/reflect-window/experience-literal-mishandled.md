---
name: literal-mishandled
description: reflected に「未処理」という語がリテラルで書かれた experience（Issue #137 の実害ケース）
domain: reflect-window-fixture
metadata:
  type: experience
  outcome: bad
  target: skill:run-cycle
  signal: 雛形をコピーして reflected 行に「未処理」と書いてしまった
  recurrence: 2
  confidence: high
  reflected: 未処理
---
日付として解釈できない値なので**未処理**として拾われなければならない。
