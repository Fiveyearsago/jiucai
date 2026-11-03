import SwiftUI
import RegistrationCore

private let ink = Color(red: 0.13, green: 0.20, blue: 0.20)
private let accent = Color(red: 0.15, green: 0.43, blue: 0.35)
private let canvas = Color(red: 0.97, green: 0.97, blue: 0.95)

struct ContentView: View {
    @ObservedObject var model: RegistrationModel
    @State private var section = "workspace"
    @State private var selectedRecord: UUID?
    @State private var showResolution = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                if section == "records" { header }
                switch section {
                case "headers": RequestHeadersView(model: model, pane: model.registrationPage)
                case "records": records
                case "network": NetworkInspectorView(pane: model.registrationPage)
                case "proxy": ProxyConfigurationView(model: model)
                default: workspace
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(canvas).foregroundStyle(ink).tint(accent)
        .confirmationDialog("请先在官网核对账号是否已经存在。", isPresented: $showResolution, titleVisibility: .visible) {
            Button("已确认注册成功") { if let id = selectedRecord { model.resolveRecord(id, exists: true) } }
            Button("已确认未注册，允许重试") { if let id = selectedRecord { model.resolveRecord(id, exists: false) } }
            Button("取消", role: .cancel) {}
        } message: { Text("这里保存你的核对结果，不会再次提交注册。") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "leaf.fill").font(.system(size: 23)).foregroundStyle(.white)
                    .frame(width: 45, height: 45).background(accent, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Beauty").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("注册助手 · macOS").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 28)
            VStack(spacing: 5) {
                nav("workspace", "注册工作台", "rectangle.split.2x1")
                nav("records", "注册记录", "tray.full", count: model.records.count)
                nav("network", "网络请求", "network", count: model.registrationPage.networkRecords.count)
                nav("proxy", "代理池", "arrow.triangle.2.circlepath", count: model.proxyConfiguration.activeEntries.count)
                nav("headers", "请求头", "slider.horizontal.3")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("任务配置").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    input("用户名前缀") { TextField("xiaorange", text: $model.configuration.prefix) }
                    HStack(spacing: 12) {
                        input("起始编号") { TextField("176", value: $model.configuration.startIndex, formatter: integerFormatter) }
                        input("注册数量") { TextField("1", value: $model.configuration.count, formatter: integerFormatter) }
                    }
                    HStack {
                        Text("编号位数").font(.system(size: 12))
                        Spacer()
                        Picker("编号位数", selection: $model.configuration.digits) {
                            ForEach(1...6, id: \.self) { Text("\($0) 位").tag($0) }
                        }.labelsHidden().frame(width: 85)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.configuration.username(max(1, model.configuration.startIndex))).font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text("@fviainboxes.com").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    input("注册密码") { SecureField("输入 8–128 位密码", text: $model.password) }
                    Text(model.passwordStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    input("邀请码") { TextField("邀请码（可选）", text: $model.configuration.invitation) }
                    input("账号间隔（秒）") { TextField("60", value: $model.configuration.intervalSeconds, formatter: integerFormatter) }
                    input("429 冷却（分钟，0 = 停止）") { TextField("0", value: $model.configuration.cooldownMinutes, formatter: integerFormatter) }
                    VStack(alignment: .leading, spacing: 8) {
                        Link("阅读邮箱服务条款 ↗", destination: URL(string: "https://fviainboxes.com/terms")!).font(.caption)
                        Toggle("已阅读并同意邮箱服务条款", isOn: $model.acknowledgedMailboxTerms)
                            .toggleStyle(.checkbox).font(.system(size: 11))
                        Text("临时邮箱公开可读，请勿用于敏感账号。").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.disabled(model.isRunning).padding(.bottom, 12)
            }
            VStack(spacing: 9) {
                if model.isRunning {
                    HStack {
                        Button { model.togglePause() } label: {
                            Label(model.isPaused ? "继续任务" : "暂停", systemImage: model.isPaused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button("停止") { model.stop() }.controlSize(.large)
                    }
                } else {
                    Button { section = "workspace"; model.start() } label: {
                        HStack { Image(systemName: "play.fill"); Text("开始注册"); Spacer(); Image(systemName: "arrow.right") }.padding(.vertical, 4)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.storageAvailable)
                }
                if model.isRunning {
                    Text("任务按顺序执行 · 当前 \(model.completedInRun)/\(model.totalInRun)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 22).padding(.bottom, 24).frame(width: 285)
        .background(Color.white.opacity(0.7))
    }

    private var integerFormatter: NumberFormatter {
        let f = NumberFormatter(); f.numberStyle = .none; f.allowsFloats = false; return f
    }
    private func input<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            content().textFieldStyle(.roundedBorder).controlSize(.large)
        }
    }
    private func nav(_ key: String, _ title: String, _ symbol: String, count: Int? = nil) -> some View {
        Button { section = key } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 19)
                Text(title).font(.system(size: 13, weight: section == key ? .semibold : .regular))
                Spacer()
                if let count { Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
            }.padding(11).background(section == key ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("每一次注册，都有记录。")
                    .font(.system(size: 25, weight: .semibold))
                Text("成功与待核对的提交分开记录，避免重复操作。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(model.isPaused ? Color.orange : accent).frame(width: 7, height: 7)
                Text(model.isRunning ? (model.isPaused ? "等待处理" : "任务运行中") : "本地客户端").font(.caption)
            }.padding(.horizontal, 12).padding(.vertical, 8).background(.white, in: Capsule())
        }.padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 24)
    }

    private var workspace: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                metric("本次进度", value: "\(model.completedInRun) / \(model.totalInRun)", symbol: "circle.dotted")
                metric("已成功", value: "\(model.successCount)", symbol: "checkmark.circle")
                metric("待核对", value: "\(model.uncertainCount)", symbol: "clock.badge.questionmark")
            }
            browserArea
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.alignleft").foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    if model.isRunning || model.totalInRun > 0 {
                        HStack(spacing: 8) {
                            Text(model.phase).fontWeight(.medium)
                            if !model.currentUsername.isEmpty { Text(model.currentUsername).monospaced() }
                            Text(model.detail).foregroundStyle(.secondary).lineLimit(1).help(model.detail)
                        }.font(.system(size: 11))
                    }
                    if let message = model.logs.last {
                        Text(message).font(.system(size: 11, design: .monospaced)).lineLimit(1).textSelection(.enabled)
                    }
                }
                Spacer()
                Button("记录目录") { model.revealRecords() }.buttonStyle(.plain).font(.caption).foregroundStyle(accent)
            }.frame(minHeight: 36)
        }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 22)
    }
    private func metric(_ title: String, value: String, symbol: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 25, weight: .medium, design: .rounded))
            }
            Spacer()
            Image(systemName: symbol).font(.system(size: 23, weight: .light)).foregroundStyle(accent.opacity(0.7))
        }.padding(18).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 13))
    }

    private var browserArea: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("网页", selection: $model.tab) {
                    Text("注册页面").tag("registration")
                    Text("邮箱收件箱").tag("mailbox")
                }.pickerStyle(.segmented).frame(width: 240)
                Spacer()
                if model.isRunning && model.step == 3 {
                    TextField("手动输入 6 位验证码", text: $model.manualCode)
                        .textFieldStyle(.roundedBorder).frame(width: 166)
                }
                Text(model.tab == "registration" ? "api.jiucaihezi.studio" : "fviainboxes.com")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Button { model.openPages() } label: { Image(systemName: "arrow.clockwise") }
                    .help("打开或重新载入网页").disabled(model.isRunning)
            }.padding(12).background(Color.white)
            Divider()
            ZStack {
                BrowserSurface(pane: model.registrationPage).opacity(model.tab == "registration" ? 1 : 0).allowsHitTesting(model.tab == "registration")
                BrowserSurface(pane: model.mailboxPage).opacity(model.tab == "mailbox" ? 1 : 0).allowsHitTesting(model.tab == "mailbox")
                if !model.pagesOpened && !model.isRunning {
                    VStack(spacing: 15) {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(accent)
                        Text("注册与验证，在一个窗口完成").font(.system(size: 17, weight: .medium))
                        Text("点击开始后自动打开网页，也可以先检查页面。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("打开页面") { model.openPages() }.controlSize(.large)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(.white).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(ink.opacity(0.08), lineWidth: 1))
    }

    private var records: some View {
        VStack(spacing: 18) {
            HStack {
                Text("全部记录  \(model.records.count)").font(.system(size: 14, weight: .medium))
                Spacer()
                if let id = selectedRecord, model.records.first(where: {$0.id == id})?.status == .uncertain {
                    Button("记录核对结果") { showResolution = true }.disabled(model.isRunning)
                }
                Button("打开记录目录") { model.revealRecords() }
                Button("导出 CSV") { model.exportCSV() }.buttonStyle(.borderedProminent).disabled(model.records.isEmpty)
            }
            if model.records.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "tray").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(accent)
                    Text("还没有注册记录").font(.headline)
                    Text("任务开始后，结果会自动保存在这台 Mac 上。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 13))
            } else {
                VSplitView {
                    Table(model.records.reversed(), selection: $selectedRecord) {
                        TableColumn("用户名") { record in Text(record.username).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }.width(min: 100, ideal: 130)
                        TableColumn("邮箱") { record in Text(record.email).font(.system(size: 12)).textSelection(.enabled) }.width(min: 180, ideal: 240)
                        TableColumn("状态") { record in
                            Text(record.status.title).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(record.status == .succeeded ? accent : (record.status == .uncertain ? Color.orange : Color.secondary))
                        }.width(min: 80, ideal: 110)
                        TableColumn("更新时间") { record in Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)) }.width(min: 110, ideal: 150)
                        TableColumn("备注") { record in Text(record.note).font(.system(size: 11)).help(record.note) }
                    }.clipShape(RoundedRectangle(cornerRadius: 10)).frame(minHeight: 160)
                    if let id = selectedRecord, let record = model.records.first(where: { $0.id == id }) {
                        AccountRecordInspector(record: record).id(record.id).frame(minHeight: 300)
                    }
                }
            }
            Text("记录与导出文件包含用户名、邮箱和状态，不包含密码或验证码。网络详情不含 Cookie、Authorization、查询参数和请求正文。")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 28).padding(.bottom, 26)
    }
}

