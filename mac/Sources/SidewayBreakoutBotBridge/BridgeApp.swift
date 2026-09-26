import SwiftUI

@main
struct SidewayBreakoutBotBridgeApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        WindowGroup("Sideway Breakout Bot -- MT5 Signal Bridge") {
            ContentView()
                .environmentObject(model)
        }
    }
}
