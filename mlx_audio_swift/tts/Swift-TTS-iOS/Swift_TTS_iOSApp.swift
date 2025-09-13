//
//  Swift_TTS_iOSApp.swift
//  Swift-TTS-iOS
//
//  Created by Sachin Desai on 5/20/25.
//

import SwiftUI
import BackgroundTasks

@main
struct Swift_TTS_iOSApp: App {
    init() {
        // Register background tasks
        BGTaskManager.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: KokoroTTSModel())
                .onAppear {
                    // Optional: cancel all pending tasks on dev runs
                    // BGTaskScheduler.shared.cancelAllTaskRequests()
                }
        }
    }
}
