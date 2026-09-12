import Foundation

let root = URL(fileURLWithPath: "/Users/scy/Desktop/AI客服记录")
let pending = root.appendingPathComponent("待发送", isDirectory: true)
let runtime = root.appendingPathComponent("运行状态", isDirectory: true)
let arguments = Array(CommandLine.arguments.dropFirst())
let runID = arguments.first ?? "sender-stress-\(Int(Date().timeIntervalSince1970))"
let users = ["stoneshishininger", "tb263147182"]
let countPerUser = arguments.count > 1 ? (Int(arguments[1]) ?? 30) : 30
let messagePrefix = arguments.count > 2 ? arguments[2] : nil
let fileManager = FileManager.default
let timestampFormatter = ISO8601DateFormatter()
timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

try fileManager.createDirectory(at: pending, withIntermediateDirectories: true)
try fileManager.createDirectory(at: runtime, withIntermediateDirectories: true)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
encoder.dateEncodingStrategy = .iso8601

var manifest: [[String: Any]] = []
let baseDate = Date()

for index in 1...countPerUser {
    for (userOffset, uid) in users.enumerated() {
        let taskID = "\(runID)-\(uid)-\(String(format: "%02d", index))"
        let createdAt = timestampFormatter.string(
            from: baseDate.addingTimeInterval(Double((index - 1) * users.count + userOffset) / 1000.0)
        )
        let message = messagePrefix.map {
            "\($0)｜\(uid)｜第\(String(format: "%02d", index))/\(countPerUser)条"
        } ?? UUID().uuidString
        let object: [String: Any] = [
            "schema_version": 1,
            "task_id": taskID,
            "uid": uid,
            "source_history_version": runID,
            "source_task": "sender_stress_test",
            "decision": "auto_send",
            "risk_level": "low",
            "reply_text": message,
            "reason": "用户授权的独立发送功能压力测试",
            "created_at": createdAt,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let destination = pending.appendingPathComponent("\(taskID).json")
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw NSError(domain: "StressTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "任务已存在：\(taskID)"])
        }
        try data.write(to: destination, options: [.atomic])
        manifest.append(["task_id": taskID, "uid": uid, "message": message, "created_at": createdAt])
    }
}

let manifestObject: [String: Any] = [
    "run_id": runID,
    "created_at": timestampFormatter.string(from: Date()),
    "count_per_user": countPerUser,
    "total": manifest.count,
    "tasks": manifest,
]
let manifestData = try JSONSerialization.data(withJSONObject: manifestObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
let manifestURL = runtime.appendingPathComponent("\(runID)-manifest.json")
try manifestData.write(to: manifestURL, options: [.atomic])

print("run_id=\(runID)")
print("queued=\(manifest.count)")
print("manifest=\(manifestURL.path)")
