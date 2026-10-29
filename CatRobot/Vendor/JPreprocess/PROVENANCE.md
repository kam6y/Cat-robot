# Japanese pronunciation frontend sources

- Adapter: `native/japanese-pronunciation`, owned by this project. Swift loads it through a static C ABI XCFramework.
- jpreprocess: 0.15.0, [upstream](https://github.com/jpreprocess/jpreprocess), crate VCS commit `07a78220c1e850a001998451bd1e7c88709ee379`, BSD-3-Clause. `LICENSE` is copied from that commit.
- Compiled dictionary: [v0.15.0 release](https://github.com/jpreprocess/jpreprocess/releases/tag/v0.15.0), `naist-jdic-jpreprocess.tar.gz`, SHA-256 `8a930bbc57bf4adcf521d53544c7dc9ab8ab3aa997a591b1b1608dc5539017b8`. Exact extracted files are in `CatRobot/Resources/jpreprocess-manifest.json`.
- Dictionary source: [naist-jdic v0.1.3](https://github.com/jpreprocess/naist-jdic/tree/v0.1.3), as recorded in jpreprocess 0.15.0's `crates/jpreprocess-naist-jdic/build.json`. Its `COPYING` is preserved in full, including NAIST, UniDic, Open JTalk and JPreprocess notices.
- Rust compiler: 1.90.0. Transitive crate versions and registry checksums are fixed in `Cargo.lock`. `DEPENDENCY-LICENSES.txt` contains declared license expressions and original texts for the resolved iOS dependency graph, including build dependencies.
- Packages missing a license file in their published crate use the matching upstream VCS commit: jlabel `83ebc0b6b3a721b390123b5a8dd50774c5fc57d7`, lindera `d135c2821f65eb1becbbd4835cf2c1a5d0c2045e`, and kanaria `c994ccf06d179851a1c7c3285c3a408ccb6279ec` (repository moved to [samunohito/kanaria](https://github.com/samunohito/kanaria), file `LICENSE.txt`).

`prepare_jpreprocess_assets.py` verifies downloads and extracts only pinned normal files. `build_jpreprocess.sh` explicitly compiles device arm64 and Simulator arm64/x86_64 libraries. The build receipt records source and framework hashes; ordinary Xcode builds validate this receipt and dictionary, and do not download or build Rust. Generated assets are ignored under `CatRobot/LocalAssets/JPreprocess`.

The adapter preserves Japanese surface text for Supertonic naturalness. It applies dictionary readings only to complete eligible Latin terms and verbalizes unprotected plus operators; model, dictionary and dependency versions are unchanged.
