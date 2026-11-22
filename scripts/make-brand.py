#!/usr/bin/env python3
"""生成星语输入法的图标 SVG：中文直角引号「」框住一颗四角星（「」是语，✦ 是星）。

python3 scripts/make-brand.py resources/brand
  xingyu-mark.svg   黑色母版，256 画布（其他文件都由它缩放、上色）
  xingyu.svg        图标：白色圆角底 + 黑色引号和星（README、组织头像、Windows 图标）
  xingyu-glyph.svg  只有前景（黑色引号和星），1024 画布，给 Rime.icon（Icon Composer）当前景层
  xingyu-mono.svg   黑色单色、几乎铺满画布，给 16 像素的菜单栏 / 托盘

生成后：
  cp resources/brand/xingyu-glyph.svg Rime.icon/Assets/logo.svg
  rsvg-convert -f pdf -w 16 -h 16 resources/brand/xingyu-mono.svg -o resources/nova.pdf
Windows 的 .ico 由 nova-windows/nova/make-icons.sh 从 xingyu.svg / xingyu-mono.svg 生成。
"""
import os
import sys

INK = "#FFFFFF"     # 底色：白（黑白原型；Mac 深色模式下由 Icon Composer 自动反成黑底白字）
LIGHT = "#111111"   # 引号
STAR = "#111111"    # 星，和引号同色

# 256 画布上的构造：笔画 28；「 占左上，」占右下，两者中心对称；星居中，半径 52。
QUOTES = ("M36 36 H112 V64 H64 V148 H36 Z "
          "M220 220 H144 V192 H192 V108 H220 Z")


def star(cx=128, cy=128, r=52, c=0.24):
    """四角星，四条边向内弯（二次曲线控制点在 c·r 处）。"""
    k = c * r
    p = lambda x, y: f"{cx + x:g} {cy + y:g}"
    return (f"M{p(0, -r)} Q{p(k, -k)} {p(r, 0)} Q{p(k, k)} {p(0, r)} "
            f"Q{p(-k, k)} {p(-r, 0)} Q{p(-k, -k)} {p(0, -r)} Z")


def svg(size, body, title="星语输入法"):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" '
            f'width="{size}" height="{size}" role="img"><title>{title}</title>\n{body}\n</svg>\n')


def placed(scale, offset, body):
    """把 256 画布上的图形缩放 scale 后平移 offset。"""
    return f'<g transform="translate({offset:g} {offset:g}) scale({scale:g})">{body}</g>'


def main(out):
    os.makedirs(out, exist_ok=True)
    mark = f'<path fill="#111" d="{QUOTES} {star()}"/>'
    fg = f'<path fill="{LIGHT}" d="{QUOTES}"/><path fill="{STAR}" d="{star()}"/>'
    # 彩色图标：图形约占底板 64%（app 图标惯例 60–70%），略高于几何中心做视觉居中。
    s = 0.64 * 1024 / 184           # 图形外框 36..220 = 184
    color = svg(1024, f'<rect width="1024" height="1024" rx="228" fill="{INK}"/>\n'
                      + placed(s, 512 - 128 * s, fg))
    glyph = svg(1024, placed(s, 512 - 128 * s, fg))
    # 菜单栏：图形铺到 92%，16 像素下笔画约 2 像素。
    m = 0.92 * 1024 / 184
    mono = svg(1024, placed(m, 512 - 128 * m, f'<path fill="#000" d="{QUOTES} {star()}"/>'))
    files = {"xingyu-mark.svg": svg(256, mark), "xingyu.svg": color,
             "xingyu-glyph.svg": glyph, "xingyu-mono.svg": mono}
    for name, text in files.items():
        with open(os.path.join(out, name), "w") as f:
            f.write(text)


if __name__ == "__main__":
    main(sys.argv[1])
