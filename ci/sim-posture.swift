// Looks for the iPhone Duo's posture (fold) controls in Xcode's private simulator frameworks, for CI.
//   swift ci/sim-posture.swift list
// Prints Objective-C classes and methods in CoreSimulator and SimulatorKit whose names mention posture, hinge,
// fold or crease, with their type encodings.
import Foundation
import ObjectiveC

func developerDir() -> String {
    if let d = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !d.isEmpty { return d }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    p.arguments = ["-p"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let dev = developerDir()
let images = [
    "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
    dev + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
]
for path in images {
    if dlopen(path, RTLD_NOW) == nil {
        print("can't load \(path): \(String(cString: dlerror()))")
    }
}

let pattern = try! NSRegularExpression(pattern: "posture|hinge|fold|crease|lid", options: .caseInsensitive)
func matches(_ s: String) -> Bool { pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

func methods(of cls: AnyClass, prefix: String) -> [String] {
    var out: [String] = []
    var n: UInt32 = 0
    guard let list = class_copyMethodList(cls, &n) else { return out }
    for i in 0..<Int(n) {
        let m = list[i]
        let sel = NSStringFromSelector(method_getName(m))
        let types = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
        out.append("\(prefix)\(sel)  \(types)")
    }
    free(list)
    return out
}

var count: UInt32 = 0
guard let classes = objc_copyClassList(&count) else { fatalError("no classes") }
var found = 0
for i in 0..<Int(count) {
    let cls: AnyClass = classes[i]
    guard let image = class_getImageName(cls).map({ String(cString: $0) }),
          image.contains("CoreSimulator") || image.contains("SimulatorKit") else { continue }
    let name = String(cString: class_getName(cls))
    let all = methods(of: cls, prefix: "-") + (object_getClass(cls).map { methods(of: $0, prefix: "+") } ?? [])
    let hits = matches(name) ? all : all.filter(matches)
    if hits.isEmpty { continue }
    found += 1
    print("\(name)  (\(URL(fileURLWithPath: image).lastPathComponent))")
    for h in hits.prefix(60) { print("    \(h)") }
}
print("\(found) classes with posture-like methods among \(count) classes")
