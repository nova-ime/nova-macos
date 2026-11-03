// 生成菜单栏图标 resources/nova.pdf：swift scripts/make-menu-icon.swift resources/nova.pdf
import AppKit
// 22x16 的菜单栏图标：实心圆角矩形，镂空出两个相连的词块和一个往下分出的备选。
final class Icon: NSView {
  override var isFlipped: Bool { false }
  override func draw(_ r: NSRect) {
    // 奇偶填充：外框里的形状变成镂空。形状之间只相接、不重叠，否则重叠处又会被填上。
    let path = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 21, height: 15), xRadius: 3.5, yRadius: 3.5)
    path.windingRule = .evenOdd
    let chip = { (r: NSRect) in path.append(NSBezierPath(roundedRect: r, xRadius: 1.2, yRadius: 1.2)) }
    chip(NSRect(x: 3.5, y: 8.5, width: 6, height: 4))   // 上排左词块
    chip(NSRect(x: 12.5, y: 8.5, width: 6, height: 4))  // 上排右词块
    path.append(NSBezierPath(rect: NSRect(x: 9.5, y: 9.9, width: 3, height: 1.2)))   // 连线
    path.append(NSBezierPath(rect: NSRect(x: 5.0, y: 4.6, width: 1.2, height: 3.9))) // 分支竖线
    path.append(NSBezierPath(rect: NSRect(x: 6.2, y: 4.6, width: 1.3, height: 1.2))) // 分支横线
    chip(NSRect(x: 7.5, y: 3.2, width: 5, height: 4))   // 备选
    NSColor.black.setFill()
    path.fill()
  }
}
let view = Icon(frame: NSRect(x: 0, y: 0, width: 22, height: 16))
try! view.dataWithPDF(inside: view.bounds).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
