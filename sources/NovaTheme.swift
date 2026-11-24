//
//  NovaTheme.swift
//  Nova Squirrel
//
//  候选面板的主题：颜色、字体、字号、形状一整套，存成 .yaml。读写和对比度检查在 nova-ui（theme.cc），
//  和 Windows 用同一份格式，一个主题文件两边通用。
//
//  自带的主题在 SharedSupport/nova_themes，用户的在 <用户目录>/nova_themes，同名时用户的优先。
//  选哪套记在 UserDefaults：NovaTheme 是主题编号，或者 "auto"（跟随系统：浅色用 NovaThemeLight，深色用 NovaThemeDark）。
//

import AppKit

// 一套主题。包着 nova-ui 的 NovaUITheme，改了之后要重新取颜色。
final class NovaTheme {
  let pointer: OpaquePointer

  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  convenience init() { self.init(nova_ui_theme_new()) }
  deinit { nova_ui_theme_free(pointer) }

  static func load(path: String) -> NovaTheme? { nova_ui_theme_load(path).map(NovaTheme.init) }
  static func parse(_ yaml: String) -> NovaTheme? { nova_ui_theme_parse(yaml).map(NovaTheme.init) }

  func copy() -> NovaTheme { NovaTheme(nova_ui_theme_copy(pointer)) }

  subscript(key: String) -> String {
    get { nova_ui_theme_get(pointer, key).map { String(cString: $0) } ?? "" }
    set { _ = nova_ui_theme_set(pointer, key, newValue) }
  }

  var name: String { self["name"] }
  var dark: Bool { self["appearance"] != "light" }

  func color(_ token: NovaUIColor) -> NSColor {
    var rgba = (0.0, 0.0, 0.0, 0.0)
    withUnsafeMutablePointer(to: &rgba) {
      $0.withMemoryRebound(to: Double.self, capacity: 4) { nova_ui_theme_color(pointer, token, $0) }
    }
    return NSColor(srgbRed: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3)
  }

  // 按主题填好字号和形状；linear、show_share 由调用方给。
  func fill(_ style: inout NovaUIStyle) { nova_ui_theme_style(pointer, &style) }

  var yaml: String { String(cString: nova_ui_theme_dump(pointer)) }
  func save(path: String) -> Bool { nova_ui_theme_save(pointer, path) != 0 }

  // 看不清的地方，一行一条。
  var problems: [String] { String(cString: nova_ui_theme_check(pointer)).split(separator: "\n").map(String.init) }
  // 读文件时跳过的行。
  var parseProblems: [String] { String(cString: nova_ui_theme_problems(pointer)).split(separator: "\n").map(String.init) }

  static var fields: [NovaUIThemeField] {
    var count: Int32 = 0
    guard let fields = nova_ui_theme_fields(&count) else { return [] }
    return (0..<Int(count)).map { fields[$0] }
  }
}

enum NovaThemes {
  static let changed = Notification.Name("NovaThemeChanged")
  static let auto = "auto"
  static let sharedDir = SquirrelApp.appDir.appending(components: "Contents", "SharedSupport", "nova_themes", directoryHint: .isDirectory)
  static let userDir = SquirrelApp.userDir.appending(component: "nova_themes", directoryHint: .isDirectory)

  struct Entry: Hashable {
    let id: String
    let name: String
    let path: String
    let dark: Bool
    let user: Bool
    // 用户目录里有、app 里也有同名的：删掉就回到自带的那一份。
    let overridesBuiltIn: Bool
  }

  private static let selectionKey = "NovaTheme"
  private static let lightKey = "NovaThemeLight"
  private static let darkKey = "NovaThemeDark"

  static var selection: String {
    get { UserDefaults.standard.string(forKey: selectionKey) ?? auto }
    set { UserDefaults.standard.set(newValue, forKey: selectionKey); reload() }
  }
  static var lightID: String {
    get { UserDefaults.standard.string(forKey: lightKey) ?? "light" }
    set { UserDefaults.standard.set(newValue, forKey: lightKey); reload() }
  }
  static var darkID: String {
    get { UserDefaults.standard.string(forKey: darkKey) ?? "dark" }
    set { UserDefaults.standard.set(newValue, forKey: darkKey); reload() }
  }

  static func list() -> [Entry] {
    let builtIn = Set(scan(sharedDir.path, nil).map(\.id))
    return scan(sharedDir.path, userDir.path).map {
      Entry(id: $0.id, name: $0.name, path: $0.path, dark: $0.dark, user: $0.user, overridesBuiltIn: $0.user && builtIn.contains($0.id))
    }
  }

  private static func scan(_ shared: String, _ user: String?) -> [(id: String, name: String, path: String, dark: Bool, user: Bool)] {
    guard let list = nova_ui_theme_list(shared, user) else { return [] }
    defer { nova_ui_theme_list_free(list) }
    var count: Int32 = 0
    guard let entries = nova_ui_theme_list_entries(list, &count) else { return [] }
    return (0..<Int(count)).map { index in
      let entry = entries[index]
      let name = String(cString: entry.name)
      let id = String(cString: entry.id)
      return (id, name.isEmpty ? id : name, String(cString: entry.path), String(cString: entry.appearance) != "light", entry.user != 0)
    }
  }

  static func path(of id: String) -> String? { list().first { $0.id == id }?.path }

  // 已经读进来的主题，按编号。改了选择或者存了主题就清掉。
  private static var cache = [String: NovaTheme]()

  static func theme(id: String) -> NovaTheme {
    if let theme = cache[id] { return theme }
    let theme = path(of: id).flatMap { NovaTheme.load(path: $0) } ?? NovaTheme()
    cache[id] = theme
    return theme
  }

  // 现在该用哪套：跟随系统时看系统是深色还是浅色。
  static func current(dark: Bool) -> NovaTheme {
    let id = selection == auto ? (dark ? darkID : lightID) : selection
    return theme(id: id)
  }

  static var systemDark: Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }

  static func reload() {
    cache.removeAll()
    NotificationCenter.default.post(name: changed, object: nil)
  }

  // 用户目录里不和已有主题重名的编号。
  static func freeID(base: String) -> String {
    let taken = Set(list().map(\.id))
    var id = base
    var index = 2
    while taken.contains(id) {
      id = "\(base)-\(index)"
      index += 1
    }
    return id
  }

  static func userPath(id: String) -> String {
    try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
    return userDir.appending(component: "\(id).yaml").path
  }

  // 存进用户目录。成功后清缓存，面板下次显示就用新的。
  @discardableResult
  static func save(_ theme: NovaTheme, id: String) -> Bool {
    let ok = theme.save(path: userPath(id: id))
    reload()
    return ok
  }

  static func delete(id: String) {
    try? FileManager.default.removeItem(atPath: userDir.appending(component: "\(id).yaml").path)
    if selection == id { selection = auto }
    if lightID == id { lightID = "light" }
    if darkID == id { darkID = "dark" }
    reload()
  }

  // 主题里的字体：可写多个，逗号分隔，前面的优先。找不到的跳过，都找不到就用 fallback。
  static func font(faces: String, size: CGFloat, fallback: NSFont) -> NSFont {
    let fonts = faces.split(separator: ",").compactMap { face -> NSFont? in
      let name = face.trimmingCharacters(in: .whitespaces)
      return NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) ?? NSFont(name: name, size: size)
    }
    guard let first = fonts.first else { return fallback }
    let descriptor = first.fontDescriptor.addingAttributes([.cascadeList: fonts.dropFirst().map(\.fontDescriptor)])
    return NSFont(descriptor: descriptor, size: size) ?? first
  }
}
