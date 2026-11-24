//
//  NovaThemeEditor.swift
//  Nova Squirrel
//
//  设置面板的「外观」页和主题编辑器。字段的名字、分组、范围都来自 nova-ui（nova_ui_theme_fields），
//  Windows 的编辑器用同一张表，所以两边能改的东西一样。预览用的是真正的面板绘制代码（NovaLayout + NovaView）。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 预览用的内容：五种词块颜色、字母行、备选格都露出来。
enum NovaThemeSample {
  // 自然码：wo mf | mk tm | qu | gs yr | sj bu。焦点在最后一块，带备选。
  static var tree: NovaContent {
    let us = "\u{1f}"
    let lines = [
      ["0", "0", "4", "womf", "我们"],
      ["0c", "4", "8", "mktm", "明天"],
      ["0u", "8", "10", "qu", "去"],
      ["1", "10", "14", "gsyr", "公园"],
      ["0f", "14", "18", "sjbu", "散步" + us + "71", "散布" + us + "20", "三步"]
    ]
    var content = NovaContent()
    content.blocks = NovaBlock.parse(tree: lines.map { $0.joined(separator: "\t") + "\n" }.joined())
    content.letters = "womfmktmqugsyrsjbu"
    content.cursor = 18
    return content
  }

  // 普通候选列表：底板、文字、次要文字。
  static var list: NovaContent {
    var content = NovaContent()
    content.preedit = "nihk"
    content.candidates = [
      NovaCandidate(label: "1", text: "你好", comment: ""),
      NovaCandidate(label: "2", text: "拟好", comment: ""),
      NovaCandidate(label: "3", text: "你", comment: "nǐ")
    ]
    return content
  }
}

// 用真正的面板代码画一个样子。
private struct NovaPreview: NSViewRepresentable {
  let theme: NovaTheme
  let content: NovaContent
  // theme 是引用类型，改了字段对象不变；靠这个数字让 SwiftUI 重画。
  let revision: Int

  func makeNSView(context: Context) -> NovaView { NovaView() }

  func updateNSView(_ view: NovaView, context: Context) {
    view.layoutResult = NovaLayout(content: content, style: NovaStyle(theme: theme), maxWidth: 520, upward: false)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NovaView, context: Context) -> CGSize? {
    nsView.layoutResult?.size
  }
}

private struct NovaPreviewCard: View {
  let theme: NovaTheme
  let revision: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      NovaPreview(theme: theme, content: NovaThemeSample.tree, revision: revision)
      NovaPreview(theme: theme, content: NovaThemeSample.list, revision: revision)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    // 面板浮在别的应用上面，背景按主题的深浅给一个接近的底色。
    .background(RoundedRectangle(cornerRadius: 8).fill(theme.dark ? Color(white: 0.18) : Color(white: 0.93)))
  }
}

// MARK: - 外观页

struct NovaAppearanceTab: View {
  @State private var entries = NovaThemes.list()
  @State private var selection = NovaThemes.selection
  @State private var lightID = NovaThemes.lightID
  @State private var darkID = NovaThemes.darkID
  @State private var revision = 0
  @State private var message = ""

