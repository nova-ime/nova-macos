//
//  NovaPanel.swift
//  Nova Squirrel
//
//  候选面板的窗口、绘制和鼠标。内容的几何在 NovaLayout。
//

import AppKit

final class NovaView: NSView {
  var layoutResult: NovaLayout? {
    didSet { needsDisplay = true }
  }
  var hovered: NovaLayout.Hit? {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil))
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let layout = layoutResult else { return }
    if layout.card {
      layout.style.color(NOVA_COLOR_CARD).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: layout.cornerRadius, yRadius: layout.cornerRadius).fill()
    }
    for link in layout.links {
      link.color.setFill()
      link.rect.fill()
    }
    layout.style.color(NOVA_COLOR_BRANCH).setStroke()
    layout.branches.lineWidth = 1
    layout.branches.stroke()
    for box in layout.boxes {
      (box.token == NOVA_COLOR_ALT_FILL && box.rect == hovered?.rect ? layout.style.color(NOVA_COLOR_ALT_HOVER) : box.color).setFill()
      NSBezierPath(roundedRect: box.rect, xRadius: box.radius, yRadius: box.radius).fill()
    }
    for run in layout.runs {
      // 不带 usesLineFragmentOrigin 时，原点就是基线，字体回退不会让行之间错位。
      run.string.draw(with: NSRect(x: run.x, y: run.baseline, width: bounds.width, height: 0), options: [])
    }
  }
}

final class NovaPanel: NSPanel {
  var inputController: SquirrelInputController?
  var position = NSRect.zero

  private let view = NovaView()
  private let indicator = NovaIndicator()
  private var style = NovaStyle()
  private var statusMessage = ""
  private var statusTimer: Timer?
  private var statusType = "mix"
  private var pressed: NovaAction?
  private var scrollDelta: CGFloat = 0
  private var shown: NovaContent?
  // 一次输入期间面板的位置固定，输入结束才重新定位。
  private var anchor: Anchor?
#if DEBUG
  private var previewUpward = false
#endif

  private(set) var inlinePreedit = false
  private(set) var inlineCandidate = false
  var linear: Bool { style.linear }

  private static let statusDuration: TimeInterval = 1.2
  private static let caretGap: CGFloat = 2
  private static let screenMargin: CGFloat = 8
  // 光标离屏幕右边太近时，先把面板左移到至少有这么宽。之后放不下就换行，不再移动。
  private static let minimumWidth: CGFloat = 480

  fileprivate struct Anchor {
    let left: CGFloat
    // 往下长时是面板上边，往上长时是面板下边。
    let edgeY: CGFloat
    let upward: Bool
    let maxWidth: CGFloat
  }

  init() {
    super.init(contentRect: .zero, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
    level = .init(Int(CGShieldingWindowLevel()))
    hasShadow = false
    isOpaque = false
    backgroundColor = .clear
    view.autoresizingMask = [.width, .height]
    let root = NSView()
    root.addSubview(view)
    contentView = root
  }

#if DEBUG
  // 开发用预览：不经过输入法，直接决定方向和是否显示比例。
  func prepareForPreview(upward: Bool, showShare: Bool) {
    previewUpward = upward
    style.showShare = showShare
  }
#endif

  // 字体、字号、颜色、形状都在主题里（NovaThemes），这里只读和主题无关的几项。
  func load(config: SquirrelConfig) {
    var style = NovaStyle(theme: NovaThemes.current(dark: NovaThemes.systemDark))
    style.linear = config.getString("style/candidate_list_layout") == "linear"
    style.showShare = config.getBool("style/show_share") ?? false
    self.style = style
    inlinePreedit = config.getBool("style/inline_preedit") ?? false
    inlineCandidate = config.getBool("style/inline_candidate") ?? false
    statusType = config.getString("style/status_message_type") ?? "mix"
  }

  func update(_ content: NovaContent) {
    if content.preedit.isEmpty && content.candidates.isEmpty {
      if !statusMessage.isEmpty {
        showStatus(statusMessage)
        statusMessage = ""
      } else if statusTimer == nil {
        hide()
      }
      return
    }
    statusMessage = ""
    // 刚才显示的是状态消息，那个位置不算这次输入的。
    if statusTimer != nil {
      anchor = nil
    }
    statusTimer?.invalidate()
    statusTimer = nil
    indicator.dismiss()
    show(content)
  }

  func updateStatus(long: String, short: String) {
    switch statusType {
    case "long":
      statusMessage = long
    case "short":
      statusMessage = short.isEmpty ? long.first.map(String.init) ?? "" : short
    default:
      statusMessage = short.isEmpty ? long : short
    }
  }

  func hide() {
    statusTimer?.invalidate()
    statusTimer = nil
    shown = nil
    anchor = nil
    view.hovered = nil
    orderOut(nil)
  }

  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      pressed = hit(at: event)?.action
    case .leftMouseUp:
      if let pressed, pressed == hit(at: event)?.action {
        perform(pressed)
      }
      pressed = nil
    case .mouseEntered:
      acceptsMouseMovedEvents = true
    case .mouseExited:
      acceptsMouseMovedEvents = false
      view.hovered = nil
      pressed = nil
    case .mouseMoved:
      view.hovered = hit(at: event)
    case .scrollWheel:
      scroll(event)
    default:
      break
    }
    super.sendEvent(event)
  }
}

