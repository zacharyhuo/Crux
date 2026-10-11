<p align="center">
  <img src="Crux/AppIcon.icon/Assets/crux-light.png" alt="Crux 应用图标" width="128" height="128">
</p>
<h1 align="center">Crux</h1>
<p align="center">面向开发者的 macOS 原生离线文档阅读器。</p>
<p align="center">简体中文 · <a href="README.md">English</a></p>

## Early Preview

Crux 是用 SwiftUI 和 AppKit 开发的开源 Dash 兼容 docset 阅读器。你可以安装文档，
搜索符号，在多标签工作区阅读本地页面，也可以通过项目代码学习 Swift 与 macOS 原生开发。

项目仍处于早期预览阶段。客户端、文档供应和应用发布各有自己的验收进度。
公开匿名下载与带密钥的 Sparkle 发布还需要上线验收，本地测试和私有发布记录不能证明公开托管已经就绪。

## 为什么做 Crux

写代码时，查一个 API 签名或参考页面不应该依赖网络。安装 docset 后，Crux 把符号搜索与
HTML 文档放进原生 macOS 工作区，提供键盘命令、独立的标签页历史和由你管理的资料库。

Crux 读取 Dash docset 格式，并参考 Zeal 的兼容行为。客户端、docset 构建工具和规划中的
服务端分别放在独立仓库，阅读本地文档不需要启动后端。

## 已有功能

以下功能在当前源码中已有实现和对应测试：

- 导入展开的 `.docset` 和受支持的压缩包，从目录发现、下载和安装文档，订阅 Dash XML feed，查看下载进度。
- 添加、重命名、启用或禁用文档源。启用多个源时，资料库按来源分组并标明归属。
- 搜索 Dash 与旧版 ZDash 符号索引，按 docset 或符号类型筛选，展开相关结果。
  输入已识别的 `prefix:` 可以选中对应 docset。
- 按 docset 开启全文索引，查看分组的页面结果和索引进度。
- 在标签页中阅读本地 HTML，使用前进、后退、页内搜索、目录和缩放，也可以恢复上次会话。
- 自选资料库目录并迁移已安装文档，全局或按 docset 控制页面的远程资源。
  能否完整离线使用仍取决于文档包是否包含所需内容。
- 对提供可验证产物的版本化来源，选择精确版本、固定旧版本或跟随最新推荐。
  替换前校验 SHA-256、字节数和 bundle 身份。
- 支持英文与简体中文。Crux Beta 与正式应用共享源码，使用独立的 bundle 身份和数据目录。
- 通过 Sparkle 检查应用更新。配置完成的发布构建支持签名 feed、签名压缩包和发布说明；
  未配置的本地构建会禁用更新。

## 文档来源

Crux 版本化目录与 Zeal 旧版目录使用独立协议，Sources 设置默认 **Crux 启用、Zeal 禁用**。
来源模型和设置界面已实现，并已通过隔离的原生 Beta 验收。
你可以在内置 Crux 版本化目录之外，添加自定义 Zeal 兼容目录与 Dash XML feed。
每个来源的配置身份独立于发布者的 `sourceId`。

同一源的同一 docset 只保留一个已安装版本，更新或切换版本会替换这份安装；
不同源可以各自安装同名 docset。新下载默认使用版本化目录推荐的最新版本。
停用或删除来源后，已安装文档仍可离线阅读，也不会自动归属到新添加的来源。

来源默认使用 HTTPS，也可以明确选择本地 HTTP 策略，限定为 `localhost`、loopback 或私有 IP
字面量，包括 IPv6 ULA。公网地址和其他主机名不能使用 HTTP，HTTPS 请求也不能重定向降级到 HTTP。
策略测试和真实 loopback 传输已通过；私网与 IPv6 的部署验证仍需在对应环境完成。

