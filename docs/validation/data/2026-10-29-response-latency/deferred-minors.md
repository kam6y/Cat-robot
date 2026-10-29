# 保留した軽微な指摘

- Final: minor (deferred): local preparation task name shadows model-preparation property; ownership tested, readability cost remains.

- Final: minor (deferred): excluded long hint is normalized before length rejection and confirmed input is normalized again; preserves validation, costs redundant normalization.

長さ除外時のpreparationDiscardedは、既存のhint拒否の意味を含むことを記録し、先行合成数はpreparationStartedで集計する。
