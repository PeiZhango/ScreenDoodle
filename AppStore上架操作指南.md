# ScreenDoodle 上架 Mac App Store 操作指南

> 适用版本：当前 Swift Package 工程（无 `.xcodeproj`，经 `scripts/build.sh` 手工打包签名）
> 结论先行：**目前工程无法直接上架**，必须先补 Xcode 工程 + App Sandbox + App Store 分发证书，再逐个验证沙盒下功能可用性。

---

## 1. 现状与差距总览

| 维度 | 现状 | 上架要求 | 是否阻塞 |
|---|---|---|---|
| 工程形态 | Swift Package（`swift build`） | 需要 `.xcodeproj` 走 Archive/Upload | 🔴 阻塞 |
| App Sandbox | 未开启 | `com.apple.security.app-sandbox = true` 强制 | 🔴 阻塞 |
| 签名证书 | `Apple Development`（[build.sh](scripts/build.sh) L69，含硬编码邮箱） | `Apple Distribution` 证书 | 🔴 阻塞 |
| 描述文件 | 无 | `Mac App Store` provisioning profile | 🔴 阻塞 |
| Bundle ID | `com.screendoodle.app`（[build.sh](scripts/build.sh) L38） | 需在开发者后台注册 | 🔴 阻塞 |
| 敏感能力 | 屏幕录制 / 全局快捷键 / 置顶窗 / 全局隐藏光标 | 需在沙盒下逐项实测 | 🟡 待验证 |
| 隐私 | 无网络、无数据收集 | 隐私标签声明「屏幕录制」 | 🟢 需填写 |

---

## 2. 前置准备（一次性）

