//
//  Swift_TTS_WidgetsLiveActivity.swift
//  Swift-TTS-Widgets
//
//  Created by Sachin Desai on 8/24/25.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct Swift_TTS_WidgetsAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct Swift_TTS_WidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: Swift_TTS_WidgetsAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension Swift_TTS_WidgetsAttributes {
    fileprivate static var preview: Swift_TTS_WidgetsAttributes {
        Swift_TTS_WidgetsAttributes(name: "World")
    }
}

extension Swift_TTS_WidgetsAttributes.ContentState {
    fileprivate static var smiley: Swift_TTS_WidgetsAttributes.ContentState {
        Swift_TTS_WidgetsAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: Swift_TTS_WidgetsAttributes.ContentState {
         Swift_TTS_WidgetsAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: Swift_TTS_WidgetsAttributes.preview) {
   Swift_TTS_WidgetsLiveActivity()
} contentStates: {
    Swift_TTS_WidgetsAttributes.ContentState.smiley
    Swift_TTS_WidgetsAttributes.ContentState.starEyes
}