  private var shownID: String {
    selection == NovaThemes.auto ? (NovaThemes.systemDark ? darkID : lightID) : selection
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("主题").frame(width: 60, alignment: .leading)
        Picker("", selection: $selection) {
          Text("跟随系统").tag(NovaThemes.auto)
          Divider()
          ForEach(entries, id: \.id) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .frame(width: 220)
        .onChange(of: selection) { NovaThemes.selection = $0; revision += 1 }
      }
      if selection == NovaThemes.auto {
        HStack {
          Text("浅色时").frame(width: 60, alignment: .leading)
          themePicker($lightID, dark: false).onChange(of: lightID) { NovaThemes.lightID = $0; revision += 1 }
          Text("深色时").padding(.leading, 12)
          themePicker($darkID, dark: true).onChange(of: darkID) { NovaThemes.darkID = $0; revision += 1 }
        }
      }

      NovaPreviewCard(theme: NovaThemes.theme(id: shownID), revision: revision)

      HStack {
        Button("编辑…") { edit(id: shownID) }
        Button("复制成新主题…") { duplicate(id: shownID) }
        if let entry = entries.first(where: { $0.id == shownID }), entry.user {
          Button(entry.overridesBuiltIn ? "恢复自带" : "删除") { remove(entry) }
        }
        Spacer()
        Button("导入…") { importTheme() }
        Button("导出…") { exportTheme(id: shownID) }
      }
      if !message.isEmpty {
        Text(message).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Text("主题包括颜色、字体、字号和形状。主题文件在设置文件夹的 nova_themes 里，也可以直接用编辑器改。")
        .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .onReceive(NotificationCenter.default.publisher(for: NovaThemes.changed)) { _ in refresh() }
  }

  private func themePicker(_ binding: Binding<String>, dark: Bool) -> some View {
    Picker("", selection: binding) {
      ForEach(entries.filter { $0.dark == dark }, id: \.id) { Text($0.name).tag($0.id) }
      let others = entries.filter { $0.dark != dark }
      if !others.isEmpty {
        Divider()
        ForEach(others, id: \.id) { Text($0.name).tag($0.id) }
      }
    }
    .labelsHidden()
    .frame(width: 150)
  }

  private func refresh() {
    entries = NovaThemes.list()
    selection = NovaThemes.selection
    lightID = NovaThemes.lightID
    darkID = NovaThemes.darkID
    revision += 1
  }

  private func edit(id: String) {
    NovaThemeEditorWindow.open(theme: NovaThemes.theme(id: id).copy(), id: id)
  }

  private func duplicate(id: String) {
    let theme = NovaThemes.theme(id: id).copy()
    theme["name"] = theme.name + " 副本"
    theme["author"] = ""
    NovaThemeEditorWindow.open(theme: theme, id: NovaThemes.freeID(base: "custom"))
  }

  private func remove(_ entry: NovaThemes.Entry) {
    let alert = NSAlert()
    alert.messageText = entry.overridesBuiltIn ? "把「\(entry.name)」恢复成自带的样子？" : "删除主题「\(entry.name)」？"
    alert.informativeText = "会删掉设置文件夹里的 nova_themes/\(entry.id).yaml。"
    alert.addButton(withTitle: entry.overridesBuiltIn ? "恢复" : "删除")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    NovaThemes.delete(id: entry.id)
  }

  private func importTheme() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText, UTType(filenameExtension: "yml") ?? .plainText]
    panel.message = "选一个 Nova 星语的主题文件（.yaml）"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let theme = NovaTheme.load(path: url.path) else {
      message = "读不了 \(url.lastPathComponent)。"
      return
    }
    let id = NovaThemes.freeID(base: url.deletingPathExtension().lastPathComponent)
    NovaThemes.save(theme, id: id)
    NovaThemes.selection = id
    let skipped = theme.parseProblems
    message = "已导入「\(theme.name)」并选用。" + (skipped.isEmpty ? "" : "跳过了 \(skipped.count) 行不认识的设置。")
    refresh()
  }

  private func exportTheme(id: String) {
    let theme = NovaThemes.theme(id: id)
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(id).yaml"
    panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    message = theme.save(path: url.path) ? "已导出到 \(url.path)。" : "导出失败。"
  }
}

// MARK: - 编辑器

final class NovaThemeEditorWindow: NSObject, NSWindowDelegate {
  private static var open = [NovaThemeEditorWindow]()
  private let window: NSWindow

  static func open(theme: NovaTheme, id: String) {
    let editor = NovaThemeEditorWindow(theme: theme, id: id)
    open.append(editor)
    NSApp.activate(ignoringOtherApps: true)
    editor.window.makeKeyAndOrderFront(nil)
  }

  private init(theme: NovaTheme, id: String) {
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.title = "编辑主题"
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.delegate = self
    window.contentView = NSHostingView(rootView: NovaThemeEditor(model: NovaThemeModel(theme: theme, id: id)) { [weak self] in
      self?.window.close()
    })
    window.center()
  }

  func windowWillClose(_ notification: Notification) {
    Self.open.removeAll { $0 === self }
  }
}

final class NovaThemeModel: ObservableObject {
  let theme: NovaTheme
  let id: String
  @Published var revision = 0
  @Published var problems: [String]

  init(theme: NovaTheme, id: String) {
    self.theme = theme
    self.id = id
    problems = theme.problems
  }

  func value(_ key: String) -> String { theme[key] }

  func set(_ key: String, _ value: String) {
    guard theme[key] != value else { return }
    theme[key] = value
    problems = theme.problems
    revision += 1
  }
}

private struct NovaThemeEditor: View {
  @ObservedObject var model: NovaThemeModel
  let close: () -> Void
  @State private var saved = false

