# Fixed Left Camera Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 前面カメラが画面の左にある横向きに固定し、反対向き用のコードを削除する。

**Architecture:** `UIInterfaceOrientationLandscapeRight`だけを宣言する。動的orientation readerと独自orientationの受け渡しを削除する。AVFoundationの端末固有センサー補正は固定`.landscapeRight`で取得する。

**Tech Stack:** Swift 6、SwiftUI、AVFoundation、Vision、XCTest、Xcode 27.1。

**Spec:** `docs/superpowers/specs/2026-10-26-fixed-left-camera-design.md`

## Global Constraints

- 前面カメラは画面の左、充電端子は右。
- 非鏡像、画像の鮮度、generation、取消、背景・設定・権限・熱による無効化を維持する。
- 左固定時のyaw/pitch、画面中心への補正、保存済みキャリブレーション値を変えない。
- 既存の`feature/look` worktreeで作業する。通常作業ツリーや完成済み顔ブランチは変更しない。

## Review Focus

- Info.plistとAVFoundationの方向名が実際のカメラ左固定と一致すること：AppIdentityTestsと実機再確認。
- センサーの取付角とユーザーが端末を回す処理を混同しないこと：CameraFrameCacheTestsとFaceCapturePolicyTestsの既存センサー回転ケースを保持。
- 左固定の追尾の符号・補正・deadbandが変わらないこと：FaceTrackingGeometryTestsの既存期待角度を保持。
- 向きの削除が共有captureの所有権や古い画像の拒否を弱めないこと：ConversationCameraTests、LookToolTests、FaceTrackingCoordinatorTestsを更新して維持。
- アプリの背景・設定復帰と会話への影響：既存integrationを含む全Simulator試験と実機起動。

---

### Task 1: 左固定への縮小と検証

**Files:**
- Modify: `CatRobot/Resources/Info.plist`, `CatRobot/App/AppRootView.swift`
- Delete: `CatRobot/App/FaceTrackingOrientationReader.swift`
- Modify: `CatRobot/FaceTracking/{FaceTrackingTypes,FaceTrackingCoordinator,FaceTrackingGeometry,FaceCapturePolicy,AppleFaceCaptureSource}.swift`
- Modify: `CatRobot/Vision/{ConversationCamera,CameraSnapshot,CameraFrameCache}.swift`
- Test: `CatRobotTests/App/AppIdentityTests.swift`, `CatRobotTests/FaceTracking/`, `CatRobotTests/Vision/`
- Regenerate: `CatRobot.xcodeproj/project.pbxproj`
- Update: `README.md`, look仕様・計画・検証記録。

**Interfaces:**
- Consumes: 現行`FaceCaptureSource`、`FaceObservation`、`CameraSnapshot`とcapture所有権。
- Produces: `FaceCaptureSource.start(generation: UUID)`。`FaceObservation`と`CameraSnapshot`にorientationを持たせず、固定方向で正規化済みの座標・画像を渡す。

- [x] **Step 1: 既存AppIdentityTestsの対応方向を`["UIInterfaceOrientationLandscapeRight"]`だけに更新する。**
- [x] **Step 2: 失敗を確認する。** Run: `bash /private/tmp/cat-look/session-ledger-final/run-tests.sh AppIdentityTests`。Expected: 現行bundleが両方向を宣言するためassertionが1件失敗。
- [x] **Step 3: 方向監視・反対向きの分岐・orientation引数と状態を削除する。** センサー回転は固定`.landscapeRight`へ正規化し、Visionのupright boxをそのまま投影する。向き変更専用の試験だけを削除し、他の境界の試験と左固定時の数値期待値を維持する。プロジェクトを再生成する。
- [x] **Step 4: 全体検証する。** Run: `ruby scripts/test_generate_project.rb` と `bash /private/tmp/cat-look/session-ledger-final/run-tests.sh`。Expected: 生成契約PASS、全試験失敗0（実機専用2件スキップ）。`git diff --check`も成功。
- [x] **Step 5: 変更をcommitする。** 全体差分を一度独立レビューし、重要な問題があれば再現試験から修正する。
- [x] **Step 6: 同じsource revisionを実機ビルド・更新インストール・起動し、左固定で基本lookを再確認する。** Expected: 署名検証・install・launch成功。視覚と読み上げは利用者の観察を記録する。