Crux 自有文档供应由 [crux-docset](https://github.com/zacharyhuo/crux-docset) 提供。
Python 构建、验证与发布流程已有实现，仓库中记录了私有发布验收。
公开目录、feed 和压缩包的匿名访问仍需单独验收。私有 GitHub 仓库需要认证，
客户端不会嵌入 GitHub token 来绕过访问限制。
[消费协议](https://github.com/zacharyhuo/crux-docset/blob/develop/v1/contracts/crux-consumer.md)
说明了版本身份、完整性校验和发布规则。

Zeal 是可选兼容来源。目录地址为 `https://api.zealdocs.org/v1/docsets`，
返回 JSON 原始数组；下载通过独立的
`https://go.zealdocs.org/d/{sourceId}/{name}/latest` 路由完成。
这类条目不提供 Crux 的可验证版本历史，服务访问和文档再分发权限也需要另行确认。
[Zeal 兼容协议](https://github.com/zacharyhuo/crux-server/blob/develop/v1/contracts/zeal-compatible-catalog.md)
记录了这条边界，不代表已有服务部署。

你也可以导入本地 bundle，或订阅文档发布者提供的 HTTPS Dash feed。
再分发文档或图标前，需要确认发布者的使用条款。

## 开发

### 环境要求

- macOS 26 或更高版本、Apple Silicon Mac。Xcode 项目只构建 arm64，不支持 Intel Mac。
- 包含 macOS 26 SDK 与 Swift 6.2 或更高版本的 Xcode。CruxCore 声明
  `swift-tools-version: 6.2`，应用使用 Swift 6 语言模式，项目的创建和升级元数据为 Xcode 26.6。
- Apple 命令行构建工具，包括 `make`、`curl` 和 `tar`。
  应用更新工具的检查使用 Node.js 24。

### 先构建必需的原生依赖

在仓库根目录执行，**应用构建与 CruxCore 测试都需要先完成这一步**：

```sh
./scripts/build-libarchive-xcframework.sh --build
```

脚本下载并校验固定的 libarchive **3.8.9** 源码，对应 commit
`27cbc7827172698143e440801fc0ba39ccb4f1f5` 和 SHA-256
`888c934f9d95648ecb9163dc8e23ab80a476ecb81a8f1154704a227b5b676dde`。
随后生成 arm64 静态 `Artifacts/CLibArchive.xcframework`、ZIP 和
`Artifacts/libarchive-build.json`。这是必需的 binary target，产物不提交到 Git。
`--verify-source` 只校验下载，不会生成构建依赖。使用打包好的应用不需要安装 Homebrew。

Swift 依赖通过 package manifest 和 `Package.resolved` 锁定。

### 隔离构建与测试

用 Xcode 打开 `Crux.xcodeproj` 并选择共享的 **Crux Beta** scheme，或执行：

```sh
xcodebuild build \
  -project Crux.xcodeproj \
  -scheme 'Crux Beta' \
  -configuration BetaDebug \
  -destination 'platform=macOS' \
  -derivedDataPath build/Beta \
  CODE_SIGN_IDENTITY=- \
  CRUX_CODE_SIGN_ENTITLEMENTS=Crux/Crux-AdHoc.entitlements

swift test --package-path Packages/CruxCore

# 用优化构建检查 20 个 docset 的搜索 p95 门槛。
swift test -c release --package-path Packages/CruxCore \
  --filter SymbolSearchPerformanceTests
swift test -c release --package-path Packages/CruxCore \
  --filter FullTextSearchPerformanceTests

xcodebuild test \
  -project Crux.xcodeproj \
  -scheme 'Crux Beta' \
  -configuration BetaDebug \
  -destination 'platform=macOS' \
  -derivedDataPath build/BetaTests \
  CODE_SIGN_IDENTITY=-

node --test tools/app-updates/test/*.test.mjs
```

本地签名构建使用 `Crux/Crux-AdHoc.entitlements`，让没有 Apple Team ID 的应用能够加载
Sparkle，同时保留沙盒与 Hardened Runtime。本地 Release/BetaRelease 打包还需设置
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`。使用证书分发时改用标准的
`Crux/Crux.entitlements`。最终包必须实际启动验收：签名完整性通过不代表能启动。

自生成 docset 的 GUI 测试必须使用 `com.zacharyhuo.Crux.Beta`。
Core 测试使用临时目录，Debug 应用托管测试和 UI 测试通过现有测试运行时分配独立的数据与偏好。
Beta 夹具不能复制正式应用的资料库、偏好或 security-scoped bookmark。
需要专用夹具的验收测试如果被跳过，不能算验收通过。

原生 UI 测试期间需要保持桌面解锁，避免操作键盘鼠标。来源和前缀测试会粘贴固定夹具文本，
避免输入法改变测试输入；测试保留剪贴板原数据但不输出，并在剪贴板未被其他应用改动时恢复。
Sources 测试保留可访问性树附件。XCTest 可能无法截取外接显示器窗口，因此视觉检查单独进行。

macOS UI 测试可能需要在“系统设置 → 隐私与安全性 → 开发者工具”中允许 Xcode 或发起命令的终端。
`DevToolsSecurity` 把这套授权策略称为 developer mode，macOS 没有单独的同名设置开关。
只构建测试 target 不需要修改这项主机策略。

### 应用发布

[Sparkle 发布指南](tools/app-updates/README.md) 包含 stable/Beta 独立密钥、受保护发布环境、
ZIP/DMG 打包与签名发布说明。免费 Apple 账号或 ad-hoc 签名不提供 Developer ID 签名和公证。
可选的 Developer ID/公证流程需要付费 Apple 开发者资格，并使用真实凭据完成验收。

公开更新需要 appcast 与 Release 资产支持匿名 HTTPS 访问，私有来源不能直接供匿名客户端获取。
私钥留在发布基础设施中，应用只包含公开验证密钥。没有 Sparkle 配置的旧版应用需要手动安装一次作为更新起点。

### 目录结构

- `Crux/`：原生 scene、阅读器、资料库、搜索与本地化资源。
- `Packages/CruxCore/`：解析、搜索、传输、安装与 Core 测试。
- `CruxTests/` 和 `CruxUITests/`：隔离的集成测试与 UI 测试。
- `scripts/`：依赖构建、Beta 启动与打包。
- `tools/app-updates/`：Sparkle 发布与验收工具。

贡献方式、信任边界和来源说明分别见 [CONTRIBUTING.md](CONTRIBUTING.md)、
[SECURITY.md](SECURITY.md) 与 [PROVENANCE.md](PROVENANCE.md)。

## 路线图

| 方向 | 状态 |
| --- | --- |
| 本地阅读器、资料库、符号搜索、可选全文索引与精确版本替换 | 已实现，继续预览版回归和使用体验检查 |
| 多来源管理，默认 Crux 启用、Zeal 禁用 | 已实现，隔离的原生 Beta 验收已完成 |
| 公开文档供应与带签名的应用更新 | 流程代码已有，匿名 HTTPS 与真实发布仍待验收 |
| 菜单栏快捷入口 | 计划中，现有应用菜单命令已实现 |
| 本地文档生成 agent | 计划中，现有 CLI 构建工具位于 crux-docset |
| 扩展文档供应 | Python 流程已有，Go/Spring adapter 仍为实验实现，需要独立资格审核 |
| 自部署目录与任务编排服务 | crux-server 只有协议和调研，尚无 Java 服务或部署 |

## 许可证

Crux 自有源码采用 [MIT 许可证](LICENSE)。这项许可适用于当前客户端源码，不改变早期发布的许可。

依赖和参考项目保留各自的使用条款，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
与 [PROVENANCE.md](PROVENANCE.md)。应用许可证不会改变 docset 内容、上游图标或其他仓库的许可证。
