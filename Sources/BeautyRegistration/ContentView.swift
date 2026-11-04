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
                case "headers": RequestHeadersView(model: model, monitor: model.networkMonitor)
                case "records": records
                case "network": NetworkInspectorView(monitor: model.networkMonitor)
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
        .onChange(of: model.configuration.prefix) { _ in refreshFormIfIdle() }
        .onChange(of: model.configuration.startIndex) { _ in refreshFormIfIdle() }
        .onChange(of: model.configuration.digits) { _ in refreshFormIfIdle() }
        .onAppear { model.startProxySourceUpdates() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stopProxySourceUpdates() }
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
                nav("network", "网络请求", "network", count: model.networkMonitor.networkRecords.count)
                nav("proxy", "代理池", "arrow.triangle.2.circlepath", count: model.proxyConfiguration.activeEntries.count)
                nav("headers", "请求头", "slider.horizontal.3")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("批量任务配置").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
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
                    input("无代理重试间隔（分钟，0 = 默认间隔）") { TextField("0", value: $model.configuration.cooldownMinutes, formatter: integerFormatter) }
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
                        HStack { Image(systemName: "play.fill"); Text("开始批量注册"); Spacer(); Image(systemName: "arrow.right") }.padding(.vertical, 4)
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
    private func refreshFormIfIdle() {
        if !model.isRunning { model.refreshNativeForm() }
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
            nativeRegistrationArea
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

    private var nativeRegistrationArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("注册账号").font(.system(size: 24, weight: .semibold))
                        Text("填写注册信息，获取验证码后完成注册。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isRunning {
                        Label(model.isManualFlow ? "单个账号" : "批量任务", systemImage: model.isManualFlow ? "person" : "person.2")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(accent.opacity(0.08), in: Capsule())
                    }
                }

                HStack(spacing: 9) {
                    registrationStep(1, title: "填写注册信息")
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    registrationStep(2, title: "请求验证码")
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    registrationStep(3, title: "输入验证码")
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    registrationStep(4, title: "注册用户")
                    Spacer(minLength: 0)
                }

                HStack(alignment: .center, spacing: 18) {
                    connectionStatus("接口连接", value: model.siteStatusDescription, symbol: "network")
                    Divider().frame(height: 30)
                    connectionStatus("当前代理", value: model.activeProxyDescription, symbol: "arrow.triangle.2.circlepath")
                    Spacer(minLength: 0)
                    Button { model.checkAPIConnection() } label: {
                        HStack(spacing: 6) {
                            if model.isCheckingConnection { ProgressView().controlSize(.small) }
                            Text(model.isCheckingConnection ? "正在检查" : "检查连接")
                        }
                    }.disabled(model.isRunning || model.isCheckingConnection)
                }.padding(14).background(canvas, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 20) {
                        input("用户名") { TextField("输入用户名", text: $model.formUsername) }
                        input("邮箱地址") { TextField("name@fviainboxes.com", text: $model.formEmail) }
                    }
                    HStack(alignment: .top, spacing: 20) {
                        input("注册密码") { SecureField("输入 8–128 位密码", text: $model.password) }
                        input("邀请码") { TextField("邀请码（可选）", text: $model.configuration.invitation) }
                    }
                    Text(model.passwordStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("自动读取临时邮箱验证码", isOn: $model.autoReadMailbox)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                    Text(model.autoReadMailbox ? "收到邮件后自动填入验证码，也可以手动输入。" : "请查看邮箱中的验证邮件，并手动输入验证码。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.disabled(model.isRunning)

                Divider()

                HStack(alignment: .bottom, spacing: 12) {
                    input("邮箱验证码") {
                        TextField("输入 6 位验证码", text: $model.manualCode)
                            .font(.system(size: 14, design: .monospaced))
                            .disabled(!model.waitingForCode)
                    }.frame(maxWidth: 240)
                    Button { model.requestNativeVerification() } label: {
                        HStack(spacing: 7) {
                            if model.isRunning && model.isManualFlow && !model.verificationSent {
                                ProgressView().controlSize(.small)
                            }
                            Text("请求验证码")
                        }
                    }.controlSize(.large).disabled(model.isRunning || !model.storageAvailable)
                    Spacer()
                    Button { model.submitNativeRegistration() } label: {
                        Label("注册用户", systemImage: "person.badge.plus")
                            .padding(.horizontal, 9)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.canSubmitNativeRegistration)
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.verificationSent ? "envelope.badge" : "info.circle")
                        .foregroundStyle(accent)
                    Text(verificationHint).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.isRunning {
                    HStack(alignment: .top, spacing: 9) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.phase).font(.system(size: 12, weight: .medium))
                            Text(model.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(13).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(ink.opacity(0.08), lineWidth: 1))
    }

    private var currentFormStep: Int {
        if model.verificationSent {
            return model.waitingForCode ? 3 : 4
        }
        return model.isRunning ? 2 : 1
    }

    private var verificationHint: String {
        if model.verificationSent {
            if !model.isRunning { return "本次流程已结束。可修改注册信息后，再次请求验证码。" }
            if model.isRunning && !model.isManualFlow { return "批量任务会在取得验证码后自动完成注册。需要时可在此手动补填。" }
            return model.waitingForCode ? "验证码已发送。确认验证码后，点击「注册用户」完成注册。" : "验证码已就绪，正在完成注册。"
        }
        return "先请求验证码，再填写收到的 6 位验证码。单个账号需点击「注册用户」提交。"
    }

    private func registrationStep(_ number: Int, title: String) -> some View {
        HStack(spacing: 7) {
            Text("\(number)").font(.system(size: 10, weight: .semibold, design: .rounded))
                .frame(width: 21, height: 21)
                .background(number == currentFormStep ? accent : accent.opacity(0.08), in: Circle())
                .foregroundStyle(number == currentFormStep ? .white : accent)
            Text(title).font(.system(size: 11, weight: number == currentFormStep ? .semibold : .regular))
                .foregroundStyle(number == currentFormStep ? ink : .secondary)
        }
    }

    private func connectionStatus(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 11, weight: .medium)).lineLimit(1).help(value)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
                    Text("历史注册截图").font(.system(size: 13, weight: .semibold))
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
            Text(record.status == 0 ? "连接失败" : "\(record.status)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 50).padding(.vertical, 2)
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

/// Summary, request headers, and response details for one API request.
private struct NetworkRecordDetail: View {
    let record: NetworkRecord
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                var summary: [(String, String)] {
                    var rows = [("URL", "https://api.jiucaihezi.studio" + record.path), ("方法", record.method),
                                ("状态", record.status == 0 ? "连接失败" : "\(record.status)"), ("来源", record.transport),
                                ("时间", record.date.formatted(date: .abbreviated, time: .standard))]
                    if let retry = record.retryAfter { rows.append(("Retry-After", retry)) }
                    return rows
                }
                inspectorSection("摘要", rows: summary, keyColor: .green)
                inspectorSection("请求", rows: record.requestHeaders.map { ($0.name, $0.value) }, keyColor: .blue,
                                 empty: "此请求没有记录可显示的请求头。")
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
    @ObservedObject var monitor: RequestMonitor

    @State private var selectedRequest: UUID?
    @State private var newHeaderName = ""
    @State private var newHeaderValue = ""
    private var displayed: RequestHeaderConfiguration { monitor.appliedHeaders ?? model.headerConfiguration }
    private var observation: RequestHeaderObservation? {
        monitor.requestObservations.first(where: { $0.id == selectedRequest }) ?? monitor.requestObservations.first
    }
    private var userAgent: String {
        if monitor.appliedHeaders == nil, let agent = displayed.mode.userAgent { return agent }
        return monitor.currentUserAgent.isEmpty ? (displayed.mode.userAgent ?? "系统默认") : monitor.currentUserAgent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("请求头").font(.system(size: 25, weight: .semibold))
                    Spacer()
                    Label(monitor.appliedHeaderMode == nil ? "等待请求" : "已应用到接口请求", systemImage: monitor.appliedHeaderMode == nil ? "clock" : "checkmark.circle")
                        .font(.system(size: 11)).foregroundStyle(accent)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(accent.opacity(0.08), in: Capsule())
                }
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(monitor.appliedHeaders == nil ? "下次使用的配置" : "最近请求的配置").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(displayed.mode.title).font(.system(size: 18, weight: .semibold))
                        }
                        Spacer()
                        Text("api.jiucaihezi.studio").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Divider()
                    headerRow("User-Agent", value: userAgent)
                    Divider()
                    headerRow("Accept", value: displayed.accept.value ?? "原生默认（未覆盖）")
                    Divider()
                    headerRow("Accept-Language", value: displayed.language.value ?? "系统默认（未覆盖）")
                }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 14) {
                    Text("兼容配置").font(.system(size: 16, weight: .semibold))
                    HStack(alignment: .top, spacing: 24) {
                        Picker("请求标识", selection: $model.headerConfiguration.mode) {
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
                    } else if let applied = monitor.appliedHeaders, applied != model.headerConfiguration {
                        Text("已保存新配置，下次请求时生效。最近请求使用：\(applied.title)。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text("配置自动保存，用于检查连接、请求验证码和提交注册。")
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
                        Text("最近 \(monitor.requestObservations.count) 条 · 仅本次运行").font(.caption).foregroundStyle(.secondary)
                    }
                    if let observation {
                        Picker("查看请求", selection: $selectedRequest) {
                            Text("最新请求").tag(nil as UUID?)
                            ForEach(monitor.requestObservations) { item in
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
                        Text("尚无请求。检查连接、请求验证码或提交注册后，这里会显示实际发送的接口请求。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 13))
                Text("详情显示接口请求及所使用的请求头配置。仅保留所列非敏感字段，网址查询参数、Cookie、Authorization 和请求正文不进入记录。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(28)
        }
        .onChange(of: monitor.requestObservations.map(\.id)) { ids in
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
    @State private var selectedProxies: Set<UUID> = []
    @State private var sourceIntervalDraft = ""
    @State private var sourceURLDraft = ""

    private var proxyControlsLocked: Bool {
        model.isRunning || model.isTestingProxies || model.isRefreshingProxySources
    }

    private var sourceControlsLocked: Bool {
        model.isRefreshingProxySources || !model.storageAvailable
    }

    private var automaticSourceUpdates: Binding<Bool> {
        Binding(
            get: { model.proxyConfiguration.sourceConfiguration.automatic },
            set: { automatic in
                var configuration = model.proxyConfiguration.sourceConfiguration
                configuration.automatic = automatic
                _ = model.saveProxySourceConfiguration(configuration)
            }
        )
    }

    private var registrationProbeConcurrency: Binding<Int> {
        Binding(
            get: { model.proxyConfiguration.sourceConfiguration.registrationConcurrency },
            set: { _ = model.saveRegistrationProxyConcurrency($0) }
        )
    }

    private func resultColor(_ verdict: ProxyManager.TestResult.Verdict) -> Color {
        switch verdict { case .usable: return accent; case .blocked: return .orange; case .unreachable: return .red }
    }

    private var millisecondsFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.usesGroupingSeparator = false
        return formatter
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("代理池").font(.system(size: 25, weight: .semibold))
                        Text("选中代理后直接开始注册；接口无法连接或注册出错时，丢弃当前代理并自动使用下一个。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("启用代理", isOn: $model.proxyConfiguration.enabled)
                        .toggleStyle(.switch).disabled(proxyControlsLocked)
                }

                proxySourceCard

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
                                model.saveProxyLatencyLimits()
                                pasteText = ""
                            }
                        }.disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.storageAvailable || model.isTestingProxies)
                        Button("清空列表") {
                            model.proxyConfiguration.entries.removeAll()
                        }.foregroundStyle(.red.opacity(0.8)).disabled(model.proxyConfiguration.entries.isEmpty || proxyControlsLocked)
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
                    }.disabled(proxyControlsLocked)
                    Text("旧代理优先，新添加的代理排在下一轮末尾；使用前不再测速，注册失败立即丢弃并换下一个。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 10) {
                    Text("测速门槛与请求超时").font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 8) {
                        Text("批量测试")
                        TextField("3000", value: $model.proxyConfiguration.poolTestLimitMilliseconds, formatter: millisecondsFormatter)
                            .frame(width: 90).textFieldStyle(.roundedBorder)
                        Text("ms")
                    }.font(.system(size: 13)).disabled(proxyControlsLocked)
                    Text("任务运行期间可以补充代理。代理全部不可用时，任务保持运行，添加代理后自动继续。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("批量测试超过门槛自动删除。请输入大于 0 的整数，设置自动保存。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("接口请求超时")
                        TextField("10", value: $model.proxyConfiguration.pageLoadingTimeoutSeconds, formatter: millisecondsFormatter)
                            .frame(width: 90).textFieldStyle(.roundedBorder)
                        Text("秒")
                    }.font(.system(size: 13)).disabled(proxyControlsLocked)
                    Text("接口请求超过 \(model.proxyConfiguration.pageLoadingTimeoutSeconds) 秒未完成，自动删除当前代理并尝试下一个。等待邮件验证码不计入此时间。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let error = model.proxyLatencyError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))

                // Proxy list
                LazyVStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("代理列表  \(model.proxyConfiguration.entries.count)").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("启用 \(model.proxyConfiguration.activeEntries.count) 个").font(.caption).foregroundStyle(.secondary)
                        if !selectedProxies.isEmpty {
                            Button("删除选中 (\(selectedProxies.count))") {
                                model.proxyConfiguration.entries.removeAll { selectedProxies.contains($0.id) }
                                selectedProxies.removeAll()
                            }.foregroundStyle(.red.opacity(0.8)).disabled(proxyControlsLocked)
                        }
                        Picker("测试并发", selection: $model.proxyTestConcurrency) {
                            ForEach(1...ProxyManager.maximumBatchConcurrency, id: \.self) { Text("\($0) 个").tag($0) }
                        }.frame(width: 140).disabled(proxyControlsLocked)
                        if model.isTestingProxies {
                            Button("停止测试") { model.stopProxyTests() }
                        } else {
                            Button("全部测试") { model.testProxies(model.proxyConfiguration.entries) }
                                .disabled(model.proxyConfiguration.entries.isEmpty || proxyControlsLocked || model.proxyLatencyError != nil)
                        }
                    }
                    Text("默认同时测试 \(ProxyManager.defaultBatchConcurrency) 个，最多 \(ProxyManager.maximumBatchConcurrency) 个；其余排队，排队时间不计入延时，网络较慢时可调为 1 个。测试超过 \(model.proxyConfiguration.poolTestLimitMilliseconds) ms 或不可用的代理会自动删除。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("批量测速检查接口连接；使用代理时直接开始注册，请求失败自动丢弃并切换下一个。开始注册会先停止手动批量测试，后台自动补充代理继续运行。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.proxyTestsTotal > 0 {
                        HStack(spacing: 12) {
                            ProgressView(value: Double(model.proxyTestsCompleted), total: Double(model.proxyTestsTotal))
                                .frame(maxWidth: 220)
                            Text("已测 \(model.proxyTestsCompleted)/\(model.proxyTestsTotal) · 已丢弃 \(model.proxyTestsDiscarded)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
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
                                Toggle("", isOn: $entry.enabled).labelsHidden().disabled(proxyControlsLocked)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "\(entry.host):\(entry.port)").font(.system(size: 12, design: .monospaced))
                                    if !entry.user.isEmpty {
                                        Text(verbatim: entry.user).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    if model.proxyTestPending.contains(entry.id) {
                                        Text("排队 / 测试中…")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    } else if let result = model.proxyTestResults[entry.id] {
                                        Text(verbatim: result.summary).font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(resultColor(result.verdict)).textSelection(.enabled)
                                    }
                                }
                                Spacer()
                                Button("测试") { model.testProxies([entry]) }.disabled(proxyControlsLocked || model.proxyLatencyError != nil)
                                Button {
                                    model.proxyConfiguration.entries.removeAll { $0.id == entry.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.6))
                                }.buttonStyle(.plain).disabled(proxyControlsLocked)
                            }.padding(.vertical, 4)
                            Divider()
                        }
                    }
                }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))

                Text("代理功能需要 macOS 14 或更高版本。代理密码以明文存储在本地记录文件中，请勿在共享设备上使用。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(28)
        }
        .onAppear {
            sourceIntervalDraft = String(model.proxyConfiguration.sourceConfiguration.intervalMinutes)
        }
        .onChange(of: model.proxyConfiguration.sourceConfiguration.intervalMinutes) { interval in
            sourceIntervalDraft = String(interval)
        }
        .onChange(of: model.proxyConfiguration.entries.count) { _ in
            selectedProxies.formIntersection(model.proxyConfiguration.entries.map(\.id))
        }
        .onChange(of: model.proxyConfiguration.poolTestLimitMilliseconds) { _ in model.saveProxyLatencyLimits() }
        .onChange(of: model.proxyConfiguration.pageLoadingTimeoutSeconds) { _ in model.saveProxyLatencyLimits() }
    }

    private var proxySourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自动补充代理").font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("定时更新", isOn: automaticSourceUpdates)
                    .toggleStyle(.switch).disabled(!model.storageAvailable)
            }
            Text("从来源下载代理列表，自动测速后将可用代理加入代理池。注册运行期间也会持续补充。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("注册请求优先，后台使用较低优先级；减少并发可降低网络占用，被打断的探测稍后重试，不计为不通。")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            Picker("注册时后台并发", selection: registrationProbeConcurrency) {
                Text("0 个（注册请求时让路）").tag(0)
                ForEach(1...3, id: \.self) { count in Text("\(count) 个").tag(count) }
            }.frame(maxWidth: 350, alignment: .leading).disabled(!model.storageAvailable)
            Text("默认 1 个，可在运行中调整。1–3 个与注册同时探测；0 个仅在注册请求间隙探测。任务结束后恢复普通测试并发。")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("更新间隔")
                TextField("60", text: $sourceIntervalDraft)
                    .frame(width: 70).textFieldStyle(.roundedBorder)
                    .onSubmit(saveSourceInterval)
                Text("分钟")
                Button("保存间隔", action: saveSourceInterval)
            }.font(.system(size: 13)).disabled(sourceControlsLocked)

            VStack(alignment: .leading, spacing: 9) {
                Text("代理来源").font(.system(size: 12, weight: .medium))
                ForEach(Array(model.proxyConfiguration.sourceConfiguration.urls.enumerated()), id: \.offset) { index, url in
                    HStack(alignment: .top, spacing: 12) {
                        Text(verbatim: url).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("移除") { removeSourceURL(at: index) }
                            .disabled(sourceControlsLocked)
                    }
                }
                HStack(spacing: 8) {
                    TextField("https://example.com/proxies.txt", text: $sourceURLDraft)
                        .textFieldStyle(.roundedBorder).onSubmit(addSourceURL)
                    Button("添加来源", action: addSourceURL)
                        .disabled(sourceURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.disabled(sourceControlsLocked)
            }

            Divider()
            HStack(spacing: 10) {
                Button("立即更新并测速") { model.refreshProxySources() }
                    .disabled(model.isRefreshingProxySources || model.isTestingProxies || !model.storageAvailable || model.proxyConfiguration.sourceConfiguration.urls.isEmpty || model.proxyLatencyError != nil)
                if model.isRefreshingProxySources {
                    ProgressView().controlSize(.small)
                    Button("停止更新") { model.stopProxySourceRefresh() }
                }
                Spacer()
            }
            if !model.proxySourceStatus.isEmpty {
                Text(model.proxySourceStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("候选 \(model.proxySourceCandidates) · 已测 \(model.proxySourceTested) · 新增 \(model.proxySourceAdded) · 淘汰 \(model.proxySourceRejected)")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("上次更新：\(sourceRefreshDate(model.lastProxySourceRefreshAt, fallback: "尚未更新"))")
                Text("下次更新：\(sourceRefreshDate(model.nextProxySourceRefreshAt, fallback: "未安排"))")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(Array(model.proxySourceErrors.enumerated()), id: \.offset) { _, error in
                Text(verbatim: error).font(.system(size: 11)).foregroundStyle(.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))
    }

    private func saveSourceInterval() {
        guard !sourceControlsLocked else { return }
        var configuration = model.proxyConfiguration.sourceConfiguration
        configuration.intervalMinutes = Int(sourceIntervalDraft.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if model.saveProxySourceConfiguration(configuration) {
            sourceIntervalDraft = String(model.proxyConfiguration.sourceConfiguration.intervalMinutes)
        }
    }

    private func addSourceURL() {
        guard !sourceControlsLocked else { return }
        var configuration = model.proxyConfiguration.sourceConfiguration
        configuration.urls.append(sourceURLDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        if model.saveProxySourceConfiguration(configuration) { sourceURLDraft = "" }
    }

    private func removeSourceURL(at index: Int) {
        guard !sourceControlsLocked else { return }
        var configuration = model.proxyConfiguration.sourceConfiguration
        guard configuration.urls.indices.contains(index) else { return }
        configuration.urls.remove(at: index)
        _ = model.saveProxySourceConfiguration(configuration)
    }

    private func sourceRefreshDate(_ date: Date?, fallback: String) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? fallback
    }
}

private struct NetworkInspectorView: View {
    @ObservedObject var monitor: RequestMonitor
    @State private var selectedID: UUID?

    private var selected: NetworkRecord? {
        monitor.networkRecords.first(where: { $0.id == selectedID }) ?? monitor.networkRecords.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("网络请求").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("最近 \(monitor.networkRecords.count) 条").font(.caption).foregroundStyle(.secondary)
                    Button { monitor.clearNetworkRecords() } label: {
                        Image(systemName: "trash").font(.caption)
                    }.help("清空记录").buttonStyle(.plain).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                if monitor.networkRecords.isEmpty {
                    Text("尚无请求记录。检查连接、请求验证码或提交注册后，这里会显示实际发生的接口请求。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(monitor.networkRecords, selection: $selectedID) { NetworkRequestRow(record: $0).tag($0.id) }
                        .listStyle(.plain)
                }
                Divider()
                Text("记录显示请求时间与响应状态。选择请求可查看详情。")
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
