import AppKit

enum AppRelauncher {
    enum Failure: LocalizedError {
        case notAnAppBundle

        var errorDescription: String? { "This copy of OpenUsage can't restart itself. Quit and reopen it." }
    }

    @MainActor
    static func relaunch() throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { throw Failure.notAnAppBundle }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open -n "$2""#,
            "openusage-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            bundleURL.path,
        ]
        try waiter.run()
        NSApp.terminate(nil)
    }
}
