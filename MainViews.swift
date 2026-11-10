import SwiftUI
import UIKit

// MARK: - App

struct PerfApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var sampler = SystemSampler()
    @StateObject private var procs = ProcessStore()
    @StateObject private var daemons = DaemonStore()
    @StateObject private var cleaner = CleanerStore()
    @StateObject private var booster = Booster()
    @StateObject private var rootState = RootState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(sampler)
                .environmentObject(procs)
                .environmentObject(daemons)
                .environmentObject(cleaner)
                .environmentObject(booster)
                .environmentObject(rootState)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "fa_IR"))
                .accentColor(Color.accentOrange)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sampler: SystemSampler
    @EnvironmentObject var procs: ProcessStore
    @EnvironmentObject var rootState: RootState
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0

    func screen<V: View>(_ v: V) -> some View {
        NavigationView {
            v.navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }

    var body: some View {
        TabView(selection: $tab) {
            screen(DashboardView(goTune: { tab = 4 }))
                .tabItem { Label("داشبورد", systemImage: "speedometer") }.tag(0)
            screen(ProcessesView())
                .tabItem { Label("پردازه‌ها", systemImage: "list.bullet.rectangle") }.tag(1)
            screen(DaemonsView())
                .tabItem { Label("دیمن‌ها", systemImage: "gearshape.2.fill") }.tag(2)
            screen(CleanerView())
                .tabItem { Label("پاک‌سازی", systemImage: "trash.circle.fill") }.tag(3)
            screen(TuneView())
                .tabItem { Label("بهینه‌سازی", systemImage: "bolt.fill") }.tag(4)
        }
        .onAppear {
            procs.settings = settings
            updateSampler()
            Task {
                await rootState.probe()
                await procs.refresh()
            }
        }
        .onChange(of: tab) { _ in updateSampler() }
        .onChange(of: phase) { _ in updateSampler() }
        .task {
            // process list is only refreshed when a tab that shows it is open (or the guard is on)
            while !Task.isCancelled {
                let needed = tab <= 2 || settings.guardOn
                if phase == .active && needed { await procs.refresh() }
                let base = max(settings.interval, 1.5)
                let secs = tab == 0 ? max(base, 4) : base
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            }
        }
    }

    /// live system sampling only runs while the dashboard is visible (saves CPU and avoids lag)
    func updateSampler() {
        if tab == 0 && phase == .active { sampler.start() } else { sampler.stop() }
    }
}

// MARK: - Dashboard

struct GaugeCard: View {
    let title: String
    let value: Double?
    let subtitle: String
    let color: Color
    let hist: [Double]

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RingProgress(progress: (value ?? 0) / 100, lineWidth: 9,
                             colors: [color.opacity(0.6), color, color.opacity(0.6)])
                Text(value.map { fmtPct($0) } ?? "—")
                    .font(.subheadline.bold()).minimumScaleFactor(0.6)
            }
            .frame(width: 72, height: 72)
            Text(title).font(.caption.bold())
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
            Sparkline(values: hist, color: color).frame(height: 28)
        }
        .frame(maxWidth: .infinity)
        .glass(radius: 20, pad: 12)
    }
}

