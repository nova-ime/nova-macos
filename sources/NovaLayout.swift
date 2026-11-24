//
//  NovaLayout.swift
//  Nova Squirrel
//
//  候选面板的数据和几何。这里只算要画什么、画在哪，不碰窗口。
//  平台无关的部分（nova_tree 解析、内容组装、排版）在 nova-ui/（C++，C API 见 nova_ui.h），
//  这个文件只是 macOS 的薄封装：提供测宽回调，按主题（NovaTheme）把颜色语义换成颜色，把显示列表转成 NovaView 能画的结构。
//

import AppKit

struct NovaChoice: Equatable {
  let text: String
  // 在同一段候选里占的词频比例（0-100），不是真实概率。词库里没有时为空。
  let share: Int?

  init(text: String, share: Int?) {
    self.text = text
    self.share = share
  }

  init(_ choice: NovaUIChoice) {
    text = choice.text.map { String(cString: $0) } ?? ""
    share = choice.has_share != 0 ? Int(choice.share) : nil
  }
}

struct NovaBlock: Equatable {
  // 这块在原始字母里的范围（字节偏移，原始字母都是 ASCII，也就是第几个字母）。
  let from: Int
  let to: Int
  let pinned: Bool
  let focused: Bool
  let corrected: Bool
  // 换几个上下文窗口解码，这块的结果不一样：解码器拿不准，标橙。
  let uncertain: Bool
  // 没有焦点时直接显示备选的不确定块。
  let overview: Bool
  let word: NovaChoice
  let alternatives: [NovaChoice]
  // 焦点块的备选分页时的「第几页/共几页」，不分页时为空。
  let page: String
  // ↓/↑ 换词时当前用的是这一页的第几个备选（从 1 起），没有时为空。
  let current: Int?
  // 原样的标记字段，只给界面日志用。
  let flags: String

  init(_ block: NovaUIBlock) {
    from = Int(block.from)
    to = Int(block.to)
    pinned = block.pinned != 0
    focused = block.focused != 0
    corrected = block.corrected != 0
    uncertain = block.uncertain != 0
    overview = block.overview != 0
    word = NovaChoice(block.word)
    alternatives = (0..<Int(block.alt_count)).map { NovaChoice(block.alts[$0]) }
    page = block.page.map { String(cString: $0) } ?? ""
    current = block.has_current != 0 ? Int(block.current) : nil
    flags = block.flags.map { String(cString: $0) } ?? ""
  }

  // nova_tree 属性：每块一行，格式见 nova_sentences.lua。解析在 nova-ui。
  static func parse(tree: String) -> [NovaBlock] {
    guard let parsed = nova_ui_tree_parse(tree) else { return [] }
    defer { nova_ui_tree_free(parsed) }
    var count: Int32 = 0
    guard let blocks = nova_ui_tree_blocks(parsed, &count) else { return [] }
    return (0..<Int(count)).map { NovaBlock(blocks[$0]) }
  }

  // 颜色的名字，界面日志（NovaUILog）记这个。
  var tone: String {
    if pinned {
      return "green"
    }
    if corrected {
      return "purple"
    }
    return uncertain ? "orange" : "blue"
  }
}

struct NovaCandidate {
  let label: String
  let text: String
  let comment: String
}

struct NovaContent {
  var preedit = ""
  // 无效范围表示整行都是正文（状态消息），有效范围表示其余部分是已转换或未选中的输入。
  var selRange = NSRange.empty
  var blocks = [NovaBlock]()
  // 原始字母和光标位置（第几个字母之前）。空表示不显示字母行。
  var letters = ""
  var cursor = 0
  // 全拼时 letters 是拼音，而光标和词块范围是双拼编码里的位置：letterMap[编码位置] = 拼音位置。
  // 空表示 letters 就是编码。
  var letterMap = [Int]()
  var candidates = [NovaCandidate]()
  var highlighted = 0

  init() {}

