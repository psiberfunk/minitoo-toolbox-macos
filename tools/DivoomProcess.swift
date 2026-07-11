import Foundation

enum DivoomProcessError: Error {
    case launchFailed(String)
    case nonZeroExit(Int32, String)
}

/// Binary-safe subprocess capture. DivoomMenuBar.swift's existing `run()`
/// decodes captured stdout as a String -- not safe for ffmpeg's raw RGB24
/// video stdout, which is arbitrary binary data (String decoding would
/// corrupt or drop invalid-UTF-8 byte sequences).
enum DivoomProcess {
    static func runCapturingData(_ executable: String, _ args: [String]) throws -> (stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read both pipes concurrently on background queues, not
        // sequentially after waitUntilExit() -- ffmpeg can fill a pipe's
        // kernel buffer on one stream while blocked waiting for the other
        // to be drained, which would deadlock a naive read-then-wait.
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            throw DivoomProcessError.launchFailed(String(describing: error))
        }
        process.waitUntilExit()
        group.wait()

        guard process.terminationStatus == 0 else {
            throw DivoomProcessError.nonZeroExit(process.terminationStatus, String(data: stderrData, encoding: .utf8) ?? "")
        }
        return (stdoutData, stderrData)
    }
}