  private let groups: [(String, [NovaUIThemeField])] = {
    var order = [String]()
    var map = [String: [NovaUIThemeField]]()
    for field in NovaTheme.fields {
      let group = String(cString: field.group)
      if map[group] == nil { order.append(group) }
      map[group, default: []].append(field)
    }
    return order.map { ($0, map[$0]!) }
  }()

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ForEach(groups, id: \.0) { group in
            VStack(alignment: .leading, spacing: 8) {
              Text(group.0).font(.headline)
              ForEach(group.1, id: \.key) { field in
                NovaThemeFieldRow(model: model, field: field)
              }
            }
          }
        }
        .padding(16)
      }
      .frame(width: 420)
      Divider()
      VStack(alignment: .leading, spacing: 12) {
        Text("预览").font(.headline)
        NovaPreviewCard(theme: model.theme, revision: model.revision)
        if model.problems.isEmpty {
          Label("颜色都看得清。", systemImage: "checkmark.circle").foregroundColor(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(model.problems, id: \.self) { problem in
              Label(problem, systemImage: "exclamationmark.triangle").foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        Text("存在设置文件夹的 nova_themes/\(model.id).yaml。").font(.callout).foregroundColor(.secondary)
        Spacer()
        HStack {
          Spacer()
          Button("取消") { close() }.keyboardShortcut(.cancelAction)
          Button("存储并使用") { save() }.keyboardShortcut(.defaultAction)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 860, minHeight: 600)
  }

  private func save() {
    guard NovaThemes.save(model.theme, id: model.id) else {
      let alert = NSAlert()
      alert.messageText = "存不了主题文件"
      alert.informativeText = NovaThemes.userPath(id: model.id)
      alert.runModal()
      return
    }
    // 跟随系统时，存到和主题深浅对应的那一边；否则直接选用它。
    if NovaThemes.selection == NovaThemes.auto {
      if model.theme.dark { NovaThemes.darkID = model.id } else { NovaThemes.lightID = model.id }
    } else {
      NovaThemes.selection = model.id
    }
    close()
  }
}

private struct NovaThemeFieldRow: View {
  @ObservedObject var model: NovaThemeModel
  let field: NovaUIThemeField

  private var key: String { String(cString: field.key) }
  private var label: String { String(cString: field.label) }
  private var note: String { String(cString: field.note) }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label).frame(width: 96, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        control
        if !note.isEmpty {
          Text(note).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @ViewBuilder private var control: some View {
    switch field.kind {
    case NOVA_THEME_NUMBER:
      HStack {
        Slider(value: Binding(get: { Double(model.value(key)) ?? field.min },
                              set: { model.set(key, Self.format(($0 / field.step).rounded() * field.step)) }),
               in: field.min...field.max)
        Text(model.value(key)).monospacedDigit().frame(width: 40, alignment: .trailing)
      }
    case NOVA_THEME_CHOICE:
      Picker("", selection: Binding(get: { model.value(key) }, set: { model.set(key, $0) })) {
        ForEach(String(cString: field.choices).split(separator: ",").map(String.init), id: \.self) { choice in
          Text(Self.choiceName(choice)).tag(choice)
        }
      }
      .pickerStyle(.segmented).labelsHidden().frame(width: 160)
    case NOVA_THEME_COLOR:
      HStack {
        ColorPicker("", selection: Binding(get: { Self.color(model.value(key)) }, set: { model.set(key, Self.hex($0)) }),
                    supportsOpacity: false)
          .labelsHidden()
        Text(model.value(key)).font(.system(.body, design: .monospaced)).foregroundColor(.secondary)
      }
    default:
      HStack {
        TextField("", text: Binding(get: { model.value(key) }, set: { model.set(key, $0) }))
        if key.hasPrefix("font/") {
          Menu("选…") {
            Button("系统字体") { model.set(key, "") }
            Divider()
            ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { family in
              Button(family) { model.set(key, family) }
            }
          }
          .fixedSize()
        }
      }
    }
  }

  private static func choiceName(_ choice: String) -> String {
    switch choice {
    case "dark": "深色"
    case "light": "浅色"
    default: choice
    }
  }

  private static func format(_ value: Double) -> String {
    String(format: "%g", (value * 100).rounded() / 100)
  }

  private static func color(_ hex: String) -> Color {
    var value: UInt64 = 0
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard Scanner(string: digits).scanHexInt64(&value), digits.count == 6 || digits.count == 8 else { return .black }
    let rgba = digits.count == 8 ? value : (value << 8) | 0xff
    return Color(.sRGB, red: Double((rgba >> 24) & 0xff) / 255, green: Double((rgba >> 16) & 0xff) / 255,
                 blue: Double((rgba >> 8) & 0xff) / 255, opacity: Double(rgba & 0xff) / 255)
  }

  private static func hex(_ color: Color) -> String {
    guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return "#000000" }
    func byte(_ value: CGFloat) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
  }
}
