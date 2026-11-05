# Touchline 23

[English](README.md) · [打包指南](docs/packaging-gui.zh-CN.md) · [兼容性记录](docs/fifa23/compatibility.md)

Touchline 23 是专门运行 **Nintendo Switch 版 FIFA 23 Legacy Edition（FIFA 23 遗产版）**
的原生 Apple 芯片移植项目，提供 **macOS、iOS 和 iPadOS** 启动器，独立维护、独立发布。
游戏自身的 ARM64 代码运行在宿主实现的系统服务、图形、音频和输入接口上。

游戏文件和主机密钥需要由你自行提供。仓库只包含源码、兼容性元数据与构建工具，
不提供游戏、密钥或可直接分发的游戏资源。

## 开始使用

1. 准备自己的本体 XCI/NSP、`prod.keys`，以及可选的 1.0.3 NSP 更新包。
2. 按下方命令构建 `Touchline23.app` 或未签名的 `Touchline23.ipa`，也可以使用图形界面的
   **Touchline 23 Packaging**。
3. macOS 在启动器里选择资源文件夹；iPhone/iPad 通过“文件”将资源放进 App 的 Documents
   目录，子文件夹也会被扫描。
4. 核对识别结果，选择界面语言、游戏语言和主机模式，再开始游戏。设置中提供“关于 Touchline 23”。

IPA 需要自行签名与侧载。公开源代码不代表可以转售或重新分发本地构建中包含的游戏代码和派生资源。

## 平台与当前状态

| 平台／功能 | 证据与范围 |
| --- | --- |
| Apple 芯片，macOS 26+ | MacBook Air M1 上验证过菜单和正式比赛 |
| iPhone，iOS 26+ | iPhone Air 用户反馈已能游玩；当前 App/IPA 另有编译和静态检查记录 |
| iPad，iPadOS 26+ | 共用 iOS 界面和打包目标，尚无独立的 iPad 游玩记录 |
| 掌机／底座、音效和解说、观众、指示器、2D/3D 雷达、存档 | 验证记录中有 Mac 证据及 iPhone 反馈 |
| 触摸虚拟手柄与游戏手柄 | iPhone 用户测试通过，手柄型号覆盖仍有限 |
| 动态球员阴影 | Mac 正式比赛投影及针对性 GPU 检查通过，iPhone 详细对照仍不完整 |
| macOS MOD overlay | 可选资源覆盖文件夹，有合成测试；不保证某个 FIFA MOD 一定兼容 |
| 双语启动器／关于页面 | 英文和简体中文；Mac 关于页面交互已测试，iOS 关于页面仅编译，未做设备点击验证 |

[兼容性](docs/fifa23/compatibility.md)和[验证记录](docs/fifa23/validation.md)分别标明实际游玩、
用户反馈、构建审计和自动测试。构建了新产物，不等于重新验证过游戏运行。

## 游戏版本与资源模式

| 项目 | 信息 |
| --- | --- |
| 游戏 | FIFA 23 Legacy Edition（Nintendo Switch） |
| Title ID | `01001C8016B4E000` |
| 本体 | 1.0.0（`v0`），也是 Shader 的来源版本 |
| 可选更新 | 1.0.3（`v196608`），现有游玩记录对应的版本 |
| App／Bundle ID | Touchline 23／`com.ohxiaoguang.touchline23` |

代码与资源必须属于同一游戏版本。登记了 1.0.0 构建，并不意味着它有与 1.0.3 相同的游玩验证范围。

**外置 XCI/NSP（默认）**：启动器校验匹配的文件，原地读取容器。本体、密钥和 RomFS 不进入
产物，但 App 仍包含重写后的程序模块与派生 Shader 库。

**Directory**：打包工具和底层脚本可以准备并内置 RomFS，产物明显更大，资源版本也随构建固定。
详见[打包指南](docs/packaging-gui.zh-CN.md)。本 FIFA profile 不提供 DLC 选择器。

macOS 可在启动器设置中另选存档和日志的存储位置。iOS 的存档和诊断留在 App 容器内，重装前请备份。

## 从源码构建

需要 Apple 芯片 Mac、Xcode 及 Metal 工具链、.NET 10、SPIRV-Cross、相关 Python 依赖，
iOS 另需 XcodeGen。[构建指南](docs/fifa23/build.md)列出了实际验证的工具版本、锁定指纹和依赖安装方法。
这些构建使用的项目源码已包含在公开仓库中。Git 克隆和下载的源码压缩包构建方式相同：
构建链不读取 `.git`，完整的重新构建也不需要任何旧构建产物。

