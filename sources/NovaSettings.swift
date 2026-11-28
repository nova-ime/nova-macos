//
//  NovaSettings.swift
//  Squirrel
//
//  Nova 的设置面板：输入方式、开关、使用说明、高级（设置文件夹、重新加载）。Rime 的方案选单不再露出来（Nova 只有一个方案），
//  原来放在选单里的开关都在这里改。
//
//  面板里的选择记在 UserDefaults，是唯一的来源：每个会话建好时、面板里改了之后，都按它设 Rime 的选项
//  （SquirrelInputController.applyNovaOptions）。第一次切到 Nova 时自动打开面板，先选输入方式。
//  高级用户照旧可以在用户目录里写 nova.custom.yaml，「重新加载设置」之后生效。
//

import AppKit
import SwiftUI

enum NovaOptions {
  static let changed = Notification.Name("NovaOptionsChanged")
  private static let layoutKey = "NovaLayout"
  private static let chosenKey = "NovaLayoutChosen"

  // 和 nova.schema.yaml 里那组单选开关的 options 一致，顺序也一致。
  static let layouts: [(id: String, name: String, hint: String)] = [
    ("zrm", "自然码双拼", "Nova 的原生方案"),
    ("flypy", "小鹤双拼", ""),
    ("mspy", "微软双拼", "ing 是 ;"),
    ("sogou", "搜狗双拼", "ing 是 ;"),
    ("quanpin", "全拼", "可以只打声母，没打完也出候选")
  ]

  // 面板里的开关：Rime 选项名、说明。
  static let toggles: [(id: String, name: String)] = [
    ("full_shape", "全角字符"),
    ("ascii_punct", "中文状态下用英文标点"),
    ("quanpin_partial", "全拼补全：没打完也出候选"),
    ("fuzzy_zcs", "模糊音：平翘舌（zh/z、ch/c、sh/s）"),
    ("fuzzy_nasal", "模糊音：前后鼻音（an/ang、en/eng、in/ing、ian/iang、uan/uang）"),
    ("fuzzy_nl", "模糊音：n/l"),
    ("fuzzy_fh", "模糊音：f/h"),
    ("fuzzy_rl", "模糊音：r/l")
  ]

  // 只用来分组显示；模糊音和全拼补全都默认关，用户在设置里打开。
  private static let fuzzyToggles: Set<String> = ["fuzzy_zcs", "fuzzy_nasal", "fuzzy_nl", "fuzzy_fh", "fuzzy_rl"]

  static func isFuzzy(_ id: String) -> Bool { fuzzyToggles.contains(id) }

  static var layout: String {
    get { UserDefaults.standard.string(forKey: layoutKey) ?? "zrm" }
    set {
      UserDefaults.standard.set(newValue, forKey: layoutKey)
      UserDefaults.standard.set(true, forKey: chosenKey)
      NotificationCenter.default.post(name: changed, object: nil)
    }
  }

  static var layoutChosen: Bool { UserDefaults.standard.bool(forKey: chosenKey) }

  static func toggle(_ id: String) -> Bool {
    UserDefaults.standard.bool(forKey: "NovaOption.\(id)")
  }

  static func setToggle(_ id: String, _ value: Bool) {
    UserDefaults.standard.set(value, forKey: "NovaOption.\(id)")
    NotificationCenter.default.post(name: changed, object: nil)
  }

  // 要设给 Rime 的所有选项。单选组每一项都设，选中的为真。
  static var all: [(String, Bool)] {
    let current = layout
    return layouts.map { ($0.id, $0.id == current) } + toggles.map { ($0.id, toggle($0.id)) }
  }
}

final class NovaSettingsWindow: NSObject, NSWindowDelegate {
  static let shared = NovaSettingsWindow()
  private var window: NSWindow?

  func show(tab: NovaSettingsView.Tab = .layout) {
    if window == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
      window.title = "Nova 设置"
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.level = .floating
      self.window = window
    }
    window?.contentView = NSHostingView(rootView: NovaSettingsView(tab: tab))
    window?.center()
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    // 第一次打开时没选就关掉，也算选了默认的自然码，不再每次弹。
    if !NovaOptions.layoutChosen { NovaOptions.layout = NovaOptions.layout }
  }
}

struct NovaSettingsView: View {
  enum Tab: Hashable { case layout, options, appearance, help, advanced }
  @State var tab: Tab

  var body: some View {
    TabView(selection: $tab) {
      LayoutTab().tabItem { Text("输入方式") }.tag(Tab.layout)
      OptionsTab().tabItem { Text("选项") }.tag(Tab.options)
      NovaAppearanceTab().tabItem { Text("外观") }.tag(Tab.appearance)
      HelpTab().tabItem { Text("使用说明") }.tag(Tab.help)
      AdvancedTab().tabItem { Text("高级") }.tag(Tab.advanced)
    }
    .padding(16)
    .frame(width: 600, height: 560)
  }
}

