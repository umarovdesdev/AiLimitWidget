// Панель виджета: разделы Claude Code, Antigravity, Codex и других ИИ, вход/выход, подробности.

import AppKit
import SwiftUI

enum Ink {
    static let primary = Color(hex: "#F5F5F7"), body = Color(hex: "#D1D1D6"), secondary = Color(hex: "#AEAEB2"),
               tertiary = Color(hex: "#8E8E93"), faint = Color(hex: "#636366"), error = Color(hex: "#FF6961")
}

struct PanelView: View {
    @ObservedObject var w: Widget

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            // открыта наведением — только полосы лимитов и время сброса, без шапки и подробностей
            if !w.preview { header }
            if w.confirmLogout || w.loggingOut {
                LogoutPanel(w: w)
            } else {
                sections(now)
            }
            if !w.preview && !w.confirmLogout && !w.loggingOut { DetailsView(w: w, now: now) }
        }
        .padding(EdgeInsets(top: w.preview ? 2 : 12, leading: 14, bottom: w.preview ? 12 : 14, trailing: 12))
        .frame(width: 344, alignment: .topLeading)
        .background(Tint(level: w.s.transparency))
        .environment(\.colorScheme, .dark)
    }

    var header: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Image(systemName: "asterisk").font(.system(size: 13, weight: .heavy)).foregroundColor(Color(nsColor: Pal.accent))
                Image(systemName: "sparkle").font(.system(size: 11, weight: .bold)).foregroundColor(Color(nsColor: Pal.gemini)).offset(x: 11, y: 10)
            }
            .frame(width: 24, height: 24, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 1) {
                Text("Лимиты ИИ").font(.system(size: 15, weight: .semibold)).foregroundColor(Ink.primary)
                Text(w.subText).font(.system(size: 11.5)).foregroundColor(Ink.secondary).lineLimit(1)
            }
            .padding(.leading, 9)
            Spacer(minLength: 6)
            RoundButton(help: "Обновить") {
                if w.anyFetching {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
            } action: { w.fetchAll() }
            RoundButton(help: "Меню") {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
            } action: { w.showMenu() }
        }
    }

    // по разделу на сервис
    @ViewBuilder func sections(_ now: Date) -> some View {
        if w.s.showClaude {
            ProviderHeader(name: "Claude Code", colors: [Pal.accent], note: w.plan, first: true)
            if w.loggedOut {
                LoginPanel(w: w)
            } else if let sess = w.session {
                let active = sess.resetsAt.map { $0 > now } ?? false
                LimitRow(l: sess, now: now, note: active ? nil : "Не начата — 5-часовое окно начнётся с первого запроса", accent: Pal.accent)
            } else {
                Hint("Загрузка…")
            }
            if !w.loggedOut {
                ForEach(w.weekly, id: \.key) { l in LimitRow(l: l, now: now, note: nil, accent: Pal.accent) }
            }
            if !w.status.isEmpty { StatusLine(w.status, w.statusIsError) }
        }
        if w.s.showAgy {
            let credits = (w.agyCredits ?? 0) > 0 ? "кредиты: \(Int(w.agyCredits!.rounded()))" : nil
            ProviderHeader(name: "Antigravity", colors: [Pal.gemini, Pal.agyClaude], note: credits, first: !w.s.showClaude)
            if w.agyGroups.isEmpty && w.agyStatus.isEmpty { Hint("Загрузка…") }
            ForEach(w.agyGroups, id: \.key) { g in AgyRow(g: g, now: now) }
            if !w.agyStatus.isEmpty { StatusLine(w.agyStatus, w.agyStatusIsError) }
        }
        if w.s.showCodex {
            ProviderHeader(name: "Codex", colors: [Pal.codex], note: w.codexPlan, first: !w.s.showClaude && !w.s.showAgy)
            if w.codexLimits.isEmpty && w.codexStatus.isEmpty { Hint(w.codexUpdatedAt != nil ? "Сервер не сообщил лимиты" : "Загрузка…") }
            ForEach(w.codexLimits, id: \.key) { l in LimitRow(l: l, now: now, note: nil, accent: Pal.codex) }
            if !w.codexStatus.isEmpty { StatusLine(w.codexStatus, w.codexStatusIsError) }
        }
        // другие ИИ — только те, в которые вошли; у каждого свой цвет
        let extras = w.shownExtras
        ForEach(extras, id: \.key) { p in
            ProviderHeader(name: p.name, colors: [p.color], note: p.plan,
                           first: !w.s.showClaude && !w.s.showAgy && !w.s.showCodex && p === extras.first)
            if p.limits.isEmpty && p.status.isEmpty { Hint("Загрузка…") }
            ForEach(p.limits, id: \.key) { l in LimitRow(l: l, now: now, note: nil, accent: p.color) }
            if !p.status.isEmpty { StatusLine(p.status, p.statusIsError) }
        }
    }
}

