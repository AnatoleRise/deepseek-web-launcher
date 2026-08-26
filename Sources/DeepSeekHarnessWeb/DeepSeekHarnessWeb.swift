// DeepSeekHarnessWeb.swift
// DeepSeek Harness Web 菜单栏常驻小应用：一键启动/停止 `dsh web` 服务 + 更新哨兵
// 构建：由项目根目录下的 Scripts/build_dmg.sh 统一完成

import SwiftUI
import AppKit

// MARK: - 可分发运行环境：只检测用户机器上的 Node/npm/dsh，不从应用包读取 Harness

struct NodeEnvironment {
    let nodePath: String
    let npmPath: String
    let binPath: String
    let nodeVersion: String
    let globalPrefix: String?
    let brewPath: String?
}

struct RuntimeEnvironment {
    let node: NodeEnvironment
    let dshPath: String
    let dshVersion: String
}

enum RuntimeDetection {
    case needsNode(reason: String, brewPath: String?)
    case needsHarness(NodeEnvironment)
    case ready(RuntimeEnvironment)
}

enum RuntimeLocator {
    /// DeepSeek Harness 当前官方约束：Node ^22.19.0 或 >=24.0.0。
    static func isSupportedNodeVersion(_ value: String) -> Bool {
        let numbers = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .compactMap { Int($0.prefix { $0.isNumber }) }
        guard numbers.count >= 2 else { return false }
        if numbers[0] == 22 { return numbers[1] >= 19 }
        return numbers[0] >= 24
    }

    static func detect(searchBins: [String]? = nil) -> RuntimeDetection {
        let bins = searchBins.map(unique) ?? candidateBinPaths()
        let brewBins = searchBins == nil ? bins + ["/opt/homebrew/bin", "/usr/local/bin"] : bins
        let brewPath = firstExecutable(named: "brew", in: brewBins)
        var unsupportedVersions: [String] = []
        var compatibleWithoutNpm: [String] = []
        var firstUsableNode: NodeEnvironment?

        for bin in bins {
            let node = (bin as NSString).appendingPathComponent("node")
            guard FileManager.default.isExecutableFile(atPath: node),
                  let version = output(of: node, arguments: ["--version"], pathPrefix: bin),
                  !version.isEmpty else { continue }
            guard isSupportedNodeVersion(version) else {
                unsupportedVersions.append(version)
                continue
            }

            let npm = firstExecutable(named: "npm", in: [bin] + bins)
            guard let npm,
                  output(of: npm, arguments: ["--version"], pathPrefix: bin) != nil else {
                compatibleWithoutNpm.append(version)
                continue
            }

            let prefix = output(of: npm, arguments: ["prefix", "--global"], pathPrefix: bin)
            var dshBins = [bin]
            if let prefix, !prefix.isEmpty {
                dshBins.append((prefix as NSString).appendingPathComponent("bin"))
            }
            dshBins.append(contentsOf: bins)

            let nodeEnvironment = NodeEnvironment(
                nodePath: node,
                npmPath: npm,
                binPath: bin,
                nodeVersion: version,
                globalPrefix: prefix,
                brewPath: brewPath
            )
            if firstUsableNode == nil { firstUsableNode = nodeEnvironment }

            guard let dsh = firstExecutable(named: "dsh", in: unique(dshBins)),
                  let dshVersion = output(of: dsh, arguments: ["--version"], pathPrefix: bin),
                  !dshVersion.isEmpty else {
                continue
            }
            return .ready(RuntimeEnvironment(node: nodeEnvironment, dshPath: dsh, dshVersion: dshVersion))
        }

        if let firstUsableNode {
            return .needsHarness(firstUsableNode)
        }

        let reason: String
        if let version = compatibleWithoutNpm.first {
            reason = "已找到 Node \(version)，但没有可用的 npm。请重新安装完整的 Node.js。"
        } else if unsupportedVersions.isEmpty {
            reason = "没有检测到 Node.js。DeepSeek Harness 需要 Node 22.19+（仅 22.x）或 Node 24+。"
        } else {
            reason = "检测到不兼容的 Node \(unsupportedVersions.joined(separator: "、"))。需要 Node 22.19+（仅 22.x）或 Node 24+。"
        }
        return .needsNode(reason: reason, brewPath: brewPath)
    }

