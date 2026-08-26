import Foundation
import Darwin

@main
struct RuntimeLocatorTests {
    static func main() throws {
        try testVersionRules()
        try testMissingNode()
        try testUnsupportedNode()
        try testMissingHarness()
        try testReadyEnvironment()
        print("RuntimeLocatorTests: 5 项全部通过")
    }

    private static func testVersionRules() throws {
        try expect(!RuntimeLocator.isSupportedNodeVersion("v22.18.0"), "Node 22.18 不应通过")
        try expect(RuntimeLocator.isSupportedNodeVersion("v22.19.0"), "Node 22.19 应通过")
        try expect(!RuntimeLocator.isSupportedNodeVersion("v23.9.0"), "Node 23 不在官方范围")
        try expect(RuntimeLocator.isSupportedNodeVersion("v24.0.0"), "Node 24 应通过")
    }

    private static func testMissingNode() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .needsNode = RuntimeLocator.detect(searchBins: [root.path]) else {
            throw TestFailure("空环境应进入 Node 安装步骤")
        }
    }

    private static func testUnsupportedNode() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try executable(at: root.appendingPathComponent("node"), body: "echo v20.0.0")
        guard case .needsNode = RuntimeLocator.detect(searchBins: [root.path]) else {
            throw TestFailure("不兼容 Node 应进入 Node 安装步骤")
        }
    }

    private static func testMissingHarness() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try compatibleNodeAndNpm(in: root)
        guard case .needsHarness(let node) = RuntimeLocator.detect(searchBins: [root.path]) else {
            throw TestFailure("缺少 dsh 应进入 Harness 安装步骤")
        }
        try expect(node.nodeVersion == "v24.1.0", "应保留检测到的 Node 版本")
    }

    private static func testReadyEnvironment() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try compatibleNodeAndNpm(in: root)
        try executable(at: root.appendingPathComponent("dsh"), body: "echo 9.9.9-test")
        guard case .ready(let runtime) = RuntimeLocator.detect(searchBins: [root.path]) else {
            throw TestFailure("完整环境应检测为 ready")
        }
        try expect(runtime.dshVersion == "9.9.9-test", "应读取 dsh 版本")
    }

    private static func compatibleNodeAndNpm(in directory: URL) throws {
        try executable(at: directory.appendingPathComponent("node"), body: "echo v24.1.0")
        try executable(
            at: directory.appendingPathComponent("npm"),
            body: "if [ \"$1\" = \"--version\" ]; then echo 11.0.0; else echo \"\(directory.path)\"; fi"
        )
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-runtime-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func executable(at url: URL, body: String) throws {
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        guard chmod(url.path, 0o755) == 0 else { throw TestFailure("无法设置测试脚本执行权限") }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message) }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
