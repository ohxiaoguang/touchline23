import Foundation
import Combine

public enum InterfaceLanguage: String, CaseIterable, Codable, Sendable {
    case system = "system"
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    public var displayName: String { self == .system ? GUIText(key: "System language").render(resolved) : self == .english ? "English" : "简体中文" }
    public func resolve(preferred: [String]) -> InterfaceLanguage {
        guard self == .system else { return self }
        let first = preferred.first?.lowercased() ?? "en"
        return first == "zh" || first.hasPrefix("zh-hans") || first.hasPrefix("zh-cn") || first.hasPrefix("zh-sg") ? .simplifiedChinese : .english
    }
    public var resolved: InterfaceLanguage { resolve(preferred: Locale.preferredLanguages) }
}

/// Language is a presentation preference, deliberately separate from build
/// configuration, approval fingerprints, process lifetime and saved records.
@MainActor
public final class LanguagePreferences: ObservableObject {
    public nonisolated static let key = "packaging.interface-language.v1"
    private let defaults: UserDefaults
    private let storageKey: String
    private var localeChanges: AnyCancellable?
    @Published public var language: InterfaceLanguage {
        didSet { defaults.set(language.rawValue, forKey: storageKey) }
    }
    public init(defaults: UserDefaults = .standard, key: String = LanguagePreferences.key) {
        self.defaults = defaults
        storageKey = key
        language = defaults.string(forKey: key).flatMap(InterfaceLanguage.init(rawValue:)) ?? .system
        localeChanges = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

/// English templates are the keys and fallback. Interpolations stay separate
/// until display, so changing language never rewrites model data or logs.
public struct GUIText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable, Equatable {
    public let key: String
    private let arguments: [Argument]
    fileprivate indirect enum Argument: Sendable, Equatable {
        case raw(String)
        case text(GUIText)
        func render(_ language: InterfaceLanguage) -> String {
            switch self { case .raw(let text): return text; case .text(let text): return text.render(language) }
        }
    }
    public init(key: String) { self.key = key; arguments = [] }
    public init(stringLiteral value: String) { self.init(key: value) }
    public struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var key = ""
        fileprivate var arguments: [Argument] = []
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"; arguments.append(.raw(String(describing: value)))
        }
        public mutating func appendInterpolation(_ value: GUIText) {
            key += "%@"; arguments.append(.text(value))
        }
    }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    public func render(_ language: InterfaceLanguage = .english) -> String {
        let template = language.resolved == .simplifiedChinese ? Self.catalog[key] ?? key : key
        guard !arguments.isEmpty else { return template }
        let pieces = template.components(separatedBy: "%@")
        guard pieces.count == arguments.count + 1 else { return key }
        var value = pieces[0]
        for (i, arg) in arguments.enumerated() { value += arg.render(language) + pieces[i + 1] }
        return value
    }
    public static func launcher(_ raw: String, language: InterfaceLanguage) -> String {
        if raw.hasPrefix("Version ") {
            let version = String(raw.dropFirst(8))
            let text: GUIText = "Version \(version)"
            return text.render(language)
        }
        return GUIText(key: raw).render(language)
    }
    public static func filesHint(_ name: String) -> GUIText {
        "Put files in Files → On My iPhone → \(name). Subfolders are scanned; files stay in place."
    }
    public static let catalog: [String: String] = [
        "Profile metadata": "游戏配置元数据",
        "FIFA 23 Legacy Edition": "FIFA 23 遗产版",
        "Nintendo Switch · Base 1.0.0 · Optional update 1.0.3": "Nintendo Switch · 本体 1.0.0 · 可选更新 1.0.3",
        "American English": "美式英语",
        "British English": "英式英语",
        "Latin American Spanish": "拉丁美洲西班牙语",
        "Canadian French": "加拿大法语",
        "Brazilian Portuguese": "巴西葡萄牙语",
        "Resource notices: %@. Open diagnostics.": "资源提示：%@ 条，请展开诊断。",
        "Showing the first 20 of %@ diagnostics.": "共 %@ 条诊断，此处显示前 20 条。",
        "Console keys": "控制台密钥",
        "Files stay where they are. Keep the drive connected while playing.": "文件保留在原处，游戏运行时请保持磁盘连接。",
        "Choose the folder that holds this game's files. Sub-folders are searched too.": "选择包含此游戏资源的文件夹，也会扫描子文件夹。",
        "Choose a writable folder on your game drive for saves, logs and temporary files. Game resources stay in their original location.": "在游戏磁盘上选择可写文件夹，用于存档、日志和临时文件。游戏资源仍保留在原处。",
        "Put files in Files → On My iPhone → %@. Subfolders are scanned; files stay in place.": "将文件放入“文件”→“我的 iPhone”→%@。子文件夹也会扫描，文件保留在原处。",
        "System language": "跟随系统",
        "Interface language": "界面语言",
        "Show virtual controller": "显示虚拟手柄",
        "Enable native Mouse HID (experimental)": "启用原生鼠标 HID（实验性）",
        "Keeps left-button touch emulation. The game must read Switch Mouse HID; this does not add a game-specific pointer bridge.": "保留左键触摸模拟。游戏需自行读取 Switch 鼠标 HID；此选项不提供任何游戏专用指针桥接。",
        "Enable touchscreen input": "启用触摸屏输入",
        "The game receives taps, drags and gestures. The virtual controller and this screen keep working when it is off.": "游戏将接收点击、拖动与手势。关闭后虚拟手柄和本界面仍然可用。",
        "This App does not contain the game files (romfs). Install the IPA again.": "此 App 内不含游戏资源（romfs），请重新安装该 IPA。",
        "This App does not contain its Shader library (msl). Install the IPA again.": "此 App 内不含 Shader 库（msl），请重新安装该 IPA。",
        "External controllers and game touch input remain available.": "外接控制器与游戏触控输入仍然可用。",
        "Show right stick in 3D mode": "在 3D 模式显示右摇杆",
        "Changes appearance only. The right stick is drawn in the 3D layout.": "仅改变显示；右摇杆只在 3D 布局下绘制。",
        "Bundled resources must match the selected base and update. To change the update, switch to External mode first.": "内嵌资源必须与所选本体和升级包匹配。如需更改升级包，请先切换到外置模式。",
        "Bundled DLC cannot be verified here; availability is checked at runtime.": "此处无法核实内嵌 DLC；实际可用性由运行时检查。",
        "Scanning DLC…": "正在扫描 DLC…",
        "DLC discovery is not verified. Check the resource diagnostics.": "DLC 识别尚未通过校验，请检查资源诊断。",
        "DLC verified before launch: %@": "启动前已通过校验的 DLC：%@",
        "This count is discovery only, not a runtime loaded count.": "此数量仅代表启动前识别结果，不代表游戏运行时已加载。",
        "Resource diagnostics": "资源诊断（含原始技术信息）",
        "Resources verified for this App.": "资源已通过此 App 的校验。",
        "Resources need attention. Open the diagnostics below.": "资源需要处理，请展开下方诊断信息。",
        "Looking for this game's files…": "正在查找此游戏的资源…",
        "Checking the selected files…": "正在检查所选文件…",
        "Checking…": "正在检查…",
        "Resources needed": "需要游戏资源",
        "Play": "开始游戏",
        "Playing": "游戏运行中",
        "Stop game": "停止游戏",
        "Game files": "游戏资源",
        "Found automatically": "自动识别的资源",
        "Game folder": "游戏资源文件夹",
        "Storage location": "存储位置",
        "Saves and logs": "存档与日志",
        "Memory available": "可用内存",
        "About Touchline 23": "关于 Touchline 23",
        "Project home": "项目主页",
        "Report an issue": "问题反馈",
        "Touchline 23 is an independent community project and is not affiliated with or endorsed by EA SPORTS, Nintendo, or their affiliates.": "Touchline 23 是独立的社区项目，与 EA SPORTS、Nintendo 及其关联公司不存在官方隶属或背书关系。",
        "The open-source license applies only to the project code explicitly covered by the license. It does not grant rights to game content, firmware, keys, or other third-party assets.": "开源许可证仅适用于明确受该许可证覆盖的项目代码，不授予游戏内容、密钥、固件或第三方资源的使用权。",
        "Please use the official GitHub repository for project information. Beware of unauthorized paid IPA resales or unofficial repackaged builds.": "请以官方 GitHub 仓库为准，警惕未经授权的付费 IPA 转售和重新打包版本。",
        "Look again": "重新扫描",
        "Rescan": "重新扫描",
        "Choose folder": "选择文件夹",
        "MOD folder (optional)": "MOD 文件夹（可选）",
        "Not selected · MODs will not be loaded": "未选择 · 不加载 MOD",
        "Choose the MOD resource folder. Choose mods/romfs or the folder containing the individual MODs.": "选择 MOD 资源文件夹，可选择 mods/romfs，或直接包含各个 MOD 的文件夹。",
        "Cannot read the MOD folder. Choose it again or clear the selection.": "无法读取 MOD 文件夹，请重新选择或清除该选择。",
        "Change": "更改",
        "No folder chosen": "尚未选择文件夹",
        "Not found": "未找到",
        "Searched, including every sub-folder": "已扫描，包括所有子文件夹",
        "Base game only": "仅本体",
        "with the update above": "包含上述升级包",
        "Choose what to run": "选择启动资源",
        "More than one match": "发现多个匹配项",
        "The update here does not match this App": "此处的升级包与 App 不匹配",
        "Use base only": "仅使用本体",
        "Use these": "使用这些资源",
        "Bundled in this App": "已内嵌于此 App",
        "Contents/Resources/romfs · nothing to select": "Contents/Resources/romfs · 无需选择",
        "Choose a storage folder before playing.": "请先选择存储文件夹再开始游戏。",
        "Pick the folder that holds this game's files": "选择包含此游戏资源的文件夹",
        "Not selected · choose a folder on your game drive": "尚未选择，请在游戏磁盘上选择文件夹",
        "The game files are inside this App; they are read only.": "游戏资源已内嵌于此 App，按只读方式使用。",
        "Game running.": "游戏运行中。",
        "Game running. Keep the resource drive connected.": "游戏运行中，请保持资源磁盘连接。",
        "Game closed. Ready to play.": "游戏已关闭，可以再次开始。",
        "Choose the folder that holds this game's files.": "请选择包含此游戏资源的文件夹。",
        "Choose a storage folder for saves and logs.": "请选择存放存档和日志的文件夹。",
        "Game files are inside this App. Ready to play.": "游戏资源已内嵌，可以开始游戏。",
        "This App carries no game files: rebuild it in directory mode.": "此 App 没有内嵌游戏资源，请以内嵌模式重新构建。",
        "Console mode": "主机模式",
        "Docked": "底座模式",
        "Handheld": "掌机模式",
        "Game language": "游戏语言",
        "Frame rate": "帧率",
        "Frame-rate counter": "显示帧率",
        "Performance HUD": "性能面板",
        "Render scale": "渲染比例",
        "Touch feedback": "触控反馈",
        "Haptic clicks when pressing touch controls.": "按下触控按键时提供触觉反馈。",
        "Game rumble": "游戏振动",
        "Vibration from the game on your phone or connected controller.": "在手机或已连接控制器上输出游戏振动。",
        "Rumble strength": "振动强度",
        "Adjusts game rumble alongside the game's own vibration setting.": "配合游戏自身的振动设置调节强度。",
        "Set by an env file": "由环境配置文件设置",
        "Sound follows Silent Mode. Turn Silent Mode off and raise the media volume if the game is quiet.": "声音遵循静音模式。如游戏无声，请关闭静音并调高媒体音量。",
        "Version %@": "版本 %@",
        "French": "法语",
        "German": "德语",
        "Italian": "意大利语",
        "Spanish": "西班牙语",
        "Japanese": "日语",
        "Korean": "韩语",
        "Russian": "俄语",
        "Dutch": "荷兰语",
        "Portuguese": "葡萄牙语",
        "Simplified Chinese": "简体中文",
        "Traditional Chinese": "繁体中文",
        "30 fps": "30 帧/秒",
        "60 fps": "60 帧/秒",
        "Localized names do not indicate in-game language support.": "中文名称仅用于目录显示，不代表游戏内支持中文。",
        "Confirm Packaging": "确认开始打包？",
        "Start Packaging": "开始打包",
        "Game": "游戏",
        "Controls": "操控",
        "Performance": "性能",
        "Game version": "游戏版本",
        "Build targets": "构建目标",
        "Shader status": "Shader 状态",
        "Output location": "输出位置",
        "Reuse cache": "复用缓存",
        "Generation required": "需要生成",
        "Validated cache": "缓存已校验",
        "Build IDs": "Build ID",
        "Shader chain": "Shader Chain",
        "Shader input digest": "Shader 输入摘要",
        "Shader count": "Shader 数量",
        "Review fingerprint (SHA-256)": "审核指纹（SHA-256）",
        "Technical Details": "技术详情",
        "Copy full value": "复制完整内容",
        "External mode keeps game images and keys outside the artifact.": "外置模式的游戏镜像与密钥保留在产物之外。",
        "Directory mode bundles prepared resources and needs more disk space.": "Directory 模式会内置已准备的资源，需要更多磁盘空间。",
        "iOS needs the extended-virtual-addressing entitlement when signing (guest reservation above 6 GB)": "iOS 签名时需要扩展虚拟地址权限（游戏预留空间超过 6 GB）。",
        "Shader source is EASF: reuse needs a completed EASF source build; automatic generation verifies the source archives": "EASF Shader 缓存需来自完整的来源构建；自动生成时会校验来源归档。",

        "Resources are prepared automatically": "自动准备游戏资源",
        "Bundled runtime is missing. Rebuild or replace the App.": "内置运行环境缺失，请重新构建或更换 App。",
        "Clear managed cache?": "清理软件管理的缓存？",
        "Clear cache": "清理缓存",
        "Remove %@ of managed cache. Other files and previous cache locations are kept.": "将清理 %@ 的软件缓存。其他文件和之前的缓存位置保持不变。",
        "Restore default output": "恢复默认输出目录",
        "Settings and diagnostics": "设置与诊断",
        "Cache folder": "缓存目录",
        "Measure cache": "计算缓存占用",
        "Clear cache…": "清理缓存…",
        "Changing the cache folder keeps the previous cache in place.": "切换目录后，之前的缓存仍保留在原处。",
        "Detect again": "重新检测",
        "Detected": "已检测到",
        "Not detected": "未检测到",
        "Tool detection is informational. Missing tools are reported by the actual build.": "检测结果仅供参考。缺少必要工具时，实际构建流程会报告错误。",
        "Settings operation failed; see diagnostic logs.": "设置操作失败，请查看诊断日志。",

        "Tool: %@": "工具：%@",
        "Add-on content": "附加内容",
        "Control metadata": "控制元数据",
        "RomFS": "RomFS",
        "Python": "Python",
        "Recipe preview": "配方预览",
        "Review": "审核",
        "Inspection": "输入检查",
        "Edit": "编辑",
        "View": "显示",
        "Window": "窗口",
        "Help": "帮助",
        "Services": "服务",
        "Hide Touchline 23 Packaging": "隐藏 Touchline 23 打包工具",
        "Hide Others": "隐藏其他",
        "Show All": "全部显示",
        "Close Window": "关闭窗口",
        "Undo": "撤销",
        "Redo": "重做",
        "Cut": "剪切",
        "Copy": "复制",
        "Paste": "粘贴",
        "Paste and Match Style": "粘贴并匹配样式",
        "Select All": "全选",
        "Enter Full Screen": "进入全屏幕",
        "Minimize": "最小化",
        "Zoom": "缩放",
        "Bring All to Front": "前置全部窗口",
        "New Window": "新建窗口",
        "Touchline 23 Packaging Help": "Touchline 23 打包工具帮助",
        "Show Tab Bar": "显示标签页栏",
        "Show All Tabs": "显示所有标签页",
        "Show Toolbar": "显示工具栏",
        "Customize Toolbar…": "自定工具栏…",
        "Previous Tab": "上一个标签页",
        "Next Tab": "下一个标签页",
        "Move Tab to New Window": "将标签页移到新窗口",
        "Merge All Windows": "合并所有窗口",
        "Close Tab": "关闭标签页",
        "Find": "查找",
        "Spelling and Grammar": "拼写和语法",
        "Substitutions": "替换",
        "Transformations": "转换",
        "Speech": "语音",
        "AutoFill": "自动填充",
        "Start Dictation…": "开始听写…",
        "Emoji & Symbols": "表情与符号",
        "Task complete": "任务已完成",
        "Preflight passed": "预检通过",
        "Elapsed %@ s · %@": "耗时 %@ 秒 · %@",
        "%@ · %@ · %@ / %@": "%@ · %@ · %@ / %@",
        "Unavailable · %@": "暂不可用 · %@",
        " · Batch ": " · 批次 ",
        " · Batch %@": " · 批次 %@",
        " · Temporary work removed": " · 临时文件已清理",
        "%@ selected; failed targets are excluded.": "已选择 %@ 个；未通过检查的目标不会构建。",
        "About Touchline 23 Packaging": "关于 Touchline 23 打包工具",
        "Advanced settings (usually unchanged)": "高级设置（开发选项，通常无需修改）",
        "Artifact audit passed": "产物审计通过",
        "Audit artifact": "审计产物",
        "Base game": "游戏本体",
        "Base game file": "游戏本体文件",
        "Base: %@": "本体：%@",
        "Batch: target %@/%@": "批次：第 %@/%@ 个目标",
        "Build": "构建",
        "Build %@ target(s) in order: %@": "按顺序构建 %@ 个目标：%@",
        "Build %@ targets…": "开始打包 %@ 个目标…",
        "Build complete · Artifact audit passed · Game runtime unverified": "打包完成 · 产物审计通过 · 游戏运行未验证",
        "Build host": "构建运行环境",
        "Build in progress": "构建进行中",
        "Build mode": "构建模式",
        "Build now": "确认执行",
        "Build progress": "构建进度",
        "Build tools": "构建工具",
        "Build…": "开始打包…",
        "Bundle audit": "产物审计",
        "Bundled resources": "内置资源",
        "Bundled resources (Directory)": "内置资源（Directory）",
        "Cancel": "取消",
        "Cancel task": "取消任务",
        "Cancelled": "已取消",
        "Cancelled · Temporary work removed; logs kept": "已取消 · 临时文件已清理，日志保留",
        "Cancelling": "正在取消",
        "Cannot identify the game; check the selected file and prod.keys.": "无法识别游戏：请检查所选文件与 prod.keys。",
        "Cannot read history · See technical details": "无法读取历史 · 请查看技术详情",
        "Check configuration": "检查配置",
        "Choose ExeFS manually: main / sdk and the adjacent control.nacp are required; iOS also reads the icon there. Python requires capstone, lz4.block and fontTools. Interpreter and dependency versions are bound to the review fingerprint.": "ExeFS 目前仍需手动指定：构建链要用其中的 main / sdk 与同级 control.nacp；iOS 也从同一文件夹读取 control.nacp 与图标。Python 需要 capstone、lz4.block、fontTools；解释器与依赖版本计入审核指纹。",
        "Choose a base game and prod.keys to identify it": "选择本体与 prod.keys 后自动识别",
        "Choose a base game and prod.keys to identify the game.": "选择游戏本体与 prod.keys 后，程序会自动识别游戏。",
        "Choose a path": "选择路径",
        "Choose a project Python with capstone, lz4.block and fontTools.": "请选择项目 Python 解释器：需要 capstone、lz4.block、fontTools。",
        "Choose an .nsp update, or leave empty": "选择 .nsp 更新包，或留空",
        "Choose an .xci or .nsp": "选择 .xci 或 .nsp",
        "Choose a resource folder or enter an .xci / .nsp path": "选择资源文件夹，或输入 .xci / .nsp 路径",
        "Choose an executable Python interpreter.": "请选择可执行的 Python 解释器。",
        "Choose an existing nxrom.dylib": "选择已有的 nxrom.dylib",
        "Choose an extracted RomFS folder": "选择已解包的 RomFS 目录",
        "Choose prod.keys": "选择 prod.keys",
        "Choose the GUI repository containing scripts/packaging_gui.py.": "请选择包含 scripts/packaging_gui.py 的 GUI 仓库。",
        "Choose…": "选择…",
        "Clear": "清除",
        "Completed": "已完成",
        "Confirm a real build": "确认一次真实构建",
        "Confirm this real build?": "是否确认执行这一次真实构建？",
        "DLC folders require iOS Directory mode; clear this input for other combinations.": "DLC 目录只用于 iOS 内置资源构建；其他组合请清空该输入。",
        "DLC folders require iOS Directory mode; this selection cannot build.": "DLC 目录只用于 iOS 内置资源构建；当前组合会阻止打包。",
        "DLC: bundle %@ (one per numbered folder)": "DLC：打包 %@（每个数字目录一份）",
        "Defaults to the base game folder": "默认为游戏本体所在目录",
        "Dependencies": "依赖环境",
        "Details": "详情",
        "Directory mode requires an extracted RomFS folder.": "内置资源模式需要选择已解包的 RomFS 目录。",
        "EASF key": "EASF 密钥",
        "EASF key file": "EASF 密钥文件",
        "Elapsed %@ s · Artifact audit passed": "耗时 %@ 秒 · 产物审计通过",
        "Elapsed %@ s · Exit %@ · See task log": "耗时 %@ 秒 · 退出码 %@ · 请查看任务日志",
        "Elapsed %@ s · Stopped": "耗时 %@ 秒 · 已停止",
        "English": "English",
        "Estimated minimum %@; available %@": "预计至少 %@；可用 %@",
        "Exit %@": "退出码 %@",
        "External XCI / NSP": "外置 XCI / NSP",
        "Failed": "失败",
        "Failed · ": "未通过 · ",
        "Failed · See task log": "失败 · 请查看任务日志",
        "File": "文件",
        "Files kept": "文件保留",
        "Find repository Python": "检测仓库虚拟环境",
        "Folder": "目录",
        "Full Shader generation is available as a recipe preview only.": "本阶段完整 Shader 生成仅支持配方预览。",
        "GUI repository": "GUI 仓库",
        "Game and container identity": "游戏识别与容器校验",
        "Game could not be identified": "无法识别游戏",
        "Game identity": "游戏识别",
        "Game runtime unverified": "游戏运行未验证",
        "Game: %@": "游戏：%@",
        "Generate Shaders": "生成 Shader",
        "Generate fonts": "生成字体",
        "Generate settings": "生成启动设置",
        "Identified": "已识别",
        "Identified %@; choose Check configuration to run preflight.": "已识别 %@；点击“检查配置”完成预检。",
        "Identify": "识别",
        "Identifying game…": "正在识别游戏…",
        "Idle": "空闲",
        "If a target fails or is cancelled, later targets will not start.": "任一目标失败或取消，后面的目标不再开始。",
        "Inputs": "输入",
        "Internal task folder: %@": "内部工作目录：%@",
        "Interrupted": "已中断",
        "Interrupted · Files kept": "任务中断 · 文件保留",
        "Keep work after failure (diagnostics; logs and results are always kept)": "失败时保留构建中间文件（用于诊断；默认只保留日志与结果）",
        "Language / 语言": "Language / 语言",
        "Live logs / success": "连续日志 / 成功",
        "No artifact": "无产物",
        "No tasks yet": "暂无任务",
        "No venv / .venv / .env found; choose an interpreter.": "所选仓库内没有 venv / .venv / .env，请手动选择解释器。",
        "None": "无",
        "Not checked": "未检查",
        "Not recorded (older review)": "未记录（旧确认单）",
        "Open": "打开",
        "Open diagnostic logs": "打开诊断日志目录",
        "Original ExeFS": "原始 ExeFS",
        "Output folder": "输出目录",
        "Output location and space": "输出位置与空间",
        "Output space": "输出空间",
        "Output: %@": "输出：%@",
        "Package App": "打包 App",
        "Package IPA": "打包 IPA",
        "Packaging": "打包方式",
        "Parallel jobs: %@": "并行任务数：%@",
        "Partially passed": "部分通过",
        "Partially passed: %@ failed; only %@ target(s) will build.": "部分通过：%@ 未通过，本次只构建通过的 %@ 个目标。",
        "Passed": "通过",
        "Paths saved; inputs will be revalidated before use.": "路径已保存；使用时仍会重新校验。",
        "Pending": "等待开始",
        "Platform and resources: %@": "平台与资源模式：%@",
        "Preflight": "预检",
        "Preflight checks": "自动检查",
        "Preflight complete · Passed": "检查完成 · 通过",
        "Preflight failed · See results below": "检查未通过 · 见下方结果",
        "Preflight failed · See technical details": "检查未通过 · 请查看技术详情",
        "Preflight failed; see results below.": "检查未通过，见下方结果。",
        "Preflight passed: %@ target(s) ready to build.": "检查通过：%@ 个目标可以开始打包。",
        "Preparing task…": "准备任务…",
        "Process tree / cancel": "父子进程 / 等待取消",
        "Program version": "程序版本",
        "Program: %@; Shader sources: %@": "程序：%@；Shader 来源：%@",
        "Publish artifact": "投放产物到输出目录",
        "Python: %@": "Python：%@",
        "Python: capstone": "Python：capstone",
        "Python: fontTools": "Python：fontTools",
        "Python: lz4.block": "Python：lz4.block",
        "Quit Touchline 23 Packaging": "退出 Touchline 23 打包工具",
        "Raw tool output / technical details": "原始工具输出 / 技术详情",
        "Read base and optional NSP update; keep resources external": "读取本体与可选 NSP 更新包，资源留在原处",
        "Reader library": "Reader 动态库",
        "Reading Title ID from game resources…": "正在从游戏资源读取 Title ID…",
        "Ready to check": "待检查",
        "Real build and artifact audit": "真实打包与产物审计",
        "Repository interpreter selected; preflight will validate it.": "已选择仓库内的解释器；仍以审核结果为准。",
        "Requires extracted RomFS": "需要已解包的 RomFS",
        "Resource mode": "资源模式",
        "Resources: bundle %@": "资源：打包 %@",
        "Resources: game data stays external; import matching containers and keys on the device.": "资源：不打包游戏数据；在设备上导入匹配的游戏容器与密钥。",
        "Reuse validated Shaders without full Metal compilation. Build and audit in an isolated task, publish only after validation, then remove this run’s work. Existing files are kept.": "仅复用已验证 Shader，不进行全量 Metal 编译。在独立任务中构建及审计，通过后才发布产物并清理本次工作目录；已有文件保持原样。",
        "Revalidate inputs and approval": "复核输入与审核指纹",
        "Review fingerprint (SHA-256): %@": "审核指纹（SHA-256）：%@",
        "Rewrite SDK": "重写 SDK",
        "Rewrite main program": "重写主程序",
        "Run preflight first.": "请先完成配置检查。",
        "Run test task": "运行模拟任务",
        "Running": "正在执行",
        "Running · %@": "运行中 · %@",
        "Save settings": "保存设置",
        "Select at least one target platform.": "请至少选择一个目标平台。",
        "Select one or both; each builds and audits in order": "可多选；顺序构建，各自独立审计",
        "Shader cache": "Shader 缓存",
        "Shader generation": "Shader 生成",
        "Show artifact": "显示产物",
        "Simulation": "模拟任务",
        "Stage %@ / %@: %@": "第 %@ / %@ 阶段：%@",
        "Starting": "正在准备",
        "Stopping the task process group…": "正在终止任务进程组…",
        "Succeeded": "成功",
        "Switch key file": "Switch 密钥文件",
        "Switch keys": "Switch 密钥",
        "Target %@/%@ (%@) · ": "第 %@/%@ 个目标（%@）· ",
        "Target platforms": "目标平台",
        "Task finished; see the result below.": "任务已结束，见下方状态。",
        "Task history": "任务历史",
        "Technical details (%@)": "失败详情（%@）",
        "Temporary work removed": "临时文件已清理",
        "Test task": "模拟任务",
        "This build has 1 target.": "本次将构建 1 个目标。",
        "This resource mode is unavailable.": "所选资源模式暂不可用。",
        "Tool: ": "工具：",
        "Unavailable · ": "暂不可用 · ",
        "Unknown": "未知",
        "Unsigned IPA and artifact audit": "未签名 IPA，产物审计",
        "Update": "更新包",
        "Update (optional)": "更新包（可选）",
        "Update: %@": "更新：%@",
        "View log": "查看日志",
        "View task log": "查看任务日志",
        "missing": "缺失",
        "Touchline 23 Packaging": "Touchline 23 打包工具",
        "stderr / failure": "stderr / 失败",
        "version unknown": "版本未知",
        "简体中文": "简体中文",
        // Shared profile metadata schema
        "Every registered game profile, with what the engine can build and what was verified.": "列出每个已登记的游戏配置，说明引擎能为它构建什么、以及已经验证过什么。",
        "Registered profile": "已登记配置",
        "Build capability": "构建能力",
        "Build verified": "构建已验证",
        "Runtime verified": "运行已验证",
        "A folder in dm/games describes this game. The entry is a description, not a verification claim.": "dm/games 下的一个目录描述了这款游戏。登记只是描述，不是验证结论。",
        "What this engine can plan and audit for the profile, derived from the profile and the engine's own dependencies.": "引擎能为该配置规划并审计到什么，由配置内容与引擎自身的依赖条件推导，不依赖游戏名单。",
        "An App or IPA was built and passed the artifact audit. The game itself was not started.": "已构建出 App 或 IPA 并通过产物审计；游戏本身尚未启动。",
        "The packaged game was started and reported working, with the record that states it.": "打包后的游戏已启动并有记录表明可用，且注明记录来源。",
        "Refresh": "刷新",
        "Done": "完成",
        "Name (A–Z)": "名称（A–Z）",
        "Title ID": "Title ID",
        "Evidence": "验证记录",
        "Search by name or Title ID": "按名称或 Title ID 搜索",
        "What the columns mean": "各列含义",
        "Profile is not readable": "配置不可读",
        "Reading the registered games…": "正在读取已登记的游戏…",
        "Select a game to see its registered profile": "选择一个游戏查看其已登记配置",
        "A profile describes constants; it does not verify a build or a run.": "配置只描述常量，不代表构建或运行已验证。",
        "App name": "App 名称",
        "Registered versions": "登记版本",
        "Code modules": "代码模块",
        "Package": "版本标识",
        "Shader versions": "Shader 版本",
        "Graphics API": "图形接口",
        "Shader archive": "Shader 归档",
        "source build required for reuse": "复用前需先完成源码构建",
        "RomFS marker": "RomFS 标记",
        "Resource modes": "资源模式",
        "Limitations": "限制",
        "Evidence source": "验证来源",
        "Note": "备注",
        "Technical details": "技术细节",
        "Catalog entry": "列表条目",
        "Read at": "读取时间",
        "Not buildable": "不可构建",
        "Only a build that passed its audit is shown as built; a started game is a separate record.": "只有通过审计的构建才标记为已构建；游戏是否启动是另一条独立记录。",
        "Built and audited (this fork)": "已构建并审计（本 fork）",
        "Built (upstream record)": "已构建（上游记录）",
        "No build record": "无构建记录",
        "Runtime reported (this fork)": "运行已报告（本 fork）",
        "Runtime (upstream record)": "运行（上游记录）",
        "No runtime record": "无运行记录",
        "Choose a project Python to read the game list.": "请选择项目 Python 以读取游戏列表。",
        "This checkout has no game registry; choose the packaging checkout.": "该仓库没有游戏注册表，请选择包含打包引擎的仓库。",
        "Cannot read the registered games; see the task log.": "无法读取已登记的游戏，请查看任务日志。",
    ]

