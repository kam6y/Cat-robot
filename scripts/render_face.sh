#!/bin/bash
# 猫の顔の macOS レンダーハーネス: build → check → render を順に実行する。
#   scripts/render_face.sh <round> [--overwrite]   例: scripts/render_face.sh 2
#       レビューに渡した round は固定。既にある round へは --overwrite なしでは書かない。
#       出力先 round-N/source.txt に製品 3 ファイルの識別子（git hash-object、差分の sha256 先頭 12 桁と基準のコミット、
#       追跡の有無と git status）を残す。
#   scripts/render_face.sh check               幾何条件の検査だけ（失敗なら終了コード 1）
#   scripts/render_face.sh preview <dir> [scale]  試し描き（check の後、作業用の dir へ。round には書かない）
#   scripts/render_face.sh measure             採用画像の実測だけを表示
#   scripts/render_face.sh measure --rendered  現在の描画を同じ計測にかける
#   scripts/render_face.sh measure --sleeping  sleeping の下書きと現在の描画を同じ計測にかける
#   scripts/render_face.sh sleeping <round> [--overwrite]
#       sleeping の round: docs/design/sleeping-2026-10-26/renders/round-N/ へ下書きとの比較画像・measure.txt・source.txt を出す。
# Xcode プロジェクトには入れない（製品の顔の 3 ファイルを swiftc で直接含める）。
set -euo pipefail

cd "$(dirname "$0")/.."
build_dir="${FACE_RENDER_BUILD_DIR:-/private/tmp/cat-face-render}"
mkdir -p "$build_dir"

product_files=(
  CatRobot/Conversation/UI/CatFaceShapes.swift
  CatRobot/Conversation/UI/CatFaceAppearance.swift
  CatRobot/Conversation/UI/CatFaceView.swift
)

swiftc -swift-version 6 -O \
  -module-name FaceRender \
  -o "$build_dir/face-render" \
  scripts/face-render/main.swift \
  scripts/face-render/Stubs.swift \
  scripts/face-render/Bitmap.swift \
  scripts/face-render/Reference.swift \
  scripts/face-render/Classify.swift \
  scripts/face-render/Measure.swift \
  scripts/face-render/Check.swift \
  scripts/face-render/Render.swift \
  "${product_files[@]}"

if [[ "${1:-}" == "check" ]]; then
  "$build_dir/face-render" check
  exit 0
fi

if [[ "${1:-}" == "preview" ]]; then
  "$build_dir/face-render" check
  "$build_dir/face-render" preview "${@:2}"
  exit 0
fi

if [[ "${1:-}" == "measure" ]]; then
  "$build_dir/face-render" measure "${@:2}"
  exit 0
fi

write_source() {
  local source_file="$1"
  {
    for file in "${product_files[@]}"; do
      echo "$(git hash-object "$file")  $file"
    done
    echo "$(git diff HEAD -- "${product_files[@]}" | shasum -a 256 | cut -c1-12)  git diff HEAD -- <3 files> | shasum -a 256 (first 12), base $(git rev-parse --short=8 HEAD)"
    for file in "${product_files[@]}"; do
      if git ls-files --error-unmatch "$file" > /dev/null 2>&1; then tracked="tracked"; else tracked="untracked"; fi
      state="$(git status --short -- "$file" | cut -c1-2 | tr ' ' '.')"
      echo "$tracked ${state:-clean}  $file"
    done
  } > "$source_file"
  echo "source:"
  sed 's/^/  /' "$source_file"
}

if [[ "${1:-}" == "sleeping" ]]; then
  round="${2:?usage: scripts/render_face.sh sleeping <round> [--overwrite]}"
  "$build_dir/face-render" check
  "$build_dir/face-render" render-sleeping --round "$round" "${@:3}"
  round_dir="docs/design/sleeping-2026-10-26/renders/round-$round"
  "$build_dir/face-render" measure --sleeping > "$round_dir/measure.txt"
  echo "measure: wrote $round_dir/measure.txt"
  write_source "$round_dir/source.txt"
  exit 0
fi

round="${1:?usage: scripts/render_face.sh <round> [--overwrite] | sleeping <round> [--overwrite] | measure [--rendered | --sleeping]}"
"$build_dir/face-render" check
"$build_dir/face-render" render --round "$round" "${@:2}"
write_source "docs/design/face-expression-2026-10-26/renders/round-$round/source.txt"
