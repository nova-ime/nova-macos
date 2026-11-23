//
//  NovaAuxDict.swift
//  Squirrel
//
//  换辅助码：在本机重新生成并编译词库。
//
//  词库里每个字后面带两个形码（`an;oy`），app 里预编译的词库（SharedSupport/build）用自然码形码。
//  万象各辅助码版本的词条完全一样，形码只跟字有关，所以 app 只带一份不含形码的词条表
//  （SharedSupport/nova_aux/nova_wx.base.xz，xz 压缩）和每种形码一张「字 → 形码」表（<方案>.txt）。
//  用户选了别的形码时：
//    1. 生成 nova_wx.dict.yaml、nova_wx_jp.dict.yaml，写进用户目录。规则见 scripts/wanxiang/aux_tables.py，
//       两边的输出逐字节一致。
//    2. 用 app 自带的 rime_deployer 编译到临时目录，读它的日志显示进度。
//    3. 把编好的词表换进用户目录的 build/，删掉生成的源文件（约 190 MB），再重新加载。
//       librime 找不到源文件时直接用 build 里的词表，只重建拼写索引。
//  换回自然码时删掉用户目录里的词表，回到 app 预编译的那份。
//
//  编译要写到临时目录再换进去：输入法进程正以内存映射读着 build/ 里的旧词表，原地覆盖会让它读到截断的文件。
//  换名不影响已经映射的旧文件。
//

import Foundation
import SwiftUI

// MARK: - 切换流程和进度

final class NovaAuxBuilder: ObservableObject {
  static let shared = NovaAuxBuilder()

  static let stages = ["生成词库", "读取词条", "整理词条", "写入词库", "重新加载"]

  @Published var running = false
  @Published var stage = 0
  @Published var fraction = 0.0
  @Published var elapsed = 0.0
  @Published var error: String?
  // 换好以后在单选下面显示一行「已换成…」，几秒后隐去；进度条换好就收起。
  @Published var done: String?
  @Published var target = NovaAux.scheme

  // 各阶段在总进度里的起点，按本机实测的用时分：生成 1.4 秒、读取 3.2 秒、整理（排序）9.3 秒、
  // 写入 1.6 秒，重新加载约 1 秒。
  private let starts = [0.0, 0.08, 0.30, 0.85, 0.95, 1.0]
  private var began = Date()
  private var sortBegan: Date?
  private var sortExpected = 10.0
  private var timer: Timer?

  private func set(stage: Int, within: Double = 0) {
    DispatchQueue.main.async {
      self.stage = stage
      let a = self.starts[stage], b = self.starts[stage + 1]
      self.fraction = max(self.fraction, a + (b - a) * min(max(within, 0), 1))
    }
  }