private struct LayoutTab: View {
  @State private var layout = NovaOptions.layout
  private let firstRun = !NovaOptions.layoutChosen

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if firstRun {
        Text("欢迎使用 Nova").font(.title2).bold()
        Text("先选你习惯的打法。以后随时可以在菜单栏的 Nova 菜单 → 设置里改。")
          .foregroundColor(.secondary)
      }
      Picker("", selection: $layout) {
        ForEach(NovaOptions.layouts, id: \.id) { item in
          HStack {
            Text(item.name)
            if !item.hint.isEmpty { Text(item.hint).foregroundColor(.secondary) }
          }.tag(item.id)
        }
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      .onChange(of: layout) { NovaOptions.layout = $0 }
      Text("试一下：选好后打「你好世界」。双拼和全拼学到的词互通，切换不会丢。")
        .foregroundColor(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
  }
}

private struct OptionsTab: View {
  @State private var values = Dictionary(uniqueKeysWithValues: NovaOptions.toggles.map { ($0.id, NovaOptions.toggle($0.id)) })

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(NovaOptions.toggles.indices, id: \.self) { index in
          if NovaOptions.isFuzzy(NovaOptions.toggles[index].id)
            && (index == 0 || !NovaOptions.isFuzzy(NovaOptions.toggles[index - 1].id)) {
            Text("模糊音（全拼）").font(.headline).padding(.top, 4)
          }
          Toggle(NovaOptions.toggles[index].name, isOn: Binding(
            get: { values[NovaOptions.toggles[index].id] ?? false },
            set: {
              values[NovaOptions.toggles[index].id] = $0
              NovaOptions.setToggle(NovaOptions.toggles[index].id, $0)
            }))
        }
        Divider()
        Text("中英切换：单按 Shift。").foregroundColor(.secondary)
        Divider()
        NovaAuxSection()
        Spacer()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
  }
}

private struct HelpTab: View {
  private let sections: [(String, [(String, String)])] = [
    ("打字", [
      ("整句", "连着打，空格整句上屏。输入框里是首选整句，面板里是原始字母。"),
      ("没打完的音节", "全拼在设置 → 选项打开「全拼补全」后，可以只打一半：m、muq、zhon 都出候选，空格直接上屏补全结果。双拼仍按完整音节。"),
      ("模糊音", "全拼支持平翘舌、前后鼻音、n/l、f/h、r/l，在设置 → 选项里可以打开。"),
      ("中英切换", "单按 Shift。以大写字母开头直接打英文。"),
      ("邮箱、网址", "照常打 abc@qq.com、www.x.cn，整段原样上屏。")
    ]),
    ("改错", [
      ("橙色、紫色的词", "紫色是 Nova 替你改过的词，橙色多是打错了键。备选在下面，按数字改；; 等于 1。"),
      ("移到某个词", "←/→ 逐个字母，Tab 往后跳一个词，Shift+Tab 往前。焦点词是黄底。"),
      ("换焦点词", "↓/↑ 换成下一个、上一个备选；-/= 或滚轮翻页。"),
      ("切分错了", "焦点词上按 [ 让出最后一个字给右边，按 ] 把右边第一个字并进来。"),
      ("打错键", "编码不成立时，卡住的那段显示成橙色字母，备选是改一个键后的写法。"),
      ("删掉学错的词", "焦点词上按 Shift+Delete 或 Control+K。")
    ]),
    ("快捷输入", [
      ("日期、时间、星期", "orq、osj、oxq"),
      ("表情", "obq"),
      ("符号", "o 加类别名，如 ofh、osx、ojt；也可以打 /fh、/sx。"),
      ("辅助码", "音节后面打大写字母（形码），筛同音字；也可以先按 ` 再打两个小写字母，ni`re 和 niRE 一样。默认自然码形码，可在「选项」里换成小鹤或墨奇。")
    ]),
    ("颜色", [
      ("蓝", "有把握"),
      ("橙", "没把握，多在打错键时出现"),
      ("紫", "Nova 结合上下文改过的词，值得看一眼"),
      ("绿", "你选过的词，还能再改"),
      ("黄底", "当前焦点")
    ])
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(sections, id: \.0) { section in
          VStack(alignment: .leading, spacing: 6) {
            Text(section.0).font(.headline)
            ForEach(section.1, id: \.0) { row in
              HStack(alignment: .top, spacing: 12) {
                Text(row.0).frame(width: 110, alignment: .leading).foregroundColor(.secondary)
                Text(row.1).fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
  }
}

private struct AdvancedTab: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("自定义") {
        VStack(alignment: .leading, spacing: 8) {
          Text("设置文件夹里的 nova.custom.yaml 可以覆盖方案的任何设置，nova_phrases.txt 是自定义短语。改完点「重新加载设置」。")
            .fixedSize(horizontal: false, vertical: true).foregroundColor(.secondary)
          HStack {
            Button("打开设置文件夹") { NSWorkspace.shared.open(SquirrelApp.userDir) }
            Button("重新加载设置") { NSApp.squirrelAppDelegate.deploy() }
            Button("打开日志") { NSWorkspace.shared.open(SquirrelApp.logDir) }
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
      }
      Spacer()
    }
    .padding(8)
  }
}