// тонировка поверх размытия: чем выше уровень прозрачности, тем лучше виден фон
struct Tint: View {
    let level: Int
    var body: some View {
        let levels: [[Double]] = [[0x99, 0xB3], [0x66, 0x80], [0x40, 0x59], [0x30, 0x40]]
        let a = levels[max(0, min(3, level))].map { $0 / 255 }
        LinearGradient(colors: [Color(hex: "#303036").opacity(a[0]), Color(hex: "#1C1C1E").opacity(a[1])], startPoint: .top, endPoint: .bottom)
    }
}

struct RoundButton<Content: View>: View {
    let help: String
    @ViewBuilder let label: () -> Content
    let action: () -> Void
    @State var hover = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundColor(Ink.body)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hover ? 0.15 : 0.001)))
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
        .padding(.leading, 4)
    }
}

struct Bar: View {
    let pct: Double
    let color: NSColor
    let height: CGFloat

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                if pct > 0 {
                    Capsule().fill(Color(nsColor: color)).frame(width: max(height, g.size.width * CGFloat(pct / 100)))
                }
            }
        }
        .frame(height: height)
        .padding(.top, 4)
    }
}

func Hint(_ text: String) -> some View {
    Text(text).font(.system(size: 12.5)).foregroundColor(Ink.secondary).padding(.top, 8)
}

func StatusLine(_ text: String, _ error: Bool) -> some View {
    Text(text).font(.system(size: 11.5)).foregroundColor(error ? Ink.error : Ink.tertiary)
        .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
}

func Dot(_ color: NSColor, _ size: CGFloat) -> some View {
    Circle().fill(Color(nsColor: color)).frame(width: size, height: size)
}

// заголовок раздела: цветные точки его лимитов, название и справа мелкая подпись (план, кредиты)
struct ProviderHeader: View {
    let name: String
    let colors: [NSColor]
    let note: String?
    let first: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.bottom, 10) }
            HStack(spacing: 0) {
                HStack(spacing: -2) { ForEach(colors.indices, id: \.self) { i in Dot(colors[i], 8) } }   // точки чуть внахлёст
                    .padding(.trailing, 7)
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(Ink.primary)
                Spacer(minLength: 6)
                if let note = note, !note.isEmpty { Text(note).font(.system(size: 11)).foregroundColor(Ink.tertiary) }
            }
        }
        .padding(.top, first ? 8 : 14)
    }
}

struct LimitRow: View {
    let l: Limit
    let now: Date
    let note: String?
    let accent: NSColor

    var body: some View {
        let expired = l.resetsAt.map { $0 <= now } ?? false
        let pct = expired || note != nil ? 0 : max(0, min(100, l.percent))
        let color = Pal.severity(pct, accent)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text(l.title).font(.system(size: 12.5)).foregroundColor(Ink.body)
                Spacer()
                Text(Fmt.pct(pct)).font(.system(size: 15, weight: .semibold)).foregroundColor(pct >= 75 ? Color(nsColor: color) : Ink.primary)
            }
            Bar(pct: pct, color: color, height: 7)
            if let text = note ?? resetText(expired) {
                Text(text).font(.system(size: 11)).foregroundColor(Ink.tertiary).lineLimit(1).truncationMode(.tail).padding(.top, 4)
            }
        }
        .padding(.top, 10)
    }

    func resetText(_ expired: Bool) -> String? {
        guard let at = l.resetsAt, !expired else { return nil }
        return "Сброс через " + Fmt.duration(at.timeIntervalSince(now)) + " · " + Fmt.resetMoment(at)
    }
}

