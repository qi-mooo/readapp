import SwiftUI

struct LoginView: View {
    @EnvironmentObject var apiService: APIService
    @StateObject private var preferences = UserPreferences.shared
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showServerSettings = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Spacer()
                
                Image(systemName: "book.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("ReadApp")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Spacer()
                
                if !preferences.serverURL.isEmpty {
                    HStack {
                        Text("服务器:")
                            .foregroundColor(.secondary)
                        Text(preferences.serverURL)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button(action: { showServerSettings = true }) {
                            Image(systemName: "gear")
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                
                VStack(spacing: 16) {
                    TextField("用户名", text: $username)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .disabled(isLoading)
                    
                    SecureField("密码", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(isLoading)
                    
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    
                    Button(action: handleLogin) {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        } else {
                            Text("登录")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        }
                    }
                    .background(canLogin ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .disabled(!canLogin || isLoading)
                }
                .padding(.horizontal, 30)
                
                if preferences.serverURL.isEmpty {
                    Button(action: { showServerSettings = true }) {
                        HStack {
                            Image(systemName: "server.rack")
                            Text("设置服务器地址")
                        }
                        .foregroundColor(.blue)
                    }
                    .padding(.top, 10)
                }
                
                Spacer()
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showServerSettings) {
                ServerSettingsView()
            }
        }
    }
    
    private var canLogin: Bool {
        !username.isEmpty && !password.isEmpty && !preferences.serverURL.isEmpty
    }
    
    private func handleLogin() {
        guard canLogin else { return }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let accessToken = try await apiService.login(username: username, password: password)
                
                await MainActor.run {
                    preferences.accessToken = accessToken
                    preferences.username = username
                    preferences.isLoggedIn = true
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - 服务器设置视图
struct ServerSettingsView: View {
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.dismiss) var dismiss
    @State private var testingConnection = false
    @State private var testResult: String?
    @State private var testSuccess: Bool = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("服务器配置")) {
                    TextField("服务器地址", text: $preferences.serverURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .disableAutocorrection(true)

                    Text("示例: http://192.168.1.100:8080")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    Text("⚠️ 重要提示")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("必须填写 http:// 或 https:// 前缀")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Section(header: Text("连接测试")) {
                    Button(action: testConnection) {
                        HStack {
                            if testingConnection {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                Text("测试中...")
                            } else {
                                Image(systemName: "network")
                                Text("测试服务器连接")
                            }
                            Spacer()
                        }
                    }
                    .disabled(preferences.serverURL.isEmpty || testingConnection)
                    
                    if let result = testResult {
                        HStack {
                            Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(testSuccess ? .green : .red)
                            Text(result)
                                .font(.caption)
                                .foregroundColor(testSuccess ? .green : .red)
                        }
                    }
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("连接失败？请检查：")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("1. 服务器已启动并监听正确端口")
                            .font(.caption)
                        Text("2. 必须填写 http:// 或 https:// 前缀")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("服务器设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .disabled(preferences.serverURL.isEmpty)
                }
            }
        }
    }
    
    private func testConnection() {
        testingConnection = true
        testResult = nil
        
        Task {
            do {
                try await APIService.shared.testServerConnection()
                await MainActor.run {
                    testResult = "✓ 连接成功，服务器可访问"
                    testSuccess = true
                    testingConnection = false
                }
            } catch {
                let errorMessage: String
                if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain {
                    switch nsError.code {
                    case NSURLErrorTimedOut:
                        errorMessage = "连接超时 - 请检查服务器地址"
                    case NSURLErrorCannotConnectToHost:
                        errorMessage = "无法连接到服务器 - 请检查服务器地址"
                    case NSURLErrorNotConnectedToInternet:
                        errorMessage = "设备未连接到网络"
                    default:
                        errorMessage = "连接失败: \(error.localizedDescription)"
                    }
                } else {
                    errorMessage = "连接失败: \(error.localizedDescription)"
                }
                
                LogManager.shared.log("连接测试失败: \(errorMessage)", category: "连接测试")
                
                await MainActor.run {
                    testResult = errorMessage
                    testSuccess = false
                    testingConnection = false
                }
            }
        }
    }
}
