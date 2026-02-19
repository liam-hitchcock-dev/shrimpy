import AppKit
import UserNotifications
import ServiceManagement
import Darwin

// MARK: - Constants

let kNotificationName = "com.shrimpy.notify"
let kNotificationMessageKey = "message"
let kNotificationTitleKey = "title"
let kTerminalBundleIDKey = "terminalBundleID"
let kSuiteName = "com.shrimpy.notifier"
let kSoundKey = "notificationSound"
let kCategoryID = "SHRIMPY_NOTIFY"
let kActionOpen = "ACTION_OPEN"
let kClaudeSettingsRelativePath = ".claude/settings.json"

func shellSingleQuoted(_ value: String) -> String {
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func currentClaudeHookCommand() -> String {
    let binaryPath = Bundle.main.bundlePath + "/Contents/MacOS/Shrimpy"
    return "\(shellSingleQuoted(binaryPath)) \"$CLAUDE_NOTIFICATION_TITLE\""
}

// MARK: - Notification History

struct NotificationHistoryEntry {
    let message: String
    let title: String
    let timestamp: Date
}

// MARK: - Terminal Detection

func parentPID(of pid: pid_t) -> pid_t {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let result = sysctl(&mib, 4, &info, &size, nil, 0)
    if result == 0 {
        return info.kp_eproc.e_ppid
    }
    return -1
}

func detectTerminalBundleID() -> String? {
    let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.microsoft.VSCode",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.jetbrains.GoLand",
        "com.apple.dt.Xcode"
    ]
    var pid = getppid()
    while pid > 1 {
        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleID = app.bundleIdentifier,
           terminalBundleIDs.contains(bundleID) {
            return bundleID
        }
        pid = parentPID(of: pid)
    }
    return nil
}

// MARK: - Entry point

let args = CommandLine.arguments
let kBundleID = "com.shrimpy.notifier"
let kInstanceLockPath = "/tmp/com.shrimpy.notifier.lock"

func acquireInstanceLock() -> Int32? {
    let fd = open(kInstanceLockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    guard fd != -1 else { return nil }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        return fd
    }
    close(fd)
    return nil
}

// Single-instance guard: use a lock file so duplicate launches from either
// app bundle or raw binary path cannot create a second menubar icon.
let _instanceLockFD = acquireInstanceLock()

// Fallback bundle check kept for compatibility with older versions.
let _runningApps = NSWorkspace.shared.runningApplications
let _alreadyRunningByBundleID = _runningApps.contains {
    $0.bundleIdentifier == kBundleID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}
let _alreadyRunning = (_instanceLockFD == nil) || _alreadyRunningByBundleID

if args.count > 1 {
    let message = args[1]
    var customTitle: String? = nil
    let terminalBundleID = detectTerminalBundleID()

    // Parse --title flag
    var i = 2
    while i < args.count {
        if args[i] == "--title" && i + 1 < args.count {
            customTitle = args[i + 1]
            i += 2
        } else {
            i += 1
        }
    }

    if _alreadyRunning {
        var userInfo: [String: String] = [kNotificationMessageKey: message]
        if let title = customTitle { userInfo[kNotificationTitleKey] = title }
        if let tBundleID = terminalBundleID { userInfo[kTerminalBundleIDKey] = tBundleID }

        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(kNotificationName),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
        exit(0)
    }
    // Not running yet — fall through and become the app, fire on launch
    AppDelegate.initialMessage = message
    AppDelegate.initialTitle = customTitle
    AppDelegate.initialTerminalBundleID = terminalBundleID
}

// If already running as menubar app with no message to send, just exit
if _alreadyRunning { exit(0) }

