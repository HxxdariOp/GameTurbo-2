import SwiftUI
import Foundation

// MARK: - Settings

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var allow: [String] { didSet { d.set(allow, forKey: "allow") } }
    @Published var cacheExclude: [String] { didSet { d.set(cacheExclude, forKey: "cacheExclude") } }
    @Published var guardOn: Bool { didSet { d.set(guardOn, forKey: "guardOn") } }
    @Published var guardCPU: Double { didSet { d.set(guardCPU, forKey: "guardCPU") } }
    @Published var guardAction: Int { didSet { d.set(guardAction, forKey: "guardAction") } }
    @Published var interval: Double { didSet { d.set(interval, forKey: "interval") } }
    @Published var tClean: Bool { didSet { d.set(tClean, forKey: "tClean") } }
    @Published var tDaemons: Bool { didSet { d.set(tDaemons, forKey: "tDaemons") } }
    @Published var tApps: Bool { didSet { d.set(tApps, forKey: "tApps") } }
    @Published var tHogs: Bool { didSet { d.set(tHogs, forKey: "tHogs") } }
    @Published var tPurge: Bool { didSet { d.set(tPurge, forKey: "tPurge") } }
    @Published var fancy: Bool { didSet { d.set(fancy, forKey: "fancy") } }
    @Published var gameApp: String { didSet { d.set(gameApp, forKey: "gameApp") } }
    @Published var gameMinutes: Int { didSet { d.set(gameMinutes, forKey: "gameMinutes") } }
    @Published var gameNice: Int { didSet { d.set(gameNice, forKey: "gameNice") } }
    @Published var gameFreeze: Bool { didSet { d.set(gameFreeze, forKey: "gameFreeze") } }
    @Published var gamePrep: Bool { didSet { d.set(gamePrep, forKey: "gamePrep") } }

    init() {
        allow = d.stringArray(forKey: "allow") ?? ["Filza", "Sileo", "Zebra", "TrollStore", "Dopamine", "NewTerm"]
        cacheExclude = d.stringArray(forKey: "cacheExclude")
            ?? ["com.spotify.client", "com.netflix.Netflix", "com.apple.Music", "com.apple.podcasts"]
        guardOn = d.bool(forKey: "guardOn")
        let gc = d.double(forKey: "guardCPU")
        guardCPU = gc == 0 ? 60 : gc
        guardAction = d.integer(forKey: "guardAction")
        let iv = d.double(forKey: "interval")
        interval = iv == 0 ? 3 : iv
        tClean = d.object(forKey: "tClean") as? Bool ?? true
        tDaemons = d.object(forKey: "tDaemons") as? Bool ?? false
        tApps = d.object(forKey: "tApps") as? Bool ?? true
        tHogs = d.object(forKey: "tHogs") as? Bool ?? true
        tPurge = d.object(forKey: "tPurge") as? Bool ?? true
        fancy = d.bool(forKey: "fancy")
        gameApp = d.string(forKey: "gameApp") ?? ""
        let gm = d.integer(forKey: "gameMinutes")
        gameMinutes = gm == 0 ? 30 : gm
        gameNice = d.object(forKey: "gameNice") as? Int ?? -10
        gameFreeze = d.object(forKey: "gameFreeze") as? Bool ?? true
        gamePrep = d.object(forKey: "gamePrep") as? Bool ?? true
    }
}

// MARK: - Root state

@MainActor
final class RootState: ObservableObject {
    @Published var info = RootInfo()
    @Published var available = false
    @Published var probing = false

    func probe() async {
        probing = true
        let i = await Task.detached { Root.probe() }.value
        info = i
        available = i.available
        probing = false
    }
}

// MARK: - Processes

@MainActor
final class ProcessStore: ObservableObject {
    @Published var procs: [Proc] = []
    @Published var guardLog: [String] = []

    weak var settings: AppSettings?
    private var prevCPU: [Int32: UInt64] = [:]
    private var prevTime: UInt64 = 0
    private var hot: [Int32: Int] = [:]
    private var busy = false