struct DashboardView: View {
    @EnvironmentObject var sampler: SystemSampler
    @EnvironmentObject var procs: ProcessStore
    @EnvironmentObject var booster: Booster
    @EnvironmentObject var rootState: RootState
    var goTune: () -> Void
    @State private var purging = false
    @State private var msg: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                HStack(spacing: 10) {
                    GaugeCard(title: "CPU", value: sampler.cpu,
                              subtitle: "\(fnum(sampler.cores.count)) هسته", color: Color.accentOrange, hist: sampler.cpuHist)
                    GaugeCard(title: "RAM",
                              value: Double(sampler.memUsed) / Double(max(sampler.memTotal, 1)) * 100,
                              subtitle: fmtBytes(sampler.memTotal), color: Color.coolBlue, hist: sampler.memHist)
                    GaugeCard(title: "GPU", value: sampler.gpu,
                              subtitle: sampler.gpu == nil ? "ناموجود (تنظیمات)" : "فعال", color: Color.okGreen, hist: sampler.gpuHist)
                }
                memoryCard
                coresCard
                tiles
                topCard(title: "پرمصرف‌ترین‌ها (CPU)", byCPU: true)
                topCard(title: "پرمصرف‌ترین‌ها (RAM)", byCPU: false)
                HStack(spacing: 10) {
                    Button { quickPurge() } label: {
                        Label(purging ? "در حال تخلیه…" : "تخلیه سریع رم", systemImage: "memorychip.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(purging)
                    Button { goTune() } label: {
                        Label("توربو", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                }
            }
            .padding()
        }
        .background(AppBackground())
        .alert(isPresented: Binding(get: { msg != nil }, set: { if !$0 { msg = nil } })) {
            Alert(title: Text(msg ?? ""), dismissButton: .default(Text("باشه")))
        }
    }

    func quickPurge() {
        purging = true
        Task {
            let before = sampler.memFree + sampler.memCached
            let mb = await booster.purge(sampler: sampler)
            try? await Task.sleep(nanoseconds: 600_000_000)
            sampler.sample()
            let after = sampler.memFree + sampler.memCached
            msg = "فشار تا \(fnum(Int(mb))) مگابایت اعمال شد.\nآزاد: \(fmtBytes(before)) ← \(fmtBytes(after))"
            purging = false
        }
    }

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("توربو").font(.largeTitle.bold())
                Text("\(SystemSampler.model) · iOS \(UIDevice.current.systemVersion)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Pill(text: rootState.probing ? "بررسی Root…" : (rootState.available ? "Root فعال" : "بدون Root"),
                     color: rootState.available ? Color.okGreen : Color.badRed)
                Pill(text: "فشار رم: \(sampler.pressureText)", color: sampler.pressureColor)
            }
        }
    }

    var memoryCard: some View {
        let total = Double(max(sampler.memTotal, 1))
        return GlassSection("حافظه (RAM)") {
            GeometryReader { g in
                HStack(spacing: 2) {
                    Capsule().fill(Color.accentOrange)
                        .frame(width: g.size.width * CGFloat(min(Double(sampler.memUsed) / total, 1)))
                    Capsule().fill(Color.amber.opacity(0.7))
                        .frame(width: g.size.width * CGFloat(min(Double(sampler.memCached) / total, 1)))
                    Capsule().fill(Color.white.opacity(0.12))
                }
            }
            .frame(height: 12)
            InfoRow(title: "استفاده‌شده (فعال + wired + فشرده)", value: fmtBytes(sampler.memUsed), color: Color.accentOrange)
            InfoRow(title: "کش / غیرفعال", value: fmtBytes(sampler.memCached), color: Color.amber)
            InfoRow(title: "آزاد", value: fmtBytes(sampler.memFree))
            InfoRow(title: "Wired", value: fmtBytes(sampler.memWired))
            InfoRow(title: "فشرده‌شده", value: fmtBytes(sampler.memCompressed))
            if let mm = sampler.gpuMemMB {
                InfoRow(title: "حافظه GPU", value: fmtBytes(UInt64(mm * 1_048_576)))
            }
        }
    }

    var coresCard: some View {
        GlassSection("هسته‌های CPU") {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(sampler.cores.enumerated()), id: \.offset) { item in
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 5)
                                .fill(LinearGradient(colors: [Color.amber, Color.deepOrange],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(height: 56 * CGFloat(item.element / 100))
                        }
                        .frame(height: 56)
                        Text(fnum(item.offset + 1)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if let r = sampler.gpuRender, let t = sampler.gpuTiler {
                InfoRow(title: "GPU — رندر / تایلر", value: "\(fmtPct(r)) / \(fmtPct(t))", color: Color.okGreen)
            }
        }
    }

    var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile(icon: "thermometer.medium", title: "وضعیت دما", value: sampler.thermalText, tint: sampler.thermalColor)
            StatTile(icon: sampler.charging ? "battery.100.bolt" : "battery.75",
                     title: sampler.lowPower ? "باتری (کم‌مصرف)" : "باتری",
                     value: sampler.battery < 0 ? "—" : fmtPct(Double(sampler.battery) * 100),
                     tint: sampler.charging ? Color.okGreen : Color.amber)
            StatTile(icon: "internaldrive.fill", title: "فضای آزاد",
                     value: "\(fmtBytes(sampler.diskFree)) از \(fmtBytes(sampler.diskTotal))", tint: Color.coolBlue)
            StatTile(icon: "clock.fill", title: "زمان روشن بودن",
                     value: fmtDuration(ProcessInfo.processInfo.systemUptime), tint: Color.accentOrange)
        }
    }

    func topCard(title: String, byCPU: Bool) -> some View {
        let list = procs.procs.sorted { byCPU ? $0.cpu > $1.cpu : $0.mem > $1.mem }.prefix(5)
        return GlassSection(title) {
            if list.isEmpty {
                Text("در حال خواندن پردازه‌ها…").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(list)) { p in
                HStack {
                    Circle().fill(p.kind.color).frame(width: 8, height: 8)
                    Text(p.name).font(.subheadline).lineLimit(1)
                    Spacer()
                    Text(byCPU ? fmtPct(p.cpu, 1) : fmtBytes(p.mem))
                        .font(.subheadline.bold())
                        .foregroundColor(byCPU && p.cpu > 50 ? Color.badRed : Color.white)
                }
            }
        }
    }
}

