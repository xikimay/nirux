import Foundation

/// Anonymized crash reports shaped like the ones macOS writes to
/// ~/Library/Logs/DiagnosticReports: a one-line JSON header, then the body.
enum CrashReportFixtures {
    static let bundleID = "com.xikimay.nirux"
    static let incidentID = "11111111-2222-3333-4444-555555555555"
    static let timestamp = "2026-09-27 11:14:48.00 +0200"

    static func header(
        incidentID: String? = incidentID,
        timestamp: String? = timestamp,
        bundleID: String? = bundleID,
        bugType: String? = "309"
    ) -> String {
        var fields: [String: Any] = [
            "app_name": "Nirux",
            "app_version": "nightly-2026.09.27",
            "build_version": "202609270901",
            "platform": 1,
            "share_with_app_devs": 0,
            "is_first_party": 0,
            "os_version": "macOS 26.5.2 (25F84)",
            "roots_installed": 0,
            "name": "Nirux"
        ]
        fields["incident_id"] = incidentID
        fields["timestamp"] = timestamp
        fields["bundleID"] = bundleID
        fields["bug_type"] = bugType
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    static func report(header: String = header(), body: String = body) -> Data {
        Data((header + "\n" + body).utf8)
    }

    struct Frame {
        let image: Int
        let symbol: String?
        let location: Int?
        let offset: Int

        init(_ image: Int, _ symbol: String?, _ location: Int?, _ offset: Int) {
            self.image = image
            self.symbol = symbol
            self.location = location
            self.offset = offset
        }
    }

    /// The crashed thread (index 2): runtime isolation check frames, the
    /// app's closure, then the operation queue plumbing — 20 frames.
    static let crashedFrames: [Frame] = [
        Frame(1, "_dispatch_assert_queue_fail", 120, 226_556),
        Frame(1, "dispatch_assert_queue$V2.cold.1", 116, 229_224),
        Frame(1, "dispatch_assert_queue", 108, 20_756),
        Frame(2, "_swift_task_checkIsolatedSwift", 48, 349_564),
        Frame(2, "swift_task_isCurrentExecutorWithFlagsImpl(swift::SerialExecutorRef, swift::swift_task_is_current_executor_flag)",
              356, 20_764),
        Frame(0, "closure #1 in NiruxShellView.inspectForPanel(_:panel:queue:)", 256, 1_349_304),
        Frame(0, "thunk for @escaping @callee_guaranteed @Sendable () -> ()", 28, 230_744),
        Frame(3, "__NSBLOCKOPERATION_IS_CALLING_OUT_TO_A_BLOCK__", 24, 254_316),
        Frame(3, "-[NSBlockOperation main]", 88, 254_012),
        Frame(3, "__NSOPERATION_IS_INVOKING_MAIN__", 16, 253_916),
        Frame(3, "-[NSOperation start]", 640, 250_856),
        Frame(3, "__NSOPERATIONQUEUE_IS_STARTING_AN_OPERATION__", 16, 250_208),
        Frame(3, "__NSOQSchedule_f", 164, 249_936),
        Frame(1, "_dispatch_block_async_invoke2", 148, 69_380),
        Frame(1, "_dispatch_client_callout", 16, 111_792),
        Frame(1, "_dispatch_continuation_pop", 596, 25_032),
        Frame(1, "_dispatch_async_redirect_invoke", 580, 22_596),
        Frame(1, "_dispatch_root_queue_drain", 360, 80_256),
        Frame(1, "_dispatch_worker_thread2", 184, 82_208),
        Frame(4, nil, nil, 11_908)
    ]

    static var body: String { body() }

    /// The app opened from the Dock. `Nirux --hook` is "Unspecified", with
    /// the agent as its parent.
    static func body(procRole: String = "Foreground", parentProc: String = "launchd") -> String {
        let frames = crashedFrames.map { frame in
            var fields = ["\"imageOffset\" : \(frame.offset)", "\"imageIndex\" : \(frame.image)"]
            if let symbol = frame.symbol { fields.append("\"symbol\" : \"\(symbol)\"") }
            if let location = frame.location { fields.append("\"symbolLocation\" : \(location)") }
            return "{" + fields.joined(separator: ", ") + "}"
        }
        return """
        {
          "uptime" : 3600,
          "procRole" : "\(procRole)",
          "parentProc" : "\(parentProc)",
          "version" : 2,
          "procName" : "Nirux",
          "procPath" : "/Applications/Nirux.app/Contents/MacOS/Nirux",
          "bundleInfo" : {
            "CFBundleShortVersionString":"nightly-2026.09.27","CFBundleVersion":"202609270901","CFBundleIdentifier":"com.xikimay.nirux"
          },
          "captureTime" : "2026-09-27 11:14:19.6973 +0200",
          "exception" : {"codes":"0x0000000000000001, 0x0000000180bac4fc","rawCodes":[1,6454691068],"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
          "termination" : {"flags":0,"code":5,"namespace":"SIGNAL","indicator":"Trace\\/BPT trap: 5","byProc":"exc handler","byPid":100},
          "faultingThread" : 2,
          "threads" : [
            {"id":1,"queue":"com.apple.main-thread","frames":[{"imageOffset":1000,"symbol":"mach_msg2_trap","symbolLocation":8,"imageIndex":4}]},
            {"id":2,"frames":[]},
            {"triggered":true,"id":3,"queue":"NSOperationQueue 0x600000000000 (QOS: UNSPECIFIED)","frames":[
              \(frames.joined(separator: ",\n      "))
            ]}
          ],
          "usedImages" : [
            {"source":"P","arch":"arm64","name":"Nirux","path":"/Applications/Nirux.app/Contents/MacOS/Nirux"},
            {"source":"P","arch":"arm64e","name":"libdispatch.dylib","path":"/usr/lib/system/libdispatch.dylib"},
            {"source":"P","arch":"arm64e","name":"libswift_Concurrency.dylib","path":"/usr/lib/swift/libswift_Concurrency.dylib"},
            {"source":"P","arch":"arm64e","name":"Foundation","path":"/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"},
            {"source":"P","arch":"arm64e","name":"libsystem_pthread.dylib","path":"/usr/lib/system/libsystem_pthread.dylib"}
          ]
        }
        """
    }
}