  // 从 nova-ui 组装好的内容复制出来。
  init(_ view: NovaUIContent) {
    preedit = view.preedit.map { String(cString: $0) } ?? ""
    selRange = view.sel_location >= 0 ? NSRange(location: Int(view.sel_location), length: Int(view.sel_length)) : .empty
    blocks = (0..<Int(view.block_count)).map { NovaBlock(view.blocks[$0]) }
    letters = view.letters.map { String(cString: $0) } ?? ""
    cursor = Int(view.cursor)
    letterMap = (0..<Int(view.letter_map_count)).map { Int(view.letter_map[$0]) }
    candidates = (0..<Int(view.candidate_count)).map {
      let candidate = view.candidates[$0]
      return NovaCandidate(label: candidate.label.map { String(cString: $0) } ?? "",
                           text: candidate.text.map { String(cString: $0) } ?? "",
                           comment: candidate.comment.map { String(cString: $0) } ?? "")
    }
    highlighted = Int(view.highlighted)
  }
}

struct NovaStyle {
  // 颜色、字体、字号、形状都来自主题。
  var theme = NovaTheme() {
    didSet { updateFonts() }
  }
  var linear = false
  // 是否在词和备选下面显示词频比例，对应 style/show_share。
  var showShare = false

  private(set) var font = NSFont.systemFont(ofSize: 15)
  private(set) var labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
  private(set) var shareFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
  private(set) var letterFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

  init(theme: NovaTheme = NovaTheme()) {
    self.theme = theme
    updateFonts()
  }

  private mutating func updateFonts() {
    let size = CGFloat(Double(theme["font/size"]) ?? 15)
    font = NovaThemes.font(faces: theme["font/face"], size: size, fallback: .systemFont(ofSize: size))
    let mono = theme["font/mono"]
    func monoFont(_ scale: CGFloat, _ fallback: NSFont) -> NSFont {
      NovaThemes.font(faces: mono, size: round(size * scale), fallback: fallback)
    }
    labelFont = monoFont(0.68, .monospacedDigitSystemFont(ofSize: round(size * 0.68), weight: .medium))
    shareFont = monoFont(0.62, .monospacedDigitSystemFont(ofSize: round(size * 0.62), weight: .regular))
    letterFont = monoFont(0.9, .monospacedSystemFont(ofSize: round(size * 0.9), weight: .regular))
  }

  var cStyle: NovaUIStyle {
    var style = NovaUIStyle()
    style.linear = linear ? 1 : 0
    style.show_share = showShare ? 1 : 0
    theme.fill(&style)
    return style
  }

  func color(_ token: NovaUIColor) -> NSColor { theme.color(token) }

  fileprivate func roleFont(_ role: NovaUIFont) -> NSFont {
    switch role {
    case NOVA_FONT_LABEL: labelFont
    case NOVA_FONT_SHARE: shareFont
    case NOVA_FONT_LETTER: letterFont
    default: font
    }
  }
}

enum NovaAction: Equatable {
  case select(Int)
  // 第几个备选（从 1 起），和数字键同一个编号。
  case pin(Int)
  case focus(Int)
  // 把原始字母光标移到第几个字母之前。
  case cursor(Int)
}

// 测宽回调要带的上下文：每个字体角色对应的字体。
private final class NovaMeasurer {
  let style: NovaStyle
  init(style: NovaStyle) { self.style = style }
}

private func novaMeasure(_ text: UnsafePointer<CChar>?, _ role: NovaUIFont, _ user: UnsafeMutableRawPointer?) -> Double {
  guard let text, let user else { return 0 }
  let measurer = Unmanaged<NovaMeasurer>.fromOpaque(user).takeUnretainedValue()
  let string = NSAttributedString(string: String(cString: text), attributes: [.font: measurer.style.roleFont(role)])
  return Double(string.size().width)
}

// 把 NovaContent 摊成 nova-ui 的 C 结构；字符串和数组都由这个对象持有，用完一起释放。
private final class NovaCContent {
  private var strings = [UnsafeMutablePointer<CChar>]()
  private var blocks = [NovaUIBlock]()
  private var choices = [UnsafeMutablePointer<NovaUIChoice>]()
  private var candidates = [NovaUICandidate]()
  private var map = [Int32]()
  private(set) var content = NovaUIContent()

