//
//  NovaLayout.swift
//  Nova Squirrel
//
//  候选面板的数据和几何。这里只算要画什么、画在哪，不碰窗口。
//

import AppKit

struct NovaChoice: Equatable {
  let text: String
  // 在同一段候选里占的词频比例（0-100），不是真实概率。词库里没有时为空。
  let share: Int?

  init(field: String) {
    let parts = field.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
    text = parts.first ?? ""
    share = parts.count > 1 ? Int(parts[1]) : nil
  }
}

struct NovaBlock: Equatable {
  let pinned: Bool
  let focused: Bool
  let corrected: Bool
  // 没有焦点时直接显示备选的不确定块。
  let overview: Bool
  let word: NovaChoice
  let alternatives: [NovaChoice]

  // nova_tree 属性：每块一行，格式见 nova_sentences.lua。
  static func parse(tree: String) -> [NovaBlock] {
    tree.split(separator: "\n").map { line in
      let fields = line.split(separator: "\t").map(String.init)
      let flags = fields.first ?? ""
      return NovaBlock(pinned: flags.hasPrefix("1"), focused: flags.contains("f"), corrected: flags.contains("c"), overview: flags.contains("o"),
                       word: NovaChoice(field: fields.count > 4 ? fields[4] : ""),
                       alternatives: fields.dropFirst(5).map(NovaChoice.init(field:)))
    }
  }

  // 比例低于这个值就算没把握，和 nova_sentences.lua 的 CONFIDENT_SHARE 一致。
  private static let confidentShare = 80

  var color: NSColor {
    if pinned {
      return NovaPalette.green
    }
    if corrected {
      return NovaPalette.purple
    }
    guard let share = word.share else { return NovaPalette.blue }
    return share >= Self.confidentShare ? NovaPalette.blue : NovaPalette.orange
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
  var candidates = [NovaCandidate]()
  var highlighted = 0
}

struct NovaStyle {
  var font = NSFont.systemFont(ofSize: 15)
  var linear = false
  // 是否在词和备选下面显示词频比例，对应 style/show_share。
  var showShare = false

  var labelFont: NSFont { .monospacedDigitSystemFont(ofSize: round(font.pointSize * 0.68), weight: .medium) }
  var shareFont: NSFont { .monospacedDigitSystemFont(ofSize: round(font.pointSize * 0.62), weight: .regular) }
}

enum NovaAction: Equatable {
  case select(Int)
  // 第几个备选（从 1 起），和数字键同一个编号。
  case pin(Int)
  case focus(Int)
}

// 全部是实色，没有透明度和描边。
enum NovaPalette {
  static let blue = NSColor(srgbRed: 0x2f / 255, green: 0x6f / 255, blue: 0xde / 255, alpha: 1)
  static let orange = NSColor(srgbRed: 0xd2 / 255, green: 0x66 / 255, blue: 0x24 / 255, alpha: 1)
  static let purple = NSColor(srgbRed: 0x7b / 255, green: 0x48 / 255, blue: 0xd8 / 255, alpha: 1)
  static let green = NSColor(srgbRed: 0x1f / 255, green: 0x9d / 255, blue: 0x6b / 255, alpha: 1)
  // 焦点块要在深浅窗口上都醒目，白色和黑色都不行。
  static let focus = NSColor(srgbRed: 0xf5 / 255, green: 0xc5 / 255, blue: 0x18 / 255, alpha: 1)
  static let altFill = NSColor(white: 0.16, alpha: 1)
  static let altHover = NSColor(white: 0.28, alpha: 1)
  static let card = NSColor(white: 0.13, alpha: 1)
  static let branch = NSColor(white: 0.55, alpha: 1)
  static let primary = NSColor.white
  static let dim = NSColor(white: 0.62, alpha: 1)
  static let share = NSColor(white: 0.5, alpha: 1)
}

struct NovaLayout {
  struct Box {
    let rect: NSRect
    let radius: CGFloat
    let color: NSColor
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

  static let cornerRadius: CGFloat = 10
  static let edge: CGFloat = 10
  private static let chipRadius: CGFloat = 6
  private static let chipPadding: CGFloat = 8
  private static let columnGap: CGFloat = 12
  private static let linkHeight: CGFloat = 3
  private static let branchIndent: CGFloat = 6
  private static let altIndent: CGFloat = 16
  private static let altPadding: CGFloat = 6
  private static let altGap: CGFloat = 8
  private static let busGap: CGFloat = 5
  private static let spineOffset: CGFloat = 10
  private static let branchRadius: CGFloat = 4
  private static let labelGap: CGFloat = 4
  private static let rowPadding: CGFloat = 6
  private static let shareRow: CGFloat = 13
  private static let altSpacing: CGFloat = 3
  private static let maxAlts: CGFloat = 6

