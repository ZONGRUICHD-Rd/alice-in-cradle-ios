# Alice in Cradle · iOS 27 Port & Separated Launcher (爱丽丝的摇篮 iOS 27 移植与独立启动器)

将你**合法拥有的 macOS（Apple Silicon / arm64）版《爱丽丝的摇篮》（Alice in Cradle）** 移植到 **iOS 27（针对 iPhone 18 Pro 120Hz ProMotion 优化）** 原生运行的开源工具链与独立 iOS 启动器。

> **架构原则：游戏与启动器完全分离（BYOG — Bring Your Own Game）**
> 本仓库与 GitHub Actions 产出的 `AliceCradleLauncher-iOS27-Unsigned.ipa` **不包含任何游戏本体、美术资源、音频、Unity 引擎二进制或版权文件**。你只需在 GitHub Actions 一键构建出启动器 IPA 安装到手机，使用时在 iOS「文件」App 中导入你自己正版的 `AliceInCradle.app`（或 `.zip` 压缩包）即可自动转换并导出可运行的游戏 IPA。

---

## 技术参考与架构来源

本项目参考并融合了 2026 年最新的原生 iOS 移植工程实践：

1. **[`zorrobyte/macos-on-ios-public`](https://github.com/zorrobyte/macos-on-ios-public)**（MIT）：macOS ARM64 → iOS 27 原生运行架构——将 `.app/Contents` 映射至 `Mac/Contents`，改写 Mach-O 平台标签（`LC_BUILD_VERSION` → iOS 27）与框架依赖，通过 UIKit / Metal / AVFoundation 兼容层（`libShim_*.dylib`）直接运行原版 ARM64 引擎，无需反编译或重制游戏。
2. **[`huzaifahshahid71-ops/hollow-games-ios-builder`](https://github.com/huzaifahshahid71-ops/hollow-games-ios-builder)**（MIT）：Unity Mono 游戏在 iOS 27 + LiveContainer 下的移动端独立打包器模式（`Hollow Builder`）——支持手机端导入 `.app`、`_mmap` → `_smmp` 去除非可执行页 `MAP_JIT`、CoreAudio→RemoteIO、CVDisplayLink 60/120Hz、以及 UIKit 虚拟触控与手柄覆盖层。
3. **[`jhaizhou-ops/sts2-ios`](https://github.com/jhaizhou-ops/sts2-ios)** & **[`HDZ123321/rimworld-ios`](https://github.com/HDZ123321/rimworld-ios)**：代码与游戏资产彻底分离的 GitHub Actions 自动化未签名 IPA 打包工作流。

---

## 核心特性（面向 iOS 27 / iPhone 18 Pro）

- **启动器与游戏分离**：GitHub Actions 直接产出轻量级未签名启动器 `AliceCradleLauncher-iOS27-Unsigned.ipa`，支持在 iPhone 上直接通过「文件」导入 `AliceInCradle.app` 文件夹或 `.zip` 压缩包。
- **版本无关自动识别**：无需硬编码单个版本 SHA-256，自动识别不同更新版本的《爱丽丝的摇篮》（Ci-en / DLsite / Steam macOS 版），自动探测 ARM64 架构与脚本后端（**Mono** 或 **IL2CPP**）。
- **完整 iOS 27 原生兼容层（14 个 `libShim_*.dylib`）**：
  - `AppKit` / `Cocoa` → UIKit 窗口、事件分发、`NSBundle` 路径映射、Metal `Managed → Shared` 纹理存储兼容
  - `CoreAudio` / `AudioUnit` → iOS `RemoteIO` + `AVAudioSession` 48kHz 立体声输出
  - `CoreVideo` → `CVDisplayLink` 60Hz / 120Hz ProMotion 帧率调度（适配 iPhone 18 Pro）
  - `CoreGraphics` / `Carbon` / `CoreServices` → 显示模式报告、键盘布局与虚拟按键状态桥接
  - `libSystem` → 容器内大小写不敏感路径解析、`_smmp`（清除 Mono 数据页 `MAP_JIT`）、崩溃栈定位、**存档路径重定向至「文件」App 可见的 `Documents/Saves/AliceInCradle`**
  - `Metal` / `IOKit` / `Security` / `SystemConfiguration` / `Foundation`
- **《爱丽丝的摇篮》专属触控与手柄覆盖层**：
  - 虚拟摇杆/方向键 + 诺艾儿全动作键位（跳跃、法杖攻击、魔法射击、盾牌防御/弹反、回避冲刺、交互、快捷道具、地图、菜单）
  - 内置实时**可视化键位编辑器**（拖拽位置、缩放大小、调整透明度、显隐开关、横竖屏独立保存）
  - 完整 **MFi / Xbox / DualSense / Backbone 手柄支持**（接入手柄自动淡出虚拟按键）
  - 60 / 120 Hz ProMotion 切换与实时 FPS / 内存浮窗
- **iOS 27 Liquid Glass UI**：启动器采用 iOS 26/27 原生 Liquid Glass 视觉风格（兼容 iOS 17+ 材质回退）。

---

## 使用方式（无需本地 Mac）

### 第一步：使用 GitHub Actions 打包启动器 IPA

1. 将本仓库推送到你的 GitHub 仓库（公开或私有均可）。
2. 进入仓库 **Actions → `Build Alice in Cradle iOS 27 Launcher IPA` → Run workflow**。
   - `runner_os`: 默认 `xcode-27`（如你的仓库暂未分配 `xcode-27` runner，可切换为 `macos-26` 或 `macos-15`）
   - `bundle_id`: 默认 `com.alicecradle.ios.launcher`（可按需修改）
   - `include_llvm_toolchain`: 默认 `false`（约 3 分钟出包；若需在手机端本地汇编链接全量 Mono AOT 伴生库可勾选 `true`，首次编译 LLVM 约需 35~50 分钟并自动缓存）
3. 等待构建完成，在 Artifacts 中下载 **`AliceCradleLauncher-iOS27-Unsigned.ipa`**。

### 第二步：安装到 iPhone 18 Pro（iOS 27）

推荐使用 **[LiveContainer](https://github.com/LiveContainer/LiveContainer)**（配合 SideStore / AltStore / 自签证书），只需占用 1 个签名位：

1. 将 `AliceCradleLauncher-iOS27-Unsigned.ipa` 导入 LiveContainer。
2. 在 LiveContainer 中长按 `AliceCradleLauncher` → **Settings** → 开启 **Fix File Picker**（确保「文件」选择器正常回调）。
3. 启动 `AliceCradleLauncher`（无需开启 JIT）。

### 第三步：导入《爱丽丝的摇篮》游戏本体

1. 准备你合法获取的 **macOS Apple Silicon（arm64 / Universal）版** `AliceInCradle.app`（可保持 `.zip` 压缩包或解压后的 `.app` 文件夹，通过隔空投送 / iCloud / USB 放到 iPhone「文件」App 中）。
2. 在启动器首页点击 **「导入游戏本体 (Import Game)」**，选择 `AliceInCradle.app` 或其 `.zip` 压缩包。
3. 选择运行模式：
   - **IL2CPP 原生模式**（若官方 macOS 包为 IL2CPP）：一键直接导出可玩的 `AliceInCradle-iOS27.ipa`。
   - **Mono 零 JIT 解释/混合模式（Mode 8 / Mode 5）**：自动去除 Mono 数据页 `MAP_JIT` 并导出免 JIT 的 `AliceInCradle-iOS27.ipa`（兼容无 JIT 环境）。
   - **Mono JIT 高性能模式（配合 StikDebug / LiveContainer JIT）**：保留完整 Mono JIT 性能，在 LiveContainer 中开启 JIT 运行，流畅度最佳。
4. 点击 **「生成 iOS 27 游戏 IPA」**，完成后在「文件 → LiveContainer → AliceCradle Exports」（或通过系统分享弹窗）将生成的 `AliceInCradle-iOS27.ipa` 导入 LiveContainer 即可畅玩！

---

## 目录结构

```text
alice-in-cradle-ios/
├── .github/workflows/
│   ├── build-launcher-ipa.yml   # GitHub Actions 主构建：编排 Shims + 启动器 IPA
│   └── ci-checks.yml            # Python 单元测试 + 版权文件防泄漏审计
├── shims/                       # iOS 27 macOS 兼容层源码（编成 14 个 libShim_*.dylib）
│   ├── include/ShimCommon.h
│   ├── overrides/
│   │   ├── AppKit.m             # NSApplication/NSWindow/NSView/NSEvent on UIKit
│   │   ├── AppKit_RuntimeHooks.m# NSBundle Mac/Contents 映射、Mono 模式、Metal 兼容
│   │   ├── AppKit_AliceControls.m# 《爱丽丝的摇篮》专属虚拟按键 + 编辑器 + 手柄 + FPS HUD
│   │   ├── AppKit_Stats.m       # FPS / CPU / 内存实时监控
│   │   ├── AudioUnit_OutputCompat.m  # macOS HALOutput -> iOS RemoteIO
│   │   ├── CoreAudio_OutputCompat.m  # CoreAudio HAL 48kHz 立体声属性仿真
│   │   ├── CoreGraphics.m       # 120Hz 显示模式 + 虚拟键盘状态同步
│   │   ├── CoreVideo_DisplayLink.m   # 60/120Hz ProMotion CVDisplayLink
│   │   ├── Carbon_Keyboard.m    # TIS 键盘布局与按键映射
│   │   ├── CoreServices_Keyboard.m   # UCKeyTranslate 翻译器
│   │   ├── IOKit.m              # 电源/HID 兼容桩
│   │   ├── Metal.m              # Metal GPU 枚举兼容
│   │   ├── Security.m           # 安全查询桩
│   │   ├── SystemConfiguration.m# 网络可达性桩
│   │   ├── Foundation_Compat.m  # Foundation macOS 扩展兼容
│   │   └── libSystem.m          # 大小写无关路径、存档重定向、_smmp、崩溃栈追踪
│   └── resources/
│       ├── Info-game-ios.plist  # 转换后游戏 IPA 的 iOS 27 Info.plist 模板
│       └── entitlements-ios.plist
├── launcher/                    # 独立 iOS 27 启动器 / 转换器 App（无任何游戏资产）
│   ├── Sources/
│   │   ├── main.m
│   │   ├── AppDelegate.m
│   │   ├── HomeController.h / .m# iOS 27 Liquid Glass 主界面、导入、模式选择、存档管理
│   │   ├── GameInspector.h / .m # 自动探测 AliceInCradle.app 架构、Unity版本、Mono/IL2CPP
│   │   ├── MachOConverter.h / .m# ARM64 解胖、LC_BUILD_VERSION->iOS27、依赖重写、_smmp别名
│   │   ├── ZipArchive.h / .m    # 原生流式 ZIP 解压与 ZIP64 IPA 打包器
│   │   ├── GameBuilder.h / .m   # 完整转换管线（支持直转与两阶段打包）
│   │   └── SaveManager.h / .m   # 存档浏览、导入、导出备份
│   └── Resources/
│       └── Info-launcher.plist
├── tools/
│   ├── build_launcher_ipa.py    # 编译所有 Shims + 启动器 App -> 输出未签名 IPA
│   ├── convert_alice.py         # Mac/CI 命令行转换器（也可本地单步转换 .app -> .ipa）
│   ├── make_icon.py             # 程序化生成启动器矢量图标（零第三方版权图片）
│   └── audit_public.py          # 仓库合规检查：确保无版权游戏文件/证书混入
└── tests/
    └── test_converter.py        # Mach-O 解析/重写与工具链单元测试
```

---

## 本地 Mac / CLI 转换（可选）

如果你手头有 Apple Silicon Mac + Xcode 27，除了使用手机端启动器，也可以直接运行命令行转换器将本地 `AliceInCradle.app` 转为未签名 IPA：

```bash
python3 tools/convert_alice.py \
  --input "/path/to/AliceInCradle.app" \
  --output "./AliceInCradle-iOS27-Unsigned.ipa" \
  --mono-mode interp
```

---

## 已知限制与注意事项

1. **必须提供 Apple Silicon（arm64 / Universal）macOS 版游戏**：Windows `.exe`（x86_64/PE）或纯 Intel Mac（x86_64）无法直接执行，因为本项目采用原生 ARM64 机器码执行而非 x86 模拟器。
2. **Mono 游戏在 iOS 27 上的性能差异**：
   - 若官方包为 **IL2CPP**，直接原生满速 120 FPS 运行。
   - 若官方包为 **Mono** 且未启用 JIT，通过 `MONO_AOT_MODE_INTERP_ONLY`（Mode 8）解释执行可能因特定 Unity 2020.3 Mono 运行时差异出现性能下降或兼容问题；建议在 **LiveContainer 中配合 StikDebug 开启 JIT**（选择启动器内的「JIT 高性能模式」），或使用桌面/两阶段 AOT 编出原生伴生库（Mode 5）。
3. **仅限个人正版自用**：请支持原作者 **NanameHacha**，勿在公开渠道分发包含游戏资产的成品 IPA。

## 许可协议

本仓库内原创代码以 **MIT License** 开源；兼容层设计致敬并保留 `zorrobyte/macos-on-ios-public`（Copyright (c) 2026 Ross Fisher）及 `huzaifahshahid71-ops/hollow-games-ios-builder` 的 MIT 版权声明。游戏本体及其商标归原版权方 **NanameHacha** 所有。