  private func cString(_ string: String) -> UnsafePointer<CChar> {
    let pointer = strdup(string)!
    strings.append(pointer)
    return UnsafePointer(pointer)
  }

  private func choice(_ choice: NovaChoice) -> NovaUIChoice {
    NovaUIChoice(text: cString(choice.text), has_share: choice.share == nil ? 0 : 1, share: Int32(choice.share ?? 0))
  }

  init(_ source: NovaContent) {
    blocks = source.blocks.map { block in
      let alternatives = UnsafeMutablePointer<NovaUIChoice>.allocate(capacity: max(block.alternatives.count, 1))
      for (index, alternative) in block.alternatives.enumerated() {
        (alternatives + index).initialize(to: choice(alternative))
      }
      choices.append(alternatives)
      return NovaUIBlock(from: Int32(block.from), to: Int32(block.to), pinned: block.pinned ? 1 : 0, focused: block.focused ? 1 : 0,
                         corrected: block.corrected ? 1 : 0, uncertain: block.uncertain ? 1 : 0, overview: block.overview ? 1 : 0,
                         word: choice(block.word), alts: UnsafePointer(alternatives), alt_count: Int32(block.alternatives.count),
                         page: cString(block.page), has_current: block.current == nil ? 0 : 1, current: Int32(block.current ?? 0),
                         flags: cString(block.flags))
    }
    candidates = source.candidates.map { NovaUICandidate(label: cString($0.label), text: cString($0.text), comment: cString($0.comment)) }
    map = source.letterMap.map { Int32($0) }
    content.preedit = cString(source.preedit)
    let valid = source.selRange.location != NSNotFound
    content.sel_location = valid ? Int32(source.selRange.location) : -1
    content.sel_length = Int32(source.selRange.length)
    content.letters = cString(source.letters)
    content.cursor = Int32(source.cursor)
    content.highlighted = Int32(source.highlighted)
  }

  // 数组指针要等所有元素都放好再取。
  func withContent<T>(_ body: (UnsafePointer<NovaUIContent>) -> T) -> T {
    blocks.withUnsafeBufferPointer { blockBuffer in
      candidates.withUnsafeBufferPointer { candidateBuffer in
        map.withUnsafeBufferPointer { mapBuffer in
          content.blocks = blockBuffer.baseAddress
          content.block_count = Int32(blockBuffer.count)
          content.candidates = candidateBuffer.baseAddress
          content.candidate_count = Int32(candidateBuffer.count)
          content.letter_map = mapBuffer.baseAddress
          content.letter_map_count = Int32(mapBuffer.count)
          return withUnsafePointer(to: &content, body)
        }
      }
    }
  }

  deinit {
    strings.forEach { free($0) }
    choices.forEach { $0.deallocate() }
  }
}

struct NovaLayout {
  struct Box {
    let rect: NSRect
    let radius: CGFloat
    let color: NSColor
    // 备选格要知道自己是备选格，鼠标悬停时换成 alt_hover。
    let token: NovaUIColor
  }
  struct Run {
    let string: NSAttributedString
    let x: CGFloat
    let baseline: CGFloat
  }
  struct Hit {
    let rect: NSRect
    let action: NovaAction
  }

  // 底板、分支线、悬停的颜色和底板圆角，画的时候用。
  let style: NovaStyle

  private(set) var size = NSSize.zero
  // 只有普通列表和状态消息有底色；树直接浮在文字下方，没有边缘可以跳动。
  private(set) var card = false
  private(set) var links = [Box]()
  private(set) var boxes = [Box]()
  private(set) var runs = [Run]()
  private(set) var hits = [Hit]()
  let branches = NSBezierPath()