private extension NovaPanel {
  func hit(at event: NSEvent) -> NovaLayout.Hit? {
    let point = view.convert(event.locationInWindow, from: nil)
    return view.layoutResult?.hits.first { $0.rect.contains(point) }
  }

  func perform(_ action: NovaAction) {
    switch action {
    case .select(let index):
      _ = inputController?.selectCandidate(index)
    case .pin(let label):
      inputController?.pinAlternative(label)
    case .focus(let index):
      // 点词块：光标移到这块的末尾，这块成为焦点。
      if let blocks = shown?.blocks, index < blocks.count {
        inputController?.moveCursor(to: blocks[index].to)
      }
    case .cursor(let position):
      inputController?.moveCursor(to: position)
    }
  }

  func scroll(_ event: NSEvent) {
    guard event.momentumPhase.isEmpty else { return }
    if event.phase == .began {
      scrollDelta = 0
    }
    scrollDelta += event.scrollingDeltaY
    if abs(scrollDelta) >= (event.hasPreciseScrollingDeltas ? 30 : 1) {
      inputController?.turnPage(up: scrollDelta > 0)
      scrollDelta = 0
    }
  }

  func showStatus(_ message: String) {
    // 中英、全半角切换：显示 logo 样式的「中」「英」「全」「半」。其余（输入方式名等）照旧用文字卡片。
    if let glyph = NovaIndicator.glyph(for: message) {
      hide()
      indicator.show(glyph, caret: position, theme: NovaThemes.current(dark: NovaThemes.systemDark))
      return
    }
    var content = NovaContent()
    content.preedit = message
    show(content)
    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: Self.statusDuration, repeats: false) { [weak self] _ in
      self?.hide()
    }
  }

  func wantsUpward(screen: NSRect) -> Bool {
#if DEBUG
    if previewUpward {
      return true
    }
#endif
    // 光标在屏幕下方三分之一，或者下面放不下整棵树，就放到光标上方。
    let lowerPart = position.minY - screen.minY < screen.height / 3
    let fitsBelow = position.minY - Self.caretGap - NovaLayout.fullHeight(style: style) >= screen.minY
    return lowerPart || !fitsBelow
  }

  func currentAnchor(screen: NSRect) -> Anchor {
    if let anchor {
      return anchor
    }
    // 树的左边贴着这段文字的开头。
    let start = position.minX - NovaLayout.edge(style: style)
    let left = max(screen.minX + Self.screenMargin, min(start, screen.maxX - Self.minimumWidth - Self.screenMargin))
    let upward = wantsUpward(screen: screen)
    let edgeY = upward ? position.maxY + Self.caretGap : position.minY - Self.caretGap
    let result = Anchor(left: left, edgeY: edgeY, upward: upward, maxWidth: screen.maxX - Self.screenMargin - left)
    // 有的应用第一次返回空矩形，这时不锁定，下次按键再定位。
    if position != .zero {
      anchor = result
    }
    return result
  }

  func show(_ content: NovaContent) {
    // 用 visibleFrame 避开 Dock 和菜单栏。
    let display = NSScreen.screens.first { $0.frame.contains(position.origin) } ?? NSScreen.main
    let screen = display?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    // 跟随系统时，深浅色可能在两次输入之间变了；主题改了也在这里换上。
    let theme = NovaThemes.current(dark: NovaThemes.systemDark)
    if theme !== style.theme {
      style.theme = theme
    }
    let anchor = currentAnchor(screen: screen)
    let layout = NovaLayout(content: content, style: style, maxWidth: anchor.maxWidth, upward: anchor.upward)
    view.layoutResult = layout
    view.hovered = nil
    shown = content

    let originY = anchor.upward ? anchor.edgeY : anchor.edgeY - layout.size.height
    setFrame(NSRect(x: anchor.left, y: originY, width: layout.size.width, height: layout.size.height), display: true)
    orderFront(nil)
  }
}