// группа Antigravity: название и две полосы рядом — 5 часов и неделя
struct AgyRow: View {
    let g: AgyGroup
    let now: Date

    var body: some View {
        let color = Pal.group(g.key)
        // упёрлись в лимит — группа стоит до сброса именно этого окна
        let hit = [g.session, g.week].compactMap { $0 }.filter { current($0, now) >= 99.5 }
            .max { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Dot(color, 6).padding(.trailing, 6)
                Text(g.title).font(.system(size: 12.5)).foregroundColor(Ink.body)
                if !g.models.isEmpty {
                    Text(g.models).font(.system(size: 11)).foregroundColor(Ink.faint).lineLimit(1).truncationMode(.tail).padding(.leading, 6)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 14) {
                MiniBar(label: "5 часов", l: g.session, now: now, accent: color)
                MiniBar(label: "Неделя", l: g.week, now: now, accent: color)
            }
            .padding(.top, 3)
            if let h = hit {
                Text(h.resetsAt.map { "Лимит исчерпан · откроется " + Fmt.resetMoment($0) } ?? "Лимит исчерпан")
                    .font(.system(size: 11)).foregroundColor(Ink.error).lineLimit(1).padding(.top, 5)
            }
        }
        .padding(.top, 10)
    }
}

struct MiniBar: View {
    let label: String
    let l: Limit?
    let now: Date
    let accent: NSColor

    var body: some View {
        let pct = current(l, now)
        let color = Pal.severity(pct, accent)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text(label).font(.system(size: 11.5)).foregroundColor(Ink.secondary)
                Spacer(minLength: 0)
                Text(l == nil ? "—" : Fmt.pct(pct)).font(.system(size: 14, weight: .semibold))
                    .foregroundColor(pct >= 75 ? Color(nsColor: color) : Ink.primary)
            }
            Bar(pct: pct, color: color, height: 5)
            if let text = caption(pct) {
                Text(text).font(.system(size: 10.5)).foregroundColor(Ink.tertiary).lineLimit(1).padding(.top, 3)
                    .help(l?.resetsAt.map(Fmt.resetMoment) ?? "")
            }
        }
        .frame(maxWidth: .infinity)
    }

    func caption(_ pct: Double) -> String? {
        guard let l = l else { return "не действует" }
        if pct < 0.5 { return "не расходовался" }
        if let at = l.resetsAt, at > now { return "сброс через " + Fmt.duration(at.timeIntervalSince(now)) }
        return nil
    }
}