  private(set) var size = NSSize.zero
  // 只有普通列表和状态消息有底色；树直接浮在文字下方，没有边缘可以跳动。
  private(set) var card = false
  private(set) var links = [Box]()
  private(set) var boxes = [Box]()
  private(set) var runs = [Run]()
  private(set) var hits = [Hit]()
  let branches = NSBezierPath()

  private let style: NovaStyle
  // 放在光标上方时，词块贴着光标，备选往上长。
  private let upward: Bool
  private var bottom = NovaLayout.edge
  private var right: CGFloat = 0

  init(content: NovaContent, style: NovaStyle, maxWidth: CGFloat, upward: Bool) {
    self.style = style
    self.upward = upward
    card = content.blocks.isEmpty
    addPreedit(content)
    if content.blocks.isEmpty {
      addCandidates(content, maxWidth: maxWidth)
    } else {
      addTree(content.blocks, maxWidth: maxWidth)
    }
    size = NSSize(width: ceil(right) + Self.edge, height: ceil(bottom) + Self.edge)
  }

  // 词块加满备选的高度，用来判断光标下方放不放得下。
  static func fullHeight(style: NovaStyle) -> CGFloat {
    let probe = NovaLayout(content: NovaContent(), style: style, maxWidth: 0, upward: false)
    return edge * 2 + probe.chipHeight + probe.shareHeight + busGap + maxAlts * probe.altRowHeight
  }
}

private extension NovaLayout {
  struct AltCell {
    let label: NSAttributedString
    let text: NSAttributedString
    let share: NSAttributedString?
    let width: CGFloat
  }
  struct Column {
    let index: Int
    let block: NovaBlock
    let chip: NSAttributedString
    let chipWidth: CGFloat
    let share: NSAttributedString?
    let cells: [AltCell]
    let firstLabel: Int
  }
  // 一排词块的竖向坐标。d 是离词块顶边的距离；往上长时整排上下翻转。
  struct Tier {
    let top: CGFloat
    let height: CGFloat
    let upward: Bool

    func y(_ distance: CGFloat) -> CGFloat {
      upward ? top + height - distance : top + distance
    }
    func rect(x: CGFloat, distance: CGFloat, width: CGFloat, height rowHeight: CGFloat) -> NSRect {
      NSRect(x: x, y: upward ? y(distance) - rowHeight : y(distance), width: width, height: rowHeight)
    }
  }

  var rowHeight: CGFloat { ceil(style.font.pointSize * 1.5) }
  var chipHeight: CGFloat { ceil(style.font.pointSize * 1.6) }
  var altHeight: CGFloat { ceil(style.font.pointSize * 1.5) }
  var shareHeight: CGFloat { style.showShare ? Self.shareRow : 0 }
  var altRowHeight: CGFloat { altHeight + (style.showShare ? Self.shareRow : Self.altSpacing) }

  func string(_ text: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
  }

  // 汉字的字面中心约在基线上方 0.38 em，让它落在行的正中。
  func baseline(of rect: NSRect, font: NSFont) -> CGFloat {
    rect.midY + font.pointSize * 0.38
  }

  mutating func addPreedit(_ content: NovaContent) {
    guard !content.preedit.isEmpty else { return }
    let length = content.preedit.utf16.count
    let selected = content.selRange.location != NSNotFound && NSMaxRange(content.selRange) <= length ? content.selRange : nil
    let text = NSMutableAttributedString(attributedString: string(content.preedit, style.font, selected == nil ? NovaPalette.primary : NovaPalette.dim))
    if let selected {
      text.addAttribute(.foregroundColor, value: NovaPalette.primary, range: selected)
    }
    let rect = NSRect(x: Self.edge, y: bottom, width: 0, height: rowHeight)
    runs.append(Run(string: text, x: Self.edge, baseline: baseline(of: rect, font: style.font)))
    right = max(right, Self.edge + text.size().width)
    bottom += rowHeight
    if !content.blocks.isEmpty || !content.candidates.isEmpty {
      bottom += 6
    }
  }

