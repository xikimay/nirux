import Darwin
import XCTest
@testable import Nirux

/// The folder Explain runs in (docs/branch-review.md, section 4.3): the
/// tracked text files as the working tree has them, nothing written to the
/// repository, and no link, secret or instruction for an agent.
final class BranchReviewExplainCopyTests: BranchReviewRepositoryTestCase {
    private var copies: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        copies = URL(fileURLWithPath: root + "/copies", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
    }

    /// Committed and staged files, with their uncommitted edits, the
    /// branch's first; not an untracked file unless asked, nor one deleted
    /// from the working tree, which isn't reported as left out: the diff
    /// shows the deletion. The index and the object store don't change.
    func testTheCopyHoldsTrackedFilesAsTheWorkingTreeHasThem() throws {
        try write("Sources/Gone.swift", "gone\n")
        try commitToMain("gone")
        try FileManager.default.removeItem(atPath: repo + "/Sources/Gone.swift")
        try write("Sources/Staged.swift", "staged\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo + "/Sources/Staged.swift")
        try git(["add", "Sources/Staged.swift"])
        try write("README.md", "edited, not committed\n")
        try write("untracked.txt", "untracked\n")
        let index = try FileManager.default.attributesOfItem(atPath: repo + "/.git/index")[.modificationDate] as? Date
        let objects = try git(["count-objects"])
        let snapshot = try snapshot()

        let copy = try XCTUnwrap(BranchReview.ExplainCopy.make(for: snapshot, options: options(), in: copies))

        XCTAssertTrue(copy.folder.lastPathComponent.hasPrefix(BranchReview.ExplainCopy.folderPrefix))
        XCTAssertEqual(copy.copied, ["README.md", "Sources/Staged.swift", "Sources/App.swift"])
        XCTAssertEqual(copy.leftOut, [])
        XCTAssertEqual(try String(contentsOf: copy.folder.appendingPathComponent("README.md"), encoding: .utf8), "edited, not committed\n")
        // Never executable: a branch's script can't run from the copy.
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: copy.folder.appendingPathComponent("Sources/Staged.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.folder.appendingPathComponent("untracked.txt").path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: repo + "/.git/index")[.modificationDate] as? Date, index)
        XCTAssertEqual(try git(["count-objects"]), objects)
        BranchReview.ExplainCopy.remove(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.folder.path))

        // The run sends untracked files' diffs when asked: the copy has them.
        let withUntracked = try XCTUnwrap(BranchReview.ExplainCopy.make(
            for: snapshot, includeUntracked: true, options: options(), in: copies
        ))
        defer { BranchReview.ExplainCopy.remove(withUntracked) }
        XCTAssertTrue(withUntracked.copied.contains("untracked.txt"))
    }

    /// Links, hard links, a file under a folder replaced by a link, a
    /// submodule, binaries and other encodings are left out. So are
    /// secrets (by name, by folder, renamed from one, or holding a key),
    /// and the branch's instructions for an agent, in any case. Code about
    /// credentials is copied.
    func testLinksSecretsAndInstructionsAreLeftOut() throws {
        try write(".env.production", "DATABASE_PASSWORD=secret\n")
        try commitToMain("env")
        try FileManager.default.createDirectory(atPath: repo + "/config", withIntermediateDirectories: true)
        try git(["mv", ".env.production", "config/production.settings"])
        let outside = root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "private\n".write(toFile: outside + "/inner.txt", atomically: true, encoding: .utf8)
        try write("linked/inner.txt", "committed\n")
        for path in [
            "certs/server.PEM", "config/credentials.json", "keys/id_ed25519.pub", "deploy/prod.env", ".npmrc",
            "k8s/secrets/db.yaml", "AuthKey_ABC.p8",
            "CLAUDE.md", "docs/claude.local.md", "AGENTS.md", ".claude/settings.json", "pkg/.Claude/agents/a.md"
        ] {
            try write(path, "x\n")
        }
        try write("Sources/CredentialsStore.swift", "struct CredentialsStore {}\n")
        try write("Sources/Secrets/Vault.swift", "struct Vault {}\n")
        try write("Sources/Masking.swift", "let pattern = \"" + "sk-" + "ant-[A-Za-z0-9]+\" // not a key\n")
        try write("Sources/Keys.swift", "let key = \"" + "sk-" + "ant-api03-" + String(repeating: "A", count: 24) + "\"\n")
        try write("Assets/logo.bin", Data([0x89, 0x50, 0x00, 0x01]))
        try write("docs/utf16.txt", Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]))
        // Valid UTF-8, but a NUL: binary.
        try write("Assets/data.bin", Data([0x68, 0x00, 0x69]))
        try FileManager.default.createSymbolicLink(atPath: repo + "/link.txt", withDestinationPath: outside + "/inner.txt")
        XCTAssertEqual(link(outside + "/inner.txt", repo + "/hard.txt"), 0)
        try commit("all kinds")
        // The folder becomes a link out of the worktree: git still lists
        // the file under it.
        try FileManager.default.removeItem(atPath: repo + "/linked")
        try FileManager.default.createSymbolicLink(atPath: repo + "/linked", withDestinationPath: outside)
        try FileManager.default.createDirectory(atPath: repo + "/vendor/sub", withIntermediateDirectories: true)
        try git(["update-index", "--add", "--cacheinfo", "160000,\(try head()),vendor/sub"])
        let snapshot = try snapshot()
        XCTAssertEqual(try file("config/production.settings", in: snapshot).oldPath, ".env.production")