// 中英切换提示：logo 的两个直角括号，中间换成一个字。淡入、停留、淡出，不接收鼠标。
final class NovaIndicator: NSPanel {
  private let glyphView = GlyphView()
  private var timer: Timer?

  private static let side: CGFloat = 36
  private static let gap: CGFloat = 4
  private static let hold: TimeInterval = 0.8
  private static let fadeIn: TimeInterval = 0.1
  private static let fadeOut: TimeInterval = 0.25

  static func glyph(for message: String) -> String? {
    switch message {
    case "中文", "中": return "中"
    case "英文", "英", "A": return "英"
    case "全角", "全": return "全"
    case "半角", "半": return "半"
    default: return nil
    }
  }

  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
               styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
    level = .init(Int(CGShieldingWindowLevel()))
    hasShadow = true
    isOpaque = false
    backgroundColor = .clear
    ignoresMouseEvents = true
    glyphView.frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
    contentView = glyphView
  }

  func show(_ glyph: String, caret: NSRect, theme: NovaTheme) {
    glyphView.glyph = glyph
    glyphView.fill = theme.color(NOVA_COLOR_CARD)
    glyphView.ink = theme.color(NOVA_COLOR_PRIMARY)
    glyphView.needsDisplay = true

    // 光标右下方；放不下就挪到屏幕内。
    let screen = (NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var origin = NSPoint(x: caret.maxX + Self.gap, y: caret.minY - Self.gap - Self.side)
    if origin.y < screen.minY { origin.y = caret.maxY + Self.gap }
    origin.x = min(max(origin.x, screen.minX), screen.maxX - Self.side)
    setFrameOrigin(origin)

    timer?.invalidate()
    alphaValue = 0
    orderFront(nil)
    NSAnimationContext.runAnimationGroup { $0.duration = Self.fadeIn; animator().alphaValue = 1 }
    timer = Timer.scheduledTimer(withTimeInterval: Self.fadeIn + Self.hold, repeats: false) { [weak self] _ in
      guard let self else { return }
      NSAnimationContext.runAnimationGroup({ $0.duration = Self.fadeOut; self.animator().alphaValue = 0 }) {
        if self.alphaValue == 0 { self.orderOut(nil) }
      }
    }
  }

  func dismiss() {
    guard isVisible else { return }
    timer?.invalidate()
    timer = nil
    orderOut(nil)
  }

  private final class GlyphView: NSView {
    var glyph = "中"
    var fill = NSColor.white
    var ink = NSColor.black
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
      let s = bounds.width / 256
      fill.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 40 * s, yRadius: 40 * s).fill()
      // logo 的两个直角括号（resources/brand/xingyu-glyph.svg，256 画布）。
      ink.setFill()
      let brackets = NSBezierPath()
      for poly in [[(36, 36), (112, 36), (112, 64), (64, 64), (64, 148), (36, 148)],
                   [(220, 220), (144, 220), (144, 192), (192, 192), (192, 108), (220, 108)]] {
        brackets.move(to: NSPoint(x: CGFloat(poly[0].0) * s, y: CGFloat(poly[0].1) * s))
        for p in poly.dropFirst() { brackets.line(to: NSPoint(x: CGFloat(p.0) * s, y: CGFloat(p.1) * s)) }
        brackets.close()
      }
      brackets.fill()
      let font = NSFont(name: "PingFangSC-Semibold", size: 104 * s) ?? .systemFont(ofSize: 104 * s, weight: .semibold)
      let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: ink])
      let size = text.size()
      text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
  }
}
