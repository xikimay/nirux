import AppKit
import WebKit

@MainActor
final class IsolatedBrowserDiagnostics: NSObject, WKScriptMessageHandler {
    static let channel = "niruxDiagnostics"
    let workspaceID: String
    private(set) var buffer = BrowserDiagnostics()
    private(set) var revision = 0
    weak var display: NSTextView? { didSet { updateDisplay() } }

    init(workspaceID: String) {
        self.workspaceID = workspaceID
    }

    func install(in controller: WKUserContentController) {
        controller.add(self, contentWorld: .defaultClient, name: Self.channel)
        let relay = """
        (() => {
            const handler = window.webkit.messageHandlers.\(Self.channel);
            let pending = [];
            let oldest = 0;
            function flush() {
                handler.postMessage(pending.slice(oldest).concat(pending.slice(0, oldest)));
                pending = [];
                oldest = 0;
            }
            window.addEventListener("\(Self.channel)", event => {
                const body = event.detail;
                if (typeof body !== "string" || body.length > 2058) return;
                if (pending.length === 0) queueMicrotask(flush);
                if (pending.length < \(BrowserDiagnostics.capacity)) {
                    pending.push(body);
                } else {
                    pending[oldest] = body;
                    oldest = (oldest + 1) % pending.length;
                }
            });
        })();
        """
        controller.addUserScript(WKUserScript(source: relay, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: Self.pageObserver, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    func clear() {
        revision += 1
        buffer = BrowserDiagnostics()
        updateDisplay()
    }

    private func updateDisplay() {
        guard let display else { return }
        let events = buffer.events
        display.string = events.isEmpty ? "No diagnostics for this page." : events.map {
            "[\($0.kind.rawValue)] \($0.message)"
        }.joined(separator: "\n")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.channel, message.world == .defaultClient, message.frameInfo.isMainFrame,
              message.webView?.configuration.websiteDataStore.isPersistent == false,
              let batch = message.body as? [String], batch.count <= BrowserDiagnostics.capacity else { return }
        for body in batch {
            guard body.utf8.count <= 8192, let separator = body.firstIndex(of: "\n"),
                  let kind = BrowserDiagnostics.Kind(rawValue: String(body[..<separator])) else { continue }
            buffer.append(kind: kind, message: String(body[body.index(after: separator)...]))
        }
        updateDisplay()
    }

    // WebKit isolates JavaScript globals across worlds. Only the page world can
    // observe calls to these APIs; its DOM events carry data to the client world.
    private static var pageObserver: String {
        #"""
        (() => {
            function emit(kind, text) {
                window.dispatchEvent(new CustomEvent("\#(channel)", {detail: kind + "\n" + text.slice(0, 2048)}));
            }
            function describe(value) {
                if (typeof value === "string") return value.slice(0, 2048);
                if (value instanceof Error && typeof value.message === "string") return value.message.slice(0, 2048);
                if (value === null || ["undefined", "number", "boolean"].includes(typeof value)) return String(value);
                return "[" + typeof value + "]";
            }
            for (const kind of ["error", "warn"]) {
                const original = console[kind];
                console[kind] = function(...args) {
                    try { emit(kind, args.slice(0, 8).map(describe).join(" ")); } catch {}
                    return Reflect.apply(original, this, args);
                };
            }
            window.addEventListener("error", event => {
                if (typeof event.message === "string") emit("exception", event.message);
            });
            window.addEventListener("unhandledrejection", event => {
                try { emit("rejection", describe(event.reason)); } catch {}
            });
            function reportStatus(kind, status, url) {
                if (status < 400) return;
                try {
                    const endpoint = new URL(url);
                    emit(kind, status + " " + endpoint.origin + endpoint.pathname);
                } catch { emit(kind, String(status)); }
            }
            const originalFetch = window.fetch;
            window.fetch = function(...args) {
                return Reflect.apply(originalFetch, this, args).then(response => {
                    try { reportStatus("fetch", response.status, response.url); } catch {}
                    return response;
                });
            };
            const originalSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.send = function(...args) {
                const completed = () => reportStatus("xhr", this.status, this.responseURL);
                this.addEventListener("loadend", completed, {once: true});
                try { return Reflect.apply(originalSend, this, args); }
                catch (error) { this.removeEventListener("loadend", completed); throw error; }
            };
        })();
        """#
    }
}