    public static func stage(_ key: String) -> GUIText {
        if key.hasPrefix("simulation-") { return "Test task" }
        let names = ["revalidate": "Revalidate inputs and approval", "generate-shaders": "Generate Shaders",
                     "rewrite-main": "Rewrite main program", "rewrite-sdk": "Rewrite SDK", "host": "Build host",
                     "font": "Generate fonts", "settings": "Generate settings", "package-app": "Package App",
                     "package-ipa": "Package IPA", "audit": "Audit artifact", "publish": "Publish artifact",
                     "check": "Preflight", "preparing": "Preparing task…"]
        return GUIText(key: names[key] ?? key)
    }
    public static func state(_ key: String) -> GUIText {
        GUIText(key: ["idle":"Idle", "starting":"Starting", "running":"Running", "cancelling":"Cancelling",
                      "succeeded":"Succeeded", "failed":"Failed", "cancelled":"Cancelled", "interrupted":"Interrupted"][key] ?? key)
    }
    public static func kind(_ key: String) -> GUIText {
        GUIText(key: ["build":"Build", "check":"Preflight", "simulation":"Simulation", "identify":"Identify",
                      "plan":"Recipe preview", "review":"Review", "inspect":"Inspection",
                      "games":"Profile metadata"][key] ?? key)
    }
    public static func mode(_ key: String) -> GUIText {
        GUIText(key: ["directory":"Bundled resources (Directory)", "nsp":"External XCI / NSP", "none":"None"][key] ?? key)
    }
    public static func platform(_ key: String) -> GUIText {
        GUIText(key: ["macos":"macOS App", "ios":"iOS IPA", "simulation":"Simulation"][key] ?? key)
    }
}


public enum DLCDiscoveryText {
    public static func summary(external: Bool, busy: Bool, verified: Bool, count: Int?) -> GUIText {
        if !external { return "Bundled DLC cannot be verified here; availability is checked at runtime." }
        if busy { return "Scanning DLC…" }
        guard verified, let count, count >= 0 else { return "DLC discovery is not verified. Check the resource diagnostics." }
        return "DLC verified before launch: \(count)"
    }
}
