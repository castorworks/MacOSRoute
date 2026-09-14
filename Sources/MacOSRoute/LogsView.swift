import AppKit
import RouteShared
import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var client: HelperClient
    @State private var onlyProblems = false
    @State private var search = ""

    private var logs: [LogEntry] {
        (client.state?.logs ?? []).reversed().filter { entry in
            (!onlyProblems || entry.level != .info) && (search.isEmpty || entry.message.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("只看警告和错误", isOn: $onlyProblems)
                Spacer()
                Text("\(logs.count) 条 · 完整日志：\(RouteConstants.helperLogPath)")
                    .foregroundStyle(.secondary)
                Button("在访达中显示") {
                    NSWorkspace.shared.selectFile(RouteConstants.helperLogPath, inFileViewerRootedAtPath: "")
                }
                Button("复制") {
                    let text = logs.reversed().map { "\($0.date.formatted(date: .numeric, time: .standard)) [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .controlSize(.small)
            .padding(12)
            Divider()
            List(logs) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.date.formatted(date: .omitted, time: .standard))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: symbol(entry.level)).foregroundStyle(color(entry.level))
                    Text(entry.message).textSelection(.enabled)
                }
            }
        }
        .searchable(text: $search, prompt: "搜索日志")
    }

    private func symbol(_ level: LogEntry.Level) -> String {
        switch level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
