import Foundation
import NiruxCore
import Testing

struct ShortDurationTests {
    @Test(arguments: [
        (-5.0, "0s"), (0, "0s"), (42, "42s"), (59.9, "59s"),
        (60, "1m"), (732, "12m"), (3599, "59m"),
        (3600, "1h00m"), (3920, "1h05m"), (7384, "2h03m")
    ])
    func shortDuration(seconds: TimeInterval, expected: String) {
        #expect(seconds.shortDuration == expected)
    }
}
