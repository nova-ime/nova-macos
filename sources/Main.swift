//
//  Main.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit

@main
struct SquirrelApp {
  // 自动测试用单独的用户目录：`defaults write im.nova.inputmethod.NovaSquirrel NovaUserDir <目录>`，
  // 重启 Nova 后生效；测完要 `defaults delete`，否则平时打的字也记到测试目录。见 .scratch/uitest。
  static let userDir = if let dir = UserDefaults.standard.string(forKey: "NovaUserDir"), !dir.isEmpty {
    URL(fileURLWithPath: dir, isDirectory: true)
  } else if let pwuid = getpwuid(getuid()) {
    URL(fileURLWithFileSystemRepresentation: pwuid.pointee.pw_dir, isDirectory: true, relativeTo: nil).appending(components: "Library", "NovaSquirrel")
  } else {
    try! FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("NovaSquirrel", isDirectory: true)
  }
  // 装在 /Library/Input Methods/NovaSquirrel.app，和官方版的 Squirrel.app 并存。
  static let appDir = Bundle.main.bundleURL
  static let logDir = FileManager.default.temporaryDirectory.appending(component: "rime.nova-squirrel", directoryHint: .isDirectory)

  // swiftlint:disable:next cyclomatic_complexity
  static func main() {
    let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee

    let handled = autoreleasepool {
      let installer = SquirrelInstaller()
      let args = CommandLine.arguments
      if args.count > 1 {
        switch args[1] {
        case "--quit":
          let bundleId = Bundle.main.bundleIdentifier!
          let runningSquirrels = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
          runningSquirrels.forEach { $0.terminate() }
          return true
#if DEBUG
        case "--tree-preview":
          // 开发用：把一段 nova_tree 画成 PNG，不经过输入法。工程没定义 DEBUG，构建时要加
          // SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG；否则这个参数会把程序当输入法启动。
          _ = NSApplication.shared
          let panel = NovaPanel()
          let environment = ProcessInfo.processInfo.environment
          // 屏幕中间的光标，默认往下长。
          panel.position = NSRect(x: 200, y: 500, width: 1, height: 20)
          panel.prepareForPreview(upward: environment["NOVA_PREVIEW_UP"] != nil, showShare: environment["NOVA_PREVIEW_SHARE"] != nil)
          var content = NovaContent()
          content.blocks = NovaBlock.parse(tree: args[2].replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t"))
          content.preedit = args[3]
          content.candidates = args[2].isEmpty ? args[3].map { NovaCandidate(label: "1", text: String($0), comment: "") } : [NovaCandidate(label: "", text: "x", comment: "")]
          if !args[2].isEmpty { content.preedit = "" }
          // 原始字母行：NOVA_PREVIEW_LETTERS=字母，NOVA_PREVIEW_CURSOR=光标位置。
          content.letters = environment["NOVA_PREVIEW_LETTERS"] ?? ""
          content.cursor = Int(environment["NOVA_PREVIEW_CURSOR"] ?? "") ?? content.letters.count
          panel.update(content)
          if let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[4]))
          }
          panel.hide()
          return true
#endif
        case "--reload":
          DistributedNotificationCenter.default().postNotificationName(.init("NovaSquirrelReloadNotification"), object: nil)
          return true
        case "--register-input-source", "--install":
          installer.register()
          return true
        case "--enable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { SquirrelInstaller.InputMode(rawValue: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              installer.enable(modes: modes)
              return true
            }
          }
          installer.enable()
          return true
        case "--disable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { SquirrelInstaller.InputMode(rawValue: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              installer.disable(modes: modes)
              return true
            }
          }
          installer.disable()
          return true
        case "--select-input-source":
          if args.count > 2, let mode = SquirrelInstaller.InputMode(rawValue: args[2]) {
            installer.select(mode: mode)
          } else {
            installer.select()
          }
          return true
        case "--build":
          // Notification
          SquirrelApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_update", comment: ""))
          // Build all schemas in current directory
          var builderTraits = RimeTraits.rimeStructInit()
          builderTraits.setCString("rime.squirrel-builder", to: \.app_name)
          rimeAPI.setup(&builderTraits)
          rimeAPI.deployer_initialize(nil)
          _ = rimeAPI.deploy()
          return true
        case "--sync":
          DistributedNotificationCenter.default().postNotificationName(.init("NovaSquirrelSyncNotification"), object: nil)
          return true
        case "--help":
          print(helpDoc)
          return true
        default:
          break
        }
      }
      return false
    }
    if handled {
      return
    }

    autoreleasepool {
      // find the bundle identifier and then initialize the input method server
      let main = Bundle.main
      let connectionName = main.object(forInfoDictionaryKey: "InputMethodConnectionName") as! String
      _ = IMKServer(name: connectionName, bundleIdentifier: main.bundleIdentifier!)
      // load the bundle explicitly because in this case the input method is a
      // background only application
      let app = NSApplication.shared
      let delegate = SquirrelApplicationDelegate()
      app.delegate = delegate
      app.setActivationPolicy(.accessory)

      // opencc will be configured with relative dictionary paths
      FileManager.default.changeCurrentDirectoryPath(main.sharedSupportPath!)

      if NSApp.squirrelAppDelegate.problematicLaunchDetected() {
        print("Problematic launch detected!")
        let args = ["Problematic launch detected! Squirrel may be suffering a crash due to improper configuration. Revert previous modifications to see if the problem recurs."]
        let task = Process()
        task.executableURL = "/usr/bin/say".withCString { dir in
          URL(fileURLWithFileSystemRepresentation: dir, isDirectory: false, relativeTo: nil)
        }
        task.arguments = args
        try? task.run()
      } else {
        NSApp.squirrelAppDelegate.setupRime()
        NSApp.squirrelAppDelegate.startRime(fullCheck: false)
        NSApp.squirrelAppDelegate.loadSettings()
        print("Squirrel reporting!")
      }

      // finally run everything
      app.run()
      print("Squirrel is quitting...")
      rimeAPI.finalize()
    }
    return
  }

  static let helpDoc = """
Supported arguments:
Perform actions:
  --quit                     quit all Squirrel process
  --reload                   deploy
  --sync                     sync user data
  --build                    build all schemas in current directory
Install Squirrel:
  --install, --register-input-source    register input source
  --enable-input-source [source id...]  input source list optional
  --disable-input-source [source id...] input source list optional
  --select-input-source [source id]     input source optional
"""
}