1. 登录 [Apple Developer](https://developer.apple.com)，确认账号为 **付费开发者账号**（个人/公司 $99/年）。
2. 在「Certificates, Identifiers & Profiles」里：
   - **创建 App ID**：类型选「App IDs」，Bundle ID 填 `com.screendoodle.app`（或改为更正式的反向域名，如 `com.yourname.screendoodle`，但需同步改 [build.sh](scripts/build.sh) L38 与工程设置）。勾选能力「App Sandbox」稍后在 entitlement 里开。
   - **创建证书**：`Apple Distribution`（类型选「Apple Distribution」）。
   - **创建 Profile**：类型选「Mac App Store」，关联上面的 App ID 与 Distribution 证书。
3. 下载并双击安装证书与 Profile 到钥匙串。

---

## 3. 代码与工程改造

### 3.1 建立 Xcode 工程（关键）

推荐用 **XcodeGen** 或**直接新建 Xcode 工程**把现有 `Sources/` 纳入：

- 新建 macOS App 工程（SwiftUI/AppKit 皆可，选 AppKit 更贴近现有代码），删除默认模板代码，把 `Sources/ScreenDoodle/**` 全部加进来。
- 或使用 XcodeGen，用一份 `project.yml` 声明 target、sources、entitlements、signing，避免手工拖拽。

工程需配置：
- `LSUIElement = YES`（菜单栏应用，无 Dock 图标）——保留现有设置。
- Target 的 `PRODUCT_BUNDLE_IDENTIFIER = com.screendoodle.app`。
- Signing：勾选「Automatically manage signing」，选 Team，用 `Apple Distribution` 证书。

### 3.2 开启 App Sandbox + Entitlements

新建 `ScreenDoodle.entitlements`（随 .xcodeproj 关联），内容：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

> `user-selected.read-write` 用于 NSSavePanel 保存截图到用户选择的目录。

### 3.3 屏幕录制能力（核心风险点）

- 涉及文件：[ScreenshotController.swift](Sources/ScreenDoodle/Screenshot/ScreenshotController.swift)、[ColorPickerOverlay.swift](Sources/ScreenDoodle/Support/ColorPickerOverlay.swift)、[OverlayWindowController.swift](Sources/ScreenDoodle/Overlay/OverlayWindowController.swift#L242)。
- 屏幕录制**依赖用户 TCC 授权**（首次会弹系统「屏幕录制」授权框），沙盒本身不额外要求专门 entitlement，但**必须在沙盒下实测** `SCScreenshotManager.captureImage` 与 `SCShareableContent` 是否正常返回。
- 验证方法：开启沙盒后本机运行，触发一次截图，确认系统授权弹窗出现且截图成功。
- 审核备注需写明：屏幕录制仅用于「用户主动发起的截图与取色」，非后台静默采集。

### 3.4 全局快捷键（Carbon）

- 文件：[HotKeyManager.swift](Sources/ScreenDoodle/Settings/HotKeyManager.swift)。
- `RegisterEventHotKey` 是公开 API，沙盒下一般可用，**不触发**辅助功能权限。需在沙盒下实测两个快捷键能注册、能触发。
- 注意审核口播：说明用系统标准 `RegisterEventHotKey`，非键盘记录。

### 3.5 置顶窗与全局隐藏光标

- 图钉置顶窗 [PinnedImageWindowController.swift](Sources/ScreenDoodle/Screenshot/PinnedImageWindowController.swift) 与取色器 [ColorPickerOverlay.swift](Sources/ScreenDoodle/Support/ColorPickerOverlay.swift) 使用 `window.level = .floating / .statusBar`。
- 取色器使用 `NSCursor.hide()` 全局隐藏光标。
- **这两类「跨窗口全局效果」在沙盒下可能有边界**：置顶层级通常可用，但全局隐藏光标在沙盒应用里可能无法影响其他 app 的光标。需实测：取色时光标是否真的隐藏、置顶窗是否稳定在最上层。

### 3.6 文件保存

- [ScreenshotController.swift](Sources/ScreenDoodle/Screenshot/ScreenshotController.swift#L362) 的 `saveToFile()` 走 NSSavePanel（powerbox），沙盒兼容。
- 但默认目录 `~/Pictures/涂鸦截图`（[Settings.swift](Sources/ScreenDoodle/Settings/Settings.swift#L98)）若不经面板直接 `FileManager` 创建会受限。确认保存流程始终由 NSSavePanel 授权后再写入即可。
- 若想「一键导出到固定目录而不弹面板」，需要用户通过 `NSOpenPanel` 先授权一次该目录并持久化 security-scoped bookmark。

### 3.7 Info.plist 补充

在 Xcode Target 的 Info 里补充：

- `ITSAppUsesNonExemptEncryption` = `NO`（声明未使用加密，免去审核加密问询）。
- `NSHumanReadableCopyright` 填写真实版权人（如 `Copyright © 2026 YourName`）。
- 保持 `LSUIElement = YES`、`CFBundleShortVersionString` 每次提交递增。

### 3.8 签名脚本改造（去硬编码邮箱）

将 [build.sh](scripts/build.sh#L69) 的写死身份改为动态匹配：

```bash
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
        | awk -F'"' '/Apple Distribution/{print $2; exit}')
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
        | awk -F'"' '/Apple Development/{print $2; exit}')
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    echo "错误：未找到签名证书" >&2
    exit 1
fi
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
```

> 注：上架提交的最终签名由 Xcode Archive 流程完成，此脚本仅用于本地手工打包验证，改不改都不影响上架主流程。

### 3.9 App 图标

- 确认 `Resources/AppIcon.icns` 为**原创或有授权**的图形，不使用 SF Symbols 作为图标，且含 1024×1024 尺寸。
- 在 Xcode 的 Assets.xcassets → AppIcon 里配置完整尺寸集（16/32/64/128/256/512，@1x 与 @2x）。

---

## 4. 打包与上传流程

1. Xcode 中选 **Any Mac (Apple Silicon, Intel)** 目标，`Product → Archive`。
2. 在 Organizer 里选中 Archive，点 **Distribute App → App Store Connect → Upload**。Xcode 会自动用 Distribution 证书签名、公证并上传。
3. 或命令行上传：导出公证后的 `.pkg`/`.app`，用 `xcrun altool --upload-app` 或 [Transporter](https://apps.apple.com/app/transporter/id1450874784) 上传。

---

## 5. App Store Connect 配置

1. 新建 App，填入名称（当前「屏幕涂鸦」）、Bundle ID、类别（工具/生产力）。
2. 上传截图（各尺寸）、编写描述与宣传文案。
3. **隐私标签**：
   - 数据用于「功能」：仅屏幕录制相关（若分类涉隐私）。
   - 明确「不收集与开发者无关的数据」，无网络传输。
   - 在「App Privacy」如实勾选屏幕录制用途。
4. 设置价格/地区、年龄分级（可能含「无限制」）。
5. **审核备注**（重要）：
   - 说明应用是菜单栏工具（`LSUIElement`），入口在菜单栏。
   - 说明屏幕录制仅用于用户主动截屏/取色，非后台监听。
   - 说明全局快捷键用系统标准 `RegisterEventHotKey`。

---

## 6. 常见被拒点对照

| 被拒点 | 本项目对应 | 对策 |
|---|---|---|
| 屏幕录制用途不明 | 截图 + 取色 | 审核备注 + 隐私标签说明「用户主动触发」 |
| 后台/静默采集 | 当前仅在用户操作时截屏 | 确认无后台自动截屏逻辑 |
| 未声明加密 | 无网络 | 加 `ITSAppUsesNonExemptEncryption=NO` |
| 图标不合规 | AppIcon.icns 来源待确认 | 换原创图标 + 全尺寸 |
| 菜单栏应用入口不清 | LSUIElement | 审核备注说明菜单栏入口与使用引导 |
| 沙盒功能失效 | 置顶/隐藏光标等 | 逐项实测并修 |

---

## 7. 上架前待办 Checklist

- [ ] 注册 App ID（`com.screendoodle.app`）
- [ ] 创建 Apple Distribution 证书 + Mac App Store Profile
- [ ] 建立 Xcode 工程并导入 `Sources/`
- [ ] 开启 App Sandbox + 配好 `.entitlements`
- [ ] 沙盒下实测：截图 / 取色 / 全局快捷键 / 置顶窗 / 隐藏光标 / 保存
- [ ] Info.plist 补 `ITSAppUsesNonExemptEncryption` 与真实版权
- [ ] 替换合规 App 图标（全尺寸）
- [ ] （可选）build.sh 去硬编码邮箱
- [ ] Xcode Archive → Upload
- [ ] App Store Connect 填隐私标签 + 审核备注 + 截图
- [ ] 提交审核并跟进