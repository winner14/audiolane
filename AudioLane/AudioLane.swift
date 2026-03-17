//
//  DeciSwitchApp.swift
//  DeciSwitch
//
//  Created by Winner on 15/03/2026.
//

import SwiftUI

@main
struct AudioRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