// MARK: - App startup

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var initialMessage: String? = nil
    static var initialTitle: String? = nil
    static var initialTerminalBundleID: String? = nil

    var statusItem: NSStatusItem?
    var settingsWindowController: SettingsWindowController?
    var historyWindowController: HistoryWindowController?

    var muted: Bool = false
    var muteMenuItem: NSMenuItem?
    var lastTerminalBundleID: String? = nil
    var notificationHistory: [NotificationHistoryEntry] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupUNCenter()
        setupDistributedListener()
        ensureClaudeNotificationHookInstalled()

        if let message = AppDelegate.initialMessage {
            lastTerminalBundleID = AppDelegate.initialTerminalBundleID
            sendNotification(message: message, title: AppDelegate.initialTitle)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Status Item

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            if let url2x = Bundle.main.url(forResource: "ShrimpyBar@2x", withExtension: "png"),
               let image = NSImage(contentsOf: url2x) {
                image.size = NSSize(width: 22, height: 22)
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "🦐"
            }
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))

        let muteItem = NSMenuItem(title: "Mute Notifications", action: #selector(toggleMute), keyEquivalent: "")
        menu.addItem(muteItem)
        muteMenuItem = muteItem

        menu.addItem(NSMenuItem(title: "Notification History", action: #selector(openHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Test Notification", action: #selector(testNotification), keyEquivalent: ""))
        let supportItem = NSMenuItem(title: "Support Shrimpy ☕", action: #selector(openSupport), keyEquivalent: "")
        menu.addItem(supportItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }

        statusItem?.menu = menu
    }

    // MARK: - Claude Hook Sync

    func ensureClaudeNotificationHookInstalled() {
        let settingsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(kClaudeSettingsRelativePath)
        let fm = FileManager.default
        let hookCommand = currentClaudeHookCommand()

        do {
            try fm.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("Shrimpy: failed to create ~/.claude directory: %@", error.localizedDescription)
            return
        }

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settingsURL.path) {
            do {
                let data = try Data(contentsOf: settingsURL)
                if !data.isEmpty {
                    guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        NSLog("Shrimpy: ~/.claude/settings.json is not a JSON object; skipping hook sync")
                        return
                    }
                    root = parsed
                }
            } catch {
                NSLog("Shrimpy: failed to parse ~/.claude/settings.json: %@", error.localizedDescription)
                return
            }
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let notificationRules = (hooks["Notification"] as? [[String: Any]]) ?? []

        let commandHook: [String: Any] = [
            "type": "command",
            "command": hookCommand
        ]

        var changed = false
        var updatedRules: [[String: Any]] = []
        var injected = false

        for var rule in notificationRules {
            let matcher = (rule["matcher"] as? String) ?? ""
            var hookItems = (rule["hooks"] as? [[String: Any]]) ?? []

            // Remove any stale Shrimpy commands (different path or old open -gj format)
            let filtered = hookItems.filter { item in
                guard let cmd = item["command"] as? String else { return true }
                return !cmd.contains("Shrimpy.app")
            }
            if filtered.count != hookItems.count {
                hookItems = filtered
                changed = true
            }

            let hasCommand = hookItems.contains {
                ($0["type"] as? String) == "command" &&
                ($0["command"] as? String) == hookCommand
            }

            if matcher == "" && !hasCommand {
                hookItems.append(commandHook)
                rule["hooks"] = hookItems
                changed = true
                injected = true
            } else if matcher == "" && hasCommand {
                injected = true
            }

            updatedRules.append(rule)
        }

        if !injected {
            updatedRules.append([
                "matcher": "",
                "hooks": [commandHook]
            ])
            changed = true
        }

        if !changed {
            return
        }

        hooks["Notification"] = updatedRules
        root["hooks"] = hooks

        do {
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: settingsURL, options: .atomic)
        } catch {
            NSLog("Shrimpy: failed to write ~/.claude/settings.json: %@", error.localizedDescription)
        }
    }

    @objc func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController()
        }
        historyWindowController?.loadHistory(notificationHistory)
        historyWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func testNotification() {
        sendNotification(message: "This is a test notification")
    }

    @objc func toggleMute() {
        muted = !muted
        muteMenuItem?.title = muted ? "Unmute Notifications" : "Mute Notifications"
    }

    @objc func openSupport() {
        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/liam.hitchcock")!)
    }

    // MARK: - UNUserNotificationCenter

    func setupUNCenter() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let openAction = UNNotificationAction(
            identifier: kActionOpen,
            title: "Open Terminal",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: kCategoryID,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == kActionOpen ||
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            focusTerminal()
        }
        completionHandler()
    }

    func focusTerminal() {
        guard let bundleID = lastTerminalBundleID else { return }
        if let termApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            if #available(macOS 14.0, *) {
                termApp.activate()
            } else {
                termApp.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    // MARK: - Distributed Notifications

    func setupDistributedListener() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receivedDistributedNotification(_:)),
            name: NSNotification.Name(kNotificationName),
            object: nil
        )
    }

    @objc func receivedDistributedNotification(_ notification: NSNotification) {
        let message = (notification.userInfo?[kNotificationMessageKey] as? String) ?? "Needs your input"
        let title = notification.userInfo?[kNotificationTitleKey] as? String
        lastTerminalBundleID = notification.userInfo?[kTerminalBundleIDKey] as? String
        sendNotification(message: message, title: title)
    }

    // MARK: - Send Notification

    func playSound(named soundName: String) {
        let path = "/System/Library/Sounds/\(soundName).aiff"
        if let sound = NSSound(contentsOfFile: path, byReference: false) {
            sound.play()
        }
    }

    func sendNotification(message: String, title: String? = nil) {
        guard !muted else { return }

        let soundName = UserDefaults.standard.string(forKey: kSoundKey) ?? "Glass"
        playSound(named: soundName)

        let resolvedTitle = title ?? "Shrimpy"

        // Prepend to history, cap at 50
        let entry = NotificationHistoryEntry(message: message, title: resolvedTitle, timestamp: Date())
        notificationHistory.insert(entry, at: 0)
        if notificationHistory.count > 50 {
            notificationHistory = Array(notificationHistory.prefix(50))
        }

        let content = UNMutableNotificationContent()
        content.title = resolvedTitle
        content.body = message
        content.categoryIdentifier = kCategoryID

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("Shrimpy: failed to post notification: %@", error.localizedDescription)
            }
        }
    }
}

