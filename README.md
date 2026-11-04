# Nova Squirrel

整句输入时，边打边改：打过去的词不会被后文改掉，打错的词按一两个键就能改。

Nova Squirrel 是[鼠须管](https://github.com/rime/squirrel) 1.1.2 的硬分叉，自带一套自然码双拼整句方案和自己的候选界面。它可以和官方鼠须管同时安装。许可证同为 GPL-3.0，不计划合回上游。

## 解决什么问题

普通的整句输入法，每按一键都会把整句重新算一遍。前面已经对的词，常常在你打后面的字时被改掉。比如"太极"打着打着变成"太及"。发现时只能退格重打，或者在一长串整句候选里找。

Nova 换了一种做法：

- **打过去的词不再变。** 一个多字词有把握，或者之后又打了两个音节都没变，就冻结，只有句尾继续跟着解码调整。单字和明显没把握的词不冻结，因为它们最常需要后文来纠正，比如"无党"后来变成"武当"。
- **没打完的字母不参与解码。** `nih` 里的 `h` 不会让前面的词闪一下；按空格时只上屏前面的完整部分，`h` 留下继续输入。
- **改错不用退格。** 系统没把握的词，下面直接列出备选，按数字就能改。改一个词时，前面的词保持不动，后面的词带着新选的字重新解码，可以跟它组词：选了"显"，后面的"时期"变成"示器"。
- **光标能停在任意字母上。** 面板里显示原始字母，`←/→` 移动光标，可以只改词里的一个字，也可以在中间增删字母；`↑/↓` 直接把光标处的词换成下一个/上一个备选。

## 怎么用

试一下这句（自然码双拼）：`tauovegewftihfnjjxjt`，输入框里显示"他说这个问题很难解决"。

| 操作 | 按键 | 结果 |
|---|---|---|
| 改没把握的词（橙色、紫色） | 直接按数字 | `1`：他说 → 她说，前面的词不变，后面的跟着重新解码 |
| 把光标移到某个词 | `←` / `→` 逐个字母，Tab / Shift+Tab 跳到下一个/上一个词的末尾 | 光标前一个字母所在的词成为焦点（黄底） |
| 换掉焦点词 | `↓` / `↑` | 直接换成下一个/上一个备选，一直按 `↑` 回到原来的词 |
| 只改词里的一个字 | 光标停在那个字的字母上 | 备选先列这个字的同音字：太极 → 太机，"太"不动 |
| 切分错了 | 焦点词的备选里有不同长度的词 | 选"我"，"我今天"就拆成"我"+"今天" |
| 看更多备选 | `-` `=`、`,` `.` 或滚轮 | 翻焦点词的备选，每页 6 个，最多 36 个 |
| 改字母 | 光标停在中间时打字、退格、`Delete` | 在光标处插入或删除，只重新解码改动的地方 |
| 回到句尾 | `End`，或在最后一个词上再按 Tab | 没有焦点，数字键直接选没把握的词 |
| 上屏 | 空格 | 不管光标在哪，整句上屏 |

颜色的含义：

| 颜色 | 含义 |
|---|---|
| 蓝 | 有把握：这个词在同音词里的词频占比 ≥ 80 |
| 橙 | 没把握，下面直接列出备选 |
| 紫 | 整句解码选了一个词频更低的词，值得看一眼 |
| 绿 | 你选过的词，还能再改 |
| 黄底 | 当前焦点 |

其他细节：

- **备选数量**：没有焦点时，每个没把握的词显示 2 个备选，全句最多 9 个编号，优先给最没把握的词。焦点词每页 6 个，页码显示在最后一个备选右边。
- **单字**：只有一个词、且选中的就是整个输入时（比如 `ni` 按 `2`），直接上屏。只打一个字母按空格，上屏的是字母本身。
- **改字母要成对**：自然码一个字两个字母。只插入或删除一个字母，后面的字母会错开一位重新配对。改过字母的地方，之前的选择作废。
- **鼠标**：点备选和按数字一样；点字母，光标落在它后面；点词块，光标落在词尾。
- **学习**：改过的词会记进用户词库，下次排得更靠前。
- **更多整句**：没有焦点时按 `↓` 或翻页，打开普通的整句候选列表，里面除了 rime 的首选，还有另外几种读法。

## 界面

- 输入框里显示首选整句；原始字母只在面板里显示一次，每个词的字母下面画一条和词块同色的线，光标是一根黄色竖线。
- 候选直接浮在文字下方，没有外框，也就没有面板边缘随输入跳动。
- 光标在屏幕下方三分之一时，界面放到输入区域上方，备选往上长。
- 一次输入期间位置固定。光标靠近屏幕右边时，界面先左移一次，之后放不下就换行。
- 实色、正常字号，不描边、不半透明。

## 设置

在 `~/Library/NovaSquirrel/nova.schema.yaml` 里改，改完重新部署（`` Control+Option+` ``）：

| 设置 | 默认 | 作用 |
|---|---|---|
| `style/show_share` | `false` | 在词和备选下面显示词频占比 |
| `style/inline_candidate` | `true` | 输入框里显示首选整句；关掉则显示双拼编码 |
| `nova_tree/enabled` | `true` | 关掉后回到普通候选列表 |

字体和字号沿用 `squirrel.yaml` 的 `style/font_face`、`style/font_point`。`squirrel.yaml` 的配色方案、圆角、竖排等设置对 Nova 不起作用。

## 安装

需要先装好[魔然](https://github.com/rime-moran/rime-moran)方案：Nova 用它的词库 `moran.extended`。用户目录里还要有语法模型 `zh-hans-t-essay-bgw.gram`。这两样本仓库都不包含。

```sh
scripts/build-nova.sh     # 构建 Release 版，产物在 build-release/
scripts/install-nova.sh   # 装到 ~/Library/Input Methods，不需要 sudo
```

第一次安装时，`~/Library/Rime` 里的方案和词库会复制到 `~/Library/NovaSquirrel`，用户词库不复制，词频从零开始。然后在输入法列表里选"Nova 鼠须管"，按 `F4` 切到 Nova 方案。

卸载：`scripts/install-nova.sh --uninstall`，用户目录会保留。

## 限制

- 解码模型没有换，还是 rime 加魔然的语法模型。Nova 改的是"错了以后怎么办"，不是"一次就猜对"。
- 每个词最多 36 个备选。正确的词不在里面时，只能改字母重打。
- 冻结让后文纠正前文的机会变少了。在 100 句维基百科句子上，整句全对从 32 句降到 30 句，逐字准确率从 82.0% 降到 81.5%。冻结的词仍可以用焦点手动改。
- 构建需要 `lib/`、`bin/` 里已有 librime，见 INSTALL.md。`package/` 和 `Makefile` 的打包及安装目标还没有适配，不要用。
- 本机临时签名，未经 Apple 公证。

---

以下内容沿用上游的说明。

    鼠鬚管
    爲物雖微情不淺
    新詩醉墨時一揮
    別後寄我無辭遠

    　　　——歐陽修

今由　[中州韻輸入法引擎／Rime Input Method Engine](https://rime.im)
及其他開源技術強力驅動

【鼠鬚管】輸入法
===
[![Download](https://img.shields.io/github/v/release/rime/squirrel)](https://github.com/rime/squirrel/releases/latest)
[![Build Status](https://github.com/rime/squirrel/actions/workflows/commit-ci.yml/badge.svg)](https://github.com/rime/squirrel/actions/workflows)
[![GitHub Tag](https://img.shields.io/github/tag/rime/squirrel.svg)](https://github.com/rime/squirrel)

式恕堂 版權所無

授權條款：[GPL v3](https://www.gnu.org/licenses/gpl-3.0.en.html)

項目主頁：[rime.im](https://rime.im)

您可能還需要 Rime 用於其他操作系統的發行版：

  * 【中州韻】（ibus-rime、fcitx-rime）用於 Linux
  * 【小狼毫】用於 Windows

安裝輸入法
---

本品適用於 macOS 13.0+

初次安裝，如果在部份應用程序中打不出字，請註銷並重新登錄。

使用輸入法
---

選取輸入法指示器菜單裏的【ㄓ】字樣圖標，開始用鼠鬚管寫字。
通過快捷鍵 `` Ctrl+` `` 或 `F4` 呼出方案選單、切換輸入方式。

定製輸入法
---

定製方法，請參考線上 [幫助文檔](https://rime.im/docs/)。

使用系統輸入法菜單：

  * 選中「在線文檔」可打開以上網址
  * 編輯用戶設定後，選擇「重新部署」以令修改生效

安裝輸入方案
---

使用 [/plum/](https://github.com/rime/plum) 配置管理器獲取更多輸入方案。

致謝
---

輸入方案設計：

  * 【朙月拼音】系列

    感謝 CC-CEDICT、Android 拼音、新酷音、opencc 等開源項目

程序設計：

  * 佛振
  * Linghua Zhang
  * Chongyu Zhu
  * 雪齋
  * faberii
  * Chun-wei Kuo
  * Junlu Cheng
  * Jak Wings
  * xiehuc

美術：

  * 圖標設計 佛振、梁海、雨過之後
  * 配色方案 Aben、Chongyu Zhu、skoj、Superoutman、佛振、梁海

本品引用了以下開源軟件：

  * Boost C++ Libraries  (Boost Software License)
  * capnproto (MIT License)
  * darts-clone  (New BSD License)
  * google-glog  (New BSD License)
  * Google Test  (New BSD License)
  * LevelDB  (New BSD License)
  * librime  (New BSD License)
  * OpenCC / 開放中文轉換  (Apache License 2.0)
  * plum / 東風破 (GNU Lesser General Public License 3.0)
  * Sparkle  (MIT License)
  * UTF8-CPP  (Boost Software License)
  * yaml-cpp  (MIT License)

感謝王公子捐贈開發用機。

問題與反饋
---

發現程序有 BUG，或建議，或感想，請反饋到 [Rime 代碼之家討論區](https://github.com/rime/home/discussions)

聯繫方式
---

技術交流，歡迎光臨 [Rime 代碼之家](https://github.com/rime/home)，
或致信 Rime 開發者 <rimeime@gmail.com>。

謝謝