        let copy = try XCTUnwrap(BranchReview.ExplainCopy.make(for: snapshot, options: options(), in: copies))
        defer { BranchReview.ExplainCopy.remove(copy) }

        XCTAssertEqual(Set(copy.copied), [
            "README.md", "Sources/App.swift", "Sources/CredentialsStore.swift", "Sources/Secrets/Vault.swift",
            "Sources/Masking.swift"
        ])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: copy.leftOut.map { ($0.path, $0.reason) }), [
            "config/production.settings": .secretPath, "certs/server.PEM": .secretPath,
            "config/credentials.json": .secretPath, "keys/id_ed25519.pub": .secretPath, "deploy/prod.env": .secretPath,
            ".npmrc": .secretPath, "k8s/secrets/db.yaml": .secretPath, "AuthKey_ABC.p8": .secretPath,
            "CLAUDE.md": .instructions, "docs/claude.local.md": .instructions, "AGENTS.md": .instructions,
            ".claude/settings.json": .instructions, "pkg/.Claude/agents/a.md": .instructions,
            "Sources/Keys.swift": .key, "Assets/logo.bin": .notText, "docs/utf16.txt": .notText, "Assets/data.bin": .notText,
            "link.txt": .notRegularFile, "hard.txt": .notRegularFile, "linked/inner.txt": .notRegularFile,
            "vendor/sub": .notRegularFile
        ])
        var everything = Set(try FileManager.default.subpathsOfDirectory(atPath: copy.folder.path))
        everything.subtract(["Sources", "Sources/Secrets"])
        XCTAssertEqual(everything, Set(copy.copied))
    }

    /// Edits git hides (assume-unchanged, skip-worktree) and files a clean
    /// filter stores as something else (git-crypt, a redaction), untracked
    /// ones too, never reach the copy: the diff doesn't show them either.
    func testFilesGitDoesntShowAsTheyAreAreLeftOut() throws {
        try write(".gitattributes", "vault.txt filter=crypt\n*.vault filter=crypt\n")
        try write("vault.txt", "plaintext\n")
        try write("config.yml", "password: committed\n")
        try commitToMain("config")
        try git(["update-index", "--assume-unchanged", "config.yml"])
        try git(["update-index", "--skip-worktree", "README.md"])
        try write("config.yml", "password: real\n")
        try write("notes.vault", "plaintext\n")

        let copy = try XCTUnwrap(BranchReview.ExplainCopy.make(
            for: try snapshot(), includeUntracked: true, options: options(), in: copies
        ))
        defer { BranchReview.ExplainCopy.remove(copy) }

        XCTAssertEqual(Set(copy.copied), [".gitattributes", "Sources/App.swift"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: copy.leftOut.map { ($0.path, $0.reason) }), [
            "config.yml": .hiddenFromGit, "README.md": .hiddenFromGit, "vault.txt": .filtered, "notes.vault": .filtered
        ])
    }

    /// Past the size limits, files aren't copied, the branch's own first;
    /// a cancelled copy leaves nothing behind.
    func testLimitsSpendOnTheBranchsFilesFirstAndCancelLeavesNothing() throws {
        try write("Sources/Changed.swift", "changed\n")
        try write("big.txt", "more than ten bytes\n")
        try git(["add", "-A"])
        let snapshot = try snapshot()
        var limits = BranchReview.ExplainCopy.Limits()
        limits.maxFileBytes = 25
        limits.maxTotalBytes = 10

        let copy = try XCTUnwrap(BranchReview.ExplainCopy.make(for: snapshot, options: options(), limits: limits, in: copies))
        defer { BranchReview.ExplainCopy.remove(copy) }

        // README.md (8 bytes) comes before Sources/Changed.swift (8 bytes)
        // in git's order: the branch's file takes the room.
        XCTAssertEqual(copy.copied, ["Sources/Changed.swift"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: copy.leftOut.map { ($0.path, $0.reason) }), [
            "big.txt": .overTotal, "README.md": .overTotal, "Sources/App.swift": .tooLarge
        ])

        let before = Set(try FileManager.default.contentsOfDirectory(atPath: copies.path))
        let cancellation = BoundedProcess.Cancellation()
        cancellation.cancel()
        XCTAssertNil(BranchReview.ExplainCopy.make(for: snapshot, options: options(), in: copies, cancellation: cancellation))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: copies.path)), before)
    }

    /// A copy holds its lock while it lives: a sweep leaves it, however
    /// old. A copy whose lock nobody holds goes; one without a lock file
    /// goes once it is old; a lock left without its folder goes. Links and
    /// other folders stay.
    func testSweepRemovesOnlyWhatNoRunHolds() throws {
        let live = try XCTUnwrap(BranchReview.ExplainCopy.make(for: try snapshot(), options: options(), in: copies))
        defer { BranchReview.ExplainCopy.remove(live) }
        let prefix = BranchReview.ExplainCopy.folderPrefix
        let unlocked = copies.appendingPathComponent(prefix + "unlocked")
        let oldWithoutLock = copies.appendingPathComponent(prefix + "old")
        let recentWithoutLock = copies.appendingPathComponent(prefix + "recent")
        let other = copies.appendingPathComponent("other-old")
        for folder in [unlocked, oldWithoutLock, recentWithoutLock, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: unlocked.path + ".lock", contents: Data())
        FileManager.default.createFile(atPath: copies.appendingPathComponent(prefix + "lone.lock").path, contents: Data())
        let link = copies.appendingPathComponent(prefix + "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        let hourAgo = Date().addingTimeInterval(-3_600)
        for folder in [live.folder, oldWithoutLock, other] {
            try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: folder.path)
        }

        BranchReview.ExplainCopy.sweep(in: copies)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: copies.path))
        XCTAssertEqual(left, [
            live.folder.lastPathComponent, live.folder.lastPathComponent + ".lock", recentWithoutLock.lastPathComponent,
            other.lastPathComponent, link.lastPathComponent
        ])
    }

    /// Secret paths by name and folder, code about credentials excepted;
    /// keys by their shape, not by a word that starts like one.
    func testSecretsAreFoundByNameAndShape() {
        for path in [
            ".env", ".env.local", "deploy/prod.env", "id_rsa", "keys/id_ecdsa.pub", "server.pem", "AuthKey_X.p8",
            "store.p12", "app.pfx", "release.jks", "debug.keystore", "putty.ppk", "prod.tfvars", "terraform.tfstate",
            ".npmrc", ".pypirc", ".git-credentials", ".netrc", "home/.ssh/config", ".aws/config", ".docker/config.json",
            ".kube/config", ".config/gh/hosts.yml", "secrets/api.txt", "config/aws_credentials.json", "App.mobileprovision",
            "app/secrets.yml", "config/client_secret.json", "terraform.tfvars.json"
        ] {
            XCTAssertTrue(BranchReview.Secrets.isSecretPath(path), path)
        }
        for path in [
            "Sources/CredentialsStore.swift", "Sources/Secrets/Vault.swift", "docs/credentials.md", "environment.ts",
            "Sources/KeyboardShortcuts.swift", "README.md", "scripts/rotate-secrets.sh", "infra/secrets.tf",
            ".github/workflows/secret-scan.yml", "src/SecretInput.vue", "styles/secret-banner.css",
            "sql/credentials_schema.sql"
        ] {
            XCTAssertFalse(BranchReview.Secrets.isSecretPath(path), path)
        }
        // Joined from parts: this file holds no key, nor anything a
        // scanner would take for one.
        func joined(_ parts: String...) -> String { parts.joined() }
        let tail = String(repeating: "a1B2", count: 10)
        let keys: [String] = [
            joined("-----", "BEGIN OPENSSH PRIVATE KEY-----"), joined("-----", "BEGIN PRIVATE KEY-----"),
            joined("LS0tLS1", "CRUdJTiBSU0E"), joined("sk-", "ant-api03-", tail), joined("sk-", "proj-", tail),
            joined("gh", "p_", String(tail.prefix(36))), joined("gh", "o_", String(tail.prefix(36))),
            joined("github", "_pat_", tail), joined("gl", "pat-", String(tail.prefix(20))),
            joined("AK", "IAABCDEFGHIJKLMNOP"), joined("AS", "IAABCDEFGHIJKLMNOP"), joined("AI", "za", String(tail.prefix(35))),
            joined("xox", "b-1234-", tail), joined("np", "m_", String(tail.prefix(36))), joined("sk_", "live_", tail),
            joined("sk-", "svcacct-", tail), joined("sk-", "None-", tail), joined("sk-", tail)
        ]
        for key in keys {
            XCTAssertTrue(BranchReview.Secrets.containsKey("token = \"\(key)\""), key)
        }
        let words: [String] = [
            joined("-----", "BEGIN CERTIFICATE-----"), joined("sk-", "ant-..."), joined("\"gh", "p_\" prefix"),
            joined("npm", "_package_version"), joined("AK", "IA is an AWS prefix"), joined("ghost_", tail),
            joined("Mask `-----", "BEGIN` lines"), joined("news/sk-", "hynix-reports-record-quarterly-profit-on-ai-demand")
        ]
        for text in words {
            XCTAssertFalse(BranchReview.Secrets.containsKey(text), text)
        }
        // A long run of token characters after a key's prefix doesn't
        // stop the check: the key after it is found.
        let run = joined("sk-", String(repeating: "Ab0_", count: 100_000))
        XCTAssertTrue(BranchReview.Secrets.containsKey(run + " " + keys[0]))
    }
}