// MARK: - Settings Window Controller

class SettingsWindowController: NSWindowController {
    private var notifDot: NSTextField?
    private var notifLabel: NSTextField?
    private var notifButton: NSButton?
    private var hookButton: NSButton?
    private var hookDot: NSTextField?
    private var hookStatusLabel: NSTextField?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shrimpy Settings"
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        window.contentView = buildContentView()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshNotificationStatus()
        refreshHookStatus()
    }

    private func buildContentView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 390))

        // App running status row
        let appDot = NSTextField(labelWithString: "●")
        appDot.textColor = NSColor.systemGreen
        appDot.font = NSFont.systemFont(ofSize: 14)
        appDot.frame = NSRect(x: 20, y: 346, width: 20, height: 20)
        view.addSubview(appDot)

        let appLabel = NSTextField(labelWithString: "Shrimpy is running")
        appLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        appLabel.frame = NSRect(x: 44, y: 346, width: 280, height: 20)
        view.addSubview(appLabel)

        // Notification permission row
        let dot = NSTextField(labelWithString: "●")
        dot.font = NSFont.systemFont(ofSize: 14)
        dot.frame = NSRect(x: 20, y: 316, width: 20, height: 20)
        view.addSubview(dot)
        notifDot = dot

        let notifLbl = NSTextField(labelWithString: "Notifications: checking…")
        notifLbl.font = NSFont.systemFont(ofSize: 13)
        notifLbl.frame = NSRect(x: 44, y: 316, width: 180, height: 20)
        view.addSubview(notifLbl)
        notifLabel = notifLbl

        let notifBtn = NSButton(title: "", target: self, action: #selector(notifButtonTapped))
        notifBtn.bezelStyle = .rounded
        notifBtn.font = NSFont.systemFont(ofSize: 12)
        notifBtn.frame = NSRect(x: 234, y: 312, width: 106, height: 26)
        notifBtn.isHidden = true
        view.addSubview(notifBtn)
        notifButton = notifBtn

        // Claude hook status row
        let hDot = NSTextField(labelWithString: "●")
        hDot.font = NSFont.systemFont(ofSize: 14)
        hDot.frame = NSRect(x: 20, y: 286, width: 20, height: 20)
        view.addSubview(hDot)
        hookDot = hDot

        let hLabel = NSTextField(labelWithString: "Claude hook: checking…")
        hLabel.font = NSFont.systemFont(ofSize: 13)
        hLabel.frame = NSRect(x: 44, y: 286, width: 280, height: 20)
        view.addSubview(hLabel)
        hookStatusLabel = hLabel

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.frame = NSRect(x: 20, y: 268, width: 320, height: 1)
        view.addSubview(separator)

        // Sound label + picker
        let soundLabel = NSTextField(labelWithString: "Notification Sound:")
        soundLabel.font = NSFont.systemFont(ofSize: 13)
        soundLabel.frame = NSRect(x: 20, y: 230, width: 140, height: 20)
        view.addSubview(soundLabel)

        let sounds = ["Glass", "Tink", "Ping", "Pop", "Purr", "Basso", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse", "Sosumi", "Submarine"]
        let picker = NSPopUpButton(frame: NSRect(x: 165, y: 226, width: 175, height: 26))
        picker.addItems(withTitles: sounds)
        let currentSound = UserDefaults.standard.string(forKey: kSoundKey) ?? "Glass"
        picker.selectItem(withTitle: currentSound)
        picker.target = self
        picker.action = #selector(soundChanged(_:))
        view.addSubview(picker)

        // Launch at Login checkbox
        if #available(macOS 13.0, *) {
            let checkbox = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(launchAtLoginToggled(_:)))
            checkbox.frame = NSRect(x: 20, y: 190, width: 260, height: 20)
            checkbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
            view.addSubview(checkbox)
        }

        // Test button
        let testButton = NSButton(title: "Test Notification", target: self, action: #selector(testTapped))
        testButton.bezelStyle = .rounded
        testButton.frame = NSRect(x: 20, y: 150, width: 160, height: 28)
        view.addSubview(testButton)

        // History button
        let historyButton = NSButton(title: "Notification History…", target: self, action: #selector(historyTapped))
        historyButton.bezelStyle = .rounded
        historyButton.frame = NSRect(x: 20, y: 110, width: 200, height: 28)
        view.addSubview(historyButton)

        // Configure Claude Hook button
        let hookBtn = NSButton(title: "Configure Claude Hook", target: self, action: #selector(configureTapped))
        hookBtn.bezelStyle = .rounded
        hookBtn.font = NSFont.systemFont(ofSize: 13)
        hookBtn.frame = NSRect(x: 20, y: 72, width: 200, height: 28)
        view.addSubview(hookBtn)
        hookButton = hookBtn

        // Info text
        let info = NSTextField(wrappingLabelWithString: "Hook invocations post to this running instance. Launch once via 'open /Applications/Shrimpy.app' and it persists in your menubar.")
        info.font = NSFont.systemFont(ofSize: 11)
        info.textColor = NSColor.tertiaryLabelColor
        info.frame = NSRect(x: 20, y: 8, width: 320, height: 58)
        view.addSubview(info)

        return view
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { self?.applyNotifStatus(settings.authorizationStatus) }
        }
    }

    func refreshHookStatus() {
        let settingsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(kClaudeSettingsRelativePath)
        let hookCommand = currentClaudeHookCommand()
        var installed = false
        if let data = try? Data(contentsOf: settingsURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hooks = root["hooks"] as? [String: Any],
           let rules = hooks["Notification"] as? [[String: Any]] {
            installed = rules.contains { rule in
                ((rule["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["type"] as? String) == "command" && ($0["command"] as? String) == hookCommand
                }
            }
        }
        hookDot?.textColor = installed ? .systemGreen : .systemOrange
        hookStatusLabel?.stringValue = installed ? "Claude hook: Configured" : "Claude hook: Not configured"
    }

    private func applyNotifStatus(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized:
            notifDot?.textColor = .systemGreen
            notifLabel?.stringValue = "Notifications: Allowed"
            notifButton?.isHidden = true
        default:
            notifDot?.textColor = .systemOrange
            notifLabel?.stringValue = "Notifications: Not allowed"
            notifButton?.title = "Open Settings"
            notifButton?.isHidden = false
        }
    }

    @objc func notifButtonTapped() {
        // Register the app with the notification system, then send user to System Settings
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshNotificationStatus() }
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
    }

    @objc func soundChanged(_ sender: NSPopUpButton) {
        guard let selected = sender.selectedItem?.title else { return }
        UserDefaults.standard.set(selected, forKey: kSoundKey)
        let path = "/System/Library/Sounds/\(selected).aiff"
        if let sound = NSSound(contentsOfFile: path, byReference: false) {
            sound.play()
        }
    }

    @objc func launchAtLoginToggled(_ sender: NSButton) {
        if #available(macOS 13.0, *) {
            do {
                if sender.state == .on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                sender.state = sender.state == .on ? .off : .on
            }
        }
    }

    @objc func testTapped() {
        if let d = NSApp.delegate as? AppDelegate {
            d.sendNotification(message: "This is a test notification")
        }
    }

    @objc func historyTapped() {
        if let d = NSApp.delegate as? AppDelegate {
            d.openHistory()
        }
    }

    @objc func configureTapped() {
        if let d = NSApp.delegate as? AppDelegate {
            d.ensureClaudeNotificationHookInstalled()
        }
        refreshHookStatus()
        hookButton?.title = "✓ Done"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.hookButton?.title = "Configure Claude Hook"
        }
    }
}

// MARK: - History Window Controller

class HistoryWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {
    var history: [NotificationHistoryEntry] = []
    var tableView: NSTableView!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notification History"
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        window.contentView = buildContentView()
    }

    func loadHistory(_ entries: [NotificationHistoryEntry]) {
        history = entries
        tableView?.reloadData()
    }

    private func buildContentView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true

        let timeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeCol.title = "Time"
        timeCol.width = 80
        tableView.addTableColumn(timeCol)

        let titleCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleCol.title = "Title"
        titleCol.width = 120
        tableView.addTableColumn(titleCol)

        let messageCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        messageCol.title = "Message"
        messageCol.width = 280
        tableView.addTableColumn(messageCol)

        scrollView.documentView = tableView
        view.addSubview(scrollView)

        return view
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return history.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let entry = history[row]
        switch tableColumn?.identifier.rawValue {
        case "time":
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            return fmt.string(from: entry.timestamp)
        case "title":
            return entry.title
        case "message":
            return entry.message
        default:
            return nil
        }
    }
}
