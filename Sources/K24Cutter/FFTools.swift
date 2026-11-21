import Foundation

/// Locates ffmpeg / ffprobe and runs them.
enum FFTools {
    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    static func locate(_ name: String) -> String? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "\(name)Path"), fm.isExecutableFile(atPath: custom) {
            return custom
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name).path, fm.isExecutableFile(atPath: bundled) {
            return bundled
        }
        var dirs = searchDirs
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var ffmpeg: String? { locate("ffmpeg") }
    static var ffprobe: String? { locate("ffprobe") }

    /// Runs a process to completion and returns stdout, stderr and exit status.
    static func run(_ exe: String, _ args: [String]) throws -> (out: Data, err: Data, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return (outData, errData, p.terminationStatus)
    }
}

/// Reads exactly `count` bytes unless EOF / error. Returns bytes read.
func readFully(_ fd: Int32, _ ptr: UnsafeMutableRawPointer, _ count: Int) -> Int {
    var got = 0
    while got < count {
        let r = read(fd, ptr + got, count - got)
        if r > 0 { got += r }
        else if r < 0 && errno == EINTR { continue }
        else { break }
    }
    return got
}

enum TimeFmt {
    /// HH:MM:SS.ff  (ff = frame within the second, like VideoReDo)
    static func string(_ t: Double, fps: Double) -> String {
        let t = max(0, t)
        var whole = Int(floor(t + 1e-6))
        let fpsI = max(1, Int(fps.rounded()))
        var ff = Int(((t - Double(whole)) * fps + 1e-3).rounded(.down))
        if ff >= fpsI { ff = 0; whole += 1 }
        if ff < 0 { ff = 0 }
        return String(format: "%02d:%02d:%02d.%02d", whole / 3600, (whole / 60) % 60, whole % 60, ff)
    }

    /// Accepts "HH:MM:SS.ff", "MM:SS", "SS.sss" (plain seconds).
    static func parse(_ s: String, fps: Double) -> Double? {
        let str = s.trimmingCharacters(in: .whitespaces)
        guard !str.isEmpty else { return nil }
        if !str.contains(":") { return Double(str) }
        var parts = str.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 3 else { return nil }
        let last = parts.removeLast()
        var secs: Double = 0
        let sp = last.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let whole = Int(sp[0].isEmpty ? "0" : sp[0]) else { return nil }
        secs = Double(whole)
        if sp.count == 2 {
            let frac = sp[1]
            if frac.count <= 2, let f = Int(frac) {
                secs += Double(f) / fps          // frames
            } else if let f = Double("0." + frac) {
                secs += f                        // decimal seconds
            } else { return nil }
        }
        var mult: Double = 60
        for p in parts.reversed() {
            guard let v = Int(p) else { return nil }
            secs += Double(v) * mult
            mult *= 60
        }
        return secs
    }

    static func arg(_ t: Double) -> String { String(format: "%.6f", max(0, t)) }

    static func mb(_ bytes: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: bytes / 1_048_576)) ?? "-"
    }
}

/// Debug log, enabled with env K24_DEBUG_LOG=/path/file.log
enum DebugLog {
    static let path = ProcessInfo.processInfo.environment["K24_DEBUG_LOG"]
    static let q = DispatchQueue(label: "k24.log")
    static func log(_ s: @autoclosure () -> String) {
        guard let path else { return }
        let line = String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + s() + "\n"
        q.async {
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
            else { try? line.write(toFile: path, atomically: false, encoding: .utf8) }
        }
    }
}