    static func output(of executable: String, arguments: [String], pathPrefix: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = pathPrefix + ":" + (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func candidateBinPaths() -> [String] {
        let home = NSHomeDirectory()
        var result = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            let sorted = versions.filter { $0.hasPrefix("v") }.sorted {
                HarnessProcessManager.compareVersion($0, $1) > 0
            }
            result.append(contentsOf: sorted.map { nvmRoot + "/" + $0 + "/bin" })
        }

        result.append(contentsOf: [
            home + "/.volta/bin",
            home + "/.asdf/shims",
            home + "/.local/share/fnm/aliases/default/bin",
            home + "/.fnm/aliases/default/bin",
            "/opt/homebrew/opt/node@24/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ])
        return unique(result)
    }

    private static func firstExecutable(named name: String, in bins: [String]) -> String? {
        for bin in unique(bins) {
            let path = (bin as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - 首次启动协调器：检测、分步安装、重试与启动服务

final class BootstrapCoordinator: ObservableObject {
    enum Step {
        case checking
        case node
        case harness
        case installingNode
        case installingHarness
        case ready
    }

    static let shared = BootstrapCoordinator()

    @Published private(set) var step: Step = .checking
    @Published private(set) var message = "正在检测运行环境…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var installOutput = ""
    @Published private(set) var nodeEnvironment: NodeEnvironment?
    @Published private(set) var brewPath: String?

    private var activeProcess: Process?
    private var hasLaunchedService = false

    var isReady: Bool { step == .ready }
    var isInstalling: Bool { step == .installingNode || step == .installingHarness }

    func begin() {
        recheck()
    }

    func recheck() {
        guard !isInstalling else { return }
        step = .checking
        message = "正在检测 Node.js、npm 和 DeepSeek Harness…"
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let detection = RuntimeLocator.detect()
            DispatchQueue.main.async { self.apply(detection) }
        }
    }

    func showSetup() {
        SetupWindowController.shared.show()
    }

    func openNodeDownload() {
        NSWorkspace.shared.open(URL(string: "https://nodejs.org/en/download")!)
    }

    func copyNodeCommand() {
        copy("brew install node@24")
    }

    func copyHarnessCommand() {
        copy("npm install -g @deepseek-ai/dsh")
    }

    func installNodeWithHomebrew() {
        guard let brewPath else {
            errorMessage = "没有检测到 Homebrew，请使用 Node.js 官方安装器。"
            return
        }
        step = .installingNode
        message = "正在使用 Homebrew 安装 Node 24…"
        runInstaller(
            executable: brewPath,
            arguments: ["install", "node@24"],
            pathPrefix: (brewPath as NSString).deletingLastPathComponent,
            fallbackStep: .node
        )
    }

    func installHarness() {
        guard let nodeEnvironment else {
            errorMessage = "Node/npm 环境已失效，请重新检测。"
            step = .node
            return
        }
        step = .installingHarness
        message = "正在全局安装 DeepSeek Harness…"
        runInstaller(
            executable: nodeEnvironment.npmPath,
            arguments: ["install", "--global", HarnessUpdateManager.packageName],
            pathPrefix: nodeEnvironment.binPath,
            fallbackStep: .harness
        )
    }

    func exitApplication() {
        NSApp.terminate(nil)
    }

    private func apply(_ detection: RuntimeDetection) {
        switch detection {
        case .needsNode(let reason, let brew):
            nodeEnvironment = nil
            brewPath = brew
            step = .node
            message = reason
            showSetup()
        case .needsHarness(let node):
            nodeEnvironment = node
            brewPath = node.brewPath
            step = .harness
            message = "Node \(node.nodeVersion) 与 npm 已就绪，但没有检测到全局 DeepSeek Harness。"
            showSetup()
        case .ready(let runtime):
            nodeEnvironment = runtime.node
            brewPath = runtime.node.brewPath
            step = .ready
            message = "运行环境已就绪。"
            HarnessProcessManager.shared.configure(runtime: runtime)
            HarnessUpdateManager.shared.startAutomaticChecks()
            SetupWindowController.shared.closeAfterSuccess()
            if !hasLaunchedService {
                hasLaunchedService = true
                HarnessProcessManager.shared.start(openWebOnLaunch: true)
            }
        }
    }

    private func runInstaller(
        executable: String,
        arguments: [String],
        pathPrefix: String,
        fallbackStep: Step
    ) {
        errorMessage = nil
        installOutput = "$ \(([executable] + arguments).joined(separator: " "))\n"
        HarnessProcessManager.shared.appendLog("\n===== 安装向导执行：\(([executable] + arguments).joined(separator: " ")) =====")

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = pathPrefix + ":" + (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        activeProcess = process

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendInstallerOutput(text)
            HarnessProcessManager.shared.appendLog(text.trimmingCharacters(in: .newlines))
        }

        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeProcess = nil
                if finished.terminationStatus == 0 {
                    self.message = "安装命令执行完成，正在重新检测…"
                    self.step = .checking
                    self.recheck()
                } else {
                    self.step = fallbackStep
                    self.errorMessage = "安装失败（退出码 \(finished.terminationStatus)）。不会自动使用 sudo，请查看输出或改用手动安装。"
                }
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            activeProcess = nil
            step = fallbackStep
            errorMessage = "无法启动安装命令：\(error.localizedDescription)"
        }
    }

    private func appendInstallerOutput(_ text: String) {
        DispatchQueue.main.async {
            self.installOutput += text
            if self.installOutput.count > 24_000 {
                self.installOutput = String(self.installOutput.suffix(24_000))
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

// MARK: - 进程管理器：探测 dsh 路径、启动/停止进程、维护运行状态

final class HarnessProcessManager: ObservableObject {
    enum RunState {
        case stopped
        case running
    }

    @Published private(set) var state: RunState = .stopped
    @Published private(set) var runtime: RuntimeEnvironment?
    private var process: Process?
    let logFileURL: URL

    /// dsh web 的固定访问地址（默认 host/port 见 cordis.patch.yml）
    static let webURL = URL(string: "http://127.0.0.1:3080")!

    /// 单例：菜单 UI 与 AppDelegate 收尾逻辑共享同一份进程状态
    static let shared = HarnessProcessManager()

    init() {
        // 日志文件固定放在 ~/Library/Logs/deepseek-harness-web.log
        let logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logFileURL = logsDir.appendingPathComponent("deepseek-harness-web.log")
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
    }

    /// 语义化版本比较（"v24.13.0" vs "v24.9.0" 按数字段比较），返回 -1/0/1
    static func compareVersion(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            let trimmed = s.hasPrefix("v") ? String(s.dropFirst()) : s
            return trimmed.split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a)
        let pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    // MARK: 启动 / 停止

    func configure(runtime: RuntimeEnvironment) {
        self.runtime = runtime
    }

    /// 启动前预检：清理占用 3080 的遗留 dsh 进程（如旧实例异常退出后的孤儿），
    /// 避免新服务 EADDRINUSE 秒崩后面板状态翻回「未运行」。
    /// 只处置 dsh 进程；其他程序占用端口仅记日志，不擅自处置。
    private func reclaimWebPortIfNeeded() {
        let port = String(Self.webURL.port ?? 3080)
        guard let pids = listeningPIDs(onPort: port), !pids.isEmpty else { return }
        for pid in pids {
            let command = processCommandLine(of: pid)
            guard command.contains("dsh") else {
                appendLog("端口 \(port) 被 PID \(pid)（\(command)）占用，不属于 dsh 进程，跳过清理")
                continue
            }
            appendLog("检测到遗留 dsh 进程占用 \(port)（PID \(pid)），自动清理后接管服务")
            kill(pid, SIGTERM)
            var waited: TimeInterval = 0
            while kill(pid, 0) == 0 && waited < 1.5 {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    /// 查询监听指定 TCP 端口的进程 PID（空数组表示端口空闲）
    private func listeningPIDs(onPort port: String) -> [Int32]? {
        let probe = Process()
        let pipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        probe.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        probe.standardOutput = pipe
        probe.standardError = Pipe()
        do {
            try probe.run()
            probe.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int32($0) }
            .filter { $0 > 0 } ?? []
    }

    /// 读取进程完整命令行（用于确认端口占用者是否为 dsh）
    private func processCommandLine(of pid: Int32) -> String {
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", String(pid)]
        ps.standardOutput = pipe
        ps.standardError = Pipe()
        do {
            try ps.run()
            ps.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 启动服务；仅应用首次启动时允许 dsh 自动打开浏览器，其余启动路径保持静默。
    func start(openWebOnLaunch: Bool = false) {
        if state == .running {
            if openWebOnLaunch {
                openWebUI()
            }
            return
        }
        guard let runtime else {
            appendLog("运行环境尚未通过检测，已阻止启动 dsh web")
            BootstrapCoordinator.shared.showSetup()
            NSSound.beep()
            return
        }

        // 启动前预检：清理遗留 dsh web 进程再接管 3080，避免秒崩导致状态翻回
        reclaimWebPortIfNeeded()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: runtime.dshPath)
        p.arguments = openWebOnLaunch ? ["web"] : ["web", "--no-open"]

        // dsh 是 `#!/usr/bin/env node` 脚本，PATH 必须优先使用通过检测的 Node。
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = runtime.node.binPath + ":" + (env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        p.environment = env

        appendLog("\n===== \(timestamp()) 由菜单栏按钮启动 dsh web =====")
        if let handle = FileHandle(forWritingAtPath: logFileURL.path) {
            defer { try? handle.close() } // run() 之后子进程已持有 fd，父进程关闭自身副本安全
            _ = try? handle.seekToEnd()
            p.standardOutput = handle
            p.standardError = handle
            do {
                try p.run()
                process = p
                state = .running
                p.terminationHandler = { [weak self] _ in
                    DispatchQueue.main.async { self?.processDidExit() }
                }
            } catch {
                appendLog("启动失败：\(error.localizedDescription)")
                NSSound.beep()
            }
        }
    }

    /// 停止服务：先 SIGINT（dsh 内部有优雅关闭），超时升级 SIGTERM，仍不行 SIGKILL
    func stop() {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        DispatchQueue.global().async {
            var waited: TimeInterval = 0
            while p.isRunning && waited < 5.5 {
                Thread.sleep(forTimeInterval: 0.2)
                waited += 0.2
            }
            if p.isRunning {
                p.terminate()
                Thread.sleep(forTimeInterval: 2)
                if p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }
    }

    /// 供更新流程使用：发 SIGINT 后阻塞等待服务退出（请在后台线程调用），
    /// 状态刷新交给 terminationHandler 在主线程完成
    func stopAndWait(timeout: TimeInterval) {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    /// 退出应用前的同步收尾：主线程短暂等待，确保不留孤儿 node 进程
    func shutdownSync(timeout: TimeInterval = 3) {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
        process = nil
        state = .stopped
    }

    /// 子进程退出（无论正常、报错还是被杀）后统一回到"未运行"态
    private func processDidExit() {
        process = nil
        state = .stopped
    }

    // MARK: 辅助动作

    func openWebUI() {
        NSWorkspace.shared.open(Self.webURL)
    }

    func openLog() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        NSWorkspace.shared.open(logFileURL)
    }

    /// 追加一行日志（供更新哨兵共用）
    func appendLog(_ text: String) {
        if let handle = FileHandle(forWritingAtPath: logFileURL.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write((text + "\n").data(using: .utf8)!)
        }
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - 更新哨兵：检测 @deepseek-ai/dsh 新版本，一键执行 npm update -g

final class HarnessUpdateManager: ObservableObject {
    enum UpdateState {
        case idle                            // 未检查或已是最新
        case checking                        // 检测中
        case available(remote: String)       // 有新版本（红点亮起）
        case updating                        // 升级执行中
        case failed(String)                  // 检测或升级失败（详情见日志）
    }

    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var localVersion: String?

    static let packageName = "@deepseek-ai/dsh"
    static let shared = HarnessUpdateManager(processManager: HarnessProcessManager.shared)
    /// 自动复查间隔：24 小时
    private let recheckInterval: TimeInterval = 24 * 3600
    /// registry 检测超时
    private let requestTimeout: TimeInterval = 10

    private let processManager: HarnessProcessManager
    private var didStartAutomaticChecks = false

    init(processManager: HarnessProcessManager) {
        self.processManager = processManager
    }

    // MARK: 定时调度

    func startAutomaticChecks() {
        guard !didStartAutomaticChecks else { return }
        didStartAutomaticChecks = true
        // 只有安装引导确认运行环境后才开始检查，避免把“未安装”误报为更新失败。
        scheduleNext(delay: 3)
    }

    private func scheduleNext(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.checkForUpdates()
            self.scheduleNext(delay: self.recheckInterval)
        }
    }

    // MARK: 版本检测

    /// 从检测到的全局 dsh 读取版本，不假设用户使用 nvm。
    private func readLocalVersion() -> String? {
        guard let runtime = processManager.runtime else { return nil }
        return RuntimeLocator.output(
            of: runtime.dshPath,
            arguments: ["--version"],
            pathPrefix: runtime.node.binPath
        )
    }

    /// 组装 registry 检测 URL：优先尊重 ~/.npmrc 里配置的源（将来配镜像也不失灵），否则官方源
    private func registryURL() -> URL? {
        var registry = "https://registry.npmjs.org"
        if let npmrc = try? String(contentsOfFile: NSHomeDirectory() + "/.npmrc", encoding: .utf8) {
            for line in npmrc.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("registry=") {
                    let value = trimmed.dropFirst("registry=".count)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    if !value.isEmpty { registry = value }
                }
            }
        }
        if !registry.hasSuffix("/") { registry += "/" }
        return URL(string: registry + Self.packageName + "/latest")
    }

    /// 检测更新（菜单「检查更新」与定时任务共用入口）
    func checkForUpdates() {
        state = .checking
        localVersion = readLocalVersion()
        guard let url = registryURL() else {
            state = .failed("无法确定 registry 地址")
            processManager.appendLog("更新检测失败：无法确定 registry 地址")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.state = .failed("网络错误")
                    self.processManager.appendLog("更新检测失败（网络）：\(error.localizedDescription)")
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let remote = json["version"] as? String else {
                    self.state = .failed("registry 响应解析失败")
                    self.processManager.appendLog("更新检测失败：registry 响应无法解析")
                    return
                }
                if let local = self.localVersion,
                   HarnessProcessManager.compareVersion(remote, local) > 0 {
                    self.state = .available(remote: remote)
                    self.processManager.appendLog("发现新版本：本地 \(local) → 远程 \(remote)")
                } else {
                    self.state = .idle
                    self.processManager.appendLog("版本检测：本地 \(self.localVersion ?? "?") / 远程 \(remote)，已是最新")
                }
            }
        }.resume()
    }

    // MARK: 一键升级

    /// 执行 npm update -g @deepseek-ai/dsh：先优雅停服务，升级完自动恢复原状
    func performUpdate() {
        guard case .available = state else { return }
        state = .updating
        processManager.appendLog("\n===== \(self.now()) 开始一键升级 dsh =====")
        let wasRunning = processManager.state == .running

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            // 1. 服务在跑则先优雅停止（替换运行中的包文件不可靠）
            if wasRunning {
                self.processManager.stopAndWait(timeout: 8)
            }
            // 2. 执行 npm update
            let code = self.runNpmUpdate()
            let refreshed = RuntimeLocator.detect()
            // 3. 回主线程刷新状态并恢复服务
            DispatchQueue.main.async {
                var newVersion = self.readLocalVersion()
                if case .ready(let runtime) = refreshed {
                    self.processManager.configure(runtime: runtime)
                    newVersion = runtime.dshVersion
                }
                if code == 0 {
                    self.localVersion = newVersion
                    self.state = .idle
                    self.processManager.appendLog("升级完成：npm update 退出码 0，当前版本 \(newVersion ?? "?")")
                } else {
                    self.state = .failed("npm update 退出码 \(code)")
                    self.processManager.appendLog("升级失败：npm update 退出码 \(code)，详情见上方 npm 输出")
                }
                // 无论成败，更新前在跑的服务都恢复
                if wasRunning {
                    self.processManager.start()
                }
            }
        }
    }

    /// 子进程执行 npm update，输出追加到统一日志；返回退出码（-1 为启动失败）
    private func runNpmUpdate() -> Int32 {
        guard let runtime = processManager.runtime else { return -1 }
        let npmPath = runtime.node.npmPath
        guard FileManager.default.isExecutableFile(atPath: npmPath) else { return -1 }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: npmPath)
        p.arguments = ["update", "-g", Self.packageName]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = runtime.node.binPath + ":" + (env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        p.environment = env

        var handle: FileHandle?
        if let h = FileHandle(forWritingAtPath: processManager.logFileURL.path) {
            _ = try? h.seekToEnd()
            p.standardOutput = h
            p.standardError = h
            handle = h
        }
        defer { try? handle?.close() }
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            processManager.appendLog("npm 启动失败：\(error.localizedDescription)")
            return -1
        }
    }

    private func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - 鲸鱼图标（dsh 官方 favicon，反色版，作为菜单栏 template 图标）

extension HarnessProcessManager {
    /// 从 app 资源加载官方鲸鱼 SVG，缩放到指定尺寸并设为 template，
    /// 由系统按菜单栏深浅色自动渲染（浅色栏黑鲸、深色栏白鲸）
    static func whaleTemplateImage(pointSize: CGFloat = 16) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "whale", withExtension: "svg"),
              let svg = NSImage(contentsOf: url), svg.isValid else {
            return nil
        }
        let small = NSImage(size: NSSize(width: pointSize, height: pointSize))
        small.lockFocus()
        svg.draw(in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize),
                 from: .zero, operation: .sourceOver, fraction: 1)
        small.unlockFocus()
        small.isTemplate = true
        return small
    }
}

// MARK: - 应用入口

#if !RUNTIME_LOCATOR_TEST
@main
struct DeepSeekHarnessWebApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var manager = HarnessProcessManager.shared
    @StateObject private var updater = HarnessUpdateManager.shared
    @StateObject private var bootstrap = BootstrapCoordinator.shared
    /// 菜单栏鲸鱼图标（加载失败时回退 SF Symbol）
    private let whaleBar = HarnessProcessManager.whaleTemplateImage()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(manager)
                .environmentObject(updater)
                .environmentObject(bootstrap)
        } label: {
            menuBarLabel
        }
        // window 样式：弹出的是"活的"面板——按钮点击不关闭、状态实时刷新、可显示旋转动画
        .menuBarExtraStyle(.window)
    }

    /// 菜单栏图标：鲸鱼（运行状态控制透明度）+ 有新版本时右下角红点
    @ViewBuilder
    private var menuBarLabel: some View {
        if let whaleBar {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: whaleBar)
                    .opacity(manager.state == .running ? 1.0 : 0.35)
                if case .available = updater.state {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                        .offset(x: 1, y: 1)
                }
            }
        } else {
            Image(systemName: manager.state == .running ? "globe" : "stop.circle")
        }
    }
}
#endif

/// 处理退出收尾与"再次双击图标"事件
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        BootstrapCoordinator.shared.begin()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出应用前优雅带走 dsh 服务，不留孤儿 node 进程
        HarnessProcessManager.shared.shutdownSync()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // 环境未完成时重新显示向导；已就绪时只确保服务启动，不重复打开浏览器。
        if BootstrapCoordinator.shared.isReady {
            HarnessProcessManager.shared.start()
        } else {
            BootstrapCoordinator.shared.showSetup()
        }
        return true
    }
}

// MARK: - 面板内容（macOS 26 原生 Liquid Glass + 系统菜单层级）

struct MenuContent: View {
    @EnvironmentObject var manager: HarnessProcessManager
    @EnvironmentObject var updater: HarnessUpdateManager
    @EnvironmentObject var bootstrap: BootstrapCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider().padding(.horizontal, 12)

            VStack(spacing: 2) {
                if bootstrap.isReady {
                    MenuActionRow(
                        title: manager.state == .running ? "停止服务" : "启动服务",
                        systemImage: manager.state == .running ? "stop.circle" : "play.circle",
                        tint: manager.state == .running ? .red : .accentColor
                    ) {
                        if manager.state == .running {
                            manager.stop()
                        } else {
                            manager.start()
                        }
                    }

                    MenuActionRow(
                        title: "打开 DeepSeek Harness Web 页面",
                        systemImage: "safari",
                        isEnabled: manager.state == .running
                    ) {
                        manager.openWebUI()
                    }
                } else {
                    MenuActionRow(
                        title: "完成安装设置…",
                        systemImage: "shippingbox.and.arrow.backward"
                    ) {
                        bootstrap.showSetup()
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            Divider().padding(.horizontal, 12)

            VStack(spacing: 2) {
                if bootstrap.isReady {
                    updateActionRow
                }

                MenuActionRow(
                    title: "查看日志…",
                    systemImage: "doc.text.magnifyingglass"
                ) {
                    manager.openLog()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            Divider().padding(.horizontal, 12)

            MenuActionRow(
                title: "退出 DeepSeek Harness Web",
                systemImage: "power",
                tint: .secondary
            ) {
                NSApp.terminate(nil)
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .frame(width: 300)
    }

    /// 状态头只承载信息，不再与操作按钮争夺视觉层级。
    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("DeepSeek Harness Web")
                    .font(.title3.bold())

                Spacer(minLength: 12)

                Circle()
                    .fill(manager.state == .running ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
                    .shadow(
                        color: manager.state == .running ? Color.green.opacity(0.35) : .clear,
                        radius: 3
                    )
                    .accessibilityLabel(manager.state == .running ? "服务正在运行" : "服务已停止")
            }

            Text(statusSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var statusSubtitle: String {
        if !bootstrap.isReady { return bootstrap.message }
        return manager.state == .running ? "运行中 · 127.0.0.1:3080" : "未运行"
    }

    /// 更新入口随五种状态变化，但始终占据同一个菜单位置，避免面板跳动。
    @ViewBuilder
    private var updateActionRow: some View {
        switch updater.state {
        case .available(let remote):
            MenuActionRow(
                title: "立即升级到 dsh \(remote)",
                subtitle: updateSubtitle,
                systemImage: "arrow.up.circle.fill",
                tint: .orange
            ) {
                updater.performUpdate()
            }
        case .checking:
            MenuActionRow(
                title: "正在检查更新…",
                subtitle: updateSubtitle,
                systemImage: "arrow.triangle.2.circlepath",
                isEnabled: false,
                showsProgress: true
            ) {}
        case .updating:
            MenuActionRow(
                title: "正在升级 dsh…",
                subtitle: updateSubtitle,
                systemImage: "arrow.down.circle",
                isEnabled: false,
                showsProgress: true
            ) {}
        case .failed:
            MenuActionRow(
                title: "重新检查更新",
                subtitle: "上次检查失败 · 详情见日志",
                systemImage: "exclamationmark.triangle.fill",
                tint: .yellow
            ) {
                updater.checkForUpdates()
            }
        case .idle:
            MenuActionRow(
                title: "检查更新",
                subtitle: updateSubtitle,
                systemImage: "checkmark.circle.fill",
                tint: .green
            ) {
                updater.checkForUpdates()
            }
        }
    }

    private var updateSubtitle: String {
        switch updater.state {
        case .idle:
            "dsh \(updater.localVersion ?? "?") · 已是最新版"
        case .checking:
            "dsh \(updater.localVersion ?? "?") · 正在检查"
        case .available(let remote):
            "dsh \(updater.localVersion ?? "?") → \(remote)"
        case .updating:
            "当前 \(updater.localVersion ?? "?") · 服务将自动恢复"
        case .failed:
            "dsh \(updater.localVersion ?? "?") · 更新检测失败"
        }
    }
}

/// 原生菜单式整行按钮：保留系统玻璃作为唯一外层材质，仅补充菜单悬停反馈。
struct MenuActionRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    var tint: Color = .accentColor
    var isEnabled: Bool = true
    var showsProgress: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isEnabled ? tint : Color.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, subtitle == nil ? 8 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering && isEnabled ? Color.primary.opacity(0.08) : .clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 原生分步安装向导

final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()

    private var window: NSWindow?
    private var closingAfterSuccess = false

    func show() {
        if window == nil {
            let content = SetupView().environmentObject(BootstrapCoordinator.shared)
            let controller = NSHostingController(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "DeepSeek Harness Web 安装向导"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func closeAfterSuccess() {
        guard let window, window.isVisible else { return }
        closingAfterSuccess = true
        window.close()
        closingAfterSuccess = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingAfterSuccess { return true }
        DispatchQueue.main.async { BootstrapCoordinator.shared.exitApplication() }
        return false
    }
}

struct SetupView: View {
    @EnvironmentObject var bootstrap: BootstrapCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DeepSeek Harness Web 安装向导")
                        .font(.title2.bold())
                    Text("启动器不会打包 DeepSeek Harness，所有安装均由您决定。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            stepIndicator

            VStack(alignment: .leading, spacing: 12) {
                Text(bootstrap.message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = bootstrap.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                stepContent
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack {
                Button("退出应用", role: .cancel) {
                    bootstrap.exitApplication()
                }
                .buttonStyle(.glass)
                .disabled(bootstrap.isInstalling)

                Spacer()

                Button("重新检测") {
                    bootstrap.recheck()
                }
                .buttonStyle(.glass)
                .disabled(bootstrap.isInstalling)
            }
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 440)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var stepIndicator: some View {
        HStack(spacing: 10) {
            stepBadge(number: "1", title: "Node.js", isActive: nodeStepActive, isComplete: nodeStepComplete)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
            stepBadge(number: "2", title: "Harness", isActive: harnessStepActive, isComplete: bootstrap.isReady)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
            stepBadge(number: "3", title: "启动", isActive: bootstrap.isReady, isComplete: bootstrap.isReady)
        }
    }

    private func stepBadge(number: String, title: String, isActive: Bool, isComplete: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green : (isActive ? Color.accentColor : Color.secondary.opacity(0.25)))
                    .frame(width: 22, height: 22)
                Image(systemName: isComplete ? "checkmark" : number + ".circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
            Text(title)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive || isComplete ? Color.primary : Color.secondary)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch bootstrap.step {
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在读取用户环境，不会安装或修改任何内容。")
                    .foregroundStyle(.secondary)
            }
        case .node:
            VStack(alignment: .leading, spacing: 10) {
                Text("请先安装兼容的 Node.js。完成后回到这里点击“重新检测”。")
                    .foregroundStyle(.secondary)

                HStack {
                    Button("打开 Node.js 官方安装页") {
                        bootstrap.openNodeDownload()
                    }
                    .buttonStyle(.glassProminent)

                    if bootstrap.brewPath != nil {
                        Button("使用 Homebrew 安装 Node 24") {
                            bootstrap.installNodeWithHomebrew()
                        }
                        .buttonStyle(.glass)

                        Button("复制命令") {
                            bootstrap.copyNodeCommand()
                        }
                        .buttonStyle(.glass)
                    }
                }

                Text("不会自动安装 Homebrew，也不会使用 sudo。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .harness:
            VStack(alignment: .leading, spacing: 10) {
                if let node = bootstrap.nodeEnvironment {
                    Label("Node \(node.nodeVersion)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text("启动器将通过 npm 为当前用户执行全局安装，不会使用本机预置副本。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("全局安装 DeepSeek Harness") {
                        bootstrap.installHarness()
                    }
                    .buttonStyle(.glassProminent)
                    Button("复制手动安装命令") {
                        bootstrap.copyHarnessCommand()
                    }
                    .buttonStyle(.glass)
                }
                Text("命令：npm install -g @deepseek-ai/dsh")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        case .installingNode, .installingHarness:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(bootstrap.step == .installingNode ? "正在安装 Node 24…" : "正在安装 DeepSeek Harness…")
                        .font(.headline)
                }
                ScrollView {
                    Text(bootstrap.installOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
        case .ready:
            Label("环境已就绪，正在启动 DeepSeek Harness Web。", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
        }
    }

    private var nodeStepActive: Bool {
        bootstrap.step == .checking || bootstrap.step == .node || bootstrap.step == .installingNode
    }

    private var nodeStepComplete: Bool {
        bootstrap.step == .harness || bootstrap.step == .installingHarness || bootstrap.step == .ready
    }

    private var harnessStepActive: Bool {
        bootstrap.step == .harness || bootstrap.step == .installingHarness
    }
}
