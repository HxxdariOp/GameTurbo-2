import SwiftUI
import UIKit
import Foundation

// MARK: - Process model

enum ProcKind: String, CaseIterable {
    case app, appex, daemon, system, jailbreak, other

    var title: String {
        switch self {
        case .app: return "برنامه"
        case .appex: return "اکستنشن"
        case .daemon: return "دیمن"
        case .system: return "سیستم"
        case .jailbreak: return "جیلبریک"
        case .other: return "سایر"
        }
    }

    var color: Color {
        switch self {
        case .app: return Color.accentOrange
        case .appex: return Color.amber
        case .daemon: return Color.coolBlue
        case .system: return Color.badRed
        case .jailbreak: return Color.okGreen
        case .other: return Color.gray
        }
    }
}

struct Proc: Identifiable, Hashable {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let status: UInt32
    let nice: Int32
    let threads: Int32
    let footprint: UInt64
    let resident: UInt64
    let virtualSize: UInt64
    let cpuNs: UInt64
    let name: String
    let path: String
    var cpu: Double = 0

    var id: Int32 { pid }
    var mem: UInt64 { footprint > 0 ? footprint : resident }
    var stopped: Bool { status == 4 }
    var kind: ProcKind { Proc.classify(path: path, name: name) }

    static func classify(path: String, name: String) -> ProcKind {
        if name == "kernel_task" || name == "launchd" { return .system }
        if path.hasPrefix("/var/jb/") || path.hasPrefix("/private/preboot/") || path.contains("/procursus/")
            || path.contains("/.jbroot-") || path.contains("/jbroot-") {
            return .jailbreak
        }
        if path.contains(".appex/") { return .appex }
        if path.contains("/Bundle/Application/") || path.hasPrefix("/Applications/") { return .app }
        if path.hasPrefix("/usr/libexec") || path.hasPrefix("/usr/sbin") || path.hasPrefix("/sbin")
            || path.hasPrefix("/System/") || path.hasPrefix("/usr/bin") {
            return .daemon
        }
        return .other
    }
}

// MARK: - Protection (things that must never be killed)

enum Guard {
    static let hard: Set<String> = [
        "kernel_task", "launchd", "SpringBoard", "backboardd", "configd", "UserEventAgent",
        "powerd", "thermalmonitord", "mediaserverd", "notifyd", "cfprefsd", "securityd",
        "trustd", "installd", "lsd", "runningboardd", "fseventsd", "keybagd", "apsd",
        "CommCenter", "wifid", "bluetoothd", "distnoted", "containermanagerd",
        "mobile_installation_proxy", "jailbreakd", "launchdhook", "watchdogd", "syslogd",
        "logd", "mDNSResponder", "networkd", "assertiond", "locationd", "coreduetd",
        "dasd", "PerfTool", "ptroot", "AppleIDAuthAgent", "nfcd", "sandboxd", "amfid",
        "diskarbitrationd", "usbd", "lockdownd", "IOMFB_bics_daemon"
    ]

    static func isProtected(_ p: Proc) -> Bool {
        p.pid <= 1 || p.pid == getpid() || hard.contains(p.name) || p.kind == .system
    }

    static func labelProtected(_ label: String) -> Bool {
        let short = label.replacingOccurrences(of: "com.apple.", with: "")
        if hard.contains(short) { return true }
        let extra: Set<String> = ["mobile.lockdown", "mobile.installd", "SpringBoard", "backboardd"]
        return extra.contains(short) || label.hasPrefix("com.apple.xpc.launchd")
    }
}

// MARK: - Root execution

struct RootInfo {
    var available = false
    var helperPath = ""
    var helperExists = false
    var spawnInfo = ""
    var raw = ""
    var code: Int32 = 0
    var uid: Int? = nil
    var uidSelf = 0
    var nonRootRaw = ""
    var nonRootCode: Int32 = 0
    var entitlements: [String: Int] = [:]
    var canReadContainers = false
}

enum Root {
    static var available = false

    /// tiny C helper embedded in the app bundle (spawned with the root persona)
    static var helperPath: String { Bundle.main.bundlePath + "/ptroot" }

    static let launchctl: String? = {
        var candidates: [String] = []
        // roothide randomises the jailbreak root: /var/containers/Bundle/Application/.jbroot-XXXX/
        if let g = pt_glob("/var/containers/Bundle/Application/.jbroot-*/usr/bin/launchctl") {
            let found = String(cString: g).split(separator: "\n").map { String($0) }
            pt_free(g)
            candidates += found
        }
        candidates += ["/var/jb/usr/bin/launchctl", "/bin/launchctl", "/usr/bin/launchctl", "/sbin/launchctl"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }()

    /// spaces inside one argument are protected with 0x1F
    static func enc(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "\u{1F}") }