    func refresh() async {
        if busy { return }
        busy = true
        defer { busy = false }

        let useRoot = Root.available
        let text = await Task.detached(priority: .userInitiated) { () -> String in
            if useRoot {
                let r = Root.helper("snapshot").out
                if r.contains("|") { return r }
            }
            let p = pt_snapshot()
            let s = p.map { String(cString: $0) } ?? ""
            pt_free(p)
            return s
        }.value

        let now = DispatchTime.now().uptimeNanoseconds
        let dt = prevTime > 0 ? Double(now &- prevTime) : 0
        var list: [Proc] = []
        var newPrev: [Int32: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "|", maxSplits: 11, omittingEmptySubsequences: false)
            guard f.count >= 12, let pid = Int32(f[0]) else { continue }
            var p = Proc(pid: pid,
                         ppid: Int32(f[1]) ?? 0,
                         uid: UInt32(f[2]) ?? 0,
                         status: UInt32(f[3]) ?? 0,
                         nice: Int32(f[4]) ?? 0,
                         threads: Int32(f[5]) ?? 0,
                         footprint: UInt64(f[6]) ?? 0,
                         resident: UInt64(f[7]) ?? 0,
                         virtualSize: UInt64(f[8]) ?? 0,
                         cpuNs: UInt64(f[9]) ?? 0,
                         name: String(f[10]),
                         path: String(f[11]))
            if dt > 0, let old = prevCPU[pid], p.cpuNs >= old {
                p.cpu = Double(p.cpuNs - old) / dt * 100
            }
            newPrev[pid] = p.cpuNs
            list.append(p)
        }
        prevCPU = newPrev
        prevTime = now
        procs = list

        if let s = settings, s.guardOn { applyGuard(list, s) }
    }

    private func applyGuard(_ list: [Proc], _ s: AppSettings) {
        var hotNow: Set<Int32> = []
        for p in list where p.cpu > s.guardCPU && !Guard.isProtected(p) && !s.allow.contains(p.name) {
            hotNow.insert(p.pid)
            hot[p.pid, default: 0] += 1
            if hot[p.pid, default: 0] >= 3 {
                hot[p.pid] = 0
                let pid = p.pid
                let action = s.guardAction
                let name = p.name
                Task.detached {
                    switch action {
                    case 1: _ = Root.kill([pid], sig: SIGSTOP)
                    case 2: _ = Root.kill([pid], sig: SIGTERM)
                    default: _ = Root.renice([pid], nice: 15)
                    }
                }
                let what = action == 1 ? "منجمد شد" : (action == 2 ? "بسته شد" : "اولویتش کم شد")
                guardLog.insert("\(name) (PID \(fnum(Int(pid)))) \(what)", at: 0)
                if guardLog.count > 30 { guardLog.removeLast() }
            }
        }
        hot = hot.filter { hotNow.contains($0.key) }
    }

    func killAsync(_ pids: [Int32], sig: Int32) async {
        _ = await Task.detached { Root.kill(pids, sig: sig) }.value
        try? await Task.sleep(nanoseconds: 300_000_000)
        await refresh()
    }

    func reniceAsync(_ pids: [Int32], nice: Int) async {
        _ = await Task.detached { Root.renice(pids, nice: nice) }.value
        await refresh()
    }

    func respring() async {
        if procs.isEmpty { await refresh() }
        if let p = procs.first(where: { $0.name == "SpringBoard" }) {
            let pid = p.pid
            _ = await Task.detached { Root.kill([pid], sig: SIGKILL) }.value
        }
    }
}

// MARK: - Daemons (launchd jobs)

struct Job: Identifiable, Hashable {
    let label: String
    let pid: Int32?
    let status: Int
    let domain: String
    var id: String { domain + "/" + label }
    var running: Bool { pid != nil }
}

struct DaemonPreset: Identifiable {
    let label: String
    let title: String
    let detail: String
    let risk: Int     // 0 safe, 1 medium, 2 high
    var id: String { label }

