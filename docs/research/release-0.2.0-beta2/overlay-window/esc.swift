import CoreGraphics
import Foundation
// Sends Escape to one process only
let pid = pid_t(CommandLine.arguments[1])!
for down in [true, false] {
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)!.postToPid(pid)
    usleep(20_000)
}