struct PanelButton: View {
    let text: String
    let color: Color
    let action: () -> Void
    @State var hover = false

    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(color))
                .opacity(hover ? 0.88 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// «не вошли»: пояснение и оранжевая кнопка
struct LoginPanel: View {
    @ObservedObject var w: Widget

    var body: some View {
        VStack(spacing: 0) {
            if w.loginProc != nil {
                Text("Подтвердите вход в браузере").font(.system(size: 14, weight: .semibold)).foregroundColor(Ink.primary)
                Text("Войдите (можно через Google) и нажмите «Authorize».\nЛимиты появятся здесь сами.")
                    .font(.system(size: 12)).foregroundColor(Ink.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6).padding(.bottom, 12)
                HStack(spacing: 8) {
                    PanelButton(text: "Отмена", color: Color(hex: "#3A3A3C")) { w.cancelLogin() }
                    PanelButton(text: "Открыть снова", color: Color(nsColor: Pal.accent)) { if let u = w.loginUrl { Shell.open(u) } }
                        .opacity(w.loginUrl != nil ? 1 : 0.5)
                }
            } else {
                Text("Войдите в свой аккаунт Claude,\nчтобы видеть лимиты использования.")
                    .font(.system(size: 12.5)).foregroundColor(Ink.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
                PanelButton(text: "Войти в Claude", color: Color(nsColor: Pal.accent)) { w.login() }
                    .frame(width: 170)
                Text("Откроется браузер — можно войти через Google.").font(.system(size: 11)).foregroundColor(Ink.tertiary).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14).padding(.bottom, 4)
    }
}

struct LogoutPanel: View {
    @ObservedObject var w: Widget

    var body: some View {
        let name = Widget.serviceName(w.logoutTarget)
        VStack(spacing: 0) {
            Text(w.loggingOut ? "Выходим из \(name)…" : "Выйти из \(name)?").font(.system(size: 14, weight: .semibold)).foregroundColor(Ink.primary)
            if !w.loggingOut {
                Text(explanation).font(.system(size: 12)).foregroundColor(Ink.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6).padding(.bottom, 12)
                HStack(spacing: 8) {
                    PanelButton(text: "Отмена", color: Color(hex: "#3A3A3C")) { w.confirmLogout = false; w.updateView() }
                    PanelButton(text: "Выйти", color: Color(nsColor: Pal.danger)) { w.doLogout() }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14).padding(.bottom, 4)
    }

    var explanation: String {
        var what = w.logoutTarget == "agy" ? "Откроется Терминал с Antigravity и выполнит /logout —\nпосле выхода закройте его."
                 : w.logoutTarget == "codex" ? "Вход общий с Codex — в нём тоже\nнужно будет войти заново (codex login)."
                 : "Вход общий с Claude Code — в нём тоже\nнужно будет войти заново."
        if w.shownServices > 1 { what += "\n\nРаздел пропадёт из виджета.\nВернуть: ⋯ → Показывать." }
        return what
    }
}

// ---------- подробности ----------
struct DetailsView: View {
    @ObservedObject var w: Widget
    let now: Date
    @State var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // подробности свёрнуты по умолчанию — иначе панель слишком высокая
            Text(w.s.showDetails ? "Скрыть подробности ▴" : "Подробнее ▾")
                .font(.system(size: 11.5)).foregroundColor(hover ? Ink.body : Ink.tertiary)
                .frame(maxWidth: .infinity).padding(.top, 12)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .onTapGesture { w.s.showDetails.toggle(); w.saveSettings(); w.updateView() }
            if w.s.showDetails { details }
        }
    }

    @ViewBuilder var details: some View {
        let claudeOn = w.s.showClaude && !w.loggedOut
        let agyOn = w.s.showAgy && !w.agyMissing
        let codexOn = w.s.showCodex && !w.codexMissing
        let accounts = accountRows(claudeOn, agyOn, codexOn)
        let emails = distinctEmails(accounts.map { $0.email })
        DetailSection("Аккаунты")
        if emails.count == 1 { Pair("Email", emails[0]) }
        ForEach(accounts.indices, id: \.self) { i in
            let a = accounts[i]
            let value = emails.count == 1 ? (a.plan ?? "подключён") : [a.plan, a.email].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            PairDot(a.color, a.service, value.isEmpty ? "подключён" : value)
        }
        // на что ушла неделя: разбивку по продуктам присылает только Claude, у остальных — недельный расход целиком
        let week = weekRows(claudeOn, agyOn, codexOn)
        if !week.isEmpty {
            DetailSection("На что ушла неделя")
            ForEach(week.indices, id: \.self) { i in PairDot(week[i].0, week[i].1, Fmt.pct(week[i].2)) }
        }
        DetailSection("Данные")
        Pair("Обновлено", lastUpdated(claudeOn, agyOn, codexOn))
        if let next = nextUpdate(claudeOn, agyOn, codexOn) { Pair("Следующее", next) }
    }

    struct AccountRow { let color: NSColor; let service: String; let email: String?; let plan: String? }

    func accountRows(_ claudeOn: Bool, _ agyOn: Bool, _ codexOn: Bool) -> [AccountRow] {
        var list: [AccountRow] = []
        if claudeOn { list.append(AccountRow(color: Pal.accent, service: "Claude Code", email: J.string(w.account?["emailAddress"]), plan: w.plan.isEmpty ? nil : "Claude " + w.plan)) }
        if agyOn { list.append(AccountRow(color: Pal.gemini, service: "Antigravity", email: w.agyEmail, plan: nil)) }
        if codexOn { list.append(AccountRow(color: Pal.codex, service: "Codex", email: w.codexEmail, plan: w.codexPlan.isEmpty ? nil : "ChatGPT " + w.codexPlan)) }
        for p in w.shownExtras { list.append(AccountRow(color: p.color, service: p.name, email: p.email, plan: p.plan.isEmpty ? nil : p.plan)) }
        return list
    }

    func distinctEmails(_ list: [String?]) -> [String] {
        var out: [String] = []
        for e in list.compactMap({ $0 }) where !e.isEmpty && !out.contains(where: { $0.caseInsensitiveCompare(e) == .orderedSame }) { out.append(e) }
        return out
    }

    func weekRows(_ claudeOn: Bool, _ agyOn: Bool, _ codexOn: Bool) -> [(NSColor, String, Double)] {
        var list: [(NSColor, String, Double)] = []
        if claudeOn { for b in w.breakdown where b.1 >= 0.5 { list.append((Pal.accent, "Claude · " + b.0, b.1)) } }
        if agyOn { for g in w.agyGroups where g.week != nil { list.append((Pal.group(g.key), g.title + " · лимит", current(g.week, now))) } }
        if codexOn, let l = w.codexLong { list.append((Pal.codex, "Codex · " + l.title.lowercased(), current(l, now))) }
        for p in w.shownExtras { if let l = p.long ?? p.short { list.append((p.color, p.name + " · " + l.title.lowercased(), current(l, now))) } }
        return list
    }

    func lastUpdated(_ claudeOn: Bool, _ agyOn: Bool, _ codexOn: Bool) -> String {
        let dates = [claudeOn ? w.updatedAt : nil, agyOn ? w.agyUpdatedAt : nil, codexOn ? w.codexUpdatedAt : nil].compactMap { $0 }
            + w.shownExtras.compactMap { $0.updatedAt }
        guard let last = dates.max() else { return "ещё нет" }
        return Fmt.date(last, Calendar.current.isDateInToday(last) ? "HH:mm:ss" : "d MMM HH:mm")
    }

    func nextUpdate(_ claudeOn: Bool, _ agyOn: Bool, _ codexOn: Bool) -> String? {
        if w.anyFetching { return "обновляю…" }
        var next: [Date] = []
        if claudeOn { next.append(w.nextFetch) }
        if agyOn { next.append(w.agyNextFetch) }
        if codexOn { next.append(w.codexNextFetch) }
        next += w.shownExtras.map { $0.nextFetch }
        guard let soon = next.filter({ $0 > now }).min() else { return nil }
        return "через " + Fmt.duration(soon.timeIntervalSince(now))
    }
}

func DetailSection(_ title: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1).padding(.top, 12).padding(.bottom, 6)
        Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Ink.tertiary).padding(.bottom, 2)
    }
}

func Pair(_ label: String, _ value: String) -> some View {
    HStack(spacing: 12) {
        Text(label).font(.system(size: 12)).foregroundColor(Ink.secondary)
        Spacer(minLength: 0)
        Text(value).font(.system(size: 12, weight: .semibold)).foregroundColor(Ink.primary).lineLimit(1).truncationMode(.tail).help(value)
    }
    .padding(.top, 3)
}

// строка подробностей с цветной точкой сервиса перед названием
func PairDot(_ color: NSColor, _ label: String, _ value: String) -> some View {
    HStack(spacing: 0) {
        Dot(color, 6).padding(.trailing, 6)
        Text(label).font(.system(size: 12)).foregroundColor(Ink.secondary)
        Spacer(minLength: 12)
        Text(value).font(.system(size: 12, weight: .semibold)).foregroundColor(Ink.primary).lineLimit(1).truncationMode(.tail).help(value)
    }
    .padding(.top, 3)
}
