//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit

final class SquirrelInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCnt: UInt = 0

  private weak var client: IMKTextInput?
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  // nova-ui 的便捷层（nova_ui_rime.h）按 void* 收 RimeApi*。
  private let rimeHandle = UnsafeMutableRawPointer(rime_get_api_stdbool())
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  private var session: RimeSessionId = 0
  private var schemaId: String = ""
  private var inlinePreedit = false
  private var inlineCandidate = false
  // for chord-typing
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""
  // 全拼时左 Shift 切英文：记录按下时间，判断是短按切换还是配合别的键。
  private var leftShiftTime: Date?
  private var leftShiftUsed = false

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to indicate the the key input was received and dealt with.
    // Key processing will not continue in that case.  In other words the
    // system will not deliver a key down event to the application.
    // Returning false means the original key down will be passed on to the client.
    var handled = false

    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 {
        return false
      }
    }

    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }

    switch event.type {
    case .flagsChanged:
      if lastModifiers == modifiers {
        handled = true
        break
      }
      // 全拼正在输入时，左 Shift 短按切英文要先上屏用户实际打的字母（git 不是 yit）；
      // 右 Shift 仍交给 ascii_composer 的 commit_text，长按超过 500ms 也不切换。
      let shiftDown = modifiers.contains(.shift)
      let shiftWasDown = lastModifiers.contains(.shift)
      if event.keyCode == 56 && shiftDown != shiftWasDown {
        if shiftDown {
          if canCommitRawOnLeftShift {
            leftShiftTime = Date()
            leftShiftUsed = false
            lastModifiers = modifiers
            return true
          }
        } else if let start = leftShiftTime {
          leftShiftTime = nil
          let used = leftShiftUsed
          leftShiftUsed = false
          lastModifiers = modifiers
          if !used && Date().timeIntervalSince(start) < 0.5 {
            if isQuanpinComposing {
              let raw = rimeProperty("nova_qp_raw") ?? ""
              let input = rimeAPI.get_input(session).map { String(cString: $0) } ?? ""
              commit(string: raw.isEmpty ? input : raw)
              rimeAPI.clear_composition(session)
            }
            rimeAPI.set_option(session, "ascii_mode", true)
            rimeUpdate()
          }
          return true
        }
      }
      if leftShiftTime != nil {
        leftShiftUsed = true
      }
      // print("[DEBUG] FLAGSCHANGED client: \(sender ?? "nil"), modifiers: \(modifiers)")
      var rimeModifiers: UInt32 = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
      // For flags-changed event, keyCode is available since macOS 10.15
      // (#715)
      let rimeKeycode: UInt32 = SquirrelKeycode.osxKeycodeToRime(keycode: event.keyCode, keychar: nil, shift: false, caps: false)

      if changes.contains(.capsLock) {
        // NOTE: rime assumes XK_Caps_Lock to be sent before modifier changes,
        // while NSFlagsChanged event has the flag changed already.
        // so it is necessary to revert kLockMask.
        rimeModifiers ^= kLockMask.rawValue
        _ = processKey(rimeKeycode, modifiers: rimeModifiers)
      }

      // Need to process release before modifier down. Because
      // sometimes release event is delayed to next modifier keydown.
      var buffer = [(keycode: UInt32, modifier: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if modifiers.contains(flag) { // New modifier
          buffer.append((keycode: rimeKeycode, modifier: rimeModifiers))
        } else { // Release
          buffer.insert((keycode: rimeKeycode, modifier: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      for (keycode, modifier) in buffer {
        _ = processKey(keycode, modifiers: modifier)
      }

      lastModifiers = modifiers
      rimeUpdate()

    case .keyDown:
      if leftShiftTime != nil {
        leftShiftUsed = true
      }
      // ignore Command+X hotkeys.
      if modifiers.contains(.command) {
        break
      }

      let keyCode = event.keyCode
      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      // print("[DEBUG] KEYDOWN client: \(sender ?? "nil"), modifiers: \(modifiers), keyCode: \(keyCode), keyChars: [\(keyChars ?? "empty")]")

      // translate osx keyevents to rime keyevents
      if let char = keyChars?.first {
        let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: char,
                                                           shift: modifiers.contains(.shift),
                                                           caps: modifiers.contains(.capsLock))
        if rimeKeycode != 0 {
          let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
          handled = processKey(rimeKeycode, modifiers: rimeModifiers)
          rimeUpdate()
        }
      }

    default:
      break
    }

    return handled
  }

  func selectCandidate(_ index: Int) -> Bool {
    let success = nova_ui_rime_select_candidate(rimeHandle, session, Int32(index)) != 0
    if success {
      rimeUpdate()
    }
    return success
  }

  // 数字键由 nova_tree_keys.lua 处理，点击备选走同一条路。
  func pinAlternative(_ label: Int) {
    if nova_ui_rime_pin_alternative(rimeHandle, session, Int32(label)) != 0 {
      rimeUpdate()
    }
  }

  // 点击字母或词块：改原始字母光标，再发 F20 让 nova_tree_keys.lua 按新光标重画树。
  func moveCursor(to position: Int) {
    if nova_ui_rime_move_cursor(rimeHandle, session, Int32(position)) != 0 {
      rimeUpdate()
    }
  }

  // 滚轮翻页和 PageUp/PageDown 走同一条路，由 nova_tree_keys.lua 处理：有焦点块时翻它的备选，
  // 否则翻普通候选列表（第一次只打开列表，停在第一页）。
  func turnPage(up: Bool) {
    if nova_ui_rime_turn_page(rimeHandle, session, up ? 1 : 0) != 0 {
      rimeUpdate()
    }
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    // print("[DEBUG] recognizedEvents:")
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] activateServer:")
    var keyboardLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    preedit = ""
    // 第一次切到 Nova：打开设置面板先选输入方式。
    if !NovaOptions.layoutChosen && !Self.welcomeShown {
      Self.welcomeShown = true
      DispatchQueue.main.async { NovaSettingsWindow.shared.show() }
    }
  }

  private static var welcomeShown = false

  // 设置面板（NovaSettings.swift）里的选择设给这个会话。
  func applyNovaOptions() {
    guard session != 0 else { return }
    for (name, value) in NovaOptions.all where rimeAPI.get_option(session, name) != value {
      rimeAPI.set_option(session, name, value)
    }
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    // print("[DEBUG] initWithServer: \(server ?? .init()) delegate: \(delegate ?? "nil") client:\(client ?? "nil")")
    super.init(server: server, delegate: delegate, client: client)
    createSession()
    NotificationCenter.default.addObserver(forName: NovaOptions.changed, object: nil, queue: .main) { [weak self] _ in
      self?.applyNovaOptions()
    }
  }

  override func deactivateServer(_ sender: Any!) {
    // print("[DEBUG] deactivateServer: \(sender ?? "nil")")
    leftShiftTime = nil
    leftShiftUsed = false
    hidePalettes()
    commitComposition(sender)
    client = nil
  }

  override func hidePalettes() {
    NSApp.squirrelAppDelegate.panel?.hide()
    super.hidePalettes()
  }

  /*!
   @method
   @abstract   Called when a user action was taken that ends an input session.
   Typically triggered by the user selecting a new input method
   or keyboard layout.
   @discussion When this method is called your controller should send the
   current input buffer to the client via a call to
   insertText:replacementRange:.  Additionally, this is the time
   to clean up if that is necessary.
   */
  override func commitComposition(_ sender: Any!) {
    leftShiftTime = nil
    leftShiftUsed = false
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] commitComposition: \(sender ?? "nil")")
    //  commit raw input
    // Nova: 全拼时 Rime 的输入是换算后的双拼码（带简拼通配符 V），用户没打过。
    // 这时上屏 nova_qp_raw，也就是用户打的拼音（lua/nova_quanpin.lua 写入，不是全拼时为空）。
    // 切到别的应用、点通知这类情况都会走到这里。
    if session != 0 {
      if let input = rimeAPI.get_input(session) {
        let raw = rimeProperty("nova_qp_raw") ?? ""
        commit(string: raw.isEmpty ? String(cString: input) : raw)
        rimeAPI.clear_composition(session)
      }
    }
  }

  // 读 Rime 上下文的属性。没有这个属性，或者 4096 字节放不下时返回 nil。
  private func rimeProperty(_ name: String) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard rimeAPI.get_property(session, name, &buffer, buffer.count), buffer[buffer.count - 1] == 0 else { return nil }
    return String(cString: buffer)
  }

  // 全拼正在输入（不是英文模式）。
  private var isQuanpinComposing: Bool {
    guard session != 0, let input = rimeAPI.get_input(session), input.pointee != 0 else { return false }
    return rimeAPI.get_option(session, "quanpin") && !rimeAPI.get_option(session, "ascii_mode")
  }

  // 连击输入开着时 Shift 也参与组合键，不在这里接管。
  private var canCommitRawOnLeftShift: Bool {
    isQuanpinComposing && !rimeAPI.get_option(session, "_chord_typing")
  }

  // 菜单栏的 Nova 菜单：输入方式（单选）、设置、重新加载设置。
  override func menu() -> NSMenu! {
    let menu = NSMenu()
    let current = NovaOptions.layout
    for (index, item) in NovaOptions.layouts.enumerated() {
      let entry = NSMenuItem(title: item.name, action: #selector(chooseLayout(_:)), keyEquivalent: "")
      entry.target = self
      entry.tag = index
      entry.state = item.id == current ? .on : .off
      menu.addItem(entry)
    }
    menu.addItem(.separator())
    let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: "")
    settings.target = self
    menu.addItem(settings)
    let help = NSMenuItem(title: "使用说明", action: #selector(openHelp), keyEquivalent: "")
    help.target = self
    menu.addItem(help)
    let deploy = NSMenuItem(title: "重新加载设置", action: #selector(deploy), keyEquivalent: "`")
    deploy.target = self
    deploy.keyEquivalentModifierMask = [.control, .option]
    menu.addItem(deploy)
    return menu
  }

  @objc func chooseLayout(_ sender: Any?) {
    // IMK 菜单回调传进来的是一个字典，菜单项在 kIMKCommandMenuItemName 下。
    var item = sender as? NSMenuItem
    if item == nil, let info = sender as? [String: Any] {
      item = info[kIMKCommandMenuItemName] as? NSMenuItem
    }
    guard let tag = item?.tag, NovaOptions.layouts.indices.contains(tag) else { return }
    NovaOptions.layout = NovaOptions.layouts[tag].id
  }

  @objc func openSettings() {
    NovaSettingsWindow.shared.show()
  }

  @objc func openHelp() {
    NovaSettingsWindow.shared.show(tab: .help)
  }

  @objc func deploy() {
    NSApp.squirrelAppDelegate.deploy()
  }

  deinit {
    destroySession()
  }
}

private extension SquirrelInputController {

  func onChordTimer(_: Timer) {
    // chord release triggered by timer
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // simulate key-ups
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    // print("[DEBUG] update chord: {\(chordKeyCodes)} << \(keycode)")
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      // you are cheating. only one human typist (fingers <= 10) is supported.
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    // reset timer
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    let app = client?.bundleIdentifier() ?? {
      SquirrelInputController.unknownAppCnt &+= 1
      return "UnknownApp\(SquirrelInputController.unknownAppCnt)"
    }()
    print("createSession: \(app)")
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""

    if session != 0 {
      updateAppOptions()
      applyNovaOptions()
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    if let appOptions = NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp) {
      for (key, value) in appOptions {
        print("set app option: \(key) = \(value)")
        rimeAPI.set_option(session, key, value)
      }
    }
  }

  func destroySession() {
    // print("[DEBUG] destroySession:")
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
    clearChord()
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    // TODO add special key event preprocessing here

    // with linear candidate list, arrow keys may behave differently.
    if let panel = NSApp.squirrelAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
    }

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))
    // print("[DEBUG] rime_keycode: \(rimeKeycode), rime_modifiers: \(rimeModifiers), handled = \(handled)")

    // TODO add special key event postprocessing here

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
        // print("[DEBUG] turned Chinese mode off in vim-like editor's command mode")
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        // non-chording key pressed
        clearChord()
      }
    }

    return handled
  }

  func rimeConsumeCommittedText() {
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text))
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  func rimeUpdate() {
    // print("[DEBUG] rimeUpdate")
    rimeConsumeCommittedText()

    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      // enable schema specific ui style
      // swiftlint:disable:next identifier_name
      if let schema_id = status.schema_id, schemaId == "" || schemaId != String(cString: schema_id) {
        schemaId = String(cString: schema_id)
        NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
        // inline preedit
        if let panel = NSApp.squirrelAppDelegate.panel {
          inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) || rimeAPI.get_option(session, "inline")
          inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
          // if not inline, embed soft cursor in preedit string
          rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
        }
      }
      _ = rimeAPI.free_status(&status)
    }

    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      // update preedit text
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""

      let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_start)), within: preedit) ?? preedit.startIndex
      let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_end)), within: preedit) ?? preedit.startIndex
      let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.cursor_pos)), within: preedit) ?? preedit.startIndex

      if inlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let endOfCandidatePreview = candidatePreview.endIndex
        if inlinePreedit {
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$
        let start = min(start, candidatePreview.endIndex)
        // caret can be either before or after the selected range.
        let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // TRICKY: display a non-empty string to prevent iTerm2 from echoing
          // each character in preedit. note this is a full-shape space U+3000;
          // using half shape characters like "..." will result in an unstable
          // baseline when composing Chinese characters.
          // Nova: 占位每个键都要重新设一次。内容没变就不调 setMarkedText 的话，
          // 有的终端会认为这个键没被输入法处理，把字母直接写进正文。
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0,
               force: !preedit.isEmpty)
        }
      }

      // update candidates
      let numCandidates = Int(ctx.menu.num_candidates)
      var candidates = [String]()
      var comments = [String]()
      for i in 0..<numCandidates {
        let candidate = ctx.menu.candidates[i]
        candidates.append(candidate.text.map { String(cString: $0) } ?? "")
        comments.append(candidate.comment.map { String(cString: $0) } ?? "")
      }
      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(preedit: preedit, selRange: selRange, candidates: candidates, comments: comments, labels: labels,
                pageNo: Int(ctx.menu.page_no), highlighted: Int(ctx.menu.highlighted_candidate_index), numCandidates: numCandidates)
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
  }

  func commit(string: String) {
    guard let client = client else { return }
    // print("[DEBUG] commitString: \(string)")
    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int, force: Bool = false) {
    guard let client = client else { return }
    // print("[DEBUG] showPreeditString: '\(preedit)'")
    if !force && self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    // print("[DEBUG] selRange.location = \(selRange.location), selRange.length = \(selRange.length); caretPos = \(caretPos)")
    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
    attrString.setAttributes(attrs, range: remainingRange)
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
  }

  // 显示树还是普通列表、字母行显示什么，由 nova-ui 决定（nova_ui_assemble）：
  // 要在 get_context 之后读，nova_tree 由候选过滤器在生成菜单时写入。
  // swiftlint:disable:next function_parameter_count
  func showPanel(preedit: String, selRange: NSRange, candidates: [String], comments: [String], labels: [String],
                 pageNo: Int, highlighted: Int, numCandidates: Int) {
    guard let client = client, let panel = NSApp.squirrelAppDelegate.panel else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    panel.position = inputPos
    panel.inputController = self
    // C 字符串由这里持有，函数结束时一起释放。
    var owned = [UnsafeMutablePointer<CChar>]()
    defer { owned.forEach { free($0) } }
    func cStrings(_ strings: [String]) -> [UnsafePointer<CChar>?] {
      strings.map { string in
        let pointer = strdup(string)!
        owned.append(pointer)
        return UnsafePointer(pointer)
      }
    }
    let preeditC = cStrings([preedit])
    let textsC = cStrings(candidates.map { $0.precomposedStringWithCanonicalMapping })
    let commentsC = cStrings(comments.map { $0.precomposedStringWithCanonicalMapping })
    let labelsC = cStrings(labels)
    var input = NovaUIAssembleInput()
    input.page_no = Int32(pageNo)
    input.highlighted = Int32(highlighted)
    input.num_candidates = Int32(numCandidates)
    input.preedit = preeditC[0]
    input.sel_location = selRange.location == NSNotFound ? -1 : Int32(selRange.location)
    input.sel_length = Int32(selRange.length)
    input.inline_preedit = inlinePreedit ? 1 : 0
    input.count = Int32(candidates.count)
    input.label_count = Int32(labels.count)
    let handle = textsC.withUnsafeBufferPointer { texts in
      commentsC.withUnsafeBufferPointer { comments in
        labelsC.withUnsafeBufferPointer { labels in
          input.texts = texts.baseAddress
          input.comments = comments.baseAddress
          input.labels = labels.baseAddress
          return nova_ui_rime_assemble(rimeHandle, session, &input)
        }
      }
    }
    guard let handle, let view = nova_ui_content_view(handle)?.pointee else { return }
    defer { nova_ui_content_free(handle) }
    let content = NovaContent(view)
    NovaUILog.record(letters: content.letters, first: content.candidates.isEmpty ? content.preedit : candidates[0], blocks: content.blocks)
    panel.update(content)
  }
}