```sh
./scripts/build-mac.sh --nsp-dir "/path/to/your/fifa23-folder"
./scripts/build-ios.sh --nsp-dir "/path/to/your/fifa23-folder"
```

输出为 `Release/Touchline23.app` 和 `Release/Touchline23.ipa`，这两个入口构建的是外置资源版本。
默认工作目录是被 Git 忽略的 `build/work`；游戏原始输入、密钥和提取／分析工作放在游戏所在磁盘上。

macOS App 默认不做签名：ad-hoc 签名需显式加 `--sign`（或用 `--sign "<身份>"` 指定签名身份），
它会把 `Info.plist` 与全部资源纳入封印。未签名的构建可正常运行。Game Mode 由 App 的
`Info.plist`（`LSApplicationCategoryType` 与 `LSSupportsGameMode`）申请，与签名无关。
Directory 版 App 内置完整 RomFS（本作约 14.8 GB），macOS 首次打开时会校验整个 App，
首次启动明显慢于之后各次。

重新构建宿主或启动器时，可复用已有成果：

| 已准备的输入 | 参数 |
| --- | --- |
| ExeFS | `--exefs <目录>` |
| 重写后的 main/sdk | `--patched <目录>` |
| macOS 和 iOS Shader 库 | `--shaders <目录>`／`--ios-shaders <目录>` |
| EASF 来源包 | `--shader-pack <pkg>` |

本体的 386 个程序生成**每个平台 520 个库**，1.0.3 更新没有新增 Shader。库必须匹配
`a885c56c665a` 翻译链及本 profile 的输入标记。已有缓存有效时直接复用，不要为界面或文档修改重新生成。
工作目录、输出路径等选项见 `./scripts/build-mac.sh --help`。

## Touchline 23 Packaging

专用于本游戏的双语 SwiftUI 工具：选择 macOS/iOS 或双平台、外置 XCI/NSP 或 Directory，
检查资源、确认构建、查看进度，最后取得审计通过的产物。保留 Shader 缓存、错误诊断和取消功能，
不再提供游戏浏览列表或不适用的 DLC 输入。

使用 `scripts/build_packaging_gui.py --output <新目录>` 构建工具。
[中文指南](docs/packaging-gui.zh-CN.md)说明内置依赖、磁盘占用、输出保护和工具本身的源码构建方式。

## 已知限制

- 不保证稳定 60 FPS。本 profile 没有 30/60 FPS 开关；共享引擎的诊断用帧节奏参数并不是经过验证的帧率补丁。
- 启动时保留 5 GiB 客户机地址空间，历史比赛样本常驻约 2.8 GiB。这是观测数据，不是适用于所有
  设备的内存要求，也不保证不会触发 iOS jetsam；已记录的 iPhone 有 8 GB 内存。
- 场地、天气、特殊场景和长时间运行覆盖不完整。加载时可能出现音频欠载，部分服务仍会打印 `[RED]` 诊断。
- 不提供在线联机或 Switch 网络服务。
- 不支持 Intel Mac，也没有单独验证过完整的 iPad／设备兼容矩阵。

## 开发与本地检查

[图形层](dm/gfx/README.md)、[profile 格式](dm/games/README.md)、
[提取流程](docs/agents/01-extract.md)和[调试指南](docs/agents/05-debugging.md)介绍开发方法。
测试在本地执行，本项目没有 GitHub Actions 工作流。

```sh
python3 -m unittest discover -s scripts/tests
python3 scripts/check_markdown_links.py
python3 scripts/check_fifa23_public.py
swift test --package-path gui
```

公开内容扫描器会对部分已保留的第三方文件类型要求人工复核，处理结论见[源码发布审查](docs/fifa23/public-audit.md)。
[构建与回归说明](docs/fifa23/build.md#regression-checks)另列资源及 GPU 测试与所需样本。

## 项目来源与致谢

Touchline 23 基于 [nxnative](https://github.com/seedds/nxnative) 及其作者和贡献者的成果开发。
FIFA 23 的兼容性、图形与资源适配及独立打包支持在该引擎基础上完成，并由本项目继续维护。
这些后续适配不会被误记成全部来自官方上游；详见[项目来源](docs/UPSTREAM.md)。

保留原始 [MIT 许可证](LICENSE)与作者声明，各依赖继续适用自身条款，包括 MsgPack 的 Apache-2.0。
[第三方声明](THIRD_PARTY_NOTICES.md)提供完整材料索引。项目图标为自行生成的原创图形。
Touchline 23 与 EA SPORTS、Nintendo 或 Apple 不存在官方隶属或背书关系。

[官方仓库](https://github.com/ohxiaoguang/touchline23) · [问题反馈](https://github.com/ohxiaoguang/touchline23/issues)
