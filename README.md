# 随取

基于 [Tendedero](https://github.com/alejandrobujan/tendedero) 的 macOS 挂绳文件取用工具：鼠标在屏幕顶部停留，选择来源，预览并拖出所需文件。

**当前阶段：完成独立仓库克隆、PRD 和开发入口初始化，尚未改造应用功能。** 当前源码、可执行目标和打包脚本仍为上游 Tendedero，不代表「随取」已实现或可安装发布。

- 需求与验收：[PRD.md](PRD.md)
- 开发边界：[AGENTS.md](AGENTS.md)
- 知识库路由：[CLAUDE.md](CLAUDE.md)
- 来源及品牌边界：[NOTICE.md](NOTICE.md)
- 原始上游说明：[README.upstream.md](README.upstream.md)

## 产品范围

只保留挂绳入口与小型设置：最近使用、自定义文件夹、剪贴板；支持文字、图片、视频及其他文件，提供预览、复制和拖出使用。记住上次来源、筛选与大小。

自定义文件夹仅有「最近修改」「最近新建」两种排序，默认最近修改；最近使用按实际使用时间排序。没有独立文件面板、工作区或目录管理界面。

## 上游基线

- 基线：Tendedero 1.6.0，提交 `32a3e47187fdea7b2fd43b3ab5a913f0ed33724a`。
- 技术：Swift、AppKit、SwiftUI；最低 macOS 14；SwiftPM 无第三方包依赖。
- `origin` 指向上游，只用于获取参考更新；尚未配置「随取」自己的远程仓库，不向上游推送。

```bash
swift build
swift scripts/check-strings.swift
```

以上命令用于验证上游编译及多语言键。上游没有测试 target，后续改造时补充与来源、排序、持久化和拖放相关的测试。

2026-10-24 初始化验证：Apple silicon 本机 `swift build` 通过；多语言检查通过（57 个键、11 种语言）；本地文档链接和知识库路由有效；原始上游 README 已逐字保留。日志在 `/tmp/suiqu-tendedero-init-build.log` 和 `/tmp/suiqu-tendedero-init-strings.log`。这些是上游基线检查，尚非随取功能验收。

上游 `scripts/build-app.sh` 会构建 `Tendedero.app` 并生成其原图标。完成随取名称、独立标识和自有图标接入前，不以该脚本产物作为随取分发或覆盖本机现有应用。
