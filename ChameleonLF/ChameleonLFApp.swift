//  ChameleonLFApp.swift
//  App entry point.

import SwiftUI

@main
struct ChameleonLFApp: App {
    @StateObject private var controller = ChameleonController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
        }
    }
}
