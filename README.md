# 运行 — macOS 版"运行"对话框

Windows 风格 Run 对话框的 macOS 实现：无边框浮动窗口，全局快捷键 **⌥R** 呼出，
输入路径/命令即可运行，支持历史记录下拉、浏览选择文件等。

## 功能

- **⌥R** 全局呼出对话框（Option+R）
- 输入路径/文件/文件夹/.app/可执行脚本/URL，回车或"确定"运行
- **打开对话框时自动填入上一次成功运行的内容并全选**，直接打字即可覆盖
- **⌥B** 触发"浏览(B)..."，**⌥O** 聚焦"打开(O):"输入框（Windows 风格助记键）
- **⌘A / ⌘C / ⌘V** 全选 / 拷贝 / 粘贴（屏幕顶部"编辑"菜单同步显示）
- **⌄** 历史下拉：最近 10 条运行成功记录，点击回填；Esc 先关下拉再关窗口
- 运行失败（找不到文件）弹窗提示，关闭后自动全选输入内容方便重输
- 常驻后台，Esc 隐藏，点 Dock 图标或 ⌥R 再次呼出

## 构建

需要 macOS + Xcode 命令行工具（`swiftc`）。

```bash
bash build.sh
```

构建产物为当前目录下的 `运行.app`（本地 ad-hoc 签名，无需开发者证书），
直接 `open 运行.app` 或拖入应用程序文件夹即可使用。

## 目录结构

```
运行源码/
├── main.swift        # Swift 主程序（窗口/热键/桥接/历史记录）
├── Run.html          # 界面（WKWebView 加载，与 Swift 通过 runBridge 通信）
├── Info.plist        # 应用配置（Bundle ID: com.local.run）
├── AppIcon.icns      # 应用图标
├── icons.iconset/    # 图标源文件
└── build.sh          # 一键构建脚本
```

## 说明

- 历史记录保存在 `~/Library/Preferences/com.local.run.plist`（键 `runHistory`）
- 调试日志写到 `/tmp/run_debug.log`
- 环境变量 `RUN_SHOW=1` 启动时直接显示窗口（调试用）