// MARK: - Processes

struct ProcRow: View {
    let p: Proc
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(p.kind.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.name).font(.subheadline.bold()).lineLimit(1)
                    if Guard.isProtected(p) { Image(systemName: "lock.fill").font(.caption2).foregroundColor(Color.badRed) }
                    if p.stopped { Pill(text: "منجمد", color: Color.coolBlue) }
                }
                Text("PID \(fnum(Int(p.pid))) · \(p.kind.title) · \(fnum(Int(p.threads))) ریسه")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text(fmtPct(p.cpu, 1)).font(.subheadline.bold())
                    .foregroundColor(p.cpu > 50 ? Color.badRed : (p.cpu > 15 ? Color.amber : Color.white))
                Text(fmtBytes(p.mem)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .glass(radius: 18, pad: 12)
    }
}

struct ProcessesView: View {
    @EnvironmentObject var procs: ProcessStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var rootState: RootState
    @State private var search = ""
    @State private var kind: ProcKind? = nil
    @State private var sort = 0
    @State private var selected: Proc?
    @State private var confirmBg = false
    @State private var msg: String?
    @State private var limit = 60

    var list: [Proc] {
        var l = procs.procs.filter { p in
            (kind == nil || p.kind == kind) && (search.isEmpty || p.name.localizedCaseInsensitiveContains(search) || String(p.pid) == search)
        }
        switch sort {
        case 1: l.sort { $0.mem > $1.mem }
        case 2: l.sort { $0.name.lowercased() < $1.name.lowercased() }
        case 3: l.sort { $0.pid < $1.pid }
        default: l.sort { $0.cpu > $1.cpu }
        }
        return l
    }

    var body: some View {
        let all = list
        let shown = Array(all.prefix(limit))
        return ScrollView {
            LazyVStack(spacing: 10) {
                HStack {
                    Text("پردازه‌ها").font(.largeTitle.bold())
                    Spacer()
                    Text("\(fnum(procs.procs.count)) پردازه").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("جستجوی نام یا PID", text: $search)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                }
                .glass(radius: 16, pad: 12)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ChipToggle(title: "همه", isOn: kind == nil) { kind = nil }
                        ForEach(ProcKind.allCases, id: \.self) { k in
                            ChipToggle(title: k.title, isOn: kind == k) { kind = k }
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("مرتب‌سازی:").font(.caption).foregroundStyle(.secondary)
                        ChipToggle(title: "CPU", isOn: sort == 0) { sort = 0 }
                        ChipToggle(title: "RAM", isOn: sort == 1) { sort = 1 }
                        ChipToggle(title: "نام", isOn: sort == 2) { sort = 2 }
                        ChipToggle(title: "PID", isOn: sort == 3) { sort = 3 }
                    }
                }
                Button { confirmBg = true } label: {
                    Label("بستن همه برنامه‌های پس‌زمینه", systemImage: "xmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(danger: true))

                if !rootState.available {
                    Text("Root فعال نیست؛ فقط پردازه‌های هم‌کاربر قابل مشاهده/کنترل‌اند. جزئیات در بهینه‌سازی ← تنظیمات.")
                        .font(.caption).foregroundColor(Color.amber)
                }
                if all.isEmpty {
                    EmptyState(icon: "list.bullet.rectangle", text: "پردازه‌ای پیدا نشد.")
                }
                ForEach(shown) { p in
                    Button { selected = p } label: { ProcRow(p: p) }.buttonStyle(.plain)
                }
                if all.count > limit {
                    Button { limit += 60 } label: {
                        Text("نمایش بیشتر (\(fnum(all.count - limit)) مورد دیگر)").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle())
                }
            }
            .padding()
        }
        .background(AppBackground())
        .sheet(item: $selected) { p in ProcessDetail(proc: p) }
        .alert(isPresented: Binding(get: { msg != nil }, set: { if !$0 { msg = nil } })) {
            Alert(title: Text(msg ?? ""), dismissButton: .default(Text("باشه")))
        }
        .confirmationDialog("برنامه‌های پس‌زمینه بسته شوند؟ (برنامه‌های لیست مستثنی بسته نمی‌شوند)",
                            isPresented: $confirmBg, titleVisibility: .visible) {
            Button("بستن", role: .destructive) {
                let targets = procs.procs.filter { $0.kind == .app && !Guard.isProtected($0) && !settings.allow.contains($0.name) }
                let pids = targets.map { $0.pid }
                Task {
                    await procs.killAsync(pids, sig: SIGKILL)
                    msg = "\(fnum(pids.count)) برنامه بسته شد."
                }
            }
            Button("انصراف", role: .cancel) {}
        }
    }
}

struct ProcessDetail: View {
    let proc: Proc
    @EnvironmentObject var procs: ProcessStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.presentationMode) private var presentation
    @State private var result: String?