  // 词块只按自身宽度排在一条连线上，放不下时另起一排。
  mutating func addTree(_ blocks: [NovaBlock], maxWidth: CGFloat) {
    let limit = maxWidth - Self.edge * 2
    var tiers = [[Column]]()
    var tierWidth: CGFloat = 0
    let hasFocus = blocks.contains(where: \.focused)
    var label = 1
    for (index, block) in blocks.enumerated() {
      let shows = hasFocus ? block.focused : block.overview
      let column = measure(block, index: index, firstLabel: hasFocus ? 1 : label, shows: shows)
      if shows && !hasFocus {
        label += block.alternatives.count
      }
      if tiers.isEmpty || tierWidth + column.chipWidth > limit {
        tiers.append([])
        tierWidth = 0
      }
      tiers[tiers.count - 1].append(column)
      tierWidth += column.chipWidth + Self.columnGap
    }
    for (index, tier) in tiers.enumerated() {
      if index > 0 {
        bottom += 8
      }
      addTier(tier)
    }
  }

  func altCell(_ choice: NovaChoice, label number: Int) -> AltCell {
    let label = string("\(number)", style.labelFont, NovaPalette.dim)
    let text = string(choice.text, style.font, NovaPalette.primary)
    let share = style.showShare ? choice.share.map { string("\($0)", style.shareFont, NovaPalette.share) } : nil
    let width = Self.altPadding * 2 + ceil(label.size().width) + Self.labelGap + ceil(text.size().width)
    return AltCell(label: label, text: text, share: share, width: width)
  }

  func measure(_ block: NovaBlock, index: Int, firstLabel: Int, shows: Bool) -> Column {
    let chip = string(block.word.text, style.font, block.focused ? .black : NovaPalette.primary)
    let chipWidth = ceil(chip.size().width) + Self.chipPadding * 2
    let cells = shows ? block.alternatives.enumerated().map { altCell($0.element, label: firstLabel + $0.offset) } : []
    let share = style.showShare ? block.word.share.map { string("\($0)", style.shareFont, NovaPalette.share) } : nil
    return Column(index: index, block: block, chip: chip, chipWidth: chipWidth, share: share, cells: cells, firstLabel: firstLabel)
  }

  mutating func addTier(_ columns: [Column]) {
    let depth = columns.map(\.cells.count).max() ?? 0
    let altsHeight = depth > 0 ? Self.busGap + CGFloat(depth) * altRowHeight : 0
    let tier = Tier(top: bottom, height: chipHeight + shareHeight + altsHeight, upward: upward)
    var x = Self.edge
    var previousEnd: CGFloat?
    var altFloor: CGFloat = 0
    for column in columns {
      if let previousEnd {
        // 连线伸进两边的词块下面，避开圆角处的缝。
        let chip = tier.rect(x: 0, distance: 0, width: 0, height: chipHeight)
        links.append(Box(rect: NSRect(x: previousEnd - 2, y: chip.midY - Self.linkHeight / 2, width: x - previousEnd + 4, height: Self.linkHeight),
                         radius: 0, color: column.block.color))
      }
      addChip(column, x: x, tier: tier)
      addAlternatives(column, x: x, tier: tier, floor: &altFloor)
      previousEnd = x + column.chipWidth
      right = max(right, x + column.chipWidth)
      x += column.chipWidth + Self.columnGap
    }
    bottom = tier.top + tier.height
  }

  mutating func addChip(_ column: Column, x: CGFloat, tier: Tier) {
    let rect = tier.rect(x: x, distance: 0, width: column.chipWidth, height: chipHeight)
    // 焦点块换底色，不用描边。
    boxes.append(Box(rect: rect, radius: Self.chipRadius, color: column.block.focused ? NovaPalette.focus : column.block.color))
    hits.append(Hit(rect: rect, action: .focus(column.index)))
    runs.append(Run(string: column.chip, x: x + Self.chipPadding, baseline: baseline(of: rect, font: style.font)))
    if let share = column.share {
      let row = tier.rect(x: x, distance: chipHeight, width: column.chipWidth, height: shareHeight)
      runs.append(Run(string: share, x: x + (column.chipWidth - ceil(share.size().width)) / 2, baseline: baseline(of: row, font: style.shareFont)))
    }
  }

