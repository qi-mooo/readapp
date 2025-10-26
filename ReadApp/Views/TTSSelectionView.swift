import SwiftUI

struct TTSSelectionView: View {
    @EnvironmentObject var apiService: APIService
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var ttsList: [HttpTTS] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("加载中...")
                } else if ttsList.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        
                        Text("暂无 TTS 引擎")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("请在后台添加 TTS 引擎配置")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("重新加载") {
                            Task {
                                await loadTTSList()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                } else {
                    List {
                        Section {
                            ForEach(ttsList) { tts in
                                TTSRow(
                                    tts: tts,
                                    isSelected: preferences.selectedTTSId == tts.id
                                ) {
                                    preferences.selectedTTSId = tts.id
                                }
                            }
                        } header: {
                            Text("选择 TTS 引擎")
                        } footer: {
                            if !preferences.selectedTTSId.isEmpty {
                                Text("当前已选择: \(ttsList.first(where: { $0.id == preferences.selectedTTSId })?.name ?? "未知")")
                                    .foregroundColor(.blue)
                            } else {
                                Text("请选择一个 TTS 引擎用于朗读")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("TTS 引擎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("刷新") {
                        Task {
                            await loadTTSList()
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadTTSList()
            }
            .alert("错误", isPresented: .constant(errorMessage != nil)) {
                Button("确定") {
                    errorMessage = nil
                }
            } message: {
                if let error = errorMessage {
                    Text(error)
                }
            }
        }
    }
    
    private func loadTTSList() async {
        isLoading = true
        errorMessage = nil
        
        do {
            ttsList = try await apiService.fetchTTSList()
            
            // 如果还没选择 TTS 引擎，尝试获取默认的
            if preferences.selectedTTSId.isEmpty && !ttsList.isEmpty {
                // 尝试获取后端默认 TTS
                if let defaultTTS = try? await apiService.fetchDefaultTTS(), !defaultTTS.isEmpty {
                    // 查找匹配的 TTS 引擎
                    if let tts = ttsList.first(where: { $0.url == defaultTTS || $0.name == defaultTTS }) {
                        preferences.selectedTTSId = tts.id
                    } else {
                        // 如果找不到，使用第一个
                        preferences.selectedTTSId = ttsList[0].id
                    }
                } else {
                    // 使用第一个
                    preferences.selectedTTSId = ttsList[0].id
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
}

struct TTSRow: View {
    let tts: HttpTTS
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tts.name)
                        .font(.headline)
                        .foregroundColor(isSelected ? .blue : .primary)
                    
                    if let contentType = tts.contentType {
                        Text(contentType)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                        .font(.title3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