  // 放在光标上方时，词块贴着光标，备选往上长。
  init(content: NovaContent, style: NovaStyle, maxWidth: CGFloat, upward: Bool) {
    self.style = style
    let source = NovaCContent(content)
    var cStyle = style.cStyle
    let measurer = NovaMeasurer(style: style)
    let layout = source.withContent { pointer in
      nova_ui_layout_create(pointer, &cStyle, novaMeasure, Unmanaged.passUnretained(measurer).toOpaque(), Double(maxWidth), upward ? 1 : 0)
    }
    guard let layout, let view = nova_ui_layout_view(layout)?.pointee else { return }
    defer { nova_ui_layout_free(layout) }
    size = NSSize(width: view.width, height: view.height)
    card = view.card != 0
    func rect(_ rect: NovaUIRect) -> NSRect { NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
    func box(_ box: NovaUIBox) -> Box { Box(rect: rect(box.rect), radius: box.radius, color: style.color(box.color), token: box.color) }
    links = (0..<Int(view.link_count)).map { box(view.links[$0]) }
    boxes = (0..<Int(view.box_count)).map { box(view.boxes[$0]) }
    for index in 0..<Int(view.path_count) {
      let segment = view.path[index]
      switch segment.kind {
      case NOVA_PATH_MOVE:
        branches.move(to: NSPoint(x: segment.x, y: segment.y))
      case NOVA_PATH_LINE:
        branches.line(to: NSPoint(x: segment.x, y: segment.y))
      default:
        branches.curve(to: NSPoint(x: segment.x, y: segment.y), controlPoint1: NSPoint(x: segment.c1x, y: segment.c1y),
                       controlPoint2: NSPoint(x: segment.c2x, y: segment.c2y))
      }
    }
    runs = (0..<Int(view.run_count)).map { index in
      let run = view.runs[index]
      let text = NSMutableAttributedString(string: String(cString: run.text),
                                           attributes: [.font: style.roleFont(run.font), .foregroundColor: style.color(run.color)])
      if run.hl_start >= 0 {
        text.addAttribute(.foregroundColor, value: style.color(run.hl_color), range: NSRange(location: Int(run.hl_start), length: Int(run.hl_end - run.hl_start)))
      }
      return Run(string: text, x: run.x, baseline: run.baseline)
    }
    hits = (0..<Int(view.hit_count)).map { index in
      let hit = view.hits[index]
      let action: NovaAction = switch hit.action {
      case NOVA_ACTION_SELECT: .select(Int(hit.value))
      case NOVA_ACTION_PIN: .pin(Int(hit.value))
      case NOVA_ACTION_FOCUS: .focus(Int(hit.value))
      default: .cursor(Int(hit.value))
      }
      return Hit(rect: rect(hit.rect), action: action)
    }
  }

  // 词块加满备选的高度，用来判断光标下方放不放得下。
  static func fullHeight(style: NovaStyle) -> CGFloat {
    var cStyle = style.cStyle
    return CGFloat(nova_ui_full_height(&cStyle))
  }

  static func edge(style: NovaStyle) -> CGFloat {
    var cStyle = style.cStyle
    return CGFloat(nova_ui_style_edge(&cStyle))
  }

  var cornerRadius: CGFloat {
    var cStyle = style.cStyle
    return CGFloat(nova_ui_style_corner_radius(&cStyle))
  }
}

// 界面日志：<用户目录>/nova_lm/debug.on 存在时，每次画面板记一行到 nova_lm/ui.log：
// `时间\t原始字母\t首选\t每块「文字=颜色/标记>第一备选」`，焦点块的颜色记成 focus，没有词块时记 list。
// 和 nova_lm 插件的 debug.log 对照，就能分清是插件没标还是面板没画；自动测试也读它。会记下打的所有字。
enum NovaUILog {
  static let dir = SquirrelApp.userDir.appending(component: "nova_lm", directoryHint: .isDirectory)
  static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
    return formatter
  }()

  static func record(letters: String, first: String, blocks: [NovaBlock]) {
    guard FileManager.default.fileExists(atPath: dir.appending(component: "debug.on").path) else { return }
    let parts = blocks.isEmpty ? ["list"] : blocks.map { block in
      "\(block.word.text)=\(block.focused ? "focus" : block.tone)/\(block.flags)" + (block.alternatives.first.map { ">" + $0.text } ?? "")
    }
    let line = ([formatter.string(from: Date()), letters, first] + parts).joined(separator: "\t") + "\n"
    let url = dir.appending(component: "ui.log")
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: url)
    }
  }
}
