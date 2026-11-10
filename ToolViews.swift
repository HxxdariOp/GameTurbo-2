import SwiftUI
import UIKit

func riskInfo(_ r: Int) -> (String, Color) {
    switch r {
    case 0: return ("امن", Color.okGreen)
    case 1: return ("متوسط", Color.amber)
    default: return ("پرخطر", Color.badRed)
    }
}

// MARK: - Daemons

struct DaemonsView: View {
    @EnvironmentObject var daemons: DaemonStore
    @EnvironmentObject var procs: ProcessStore
    @EnvironmentObject var rootState: RootState
    @State private var mode = 0
    @State private var search = ""
    @State private var onlyRunning = true
    @State private var confirm: DaemonPreset?
    @State private var busy = false
    @State private var limit = 60

    var filteredJobs: [Job] {
        daemons.jobs.filter { j in
            if j.label.hasPrefix("UIKitApplication:") || j.label.hasPrefix("0x") || j.label.hasPrefix("application.") { return false }
            if onlyRunning && !j.running { return false }
            return search.isEmpty || j.label.localizedCaseInsensitiveContains(search)
        }
    }

    func proc(of j: Job?) -> Proc? {
        guard let pid = j?.pid else { return nil }
        return procs.procs.first { $0.pid == pid }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                HStack {
                    Text("دیمن‌ها").font(.largeTitle.bold())
                    Spacer()
                    if daemons.loading || busy { ProgressView() }
                    Button { Task { await daemons.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(GlassIconStyle())
                }
                Picker("", selection: $mode) {
                    Text("پیشنهادها").tag(0)
                    Text("همه سرویس‌ها").tag(1)
                }
                .pickerStyle(.segmented)

                if !rootState.available {
                    Text("⚠️ Root فعال نیست؛ مدیریت دیمن‌ها کار نمی‌کند. وضعیت دقیق در بهینه‌سازی ← تنظیمات.")
                        .font(.caption).foregroundColor(Color.amber).glass(radius: 16, tint: Color.amber, pad: 12)
                }
                if let e = daemons.error {
                    Text(e).font(.footnote).foregroundColor(Color.amber).glass(radius: 16, tint: Color.amber, pad: 12)
                }
                if mode == 0 { presets } else { allJobs }

                if !daemons.log.isEmpty {
                    GlassSection("گزارش عملیات") {
                        ForEach(Array(daemons.log.prefix(8).enumerated()), id: \.offset) { item in
                            Text(item.element).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
        .background(AppBackground())
        .task { await daemons.refresh() }
        .confirmationDialog("این سرویس پرخطر است. مطمئنید؟", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            Button("غیرفعال کن", role: .destructive) {
                if let p = confirm { apply(p, disable: true) }
                confirm = nil
            }
            Button("انصراف", role: .cancel) { confirm = nil }
        }
    }

    var presets: some View {
        VStack(spacing: 10) {
            Text("اگر غیرفعال‌سازی دائم (launchctl) روی دستگاه شما رد شود، برنامه خودکار پردازه را می‌بندد و اگر دوباره بالا آمد، آن را منجمد می‌کند. «انجماد» همیشه کار می‌کند و با «ادامه» برمی‌گردد.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    busy = true
                    Task {
                        let n = await daemons.applySafePack()
                        daemons.addLog("بسته امن: \(fnum(n)) سرویس پردازش شد")
                        busy = false
                    }
                } label: { Label("اعمال موارد امن", systemImage: "checkmark.shield.fill").frame(maxWidth: .infinity) }
                .buttonStyle(GlassButtonStyle(prominent: true))
                Button {
                    busy = true
                    Task {
                        let n = await daemons.restoreAllPresets()
                        daemons.addLog("بازگردانی: \(fnum(n)) سرویس فعال شد")
                        busy = false
                    }
                } label: { Label("بازگردانی همه", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity) }
                .buttonStyle(GlassButtonStyle())
            }
            ForEach(DaemonPreset.all) { p in presetRow(p) }
        }
    }

    func presetRow(_ p: DaemonPreset) -> some View {
        let job = daemons.job(for: p.label)
        let off = daemons.isDisabled(p.label)
        let pr = proc(of: job)
        let (rTitle, rColor) = riskInfo(p.risk)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(p.title).font(.subheadline.bold())
                Pill(text: rTitle, color: rColor)
                Spacer()
                if pr?.stopped == true { Pill(text: "منجمد", color: Color.coolBlue) }
                else if off { Pill(text: "غیرفعال", color: Color.badRed) }
                else if job?.running == true { Pill(text: "در حال اجرا", color: Color.okGreen) }
                else if job == nil { Pill(text: "روی این دستگاه نیست", color: Color.gray) }
                else { Pill(text: "آماده", color: Color.coolBlue) }
            }
            Text(p.detail).font(.caption).foregroundStyle(.secondary)
            if let pr {
                Text("CPU \(fmtPct(pr.cpu, 1)) · RAM \(fmtBytes(pr.mem))").font(.caption2).foregroundColor(Color.accentOrange)
            }
            Text(p.label).font(.caption2).foregroundStyle(.secondary)
            if job != nil || off {
                HStack(spacing: 8) {
                    Button {
                        if off { apply(p, disable: false) }
                        else if p.risk == 2 { confirm = p }
                        else { apply(p, disable: true) }
                    } label: {
                        Text(off ? "فعال کن" : "غیرفعال کن").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle(prominent: off, danger: !off && p.risk > 0))
                    if let j = job, j.running {
                        Button {
                            run { if pr?.stopped == true { await daemons.thaw(j) } else { await daemons.freeze(j) } }
                        } label: {
                            Text(pr?.stopped == true ? "ادامه" : "انجماد").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: 18, pad: 12)
    }

    func apply(_ p: DaemonPreset, disable: Bool) {
        busy = true
        Task {
            let domain = daemons.job(for: p.label)?.domain ?? "system"
            if disable { await daemons.disable(label: p.label, domain: domain, pid: daemons.job(for: p.label)?.pid) }
            else { await daemons.enable(label: p.label, domain: domain) }
            await daemons.refresh()
            await procs.refresh()
            busy = false
        }
    }

    var allJobs: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("جستجوی سرویس", text: $search)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
            }
            .glass(radius: 16, pad: 12)
            Toggle("فقط در حال اجرا", isOn: $onlyRunning)
                .font(.subheadline)
                .glass(radius: 16, pad: 12)
            let all = filteredJobs
            ForEach(Array(all.prefix(limit))) { j in
                jobRow(j)
            }
            if all.count > limit {
                Button { limit += 60 } label: {
                    Text("نمایش بیشتر (\(fnum(all.count - limit)) مورد دیگر)").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
            }
            if all.isEmpty {
                EmptyState(icon: "gearshape.2", text: "سرویسی پیدا نشد.")
            }
        }
    }

    func jobRow(_ j: Job) -> some View {
        let pr = proc(of: j)
        let prot = Guard.labelProtected(j.label)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(j.label).font(.caption.bold()).lineLimit(2)
                Spacer()
                Pill(text: pr?.stopped == true ? "منجمد" : (j.running ? "PID \(fnum(Int(j.pid ?? 0)))" : "متوقف"),
                     color: pr?.stopped == true ? Color.coolBlue : (j.running ? Color.okGreen : Color.gray))
            }
            if let pr {
                Text("CPU \(fmtPct(pr.cpu, 1)) · RAM \(fmtBytes(pr.mem))").font(.caption2).foregroundColor(Color.accentOrange)
            }
            if prot {
                Text("🔒 محافظت‌شده").font(.caption2).foregroundColor(Color.badRed)
            } else {
                HStack(spacing: 6) {
                    if daemons.isDisabled(j.label) {
                        Button { run { await daemons.enable(label: j.label, domain: j.domain) } } label: {
                            Text("فعال کن").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GlassButtonStyle(prominent: true))
                    } else {
                        Button { run { await daemons.stopOnce(j) } } label: {
                            Text("توقف").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GlassButtonStyle())
                        if j.running {
                            Button {
                                run { if pr?.stopped == true { await daemons.thaw(j) } else { await daemons.freeze(j) } }
                            } label: {
                                Text(pr?.stopped == true ? "ادامه" : "انجماد").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(GlassButtonStyle())
                        }
                        Button { run { await daemons.disable(label: j.label, domain: j.domain, pid: j.pid) } } label: {
                            Text("غیرفعال").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GlassButtonStyle(danger: true))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: 16, pad: 12)
    }

    func run(_ op: @escaping () async -> Void) {
        busy = true
        Task {
            await op()
            await daemons.refresh()
            await procs.refresh()
            busy = false
        }
    }
}

// MARK: - Cleaner

struct CleanerView: View {
    @EnvironmentObject var cleaner: CleanerStore
    @EnvironmentObject var settings: AppSettings
    @State private var confirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Text("پاک‌سازی").font(.largeTitle.bold())
                    Spacer()
                    if cleaner.scanning || cleaner.cleaning { ProgressView() }
                    Button { Task { await cleaner.scan(exclude: settings.cacheExclude) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(GlassIconStyle())
                }
                VStack(spacing: 4) {
                    Text("قابل آزادسازی").font(.footnote).foregroundStyle(.secondary)
                    Text(fmtBytes(cleaner.totalSelected)).font(.system(size: 38, weight: .bold))
                        .foregroundColor(Color.accentOrange)
                    if cleaner.freed > 0 {
                        Text("آخرین پاک‌سازی: \(fmtBytes(cleaner.freed))").font(.caption).foregroundColor(Color.okGreen)
                    }
                }
                .frame(maxWidth: .infinity)
                .glass(tint: Color.accentOrange)

                ForEach(CleanCat.all) { c in
                    let on = cleaner.selected.contains(c.id)
                    Button {
                        if on { cleaner.selected.remove(c.id) } else { cleaner.selected.insert(c.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: c.icon).font(.title3).foregroundColor(Color.accentOrange).frame(width: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(c.title).font(.subheadline.bold())
                                    if c.risk > 0 { Pill(text: "متوسط", color: Color.amber) }
                                }
                                Text(c.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(cleaner.sizes[c.id].map { fmtBytes($0) } ?? "—").font(.subheadline.bold())
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(on ? Color.accentOrange : Color.gray)
                            }
                        }
                        .glass(radius: 18, pad: 12)
                    }
                    .buttonStyle(.plain)
                }

                Button { confirm = true } label: {
                    Label(cleaner.cleaning ? "در حال پاک‌سازی…" : "پاک‌سازی انتخاب‌شده‌ها", systemImage: "trash.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(prominent: true))
                .disabled(cleaner.cleaning || cleaner.selected.isEmpty)

                Text("برنامه‌های مستثنی از پاک‌سازی کش (مثل Spotify) را در «بهینه‌سازی ← تنظیمات» مدیریت کنید. هیچ داده شخصی، عکس یا پیام حذف نمی‌شود؛ فقط کش و فایل موقت.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(AppBackground())
        .task { if cleaner.sizes.isEmpty { await cleaner.scan(exclude: settings.cacheExclude) } }
        .confirmationDialog("فایل‌های انتخاب‌شده پاک شوند؟", isPresented: $confirm, titleVisibility: .visible) {
            Button("پاک کن", role: .destructive) {
                Task { await cleaner.clean(exclude: settings.cacheExclude) }
            }
            Button("انصراف", role: .cancel) {}
        }
    }
}

// MARK: - Tune

struct TuneView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sampler: SystemSampler
    @EnvironmentObject var procs: ProcessStore
    @EnvironmentObject var daemons: DaemonStore
    @EnvironmentObject var cleaner: CleanerStore
    @EnvironmentObject var booster: Booster
    @EnvironmentObject var rootState: RootState
    @State private var reduceMotion = false
    @State private var reduceTransp = false
    @State private var msg: String?
    @State private var confirmRespring = false

    var runningApps: [Proc] {
        procs.procs.filter { $0.kind == .app }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    Text("بهینه‌سازی").font(.largeTitle.bold())
                    Spacer()
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(GlassIconStyle())
                }
                turboCard
                gameCard
                guardCard
                tweaksCard
                GlassSection("واقع‌بینانه درباره عملکرد") {
                    Text("iOS مدیریت حافظه و CPU را خودش به‌خوبی انجام می‌دهد. بیشترین اثر این ابزار در کاهش فعالیت پس‌زمینه، فشار رم، گرمای دستگاه و مصرف باتری است؛ فرکانس CPU/GPU را نمی‌شود با نرم‌افزار بالا برد. دیمن‌های پرخطر را بدون نیاز غیرفعال نکنید.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(AppBackground())
        .onAppear { loadPrefs(); Task { await booster.gameStatus() } }
        .alert(isPresented: Binding(get: { msg != nil }, set: { if !$0 { msg = nil } })) {
            Alert(title: Text(msg ?? ""), dismissButton: .default(Text("باشه")))
        }
        .confirmationDialog("SpringBoard ریستارت شود؟ (ریسپرینگ)", isPresented: $confirmRespring, titleVisibility: .visible) {
            Button("ریسپرینگ", role: .destructive) { Task { await procs.respring() } }
            Button("انصراف", role: .cancel) {}
        }
    }

    var turboCard: some View {
        GlassSection("توربو — بهینه‌سازی یک‌لمسی") {
            Toggle("پاک‌سازی کش و فایل‌های موقت", isOn: $settings.tClean)
            Toggle("غیرفعال‌سازی دیمن‌های امن (تله‌متری)", isOn: $settings.tDaemons)
            Toggle("بستن برنامه‌های پس‌زمینه", isOn: $settings.tApps)
            Toggle("کاهش اولویت پردازه‌های پرمصرف", isOn: $settings.tHogs)
            Toggle("تخلیه حافظه (فشار روی کرنل)", isOn: $settings.tPurge)
            Button {
                Task { await booster.turbo(sampler: sampler, procs: procs, daemons: daemons,
                                           cleaner: cleaner, settings: settings) }
            } label: {
                Label(booster.running ? "در حال اجرا…" : "اجرای توربو", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(prominent: true))
            .disabled(booster.running)
            if !booster.log.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(booster.log.enumerated()), id: \.offset) { item in
                        Text(item.element).font(.caption)
                    }
                }
            }
        }
    }

    var gameCard: some View {
        GlassSection("🎮 حالت بازی (پس‌زمینه)") {
            Text("یک پردازه root جدا در پس‌زمینه می‌ماند، اولویت CPU بازی را بالا می‌برد و سرویس‌های تحلیلی را موقتاً منجمد می‌کند. بعد از شروع وارد بازی شوید؛ با پایان زمان یا دکمه توقف، همه‌چیز آزاد می‌شود.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("برنامه هدف").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(runningApps) { p in
                        Button(p.name) { settings.gameApp = p.name }
                    }
                } label: {
                    Text(settings.gameApp.isEmpty ? "انتخاب از در حال اجرا" : settings.gameApp)
                        .font(.subheadline.bold()).foregroundColor(Color.accentOrange)
                }
            }
            TextField("یا نام پردازه بازی را تایپ کنید", text: $settings.gameApp)
                .disableAutocorrection(true)
                .autocapitalization(.none)
                .glass(radius: 14, pad: 10)
            HStack(spacing: 6) {
                Text("مدت:").font(.caption).foregroundStyle(.secondary)
                ForEach([15, 30, 60, 120], id: \.self) { m in
                    ChipToggle(title: "\(fnum(m)) دقیقه", isOn: settings.gameMinutes == m) { settings.gameMinutes = m }
                }
            }
            HStack(spacing: 6) {
                Text("بوست:").font(.caption).foregroundStyle(.secondary)
                ChipToggle(title: "ملایم", isOn: settings.gameNice == -5) { settings.gameNice = -5 }
                ChipToggle(title: "قوی", isOn: settings.gameNice == -10) { settings.gameNice = -10 }
                ChipToggle(title: "حداکثر", isOn: settings.gameNice == -15) { settings.gameNice = -15 }
            }
            Toggle("انجماد سرویس‌های تحلیلی در طول بازی", isOn: $settings.gameFreeze)
            Toggle("اجرای توربو قبل از شروع", isOn: $settings.gamePrep)
            HStack(spacing: 8) {
                Button {
                    Task {
                        await booster.startGame(sampler: sampler, procs: procs, daemons: daemons,
                                                cleaner: cleaner, settings: settings, rootOK: rootState.available)
                    }
                } label: {
                    Label(booster.gameRunning ? "در حال اجرا" : "شروع حالت بازی", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(prominent: true))
                .disabled(booster.gameRunning || booster.running)
                Button { Task { await booster.stopGame() } } label: {
                    Label("توقف", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(danger: true))
            }
            if booster.gameRunning { Pill(text: "حالت بازی فعال است", color: Color.okGreen) }
            if !booster.gameInfo.isEmpty {
                Text(booster.gameInfo).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var guardCard: some View {
        GlassSection("نگهبان خودکار CPU") {
            Toggle("فعال (فقط وقتی برنامه باز است)", isOn: $settings.guardOn)
            if settings.guardOn {
                VStack(alignment: .leading, spacing: 4) {
                    Text("آستانه: بیش از \(fmtPct(settings.guardCPU)) CPU برای ۳ بار پیاپی")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $settings.guardCPU, in: 20...150, step: 5)
                }
                Picker("", selection: $settings.guardAction) {
                    Text("کم‌کردن اولویت").tag(0)
                    Text("انجماد").tag(1)
                    Text("بستن").tag(2)
                }
                .pickerStyle(.segmented)
                ForEach(Array(procs.guardLog.prefix(5).enumerated()), id: \.offset) { item in
                    Text("• " + item.element).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var tweaksCard: some View {
        GlassSection("تنظیمات سبک‌کننده رابط (تجربی)") {
            Toggle("کاهش حرکت (Reduce Motion)", isOn: Binding(get: { reduceMotion }, set: { v in
                reduceMotion = v
                setPref("ReduceMotionEnabled", v)
            }))
            Toggle("کاهش شفافیت (Reduce Transparency)", isOn: Binding(get: { reduceTransp }, set: { v in
                reduceTransp = v
                setPref("EnhancedBackgroundContrastEnabled", v)
            }))
            Text("این گزینه‌ها انیمیشن و بلور سیستم را کم می‌کنند و روی دستگاه‌های قدیمی روانی را بیشتر می‌کنند. بعد از تغییر ریسپرینگ لازم است.")
                .font(.caption).foregroundStyle(.secondary)
            Button { confirmRespring = true } label: {
                Label("ریسپرینگ", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle())
        }
    }

    func loadPrefs() {
        let d = NSDictionary(contentsOfFile: "/var/mobile/Library/Preferences/com.apple.Accessibility.plist")
        reduceMotion = (d?["ReduceMotionEnabled"] as? Bool) ?? false
        reduceTransp = (d?["EnhancedBackgroundContrastEnabled"] as? Bool) ?? false
    }

    func setPref(_ key: String, _ on: Bool) {
        Task {
            let out = await Task.detached { Root.setPref(key: key, on: on) }.value
            if !out.contains("ok") { msg = "اعمال نشد؛ احتمالاً Root فعال نیست." }
        }
    }
}

// MARK: - Settings / diagnostics

struct Capability: Identifiable {
    let id = UUID()
    let title: String
    let ok: Bool
    let detail: String
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var procs: ProcessStore
    @EnvironmentObject var rootState: RootState
    @State private var gpuDiag = ""
    @State private var gpuOK = false
    @State private var newAllow = ""
    @State private var newExclude = ""
    @State private var copied = false

    var report: String {
        let i = rootState.info
        var t = "PerfTool report\n"
        t += "device: \(SystemSampler.model) iOS \(UIDevice.current.systemVersion)\n"
        t += "helper: \(i.helperPath) exists=\(i.helperExists)\n"
        t += "root available=\(i.available) uid=\(i.uid.map(String.init) ?? "nil") selfUID=\(i.uidSelf)\n"
        t += "spawn: \(i.spawnInfo)\n"
        t += "root output[\(i.code)]: \(i.raw)\n"
        t += "nonroot output[\(i.nonRootCode)]: \(i.nonRootRaw)\n"
        for (k, v) in i.entitlements.sorted(by: { $0.key < $1.key }) { t += "ent \(k)=\(v)\n" }
        t += "containers readable=\(i.canReadContainers)\n"
        t += "launchctl=\(Root.launchctl ?? "nil")\n"
        t += "gpu ok=\(gpuOK) info=\(gpuDiag)\n"
        return t
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                diagnostics
                GlassSection("ظاهر و سرعت") {
                    Toggle("جلوه شیشه‌ای کامل (بلور و سایه — سنگین‌تر)", isOn: $settings.fancy)
                    Text("برای اعمال باید برنامه را کامل ببندید و دوباره باز کنید. روی دستگاه‌های قدیمی خاموش بماند.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("سرعت به‌روزرسانی پردازه‌ها: هر \(String(format: "%.1f", settings.interval).fa) ثانیه").font(.subheadline)
                    Slider(value: $settings.interval, in: 1.5...10, step: 0.5)
                }

                GlassSection("برنامه‌های مستثنی (هرگز بسته نمی‌شوند)") {
                    listEditor(items: $settings.allow, text: $newAllow, placeholder: "نام پردازه، مثل Filza")
                }

                GlassSection("مستثنی از پاک‌سازی کش (Bundle ID)") {
                    listEditor(items: $settings.cacheExclude, text: $newExclude, placeholder: "مثل com.spotify.client")
                }

                GlassSection("پردازه‌های محافظت‌شده") {
                    Text(Guard.hard.sorted().joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(AppBackground())
        .navigationBarTitle("تنظیمات", displayMode: .inline)
        .navigationBarHidden(false)
        .onAppear { checkGPU(); Task { await rootState.probe() } }
    }

    var diagnostics: some View {
        let i = rootState.info
        return GlassSection("بررسی قابلیت‌ها و عیب‌یابی") {
            row("پردازه کمکی ptroot", ok: i.helperExists, detail: i.helperExists ? i.helperPath : "داخل برنامه پیدا نشد؛ باید workflow جدید اجرا شده باشد.")
            row("دسترسی Root", ok: i.available,
                detail: i.available ? "پردازه کمکی با uid صفر اجرا شد." : "uid گزارش‌شده: \(i.uid.map(String.init) ?? "نامشخص") — \(i.raw.isEmpty ? "بدون خروجی" : i.raw)")
            ForEach(i.entitlements.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                row("entitlement: " + item.key.replacingOccurrences(of: "com.apple.private.", with: ""),
                    ok: item.value == 1,
                    detail: item.value == 1 ? "فعال" : (item.value == 0 ? "اعمال نشده — با TrollStore نصب کنید" : "قابل بررسی نیست"))
            }
            row("دسترسی به کانتینر برنامه‌ها", ok: i.canReadContainers,
                detail: i.canReadContainers ? "سندباکس خاموش است." : "برنامه سندباکس است.")
            row("launchctl", ok: Root.launchctl != nil, detail: Root.launchctl ?? "پیدا نشد")
            row("آمار GPU (IOKit)", ok: gpuOK, detail: gpuOK ? "مصرف فعلی را داشبورد نشان می‌دهد." : (gpuDiag.isEmpty ? "نتیجه‌ای نبود" : gpuDiag))
            row("تعداد پردازه‌های دیده‌شده", ok: procs.procs.count > 20, detail: "\(fnum(procs.procs.count)) پردازه")
            if !i.available && !i.spawnInfo.isEmpty {
                Text("جزئیات اجرا: " + i.spawnInfo).font(.caption2).foregroundColor(Color.amber)
            }
            HStack(spacing: 8) {
                Button { Task { await rootState.probe(); checkGPU() } } label: {
                    Text(rootState.probing ? "در حال بررسی…" : "بررسی مجدد").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(prominent: true))
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    Text(copied ? "کپی شد ✓" : "کپی گزارش").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
    }

    func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundColor(ok ? Color.okGreen : Color.badRed)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    func checkGPU() {
        var d = -1.0, r = -1.0, t = -1.0, m = -1.0
        gpuOK = pt_gpu(&d, &r, &t, &m) != 0
        gpuDiag = String(cString: pt_gpu_info())
    }

    func listEditor(items: Binding<[String]>, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(placeholder, text: text)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                Button {
                    let t = text.wrappedValue.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty && !items.wrappedValue.contains(t) { items.wrappedValue.append(t) }
                    text.wrappedValue = ""
                } label: { Image(systemName: "plus") }
                .buttonStyle(GlassIconStyle())
            }
            ForEach(items.wrappedValue, id: \.self) { item in
                HStack {
                    Text(item).font(.subheadline)
                    Spacer()
                    Button {
                        items.wrappedValue.removeAll { $0 == item }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(GlassIconStyle())
                }
            }
        }
    }
}
