import Foundation
import Testing

@testable import AgentNotchCore

@Suite("SocketPath")
struct SocketPathTests {
    private let normalHome = URL(fileURLWithPath: "/Users/vijay")

    @Test("the default lives under Application Support")
    func defaultPath() {
        let url = SocketPath.resolve(env: [:], home: normalHome)
        #expect(url.path == "/Users/vijay/Library/Application Support/AgentNotch/hook.sock")
    }

    @Test("AGENT_NOTCH_SOCK overrides everything")
    func envOverride() {
        let url = SocketPath.resolve(env: ["AGENT_NOTCH_SOCK": "/tmp/custom.sock"], home: normalHome)
        #expect(url.path == "/tmp/custom.sock")
    }

    @Test("an empty or whitespace override is ignored")
    func emptyOverrideIsIgnored() {
        #expect(SocketPath.resolve(env: ["AGENT_NOTCH_SOCK": ""], home: normalHome).path.hasSuffix("hook.sock"))
        #expect(SocketPath.resolve(env: ["AGENT_NOTCH_SOCK": "  "], home: normalHome).path.contains("Application Support"))
    }

    @Test("a 90-character home falls back to /tmp rather than overflowing sun_path")
    func longHomeFallsBackToTmp() {
        // 90 chars. Plus "/Library/Application Support/AgentNotch/hook.sock" (49)
        // that is 139 bytes, well past the 104-byte sun_path buffer. bind()
        // would fail with something unhelpful, so we never get there.
        let long = "/Users/" + String(repeating: "d", count: 82)
        #expect(long.count == 89)
        let home = URL(fileURLWithPath: long + "e")
        #expect(home.path.count == 90)

        let url = SocketPath.resolve(env: [:], home: home)
        #expect(url.path.hasPrefix("/tmp/agent-notch-"))
        #expect(url.path.hasSuffix(".sock"))
        #expect(SocketPath.fits(url.path))
    }

    @Test("the fallback is per-uid so two accounts never collide")
    func fallbackIsPerUID() {
        #expect(SocketPath.fallback(uid: 501).path == "/tmp/agent-notch-501.sock")
        #expect(SocketPath.fallback(uid: 502).path == "/tmp/agent-notch-502.sock")
    }

    @Test("fits() measures against the 104-byte sun_path buffer, NUL included")
    func fitsBoundary() {
        #expect(SocketPath.sunPathLimit == 104)
        #expect(SocketPath.fits(String(repeating: "a", count: 103)))
        #expect(!SocketPath.fits(String(repeating: "a", count: 104)))
        #expect(!SocketPath.fits(String(repeating: "a", count: 200)))
    }

    @Test("fits() counts BYTES, not characters")
    func fitsCountsBytes() {
        // 52 emoji is 52 characters but 208 UTF-8 bytes, and sun_path holds bytes.
        let emoji = String(repeating: "🍎", count: 52)
        #expect(emoji.count == 52)
        #expect(!SocketPath.fits(emoji))
    }

    @Test("the real default path on this machine fits")
    func realHomeFits() {
        let url = SocketPath.resolve(env: [:])
        #expect(SocketPath.fits(url.path))
    }
}