    static func shell(_ cmd: String, root: Bool) -> (code: Int32, out: String) {
        var out: UnsafeMutablePointer<CChar>? = nil
        let code = pt_run(cmd, root ? 1 : 0, &out)
        let s = out.map { String(cString: $0) } ?? ""
        if let out { pt_free(out) }
        return (code, s)
    }

    static func spawnDetached(_ cmd: String, root: Bool) -> Int32 {
        pt_spawn_detached(cmd, root ? 1 : 0)
    }

    /// Run a ptroot command (as root when available).
    static func helper(_ args: String) -> (code: Int32, out: String) {
        shell("\(helperPath) \(args)", root: available)
    }

    static func probe() -> RootInfo {
        var i = RootInfo()
        i.helperPath = helperPath
        i.helperExists = FileManager.default.isExecutableFile(atPath: helperPath)
        for k in ["com.apple.private.security.no-sandbox", "com.apple.private.persona-mgmt", "platform-application"] {
            i.entitlements[k] = Int(pt_entitlement(k))
        }
        i.canReadContainers = pt_can_read("/var/mobile/Containers/Data/Application") != 0
        i.uidSelf = Int(getuid())

        if i.helperExists {
            let r = shell("\(helperPath) whoami", root: true)
            i.spawnInfo = String(cString: pt_last_spawn_info())
            i.raw = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            i.code = r.code
            if let range = r.out.range(of: "ROOT:") {
                let digits = r.out[range.upperBound...].prefix { $0.isNumber }
                i.uid = Int(digits)
            }
            if i.uid == 0 {
                i.available = true
            } else {
                let r2 = shell("\(helperPath) whoami", root: false)
                i.nonRootRaw = r2.out.trimmingCharacters(in: .whitespacesAndNewlines)
                i.nonRootCode = r2.code
            }
        }
        available = i.available
        return i
    }

    static func kill(_ pids: [Int32], sig: Int32) -> String {
        if pids.isEmpty { return "" }
        if FileManager.default.isExecutableFile(atPath: helperPath) {
            return helper("kill \(sig) " + pids.map { String($0) }.joined(separator: " ")).out
        }
        var res = ""
        for p in pids {
            let r = Darwin.kill(p, sig)
            res += "\(p)|\(r == 0 ? "ok" : "fail")\n"
        }
        return res
    }

    static func renice(_ pids: [Int32], nice: Int) -> String {
        if pids.isEmpty { return "" }
        return helper("renice \(nice) " + pids.map { String($0) }.joined(separator: " ")).out
    }

    static func setPref(key: String, on: Bool) -> String {
        helper("setpref /var/mobile/Library/Preferences/com.apple.Accessibility.plist \(key) \(on ? 1 : 0)").out
    }
}

// MARK: - Cleaning categories

struct CleanCat: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let risk: Int            // 0 safe, 1 medium
    let patterns: [String]

    static let all: [CleanCat] = [
        CleanCat(id: "appcaches", title: "کش برنامه‌ها",
                 detail: "پوشه Caches و tmp همه برنامه‌ها و اکستنشن‌ها. برنامه‌های مستثنی‌شده پاک نمی‌شوند.",
                 icon: "square.stack.3d.up.fill", risk: 0,
                 patterns: ["/var/mobile/Containers/Data/Application/*/Library/Caches",
                            "/var/mobile/Containers/Data/Application/*/tmp",
                            "/var/mobile/Containers/Data/PluginKitPlugin/*/Library/Caches",
                            "/var/mobile/Containers/Data/PluginKitPlugin/*/tmp"]),
        CleanCat(id: "snapshots", title: "اسنپ‌شات اپ‌سوئیچر",
                 detail: "تصاویر پیش‌نمایش برنامه‌ها در چندوظیفگی؛ خودکار دوباره ساخته می‌شوند.",
                 icon: "photo.on.rectangle", risk: 0,
                 patterns: ["/var/mobile/Library/Caches/Snapshots",
                            "/var/mobile/Library/SplashBoard/Snapshots"]),
        CleanCat(id: "tmp", title: "فایل‌های موقت",
                 detail: "/tmp و /var/tmp",
                 icon: "clock.arrow.circlepath", risk: 0,
                 patterns: ["/var/tmp", "/tmp"]),
        CleanCat(id: "logs", title: "لاگ‌ها و گزارش‌های کرش",
                 detail: "CrashReporter و لاگ‌های سیستم.",
                 icon: "doc.text.fill", risk: 0,
                 patterns: ["/var/mobile/Library/Logs/CrashReporter",
                            "/var/mobile/Library/Logs/AppleSupport",
                            "/var/log"]),
        CleanCat(id: "webcache", title: "کش وب (سافاری و WebKit)",
                 detail: "کش صفحات وب؛ تاریخچه و رمزها دست‌نخورده می‌ماند.",
                 icon: "safari.fill", risk: 0,
                 patterns: ["/var/mobile/Library/Caches/com.apple.mobilesafari",
                            "/var/mobile/Library/Caches/com.apple.WebKit.*",
                            "/var/mobile/Library/Caches/Safari"]),
        CleanCat(id: "syscaches", title: "کش‌های عمیق سیستم",
                 detail: "نقشه‌ها و تصاویر کش‌شده؛ ممکن است اولین استفاده کمی کندتر شود.",
                 icon: "internaldrive.fill", risk: 1,
                 patterns: ["/var/mobile/Library/Caches/GeoServices",
                            "/var/mobile/Library/Caches/MappedImageCache"])
    ]
}