    static let all: [DaemonPreset] = [
        DaemonPreset(label: "com.apple.analyticsd", title: "Analytics", detail: "جمع‌آوری و ارسال داده‌های استفاده", risk: 0),
        DaemonPreset(label: "com.apple.aggregated", title: "Aggregated", detail: "آمارگیری مصرف و تله‌متری", risk: 0),
        DaemonPreset(label: "com.apple.awdd", title: "AWD", detail: "تشخیص‌های بی‌سیم و ارسال گزارش", risk: 0),
        DaemonPreset(label: "com.apple.wifianalyticsd", title: "Wi‑Fi Analytics", detail: "تحلیل کیفیت Wi‑Fi برای اپل", risk: 0),
        DaemonPreset(label: "com.apple.osanalytics.osanalyticshelper", title: "OS Analytics", detail: "کمک‌کننده گزارش‌های سیستم", risk: 0),
        DaemonPreset(label: "com.apple.ReportCrash", title: "ReportCrash", detail: "ساخت گزارش کرش (CPU هنگام کرش)", risk: 0),
        DaemonPreset(label: "com.apple.spindump", title: "Spindump", detail: "نمونه‌برداری از پردازه‌های هنگ‌کرده", risk: 0),
        DaemonPreset(label: "com.apple.hangtracerd", title: "Hang Tracer", detail: "ردیابی هنگ‌ها برای عیب‌یابی", risk: 0),
        DaemonPreset(label: "com.apple.touristd", title: "Tourist", detail: "نکته‌ها و «چه چیز جدید است»", risk: 0),
        DaemonPreset(label: "com.apple.tipsd", title: "Tips", detail: "برنامه نکته‌ها", risk: 0),
        DaemonPreset(label: "com.apple.mediaanalysisd", title: "Media Analysis", detail: "تحلیل چهره و اشیای عکس‌ها؛ پرمصرف CPU ولی جستجوی هوشمند عکس را از کار می‌اندازد", risk: 1),
        DaemonPreset(label: "com.apple.photoanalysisd", title: "Photo Analysis", detail: "تحلیل عکس‌ها در پس‌زمینه", risk: 1),
        DaemonPreset(label: "com.apple.parsecd", title: "Parsec", detail: "پیشنهادهای آنلاین Siri و Spotlight", risk: 1),
        DaemonPreset(label: "com.apple.suggestd", title: "Suggestions", detail: "پیشنهادهای Siri در برنامه‌ها", risk: 1),
        DaemonPreset(label: "com.apple.duetexpertd", title: "Duet Expert", detail: "پیش‌بینی رفتار و برنامه بعدی", risk: 1),
        DaemonPreset(label: "com.apple.siriknowledged", title: "Siri Knowledge", detail: "دانش پس‌زمینه Siri", risk: 1),
        DaemonPreset(label: "com.apple.corespeechd", title: "Core Speech", detail: "تشخیص «Hey Siri»", risk: 1),
        DaemonPreset(label: "com.apple.avatarsd", title: "Avatars", detail: "میموجی و آواتارها", risk: 1),
        DaemonPreset(label: "com.apple.rapportd", title: "Rapport", detail: "ارتباط دستگاه‌های اپل (Handoff)", risk: 1),
        DaemonPreset(label: "com.apple.sharingd", title: "Sharing", detail: "AirDrop و Handoff", risk: 1),
        DaemonPreset(label: "com.apple.symptomsd", title: "Symptoms", detail: "تشخیص مشکلات شبکه (Wi‑Fi Assist)", risk: 1),
        DaemonPreset(label: "com.apple.cloudd", title: "CloudKit", detail: "همگام‌سازی iCloud — غیرفعال‌سازی باعث توقف همگام‌سازی می‌شود", risk: 2),
        DaemonPreset(label: "com.apple.searchd", title: "Search", detail: "جستجوی Spotlight", risk: 2),
        DaemonPreset(label: "com.apple.mobile.softwareupdated", title: "Software Update", detail: "به‌روزرسانی iOS", risk: 2),
        DaemonPreset(label: "com.apple.softwareupdateservicesd", title: "Update Services", detail: "سرویس‌های به‌روزرسانی", risk: 2)
    ]
}

