//
//  Swift_TTS_WidgetsBundle.swift
//  Swift-TTS-Widgets
//
//  Created by Sachin Desai on 8/24/25.
//

import WidgetKit
import SwiftUI

@main
struct Swift_TTS_WidgetsBundle: WidgetBundle {
    var body: some Widget {
        Swift_TTS_Widgets()
        Swift_TTS_WidgetsControl()
        Swift_TTS_WidgetsLiveActivity()
    }
}
