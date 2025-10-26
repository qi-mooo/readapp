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
                
                // Logo 或应用名称
                Image(systemName: "book.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("ReadApp")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Spacer()
                
                // 服务器地址显示
                if !preferences.serverURL.isEmpty {
                    HStack {
                        Text("服务器:")
                            .foregroundColor(.secondary)
                        Text(preferences.serverURL)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: { showServerSettings = true }) {
                            Image(systemName: "gear")
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal)
                }
                
                // 登录表单
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
                
                // 服务器设置按钮
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
}