/// Per-account inspector: timeline plus every request seen while the account ran.
private struct AccountRecordInspector: View {
    let record: AccountRecord
    @State private var selection: UUID?
    private static let timelineID = UUID()

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(accent).frame(width: 34)
                    Text("注册时间线").font(.system(size: 12, weight: .medium))
                }.tag(Self.timelineID)
                Section("网络请求 \(record.network.count)") {
                    ForEach(record.network) { NetworkRequestRow(record: $0).tag($0.id) }
                }
            }
            .listStyle(.sidebar).frame(minWidth: 230, idealWidth: 270, maxWidth: 340)
            Group {
                if let id = selection, let entry = record.network.first(where: { $0.id == id }) {
                    NetworkRecordDetail(record: entry)
                } else {
                    timeline
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var timeline: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inspectorSection("摘要", rows: [("用户名", record.username), ("邮箱", record.email),
                    ("状态", record.status.title), ("更新时间", record.updatedAt.formatted(date: .abbreviated, time: .standard)),
                    ("备注", record.note)], keyColor: .green)
                if record.logs.isEmpty {
                    Text("此记录没有详细日志（旧版本注册的账号）。").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    inspectorSection("日志", rows: record.logs.map { line in
                        (String(line.prefix(8)), String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces))
                    }, keyColor: .secondary)
                }
                if let path = record.screenshot, let image = NSImage(contentsOfFile: path) {
                    Text("注册截图").font(.system(size: 13, weight: .semibold))
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NetworkRequestRow: View {
    let record: NetworkRecord
    var body: some View {
        HStack(spacing: 8) {
            Text("\(record.status)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 34).padding(.vertical, 2)
                .background(statusColor(record.status).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(statusColor(record.status))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.method) \(record.path)").font(.system(size: 12, design: .monospaced)).lineLimit(1)
                Text("\(record.transport) · \(record.date.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 1)
    }
}

/// Safari Web Inspector–style 摘要 / 请求 / 响应 view for one request.
private struct NetworkRecordDetail: View {
    let record: NetworkRecord
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                var summary: [(String, String)] {
                    var rows = [("URL", "https://api.jiucaihezi.studio" + record.path), ("方法", record.method),
                                ("状态", "\(record.status)"), ("来源", record.transport),
                                ("时间", record.date.formatted(date: .abbreviated, time: .standard))]
                    if let retry = record.retryAfter { rows.append(("Retry-After", retry)) }
                    return rows
                }
                inspectorSection("摘要", rows: summary, keyColor: .green)
                inspectorSection("请求", rows: record.requestHeaders.map { ($0.name, $0.value) }, keyColor: .blue,
                                 empty: "网页脚本未设置请求头。浏览器自动添加的 Cookie、Sec-Fetch-* 等字段请用 Safari 网页检查器查看。")
                inspectorSection("响应", rows: record.responseHeaders.map { ($0.name, $0.value) }, keyColor: .blue,
                                 empty: "没有可读取的响应头。")
                if !record.responseBody.isEmpty {
                    inspectorSection("响应正文", rows: [("", record.responseBody)], keyColor: .secondary)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func statusColor(_ status: Int) -> Color {
    switch status {
    case 200..<300: return accent
    case 300..<400: return .blue
    case 400..<500: return .orange
    default: return .red
    }
}

private func inspectorSection(_ title: String, rows: [(String, String)], keyColor: Color, empty: String = "无") -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.system(size: 13, weight: .semibold))
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(keyColor.opacity(0.5)).frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                if rows.isEmpty {
                    Text(empty).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    (Text(row.0.isEmpty ? "" : row.0 + ": ").foregroundColor(keyColor) + Text(row.1).foregroundColor(ink))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct RequestHeadersView: View {
    @ObservedObject var model: RegistrationModel
    @ObservedObject var pane: BrowserPane

    @State private var selectedRequest: UUID?
    @State private var newHeaderName = ""
    @State private var newHeaderValue = ""
    private var displayed: RequestHeaderConfiguration { pane.appliedHeaders ?? model.headerConfiguration }
    private var observation: RequestHeaderObservation? {
        pane.requestObservations.first(where: { $0.id == selectedRequest }) ?? pane.requestObservations.first
    }
    private var userAgent: String {
        if pane.appliedHeaders == nil, let agent = displayed.mode.userAgent { return agent }
        return pane.currentUserAgent.isEmpty ? (displayed.mode.userAgent ?? "等待浏览器提供") : pane.currentUserAgent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("请求头").font(.system(size: 25, weight: .semibold))
                    Spacer()
                    Label(pane.appliedHeaderMode == nil ? "待打开页面" : "已应用到注册页", systemImage: pane.appliedHeaderMode == nil ? "clock" : "checkmark.circle")
                        .font(.system(size: 11)).foregroundStyle(accent)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(accent.opacity(0.08), in: Capsule())
                }
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pane.appliedHeaders == nil ? "下次使用的配置" : "当前页面配置").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(displayed.mode.title).font(.system(size: 18, weight: .semibold))
                        }
                        Spacer()
                        Text("api.jiucaihezi.studio").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Divider()
                    headerRow("User-Agent", value: userAgent)
                    Divider()
                    headerRow("Accept", value: displayed.accept.value ?? "网页默认（未覆盖）")
                    Divider()
                    headerRow("Accept-Language", value: displayed.language.value ?? "网页 / 浏览器默认（未覆盖）")
                }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 14) {
                    Text("兼容配置").font(.system(size: 16, weight: .semibold))
                    HStack(alignment: .top, spacing: 24) {
                        Picker("浏览器标识", selection: $model.headerConfiguration.mode) {
                            ForEach(RequestHeaderMode.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("语言偏好", selection: $model.headerConfiguration.language) {
                            ForEach(RequestLanguage.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("响应格式", selection: $model.headerConfiguration.accept) {
                            ForEach(RequestAccept.allCases) { Text($0.title).tag($0) }
                        }
                    }.disabled(model.isRunning)
                    HStack(spacing: 10) {
                        Picker("批量差异化", selection: $model.headerVariantStrategy) {
                            ForEach(HeaderVariantStrategy.allCases) { Text($0.title).tag($0) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(model.isRunning)
                        if model.headerVariantStrategy != .fixed {
                            Text("每个账号自动使用不同的标识 / 语言组合。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if model.isRunning {
                        Text("任务运行期间保持当前配置。").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if let applied = pane.appliedHeaders, applied != model.headerConfiguration {
                        Text("已保存新配置，下次打开页面或开始任务时生效。当前页面仍使用：\(applied.title)。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text("配置自动保存，下次打开页面或开始任务时生效。语言与格式用于发送验证码、提交注册接口；语言也用于打开注册页。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("自定义请求头").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text("\(model.headerConfiguration.customHeaders.count) 项").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.headerConfiguration.customHeaders.isEmpty {
                        Text("尚未添加自定义字段。同名键会覆盖上方的语言与格式选择。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.headerConfiguration.customHeaders.keys.sorted()), id: \.self) { key in
                            HStack(spacing: 10) {
                                Text(key).font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .frame(width: 140, alignment: .leading)
                                Text(model.headerConfiguration.customHeaders[key] ?? "")
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help(model.headerConfiguration.customHeaders[key] ?? "")
                                Button { model.headerConfiguration.customHeaders.removeValue(forKey: key) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.7))
                                }.buttonStyle(.plain).help("删除该字段")
                            }.padding(.vertical, 3)
                        }
                    }
                    HStack(spacing: 10) {
                        TextField("字段名", text: $newHeaderName)
                            .textFieldStyle(.roundedBorder).frame(width: 140)
                        TextField("值", text: $newHeaderValue)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let trimmedKey = newHeaderName.trimmingCharacters(in: .whitespaces)
                            guard !trimmedKey.isEmpty, !newHeaderValue.isEmpty else { return }
                            model.headerConfiguration.customHeaders[trimmedKey] = newHeaderValue
                            newHeaderName = ""; newHeaderValue = ""
                        } label: {
                            Label("添加", systemImage: "plus.circle.fill")
                        }
                        .disabled(newHeaderName.trimmingCharacters(in: .whitespaces).isEmpty || newHeaderValue.isEmpty || model.isRunning)
                    }.disabled(model.isRunning)
                }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("请求详情").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text("最近 \(pane.requestObservations.count) 条 · 仅本次运行").font(.caption).foregroundStyle(.secondary)
                    }
                    if let observation {
                        Picker("查看请求", selection: $selectedRequest) {
                            Text("最新请求").tag(nil as UUID?)
                            ForEach(pane.requestObservations) { item in
                                Text("\(item.date.formatted(date: .omitted, time: .standard))  \(item.method) \(item.path)").tag(Optional(item.id))
                            }
                        }
                        HStack {
                            Text("\(observation.method) \(observation.path)").font(.system(size: 13, weight: .medium, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Text("\(observation.transport) · \(observation.date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("请求时配置：\(observation.profile)").font(.caption).foregroundStyle(.secondary)
                        if observation.headers.isEmpty {
                            Text("此请求没有可读取的请求头字段。").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(observation.headers) { header in
                            Divider()
                            HStack(alignment: .top, spacing: 12) {
                                headerRow(header.name, value: header.value)
                                Text(header.source).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                            }
                        }
                    } else {
                        Text("尚未观测到请求。打开注册页面后，这里会显示实际发生的导航和注册相关接口请求。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 13))
                Text("详情记录网页设置及 WebKit 暴露的字段，并非完整网络抓包；浏览器自动添加但未暴露的字段不作推测。仅保留所列非敏感字段，网址查询参数、Cookie、Authorization 和请求正文不进入记录。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(28)
        }
        .task { await pane.refreshUserAgent() }
        .onChange(of: pane.requestObservations.map(\.id)) { ids in
            if let selectedRequest, !ids.contains(selectedRequest) { self.selectedRequest = nil }
        }
    }

    private func headerRow(_ name: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(name).font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 150, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 4)
    }
}

private struct ProxyConfigurationView: View {
    @ObservedObject var model: RegistrationModel
    @State private var pasteText = ""
    @State private var parseError = ""
    @State private var testResults: [UUID: ProxyManager.TestResult] = [:]
    @State private var testing: Set<UUID> = []
    @State private var selectedProxies: Set<UUID> = []

    private func test(_ entries: [ProxyEntry]) {
        for entry in entries where !testing.contains(entry.id) {
            testing.insert(entry.id)
            Task {
                let result = await ProxyManager.test(entry)
                testResults[entry.id] = result
                testing.remove(entry.id)
            }
        }
    }
    private func resultColor(_ verdict: ProxyManager.TestResult.Verdict) -> Color {
        switch verdict { case .usable: return accent; case .blocked: return .orange; case .unreachable: return .red }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("代理池").font(.system(size: 25, weight: .semibold))
                        Text("每个账号注册前自动应用代理，防止同一 IP 触发频率限制。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("启用代理", isOn: $model.proxyConfiguration.enabled)
                        .toggleStyle(.switch).disabled(model.isRunning)
                }

                // Paste import
                VStack(alignment: .leading, spacing: 10) {
                    Text("添加代理").font(.system(size: 14, weight: .semibold))
                    Text("每行一个，格式：host:port 或 host:port:user:password")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: $pasteText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(ink.opacity(0.12)))
                    if !parseError.isEmpty {
                        Text(parseError).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("添加到列表") {
                            let lines = pasteText.components(separatedBy: .newlines)
                            let parsed = lines.compactMap { ProxyEntry.parse($0) }
                            if parsed.isEmpty && !pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                parseError = "未能解析到有效代理，请检查格式。"
                            } else {
                                parseError = ""
                                model.proxyConfiguration.entries.append(contentsOf: parsed)
                                pasteText = ""
                            }
                        }.disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning)
                        Button("清空列表") {
                            model.proxyConfiguration.entries.removeAll()
                        }.foregroundStyle(.red.opacity(0.8)).disabled(model.proxyConfiguration.entries.isEmpty || model.isRunning)
                    }
                }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))

                // Switch interval
                VStack(alignment: .leading, spacing: 10) {
                    Text("轮换策略").font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 10) {
                        Text("每").font(.system(size: 13))
                        TextField("1", value: $model.proxyConfiguration.switchEvery, formatter: {
                            let f = NumberFormatter(); f.numberStyle = .none; f.allowsFloats = false; return f
                        }()).frame(width: 60).textFieldStyle(.roundedBorder)
                        Text("个账号切换一次代理").font(.system(size: 13))
                    }.disabled(model.isRunning)
                    Text("代理按列表顺序循环使用，完成 switchEvery 个账号后切换到下一个。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))

                // Proxy list
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("代理列表  \(model.proxyConfiguration.entries.count)").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("启用 \(model.proxyConfiguration.activeEntries.count) 个").font(.caption).foregroundStyle(.secondary)
                        if !selectedProxies.isEmpty {
                            Button("删除选中 (\(selectedProxies.count))") {
                                model.proxyConfiguration.entries.removeAll { selectedProxies.contains($0.id) }
                                selectedProxies.removeAll()
                            }.foregroundStyle(.red.opacity(0.8)).disabled(model.isRunning)
                        }
                        Button(testing.isEmpty ? "全部测试" : "测试中…") { test(model.proxyConfiguration.entries) }
                            .disabled(model.proxyConfiguration.entries.isEmpty || !testing.isEmpty)
                    }
                    Text("测试会经该代理打开注册页 api.jiucaihezi.studio/sign-up，并读取网站看到的出口 IP 与 Cloudflare 节点。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.proxyConfiguration.entries.isEmpty {
                        Text("列表为空，粘贴代理后点「添加到列表」。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach($model.proxyConfiguration.entries) { $entry in
                            HStack(spacing: 10) {
                                // Selection checkbox for batch delete
                                Button {
                                    if selectedProxies.contains(entry.id) { selectedProxies.remove(entry.id) }
                                    else { selectedProxies.insert(entry.id) }
                                } label: {
                                    Image(systemName: selectedProxies.contains(entry.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selectedProxies.contains(entry.id) ? accent : Color.secondary.opacity(0.5))
                                }.buttonStyle(.plain)
                                Toggle("", isOn: $entry.enabled).labelsHidden().disabled(model.isRunning)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "\(entry.host):\(entry.port)").font(.system(size: 12, design: .monospaced))
                                    if !entry.user.isEmpty {
                                        Text(verbatim: entry.user).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    if testing.contains(entry.id) {
                                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在测试…") }
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    } else if let result = testResults[entry.id] {
                                        Text(verbatim: result.summary).font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(resultColor(result.verdict)).textSelection(.enabled)
                                    }
                                }
                                Spacer()
                                Button("测试") { test([entry]) }.disabled(testing.contains(entry.id))
                                Button {
                                    model.proxyConfiguration.entries.removeAll { $0.id == entry.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.6))
                                }.buttonStyle(.plain).disabled(model.isRunning)
                            }.padding(.vertical, 4)
                            Divider()
                        }
                    }
                }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))

                Text("代理通过修改系统 SOCKS5 偏好设置生效，每次注册完成后自动清除。仅影响注册期间的网络请求。密码以明文存储在本地记录文件中，请勿在共享设备上使用。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(28)
        }
    }
}

private struct NetworkInspectorView: View {
    @ObservedObject var pane: BrowserPane
    @State private var selectedID: UUID?

    private var selected: NetworkRecord? {
        pane.networkRecords.first(where: { $0.id == selectedID }) ?? pane.networkRecords.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("网络请求").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("最近 \(pane.networkRecords.count) 条").font(.caption).foregroundStyle(.secondary)
                    Button { pane.clearNetworkRecords() } label: {
                        Image(systemName: "trash").font(.caption)
                    }.help("清空记录").buttonStyle(.plain).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                if pane.networkRecords.isEmpty {
                    Text("尚无请求记录。打开注册页面后，这里会显示页面导航和接口请求。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(pane.networkRecords, selection: $selectedID) { NetworkRequestRow(record: $0).tag($0.id) }
                        .listStyle(.plain)
                }
                Divider()
                Text("需要 Cookie、Sec-Fetch-* 等浏览器自动添加的字段时：Safari › 开发 › 本机 › 注册页面，打开完整网页检查器。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
            if let record = selected {
                NetworkRecordDetail(record: record).background(.white)
            } else {
                Text("选择左侧请求查看详情。").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(canvas)
    }
}

private struct BrowserSurface: View {
    @ObservedObject var pane: BrowserPane
    var body: some View {
        ZStack(alignment: .top) {
            EmbeddedBrowser(pane: pane).id(pane.webViewID)
            if pane.loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在加载网页…").font(.caption) }
                    .padding(10).background(.regularMaterial, in: Capsule()).padding(.top, 12)
            }
            if let error = pane.navigationError {
                Text(error).font(.caption).padding(12).frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.14))
            }
        }
    }
}