// MARK: - System sampler

@MainActor
final class SystemSampler: ObservableObject {
    @Published var cpu = 0.0
    @Published var cores: [Double] = []
    @Published var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published var memUsed: UInt64 = 0
    @Published var memCached: UInt64 = 0
    @Published var memFree: UInt64 = 0
    @Published var memWired: UInt64 = 0
    @Published var memCompressed: UInt64 = 0
    @Published var pressure = 0
    @Published var gpu: Double? = nil
    @Published var gpuRender: Double? = nil
    @Published var gpuTiler: Double? = nil
    @Published var gpuMemMB: Double? = nil
    @Published var cpuHist: [Double] = []
    @Published var memHist: [Double] = []
    @Published var gpuHist: [Double] = []
    @Published var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published var battery: Float = -1
    @Published var charging = false
    @Published var lowPower = false
    @Published var diskFree: UInt64 = 0
    @Published var diskTotal: UInt64 = 0

    private var prevBusy = [UInt64](repeating: 0, count: 16)
    private var prevTotal = [UInt64](repeating: 0, count: 16)
    private var havePrev = false
    private var timer: Timer?
    private var tick = 0

    static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        if size <= 0 { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static let model = sysctlString("hw.machine")

    func start() {
        stop()
        UIDevice.current.isBatteryMonitoringEnabled = true
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > 60 { a.removeFirst(a.count - 60) }
    }

    func sample() {
        var busy = [UInt64](repeating: 0, count: 16)
        var total = [UInt64](repeating: 0, count: 16)
        let n = Int(pt_cpu(&busy, &total, 16))
        if n > 0 {
            var per: [Double] = []
            var sumB = 0.0, sumT = 0.0
            for i in 0..<n {
                let db = Double(busy[i] &- prevBusy[i])
                let dt = Double(total[i] &- prevTotal[i])
                per.append(havePrev && dt > 0 ? min(100, db / dt * 100) : 0)
                sumB += db
                sumT += dt
            }
            cores = per
            cpu = havePrev && sumT > 0 ? min(100, sumB / sumT * 100) : 0
            prevBusy = busy
            prevTotal = total
            havePrev = true
            push(&cpuHist, cpu)
        }

        var m = [UInt64](repeating: 0, count: 8)
        if pt_mem(&m) != 0 {
            memFree = m[0]
            memWired = m[3]
            memCompressed = m[4]
            memUsed = m[1] + m[3] + m[4]
            memCached = m[2] + m[5]
            push(&memHist, Double(memUsed) / Double(max(memTotal, 1)) * 100)
        }
        pressure = Int(pt_pressure())

        var d = -1.0, r = -1.0, t = -1.0, mm = -1.0
        if pt_gpu(&d, &r, &t, &mm) != 0 {
            gpu = d >= 0 ? d : nil
            gpuRender = r >= 0 ? r : nil
            gpuTiler = t >= 0 ? t : nil
            gpuMemMB = mm >= 0 ? mm : nil
            if let g = gpu { push(&gpuHist, g) }
        } else {
            gpu = nil
        }

        tick += 1
        if tick % 5 == 1 { updateSlow() }
    }

    private func updateSlow() {
        thermal = ProcessInfo.processInfo.thermalState
        battery = UIDevice.current.batteryLevel
        let st = UIDevice.current.batteryState
        charging = (st == .charging || st == .full)
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let a = try? FileManager.default.attributesOfFileSystem(forPath: "/var") {
            diskFree = (a[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            diskTotal = (a[.systemSize] as? NSNumber)?.uint64Value ?? 0
        }
    }

    var pressureText: String {
        switch pressure {
        case 1: return "عادی"
        case 2: return "هشدار"
        case 4: return "بحرانی"
        default: return "نامشخص"
        }
    }

    var pressureColor: Color {
        switch pressure {
        case 1: return Color.okGreen
        case 2: return Color.amber
        case 4: return Color.badRed
        default: return Color.gray
        }
    }

    var thermalText: String {
        switch thermal {
        case .nominal: return "عادی"
        case .fair: return "کمی گرم"
        case .serious: return "داغ"
        case .critical: return "بحرانی"
        @unknown default: return "نامشخص"
        }
    }

    var thermalColor: Color {
        switch thermal {
        case .nominal: return Color.okGreen
        case .fair: return Color.amber
        case .serious: return Color.deepOrange
        case .critical: return Color.badRed
        @unknown default: return Color.gray
        }
    }
}
