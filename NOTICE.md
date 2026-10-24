# 上游来源与品牌

EasyTake（随取）以 Alejandro Buján 的 [Tendedero](https://github.com/alejandrobujan/tendedero) 为底座。

- 克隆日期：2026-10-24。
- 上游版本：1.6.0。
- 基线提交：`32a3e47187fdea7b2fd43b3ab5a913f0ed33724a`。
- [LICENSE](LICENSE) 保留原文，包括源代码 MIT 许可和名称/图标不在授权范围内的说明。
- [README.upstream.md](README.upstream.md) 保留克隆时的上游 README 原文，便于核对原始能力、构建方式与来源。

随取的修改版需使用自己的名称、图标、应用标识和产品说明，不声称得到上游作者认可。上游 `scripts/make-icon.swift` 与 `docs` 中的 Tendedero 品牌素材不得作为随取的产品标识或宣传配图复用。

修改版沿用原生工程，SwiftPM 目标为 `Suiqu`，应用名称为「随取」，标识为 `local.suiqu.app`，数据目录为 `Application Support/Suiqu`。`scripts/make-suiqu-icon.swift` 绘制自有橙色闪电文件图标，构建产物不使用上游图标或宣传图。应用包内包含原始 LICENSE 及本来源说明；功能与验收状态以 [PRD.md](PRD.md) 和 [README.md](README.md) 为准。
