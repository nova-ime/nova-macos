//
//  NovaAuxGen.swift
//  Squirrel
//
//  辅助码的设置和词库生成。只用 Foundation，可以单独编译测试（见 NovaAuxDict.swift 开头的说明）。
//

import Foundation

enum NovaAux {
  static let changed = Notification.Name("NovaAuxChanged")
  private static let schemeKey = "NovaAux"
  private static let stampKey = "NovaAuxStamp"

  // 方案名、面板上的名字、生成文件头里的名字。
  static let schemes: [(id: String, name: String, label: String)] = [
    ("zrm", "自然码形码", "自然码"),
    ("flypy", "小鹤形码", "小鹤"),
    ("moqi", "墨奇码", "墨奇")
  ]

  static var scheme: String {
    get { UserDefaults.standard.string(forKey: schemeKey) ?? "zrm" }
    set { UserDefaults.standard.set(newValue, forKey: schemeKey) }
  }

  static var name: String { schemes.first { $0.id == scheme }?.name ?? "自然码形码" }

  static var dataDir: URL { Bundle.main.sharedSupportURL!.appendingPathComponent("nova_aux") }

  // 词条表随 app 升级可能变；记下生成时用的那份的大小和修改时间，对不上就要重新生成。
  static var baseStamp: String {
    let url = dataDir.appendingPathComponent("nova_wx.base.xz")
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(size)-\(Int(date))"
  }

  static var stamp: String? {
    get { UserDefaults.standard.string(forKey: stampKey) }
    set { UserDefaults.standard.set(newValue, forKey: stampKey) }
  }

  // 用的不是自然码，而 app 升级后词条表变了：用户目录里的词表过时了，要重新生成。
  static var needsRebuild: Bool { scheme != "zrm" && stamp != baseStamp }

  // MARK: 生成词库

  enum Failure: LocalizedError {
    case missing(String)
    case deployer(Int32, String)

    var errorDescription: String? {
      switch self {
      case .missing(let what): return "缺少数据文件：\(what)。请重新安装星语。"
      case .deployer(let code, let tail): return "编译词库失败（退出码 \(code)）。\(tail)"
      }
    }
  }

  private static func header(_ name: String, _ label: String, _ imports: String?) -> String {
    "# 由星语按\(label)辅助码生成（词库来自万象拼音，CC-BY-4.0），不要手改。\n"
      + "---\nname: \(name)\nversion: \"wx\"\nsort: by_weight\nuse_preset_vocabulary: false\n"
      + (imports.map { "import_tables:\n  - \($0)\n" } ?? "") + "...\n"
  }

  // 「字 → 形码」表：字\t形码[,形码...]。键是字的 Unicode 码位。
  private static func loadAux(_ data: Data) -> [UInt32: [[UInt8]]] {
    var table = [UInt32: [[UInt8]]]()
    for line in data.split(separator: 0x0A) {
      guard let tab = line.firstIndex(of: 0x09),
            let ch = String(decoding: line[line.startIndex..<tab], as: UTF8.self).unicodeScalars.first else { continue }
      table[ch.value] = line[(tab + 1)...].split(separator: 0x2C).map { Array($0) }
    }
    return table
  }

  private static let maxCombos = 4

  /// 生成主词库和简拼表。progress 收到 0…1。
  static func generate(base: Data, aux auxData: Data, label: String, main mainURL: URL, jp jpURL: URL,
                       progress: (Double) -> Void) throws {
    let aux = loadAux(auxData)
    FileManager.default.createFile(atPath: mainURL.path, contents: nil)
    FileManager.default.createFile(atPath: jpURL.path, contents: nil)
    let mainFile = try FileHandle(forWritingTo: mainURL)
    let jpFile = try FileHandle(forWritingTo: jpURL)
    defer { try? mainFile.close(); try? jpFile.close() }

    var out = [UInt8](), jp = [UInt8]()
    out.reserveCapacity(1 << 23)
    jp.reserveCapacity(1 << 22)
    out += Array(header("nova_wx", label, "nova_wx_jp").utf8)
    jp += Array(header("nova_wx_jp", label, nil).utf8)

    base.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let bytes = raw.bindMemory(to: UInt8.self)
      let total = bytes.count
      var start = 0
      var lastReport = 0
      var scalars = [UInt32]()
      var alts = [[[UInt8]]]()
      var index = [Int]()
      while start < total {
        var end = start
        while end < total && bytes[end] != 0x0A { end += 1 }
        // 词\t音节连写\t词频
        var t1 = start
        while bytes[t1] != 0x09 { t1 += 1 }
        var t2 = t1 + 1
        while bytes[t2] != 0x09 { t2 += 1 }
        let word = UnsafeBufferPointer(rebasing: bytes[start..<t1])
        let sps = UnsafeBufferPointer(rebasing: bytes[(t1 + 1)..<t2])
        let weight = UnsafeBufferPointer(rebasing: bytes[(t2 + 1)..<end])

        // 按音节查形码用的字：间隔号「·」（U+00B7）不占音节。
        scalars.removeAll(keepingCapacity: true)
        for s in String(decoding: word, as: UTF8.self).unicodeScalars where s.value != 0xB7 {
          scalars.append(s.value)
        }
        let n = sps.count / 2
        alts.removeAll(keepingCapacity: true)
        for i in 0..<n {
          let sp = [sps[2 * i], sps[2 * i + 1]]
          if i < scalars.count, let codes = aux[scalars[i]] {
            alts.append(codes.map { sp + [0x3B] + $0 })
          } else {
            alts.append([sp])
          }
        }
        // 和 itertools.product 同样的顺序：最右边的音节变得最快。最多 4 条。
        index = Array(repeating: 0, count: n)
        var written = 0
        while written < maxCombos {
          out += word
          out.append(0x09)
          for i in 0..<n {
            if i > 0 { out.append(0x20) }
            out += alts[i][index[i]]
          }
          out.append(0x09)
          out += weight
          out.append(0x0A)
          written += 1
          var k = n - 1
          while k >= 0 {
            index[k] += 1
            if index[k] < alts[k].count { break }
            index[k] = 0
            k -= 1
          }
          if k < 0 { break }
        }
        // 简拼表：词频取开头的数字（万象有几条写成 6N），是 0 的不收。
        var count = 0
        for b in weight {
          guard b >= 0x30 && b <= 0x39 else { break }
          count = count * 10 + Int(b - 0x30)
        }
        if count > 0 {
          jp += word
          jp.append(0x09)
          for i in 0..<n {
            if i > 0 { jp.append(0x20) }
            jp += [sps[2 * i], sps[2 * i + 1], 0x7E]
          }
          jp.append(0x09)
          jp += Array(String(count).utf8)
          jp.append(0x0A)
        }

        if out.count > (1 << 23) { mainFile.write(Data(out)); out.removeAll(keepingCapacity: true) }
        if jp.count > (1 << 22) { jpFile.write(Data(jp)); jp.removeAll(keepingCapacity: true) }
        if end - lastReport > (1 << 20) { progress(Double(end) / Double(total)); lastReport = end }
        start = end + 1
      }
    }
    mainFile.write(Data(out))
    jpFile.write(Data(jp))
    progress(1)
  }
}