  // 备选放不下时往右让，用一条横线接回词块。
  mutating func addAlternatives(_ column: Column, x: CGFloat, tier: Tier, floor altFloor: inout CGFloat) {
    guard !column.cells.isEmpty else { return }
    let cellX = max(x + Self.altIndent, altFloor)
    let width = column.cells.map(\.width).max() ?? 0
    let spine = cellX - Self.spineOffset
    let firstRow = chipHeight + shareHeight + Self.busGap
    let bus = tier.y(firstRow - Self.busGap / 2)
    branches.move(to: NSPoint(x: x + Self.branchIndent, y: tier.y(chipHeight)))
    branches.line(to: NSPoint(x: x + Self.branchIndent, y: bus))
    branches.line(to: NSPoint(x: spine, y: bus))
    for (row, cell) in column.cells.enumerated() {
      let distance = firstRow + CGFloat(row) * altRowHeight
      let rect = tier.rect(x: cellX, distance: distance, width: width, height: altHeight)
      addBranch(spine: spine, from: bus, toX: cellX, y: rect.midY)
      boxes.append(Box(rect: rect, radius: 5, color: NovaPalette.altFill))
      hits.append(Hit(rect: rect, action: .pin(column.firstLabel + row)))
      let line = baseline(of: rect, font: style.font)
      var cursor = cellX + Self.altPadding
      for run in [cell.label, cell.text] {
        runs.append(Run(string: run, x: cursor, baseline: line))
        cursor += ceil(run.size().width) + Self.labelGap
      }
      if let share = cell.share {
        let shareRect = tier.rect(x: cellX, distance: distance + altHeight, width: width, height: shareHeight)
        runs.append(Run(string: share, x: rect.midX - ceil(share.size().width) / 2, baseline: baseline(of: shareRect, font: style.shareFont)))
      }
    }
    right = max(right, cellX + width)
    altFloor = cellX + width + Self.altGap
  }

  func addBranch(spine: CGFloat, from: CGFloat, toX end: CGFloat, y: CGFloat) {
    let radius = min(Self.branchRadius, end - spine)
    let corner = NSPoint(x: spine, y: y)
    branches.move(to: NSPoint(x: spine, y: from))
    branches.line(to: NSPoint(x: spine, y: y > from ? y - radius : y + radius))
    branches.curve(to: NSPoint(x: spine + radius, y: y), controlPoint1: corner, controlPoint2: corner)
    branches.line(to: NSPoint(x: end, y: y))
  }

  // 普通候选列表：竖排或横排，高亮的一项铺底色。
  mutating func addCandidates(_ content: NovaContent, maxWidth: CGFloat) {
    struct Entry {
      let label: NSAttributedString
      let text: NSAttributedString
      let comment: NSAttributedString
      let width: CGFloat
    }
    let entries = content.candidates.enumerated().map { index, candidate -> Entry in
      let label = string(candidate.label, style.labelFont, NovaPalette.dim)
      let text = string(candidate.text, style.font, NovaPalette.primary)
      let comment = string(candidate.comment, style.labelFont, NovaPalette.dim)
      var width = Self.rowPadding * 2 + ceil(text.size().width)
      width += candidate.label.isEmpty ? 0 : ceil(label.size().width) + Self.labelGap
      width += candidate.comment.isEmpty ? 0 : ceil(comment.size().width) + Self.labelGap
      return Entry(label: label, text: text, comment: comment, width: width)
    }
    let uniform = style.linear ? nil : entries.map(\.width).max()
    var x = Self.edge
    let limit = maxWidth - Self.edge
    var rowTop = bottom
    for (index, entry) in entries.enumerated() {
      let width = uniform ?? entry.width
      if x > Self.edge && x + width > limit {
        x = Self.edge
        rowTop += rowHeight
      }
      let rect = NSRect(x: x, y: rowTop, width: width, height: rowHeight)
      if index == content.highlighted {
        boxes.append(Box(rect: rect, radius: Self.chipRadius, color: NovaPalette.blue))
      }
      hits.append(Hit(rect: rect, action: .select(index)))
      let line = baseline(of: rect, font: style.font)
      var cursor = x + Self.rowPadding
      for run in [entry.label, entry.text, entry.comment] where run.length > 0 {
        runs.append(Run(string: run, x: cursor, baseline: line))
        cursor += ceil(run.size().width) + Self.labelGap
      }
      right = max(right, x + width)
      if style.linear {
        x += width
      } else {
        rowTop += rowHeight
      }
    }
    bottom = style.linear || entries.isEmpty ? rowTop + (entries.isEmpty ? 0 : rowHeight) : rowTop
  }
}