    var body: some View {
        let prot = Guard.isProtected(proc)
        return SheetScaffold(proc.name) {
            GlassSection("مشخصات") {
                InfoRow(title: "PID", value: fnum(Int(proc.pid)))
                InfoRow(title: "پدر (PPID)", value: fnum(Int(proc.ppid)))
                InfoRow(title: "کاربر (UID)", value: fnum(Int(proc.uid)))
                InfoRow(title: "نوع", value: proc.kind.title, color: proc.kind.color)
                InfoRow(title: "CPU", value: fmtPct(proc.cpu, 1))
                InfoRow(title: "حافظه (footprint)", value: fmtBytes(proc.mem))
                InfoRow(title: "حافظه مجازی", value: fmtBytes(proc.virtualSize))
                InfoRow(title: "ریسه‌ها", value: fnum(Int(proc.threads)))
                InfoRow(title: "اولویت (nice)", value: fnum(Int(proc.nice)))
                Text(proc.path).font(.caption2).foregroundStyle(.secondary)
            }
            if prot {
                Text("🔒 این پردازه برای پایداری سیستم محافظت‌شده است و قابل بستن نیست.")
                    .font(.footnote).foregroundColor(Color.badRed).glass(radius: 16, tint: Color.badRed, pad: 12)
            } else {
                if proc.kind == .jailbreak {
                    Text("⚠️ این پردازه متعلق به جیلبریک است؛ بستنش ممکن است تویک‌ها یا ریسپرینگ را مختل کند.")
                        .font(.footnote).foregroundColor(Color.amber).glass(radius: 16, tint: Color.amber, pad: 12)
                }
                GlassSection("عملیات") {
                    HStack(spacing: 8) {
                        action("بستن نرم (TERM)", SIGTERM)
                        action("بستن اجباری (KILL)", SIGKILL, danger: true)
                    }
                    HStack(spacing: 8) {
                        action(proc.stopped ? "ادامه (CONT)" : "انجماد (STOP)", proc.stopped ? SIGCONT : SIGSTOP)
                        Button { renice(15) } label: { Text("کاهش اولویت").frame(maxWidth: .infinity) }
                            .buttonStyle(GlassButtonStyle())
                    }
                    HStack(spacing: 8) {
                        Button { renice(-10) } label: { Text("افزایش اولویت (بوست)").frame(maxWidth: .infinity) }
                            .buttonStyle(GlassButtonStyle(prominent: true))
                        Button { renice(0) } label: { Text("اولویت عادی").frame(maxWidth: .infinity) }
                            .buttonStyle(GlassButtonStyle())
                    }
                    Button {
                        if !settings.allow.contains(proc.name) { settings.allow.append(proc.name) }
                        result = "به لیست مستثنی اضافه شد."
                    } label: { Text("افزودن به مستثنی‌ها").frame(maxWidth: .infinity) }
                        .buttonStyle(GlassButtonStyle())
                }
            }
            if let r = result {
                Text(r).font(.footnote).foregroundColor(Color.okGreen)
            }
        }
    }

    func action(_ title: String, _ sig: Int32, danger: Bool = false) -> some View {
        Button {
            Task {
                await procs.killAsync([proc.pid], sig: sig)
                result = "ارسال شد: \(title)"
                if sig == SIGKILL || sig == SIGTERM { presentation.wrappedValue.dismiss() }
            }
        } label: { Text(title).frame(maxWidth: .infinity) }
        .buttonStyle(GlassButtonStyle(danger: danger))
    }

    func renice(_ n: Int) {
        Task {
            await procs.reniceAsync([proc.pid], nice: n)
            result = "اولویت تغییر کرد (نیازمند Root)."
        }
    }
}
