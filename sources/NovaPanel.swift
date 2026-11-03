//
//  NovaPanel.swift
//  Nova Squirrel
//
//  候选面板的窗口、绘制和鼠标。内容的几何在 NovaLayout。
//

import AppKit

private final class NovaView: NSView {
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
      NovaPalette.card.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: NovaLayout.cornerRadius, yRadius: NovaLayout.cornerRadius).fill()
    }
    for link in layout.links {
      link.color.setFill()
      link.rect.fill()
    }
    NovaPalette.branch.setStroke()
    layout.branches.lineWidth = 1
    layout.branches.stroke()
    for box in layout.boxes {
      (box.color == NovaPalette.altFill && box.rect == hovered?.rect ? NovaPalette.altHover : box.color).setFill()
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

  func load(config: SquirrelConfig) {
    var style = NovaStyle()
    let point = config.getDouble("style/font_point") ?? style.font.pointSize
    style.font = Self.font(from: config.getString("style/font_face"), size: point)
    style.linear = config.getString("style/candidate_list_layout") == "linear"
    style.showShare = config.getBool("style/show_share") ?? false
    self.style = style
    inlinePreedit = config.getBool("style/inline_preedit") ?? false
    inlineCandidate = config.getBool("style/inline_candidate") ?? false
    statusType = config.getString("style/status_message_type") ?? "mix"
  }

  // font_face 可以写多个字体，逗号分隔，前面的优先。找不到的跳过，都找不到就用系统字体。
  private static func font(from faces: String?, size: CGFloat) -> NSFont {
    let fonts = (faces ?? "").split(separator: ",").compactMap { face -> NSFont? in
      let name = face.trimmingCharacters(in: .whitespaces)
      return NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) ?? NSFont(name: name, size: size)
    }
    guard let first = fonts.first else { return .systemFont(ofSize: size) }
    let descriptor = first.fontDescriptor.addingAttributes([.cascadeList: fonts.dropFirst().map(\.fontDescriptor)])
    return NSFont(descriptor: descriptor, size: size) ?? first
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
      // 没有焦点时相当于停在最后一块的后面，← 一次到最后一块。
      if let blocks = shown?.blocks {
        inputController?.moveFocus(by: index - (blocks.firstIndex(where: \.focused) ?? blocks.count))
      }
    }
  }

  func scroll(_ event: NSEvent) {
    guard event.momentumPhase.isEmpty else { return }
    if event.phase == .began {
      scrollDelta = 0
    }
    scrollDelta += event.scrollingDeltaY
    if abs(scrollDelta) >= (event.hasPreciseScrollingDeltas ? 30 : 1) {
      _ = inputController?.page(up: scrollDelta > 0)
      scrollDelta = 0
    }
  }

  func showStatus(_ message: String) {
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
    let start = position.minX - NovaLayout.edge
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
