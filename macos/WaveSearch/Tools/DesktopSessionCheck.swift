import CoreGraphics
import Foundation

// Exit 2 is an unavailable host prerequisite, not a passed interaction check.
let session = CGSessionCopyCurrentDictionary() as? [String: Any]
var displays: UInt32 = 0
let status = CGGetActiveDisplayList(0, nil, &displays)
guard session?[kCGSessionLoginDoneKey as String] as? Bool == true,
      session?[kCGSessionOnConsoleKey as String] as? Bool == true,
      status == .success, displays > 0 else {
    FileHandle.standardError.write(Data("BLOCKED: GUI checks need access to a logged-in macOS desktop and an active display. Run them from Terminal in that desktop session.\n".utf8))
    exit(2)
}
