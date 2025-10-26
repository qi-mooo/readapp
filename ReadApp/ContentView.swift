import SwiftUI

struct ContentView: View {
    @EnvironmentObject var apiService: APIService
    @StateObject private var preferences = UserPreferences.shared
    
    var body: some View {
        if !preferences.isLoggedIn {
            LoginView()
        } else {
            NavigationView {
                BookListView()
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
    }
}

