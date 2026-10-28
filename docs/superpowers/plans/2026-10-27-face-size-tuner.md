# Face Size Tuner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** ユーザーがiPhoneで顔の倍率を決め、値をCodexへ渡せる別アプリを作る。
**Architecture:** 独立したXcodeプロジェクトと署名IDを使い、既存の描画3ファイルと描画ハーネスのenumを参照する。本体のソースとプロジェクトは変更しない。
**Tech Stack:** SwiftUI、XCTest、Xcode、既存xcodeproj gem。
**Spec:** docs/superpowers/specs/2026-10-27-face-size-tuner-design.md

## Global Constraints
- 作業場所は既存b200 worktree、基点1868b1e。
- 別bundle ID `com.kamby.CatFaceSizeTuner`、表示名「顔サイズ調整」、iOS27.0、横向きLandscapeRight。
- 本体の描画を参照し、倍率50〜100%・0.5%刻み・初期85%を提供。
- ツールは値の表示・コピーまで。本体反映はユーザーが決めた値を受け取った後にCodexが行う。

## Review Focus
- 初期値と85%リセットが本体の見た目に対応する。
- コピーした小数と表示中の描画倍率が一致する。
- 再起動と不正な保存値でも有効なプレビューへ戻る。
- パネルの表示・非表示で顔が移動せず、全画面から操作へ戻れる。
- 別アプリの配布で本体アプリのサイズ・データ・ハード動作を変えない。

### Task 1: 独立した調整アプリと検証
**Files:** 新規 `tools/face-size-tuner/{Sources,Tests,Resources,FaceSizeTuner.xcodeproj}`、`scripts/generate_face_size_tuner_project.rb`、ツールREADME。
**Interfaces:** `FaceSizeTuningModel(defaults:)`、`setScale(_:)`、`reset()`、`scale`、`copyValue`。`FaceSizePreview(scale:expression:)`を調整UIと描画試験で共有。
- [x] 保存・復元・リセット・不正値・コピー値・描画の縮小を検証する試験を作り、未実装時の失敗を確認する。
- [x] モデル、既存描画を使うプレビュー、スライダーと操作パネル、独立したプロジェクトを実装する。
- [x] 別アプリの全試験とSimulatorの操作・画像を確認する。本体223入力が変わっていないことを確認する。
- [x] 新規コンテキストの独立レビューで重要な問題を確認し、必要なら修正してコミットする。
- [x] 別アプリの署名付きビルドをiPhoneへインストールし、配布結果・使い方を記録する。

### Handoff
- [x] ユーザーにツールを渡し、80%の指定を受け取る。
- [x] 本体の通常会話画面を80%にし、既存の画面試験15件・署名検証後、iPhone 16 Proへ更新する。

[検証・配布記録](../../validation/2026-10-27-face-size-tuner.md)。調整アプリの引き渡しと、利用者が選んだ80%の本体への反映・実機更新まで完了。
