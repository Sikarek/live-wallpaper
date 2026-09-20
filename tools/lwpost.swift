// lwpost.swift — post the distributed notifications LiveWallpaper listens for.
//
// The Composer posts these itself after an export; this exists so the same thing can be done from a
// script or a test (and so the whole path can be verified without clicking anything).
//
//   ./build/lwpost                                        # just "reload your library"
//   ./build/lwpost apply                                  # ...and put the selected wallpaper on screen
//   ./build/lwpost com.sikarek.livewallpaper.ping         # bring the settings window forward

import Foundation

let names = CommandLine.arguments.dropFirst().map { argument -> String in
    argument.contains(".") ? argument : "com.sikarek.livewallpaper.\(argument)"
}
let toPost = names.isEmpty ? ["com.sikarek.livewallpaper.refresh"] : Array(names)

for name in toPost {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    print("posted \(name)")
}
// give the run loop a moment so delivery actually happens before we exit
RunLoop.current.run(until: Date().addingTimeInterval(0.4))