  func switchTo(_ scheme: String) {
    guard !running else { return }
    running = true
    error = nil
    done = nil
    target = scheme
    stage = 0
    fraction = 0
    elapsed = 0
    began = Date()
    sortBegan = nil
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try self.run(scheme)
        DispatchQueue.main.async { self.finish(scheme, nil) }
      } catch {
        DispatchQueue.main.async { self.finish(scheme, error.localizedDescription) }
      }
    }
  }

  // 整理词条阶段日志里没有中间进度，按预计时间往前走，最多走到这一段的 95%。
  private func tick() {
    elapsed = Date().timeIntervalSince(began)
    if stage == 2, let t = sortBegan {
      let a = starts[2], b = starts[3]
      fraction = max(fraction, a + (b - a) * min(Date().timeIntervalSince(t) / sortExpected, 0.95))
    }
  }

  private func finish(_ scheme: String, _ failure: String?) {
    timer?.invalidate()
    timer = nil
    elapsed = Date().timeIntervalSince(began)
    running = false
    if let failure {
      error = failure
      target = NovaAux.scheme
      return
    }
    NovaAux.scheme = scheme
    NovaAux.stamp = scheme == "zrm" ? nil : NovaAux.baseStamp
    stage = Self.stages.count
    let message = String(format: "已换成%@，用时 %.0f 秒。", NovaAux.name, elapsed)
    done = message
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self.done == message { self.done = nil } }
    fraction = 1
    NotificationCenter.default.post(name: NovaAux.changed, object: nil)
  }

  private func run(_ scheme: String) throws {
    let fm = FileManager.default
    let user = SquirrelApp.userDir
    let build = user.appendingPathComponent("build")
    // prism（拼写索引）要和词表一起换：librime 找不到词库源文件时不核对 prism 是按哪张词表建的，
    // 留着旧的会把编码对到错的词上，打出来全是乱字。
    let tables = ["nova_wx.table.bin", "nova_wx.reverse.bin", "nova_wx.table.txt", "nova.prism.bin", "nova.prism.txt"]
    let sources = ["nova_wx.dict.yaml", "nova_wx_jp.dict.yaml"].map { user.appendingPathComponent($0) }

    if scheme == "zrm" {
      // 回到 app 预编译的词表和 prism：删掉用户目录里的。删文件不影响输入法进程已经映射的旧文件。
      for f in tables { try? fm.removeItem(at: build.appendingPathComponent(f)) }
      for f in sources { try? fm.removeItem(at: f) }
      set(stage: 4)
      reload()
      return
    }

    guard let label = NovaAux.schemes.first(where: { $0.id == scheme })?.label else { return }
    let baseURL = NovaAux.dataDir.appendingPathComponent("nova_wx.base.xz")
    let auxURL = NovaAux.dataDir.appendingPathComponent("\(scheme).txt")
    guard let packed = try? Data(contentsOf: baseURL) else { throw NovaAux.Failure.missing(baseURL.lastPathComponent) }
    guard let auxData = try? Data(contentsOf: auxURL) else { throw NovaAux.Failure.missing(auxURL.lastPathComponent) }
    guard let base = try? (packed as NSData).decompressed(using: .lzma) as Data else {
      throw NovaAux.Failure.missing(baseURL.lastPathComponent)
    }

    set(stage: 0)
    try fm.createDirectory(at: user, withIntermediateDirectories: true)
    try NovaAux.generate(base: base, aux: auxData, label: label, main: sources[0], jp: sources[1]) { p in
      self.set(stage: 0, within: p)
    }
    defer { for f in sources { try? fm.removeItem(at: f) } }

    // 编译到临时目录。
    let staging = user.appendingPathComponent("build.aux-tmp")
    try? fm.removeItem(at: staging)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    try compile(user: user, staging: staging)

    // 换进 build/。换名替换目录项，输入法进程映射着的旧文件不受影响。
    try fm.createDirectory(at: build, withIntermediateDirectories: true)
    for f in tables {
      let from = staging.appendingPathComponent(f)
      guard fm.fileExists(atPath: from.path) else { continue }
      let to = build.appendingPathComponent(f)
      if rename(from.path, to.path) != 0 { throw CocoaError(.fileWriteUnknown) }
    }
    set(stage: 4)
    reload()
  }

  private func compile(user: URL, staging: URL) throws {
    let shared = Bundle.main.sharedSupportURL!
    let process = Process()
    process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/rime_deployer")
    process.arguments = ["--compile", shared.appendingPathComponent("nova.schema.yaml").path,
                         user.path, shared.path, staging.path]
    var env = ProcessInfo.processInfo.environment
    env["GLOG_logtostderr"] = "1"
    process.environment = env
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = FileHandle.nullDevice

    var pending = Data()
    var tail = [String]()
    var passes = 0
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      lock.lock()
      defer { lock.unlock() }
      pending.append(chunk)
      while let nl = pending.firstIndex(of: 0x0A) {
        let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
        pending.removeSubrange(pending.startIndex...nl)
        if line.hasPrefix("E") { tail.append(line); if tail.count > 3 { tail.removeFirst() } }
        self.parse(line, passes: &passes)
      }
    }
    try process.run()
    process.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    if process.terminationStatus != 0 {
      lock.lock()
      let message = tail.joined(separator: "\n")
      lock.unlock()
      throw NovaAux.Failure.deployer(process.terminationStatus, message)
    }
  }

  // 按 librime 编译词库时的日志推进度（dict_compiler.cc、entry_collector.cc、table.cc）。
  private func parse(_ line: String, passes: inout Int) {
    if line.contains("collecting entries from") {
      set(stage: 1, within: Double(passes) / 2)
    } else if let r = line.range(of: "Pass 1: total ") {
      passes += 1
      set(stage: 1, within: Double(passes) / 2)
      // 第二个 Pass 1 报的是主词库加简拼表的总条数。按本机实测：335 万条排序约 9.3 秒，留点余量。
      if passes == 2, let n = Double(line[r.upperBound...].prefix { $0.isNumber }) {
        DispatchQueue.main.async { self.sortExpected = max(3, 10 * n / 3_345_408) }
      }
    } else if line.contains("Pass 3:") {
      DispatchQueue.main.async { self.sortBegan = Date() }
      set(stage: 2)
    } else if line.contains("building table.") {
      set(stage: 3)
    } else if line.contains("building prism") || line.contains("building reversedb") {
      set(stage: 3, within: 0.5)
    }
  }

  private func reload() {
    DispatchQueue.main.async { NSApp.squirrelAppDelegate.deploy() }
  }
}

struct NovaAuxSection: View {
  @ObservedObject private var builder = NovaAuxBuilder.shared
  @State private var selection = NovaAux.scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("辅助码").font(.headline)
      Text("音节后面打两个大写字母（形码），在同音字里筛出想要的字。换了以后要在本机重新编译一次词库，约 20 秒。")
        .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
      Picker("", selection: $selection) {
        ForEach(NovaAux.schemes, id: \.id) { Text($0.name).tag($0.id) }
      }
      .pickerStyle(.radioGroup)
      .horizontalRadioGroupLayout()
      .labelsHidden()
      .disabled(builder.running)
      .onChange(of: selection) { value in
        if value != NovaAux.scheme { builder.switchTo(value) }
      }
      .onReceive(builder.$target) { selection = $0 }

      if builder.running || builder.error != nil {
        NovaAuxProgress(builder: builder)
      } else if let done = builder.done {
        Text(done).font(.caption).foregroundColor(.secondary).transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.3), value: builder.running)
    .animation(.easeOut(duration: 0.3), value: builder.done)
  }
}

private struct NovaAuxProgress: View {
  @ObservedObject var builder: NovaAuxBuilder

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ProgressView(value: builder.fraction)
      HStack(spacing: 14) {
        ForEach(Array(NovaAuxBuilder.stages.enumerated()), id: \.offset) { i, name in
          HStack(spacing: 4) {
            icon(i)
            Text(name).foregroundColor(i == builder.stage && builder.running ? .primary : .secondary)
          }
          .font(.caption)
        }
      }
      if let error = builder.error {
        Text(error).foregroundColor(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
      } else {
        Text(String(format: "已用 %.0f 秒，期间照常打字不受影响。", builder.elapsed))
          .font(.caption).foregroundColor(.secondary)
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
  }

  @ViewBuilder private func icon(_ i: Int) -> some View {
    if builder.error != nil && i == builder.stage {
      Image(systemName: "xmark.circle.fill").foregroundColor(.red)
    } else if i < builder.stage {
      Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
    } else if i == builder.stage && builder.running {
      ProgressView().controlSize(.mini)
    } else {
      Image(systemName: "circle").foregroundColor(.secondary)
    }
  }
}
