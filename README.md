# QuickMarkShot
<img width="752" height="554" alt="image" src="https://github.com/user-attachments/assets/55c66e05-52cf-406b-85f8-cf349b121299" />

QuickMarkShot 是一款轻量的原生 macOS 截图与标注工具。它常驻菜单栏，按下 `Option+A` 即可选取屏幕区域，完成标注后复制到剪贴板或保存为 PNG。

## 特性

- 全局快捷键 `Option+A`
- 多显示器与跨屏选区
- 选区移动和边缘缩放
- 文字、矩形、椭圆、箭头和画笔标注
- 标注颜色、线宽和文字大小调节
- 撤销上一次标注
- 一键复制到剪贴板
- 保存为 PNG 图片
- 菜单栏常驻与开机启动
- 原生 AppKit 实现，无第三方运行时依赖

## 系统要求

- macOS 14.0 或更高版本
- 从源码构建时需要 Xcode Command Line Tools

## 安装

### 从源码构建

```sh
git clone <repository-url>
cd <repository-directory>
make app
open build/QuickMarkShot.app
```

构建完成后，应用位于 `build/QuickMarkShot.app`。当前构建脚本使用本地临时签名，适合本机开发和使用。

## 首次运行

1. 启动 `QuickMarkShot.app`。
2. 按下 `Option+A`，或点击菜单栏的截图图标并选择“截图”。
3. 根据系统提示，在“系统设置 > 隐私与安全性 > 屏幕录制”中允许 QuickMarkShot。
4. 授权后再次开始截图。

QuickMarkShot 只在截图时读取选定的屏幕内容，图片会在本机处理。

## 使用方法

1. 按 `Option+A` 进入截图模式。
2. 拖动鼠标创建选区，选区可以跨越多个显示器。
3. 拖动选区内部可移动选区，拖动边缘或四角可调整大小。
4. 使用工具栏添加标注，或调整颜色、线宽和文字大小。
5. 按 `Return` 或双击选区，将结果复制到剪贴板。
6. 点击工具栏的保存按钮，将结果保存为 PNG。

在尚未创建选区时，点击鼠标右键可直接退出截图。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 开始截图 | `Option+A` |
| 复制截图 | `Return` |
| 取消截图 | `Esc` |
| 撤销标注 | `Command+Z` |
| 文字工具 | `T` |
| 矩形工具 | `R` |
| 椭圆工具 | `O` |
| 箭头工具 | `A` |
| 画笔工具 | `P` |
| 调整文字大小 | `-` / `+` |

## 菜单栏

启动后，QuickMarkShot 会以截图图标常驻菜单栏。菜单中可以：

- 开始截图
- 开启或关闭开机启动
- 退出应用

## 构建命令

```sh
# 构建 .app
make app

# 重新构建并重启应用
make restart

# 构建并打开应用
make run
```

## 技术实现

- Swift 5
- AppKit
- ScreenCaptureKit
- CoreGraphics
- Carbon Events（全局快捷键）

## 项目结构

```text
.
├── Info.plist
├── Makefile
├── README.md
├── Sources
│   ├── App.swift
│   ├── Editor.swift
│   └── main.swift
└── build
    └── QuickMarkShot.app
```

## 参与开发

欢迎通过 Issue 报告问题或提交 Pull Request。请在提交前确认项目可成功构建：

```sh
make app
```