@MainActor
final class DaemonStore: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var disabled: Set<String> = []
    @Published var log: [String] = []
    @Published var loading = false
    @Published var error: String?

    func addLog(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 40 { log.removeLast() }
    }

    nonisolated static func clip(_ s: String, _ n: Int = 140) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    nonisolated static func parse(_ s: String, domain: String) -> [Job] {
        var out: [Job] = []
        for line in s.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3, parts[0] != "PID" else { continue }
            let pid = Int32(parts[0].trimmingCharacters(in: .whitespaces))
            let st = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            let label = String(parts[2]).trimmingCharacters(in: .whitespaces)
            if label.isEmpty { continue }
            out.append(Job(label: label, pid: pid, status: st, domain: domain))
        }
        return out
    }

    func refresh() async {
        guard let lc = Root.launchctl else {
            error = "ابزار launchctl روی این دستگاه پیدا نشد."
            return
        }
        error = nil
        loading = true
        let root = Root.available
        let res = await Task.detached { () -> (String, String, String) in
            let a = Root.shell("\(lc) list", root: root).out
            let b = root ? Root.shell("\(lc) list", root: false).out : ""
            let c = Root.shell("\(lc) print-disabled system", root: root).out
            return (a, b, c)
        }.value

        var all = DaemonStore.parse(res.0, domain: root ? "system" : "user/501")
        if root { all += DaemonStore.parse(res.1, domain: "user/501") }
        jobs = all.sorted { $0.label < $1.label }

        var dis: Set<String> = []
        for line in res.2.split(separator: "\n") {
            guard let r = line.range(of: "=>") else { continue }
            let key = line[..<r.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            let val = line[r.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            if val.hasPrefix("disabled") || val.hasPrefix("true") { dis.insert(key) }
        }
        disabled = dis
        if jobs.isEmpty {
            error = "لیست سرویس‌ها خالی است. خروجی launchctl: " + DaemonStore.clip(res.0)
        }
        loading = false
    }

    func job(for label: String) -> Job? { jobs.first { $0.label == label } }

    func isDisabled(_ label: String) -> Bool { disabled.contains(label) }

    /// Strong disable ladder: disable -> bootout -> verify -> SIGKILL -> (if respawned) SIGSTOP.
    func disable(label: String, domain: String, pid: Int32?) async {
        guard let lc = Root.launchctl else { addLog("launchctl پیدا نشد"); return }
        if Guard.labelProtected(label) {
            addLog("⛔️ \(label) محافظت‌شده است و دست نمی‌خورد.")
            return
        }
        let root = Root.available
        if !root { addLog("⚠️ Root فعال نیست؛ احتمالاً این عملیات رد می‌شود.") }
        let target = "\(domain)/\(label)"

        let report = await Task.detached { () -> String in
            var log = ""
            let a = Root.shell("\(lc) disable \(target)", root: root)
            log += "disable[\(a.code)] \(DaemonStore.clip(a.out))\n"
            let b = Root.shell("\(lc) bootout \(target)", root: root)
            log += "bootout[\(b.code)] \(DaemonStore.clip(b.out))\n"

            let list1 = Root.shell("\(lc) list", root: root).out
            let still = DaemonStore.parse(list1, domain: domain).first { $0.label == label }?.pid
            if let p = still {
                _ = Root.kill([p], sig: SIGKILL)
                usleep(1_300_000)
                let list2 = Root.shell("\(lc) list", root: root).out
                let again = DaemonStore.parse(list2, domain: domain).first { $0.label == label }?.pid
                if let p2 = again {
                    _ = Root.kill([p2], sig: SIGSTOP)
                    log += "دوباره بالا آمد ← منجمد شد (PID \(p2))\n"
                } else {
                    log += "پردازه بسته شد\n"
                }
            } else {
                log += "از لیست خارج شد (unload)\n"
            }
            return log
        }.value
        addLog("غیرفعال‌سازی \(label):\n" + report.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func enable(label: String, domain: String) async {
        guard let lc = Root.launchctl else { return }
        let root = Root.available
        let target = "\(domain)/\(label)"
        let out = await Task.detached { () -> String in
            var o = ""
            o += Root.shell("\(lc) enable \(target)", root: root).out
            let plists = ["/System/Library/LaunchDaemons/\(label).plist", "/Library/LaunchDaemons/\(label).plist"]
            if let plist = plists.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                o += Root.shell("\(lc) bootstrap \(domain) \(plist)", root: root).out
            }
            o += Root.shell("\(lc) kickstart \(target)", root: root).out
            return o
        }.value
        addLog("فعال شد: \(label) \(DaemonStore.clip(out, 80))")
    }

    func stopOnce(_ job: Job) async {
        guard let lc = Root.launchctl else { return }
        if Guard.labelProtected(job.label) {
            addLog("⛔️ \(job.label) محافظت‌شده است.")
            return
        }
        let root = Root.available
        let target = "\(job.domain)/\(job.label)"
        let pid = job.pid
        let out = await Task.detached { () -> String in
            let r = Root.shell("\(lc) kill SIGTERM \(target)", root: root)
            if r.code != 0, let pid {
                return "launchctl[\(r.code)] \(DaemonStore.clip(r.out)) ← kill مستقیم: " + DaemonStore.clip(Root.kill([pid], sig: SIGTERM))
            }
            return DaemonStore.clip(r.out)
        }.value
        addLog("توقف موقت: \(job.label) \(out)")
    }

    func freeze(_ j: Job) async {
        guard let pid = j.pid else { return }
        if Guard.labelProtected(j.label) { addLog("⛔️ \(j.label) محافظت‌شده است."); return }
        let out = await Task.detached { Root.kill([pid], sig: SIGSTOP) }.value
        addLog("منجمد شد: \(j.label) (PID \(fnum(Int(pid)))) \(DaemonStore.clip(out, 60))")
    }

    func thaw(_ j: Job) async {
        guard let pid = j.pid else { return }
        let out = await Task.detached { Root.kill([pid], sig: SIGCONT) }.value
        addLog("ادامه یافت: \(j.label) \(DaemonStore.clip(out, 60))")
    }

    /// Disable every risk-0 preset that exists on this device.
    func applySafePack() async -> Int {
        await refresh()
        var n = 0
        for p in DaemonPreset.all where p.risk == 0 {
            if let j = job(for: p.label), !isDisabled(p.label) {
                await disable(label: j.label, domain: j.domain, pid: j.pid)
                n += 1
            }
        }
        await refresh()
        return n
    }

    func restoreAllPresets() async -> Int {
        await refresh()
        var n = 0
        for p in DaemonPreset.all where isDisabled(p.label) {
            await enable(label: p.label, domain: job(for: p.label)?.domain ?? "system")
            n += 1
        }
        await refresh()
        return n
    }
}

// MARK: - Cleaner

@MainActor
final class CleanerStore: ObservableObject {
    @Published var sizes: [String: UInt64] = [:]
    @Published var selected: Set<String> = ["snapshots", "tmp", "logs", "appcaches", "webcache"]
    @Published var scanning = false
    @Published var cleaning = false
    @Published var freed: UInt64 = 0

    var totalSelected: UInt64 {
        selected.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    nonisolated static func containerID(of path: String) -> String? {
        var root: String?
        for marker in ["/Library/", "/tmp"] {
            if let r = path.range(of: marker) { root = String(path[..<r.lowerBound]); break }
        }
        guard let root else { return nil }
        let d = NSDictionary(contentsOfFile: root + "/.com.apple.mobile_container_manager.metadata.plist")
        return d?["MCMMetadataIdentifier"] as? String
    }

    nonisolated static func resolve(_ cat: CleanCat, exclude: Set<String>) -> [String] {
        var out: [String] = []
        for pat in cat.patterns {
            let r = Root.helper("glob \(Root.enc(pat))").out
            for line in r.split(separator: "\n") where line.hasPrefix("/") { out.append(String(line)) }
        }
        if cat.id == "appcaches" {
            out = out.filter { path in
                if let id = containerID(of: path), exclude.contains(id) { return false }
                return true
            }
        }
        return out
    }

    nonisolated static func sumCmd(_ cmd: String, paths: [String]) -> UInt64 {
        var total: UInt64 = 0
        var i = 0
        while i < paths.count {
            let chunk = Array(paths[i..<min(i + 100, paths.count)])
            let out = Root.helper("\(cmd) " + chunk.map { Root.enc($0) }.joined(separator: " ")).out
            let last = out.split(separator: "\n").last.map { String($0) } ?? ""
            total += UInt64(last.trimmingCharacters(in: .whitespaces)) ?? 0
            i += 100
        }
        return total
    }

    func scan(exclude: [String]) async {
        scanning = true
        let ex = Set(exclude)
        let d = await Task.detached { () -> [String: UInt64] in
            var r: [String: UInt64] = [:]
            for cat in CleanCat.all {
                let paths = CleanerStore.resolve(cat, exclude: ex)
                r[cat.id] = CleanerStore.sumCmd("dusum", paths: paths)
            }
            return r
        }.value
        sizes = d
        scanning = false
    }

    func clean(exclude: [String], ids: Set<String>? = nil) async {
        let target = ids ?? selected
        if target.isEmpty { return }
        cleaning = true
        let ex = Set(exclude)
        let total = await Task.detached { () -> UInt64 in
            var t: UInt64 = 0
            for cat in CleanCat.all where target.contains(cat.id) {
                let paths = CleanerStore.resolve(cat, exclude: ex)
                t += CleanerStore.sumCmd("rmc", paths: paths)
            }
            return t
        }.value
        freed = total
        cleaning = false
        await scan(exclude: exclude)
    }
}

// MARK: - Booster (Turbo + Game mode)

@MainActor
final class Booster: ObservableObject {
    @Published var log: [String] = []
    @Published var running = false
    @Published var gameRunning = false
    @Published var gameInfo = ""

    /// processes that are safe to pause during a game session (analytics / background analysis)
    static let freezeNames = [
        "analyticsd", "aggregated", "awdd", "wifianalyticsd", "mediaanalysisd", "photoanalysisd",
        "parsecd", "suggestd", "duetexpertd", "siriknowledged", "ReportCrash", "spindump",
        "hangtracerd", "osanalyticshelper"
    ]

    func add(_ s: String) { log.append(s) }

    func purge(sampler: SystemSampler) async -> UInt64 {
        sampler.sample()
        let freeMB = (sampler.memFree + sampler.memCached / 2) / 1_048_576
        let capMB = sampler.memTotal / 1_048_576 * 4 / 10
        let target = min(freeMB, capMB)
        if target < 64 { return 0 }
        return await Task.detached { pt_purge(target) }.value
    }

    func killBackgroundApps(procs: ProcessStore, settings: AppSettings) async -> Int {
        await procs.refresh()
        let targets = procs.procs.filter {
            $0.kind == .app && !Guard.isProtected($0) && !settings.allow.contains($0.name)
                && $0.name != settings.gameApp
        }
        if targets.isEmpty { return 0 }
        let pids = targets.map { $0.pid }
        _ = await Task.detached { Root.kill(pids, sig: SIGKILL) }.value
        return targets.count
    }

    func reniceHogs(procs: ProcessStore, settings: AppSettings) async -> Int {
        await procs.refresh()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await procs.refresh()
        let hogs = procs.procs.filter {
            $0.cpu > 25 && !Guard.isProtected($0) && !settings.allow.contains($0.name)
                && $0.name != settings.gameApp
        }
        if hogs.isEmpty { return 0 }
        let pids = hogs.map { $0.pid }
        _ = await Task.detached { Root.renice(pids, nice: 15) }.value
        return hogs.count
    }

    func turbo(sampler: SystemSampler, procs: ProcessStore, daemons: DaemonStore,
               cleaner: CleanerStore, settings: AppSettings) async {
        if running { return }
        running = true
        log = []
        sampler.sample()
        let before = sampler.memFree + sampler.memCached
        add("شروع توربو… حافظه آزاد: \(fmtBytes(before))")

        if settings.tClean {
            add("🧹 پاک‌سازی کش و فایل‌های موقت…")
            await cleaner.clean(exclude: settings.cacheExclude,
                                ids: ["snapshots", "tmp", "logs", "appcaches", "webcache"])
            add("   \(fmtBytes(cleaner.freed)) فضا آزاد شد")
        }
        if settings.tDaemons {
            add("⚙️ غیرفعال‌سازی دیمن‌های امن…")
            let n = await daemons.applySafePack()
            add("   \(fnum(n)) سرویس غیرفعال شد")
        }
        if settings.tApps {
            add("📱 بستن برنامه‌های پس‌زمینه…")
            let n = await killBackgroundApps(procs: procs, settings: settings)
            add("   \(fnum(n)) برنامه بسته شد")
        }
        if settings.tHogs {
            add("🔥 کاهش اولویت پردازه‌های پرمصرف…")
            let n = await reniceHogs(procs: procs, settings: settings)
            add("   \(fnum(n)) پردازه کند شد")
        }
        if settings.tPurge {
            add("🧠 تخلیه حافظه (فشار به کرنل برای آزادسازی کش)…")
            let mb = await purge(sampler: sampler)
            add("   تا \(fnum(Int(mb))) مگابایت فشار آورده شد")
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        sampler.sample()
        let after = sampler.memFree + sampler.memCached
        add("✅ پایان. حافظه آزاد: \(fmtBytes(after))")
        running = false
    }

    // MARK: Game mode — a separate root process keeps working while the game is in front

    func gameStatus() async {
        let out = await Task.detached { Root.helper("gamestatus").out }.value
        gameRunning = out.contains("RUNNING")
    }

    func startGame(sampler: SystemSampler, procs: ProcessStore, daemons: DaemonStore,
                   cleaner: CleanerStore, settings: AppSettings, rootOK: Bool) async {
        if !rootOK {
            gameInfo = "❌ Root فعال نیست؛ حالت بازی بدون root کار نمی‌کند."
            return
        }
        if settings.gamePrep {
            await turbo(sampler: sampler, procs: procs, daemons: daemons, cleaner: cleaner, settings: settings)
        }
        let app = settings.gameApp.trimmingCharacters(in: .whitespaces)
        let appArg = app.isEmpty ? "-" : Root.enc(app)
        let names = settings.gameFreeze ? Booster.freezeNames.joined(separator: ",") : "-"
        let secs = settings.gameMinutes * 60
        let nice = settings.gameNice
        let pid = Root.spawnDetached("\(Root.helperPath) gamemode \(secs) \(appArg) \(nice) \(names)", root: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await gameStatus()
        if pid > 0 && gameRunning {
            gameInfo = "✅ فعال شد برای \(fnum(settings.gameMinutes)) دقیقه. حالا وارد بازی شوید."
        } else {
            gameInfo = "❌ اجرا نشد: " + String(cString: pt_last_spawn_info())
        }
    }

    func stopGame() async {
        _ = await Task.detached { Root.helper("gamestop").out }.value
        let names = Booster.freezeNames.joined(separator: ",")
        _ = await Task.detached { Root.helper("resume \(names)").out }.value
        await gameStatus()
        gameInfo = "⏹ متوقف شد؛ سرویس‌های منجمد آزاد شدند."
    }
}
