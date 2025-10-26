import Foundation

class LogManager {
    static let shared = LogManager()
    
    private var logs: [String] = []
    private let maxLogs = 1000
    private let queue = DispatchQueue(label: "com.readapp.logmanager", qos: .utility)
    
    private init() {
        log("应用启动", category: "系统")
    }
    
    func log(_ message: String, category: String = "通用") {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let logEntry = "[\(timestamp)] [\(category)] \(message)"
            
            self.logs.append(logEntry)
            
            // 限制日志数量
            if self.logs.count > self.maxLogs {
                self.logs.removeFirst(self.logs.count - self.maxLogs)
            }
            
            // 同时输出到控制台
            print(logEntry)
        }
    }
    
    func getAllLogs() -> String {
        return queue.sync {
            return logs.joined(separator: "\n")
        }
    }
    
    func exportLogs() -> URL? {
        let logsText = getAllLogs()
        
        // 创建临时文件
        let fileName = "ReadApp_Log_\(Date().timeIntervalSince1970).txt"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            try logsText.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            print("导出日志失败: \(error)")
            return nil
        }
    }
    
    func clearLogs() {
        queue.async { [weak self] in
            self?.logs.removeAll()
            self?.log("日志已清空", category: "系统")
        }
    }
    
    func getLogCount() -> Int {
        return queue.sync {
            return logs.count
        }
    }
}


