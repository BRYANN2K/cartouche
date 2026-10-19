import Foundation
import InstallerKit
import Testing
import UserNotifications

@testable import NotProtonApp

@MainActor
final class RecordingPoster: NotificationPosting {
    var posted: [NotificationSpec] = []
    func post(_ spec: NotificationSpec) { posted.append(spec) }
}

@MainActor
final class RecordingInstallNotifier: InstallNotifying {
    var posted: [String] = []
    func installed(name: String, job: UUID) { posted.append("installed \(name)") }
    func failed(name: String, job: UUID) { posted.append("failed \(name)") }
}

// The router stands in for UNUserNotificationCenter's delegate: a response with an
// action identifier reaches the handler of its category, as a click on the banner's
// button does. No test posts to the real notification center.
@MainActor
@Suite("Notifications", .serialized)
struct ActivityNotificationTests {

    @Test("Ready to play: \"<Game> is ready to play\" with a Play action that launches the game through Steam")
    func readyToPlay() throws {
        let poster = RecordingPoster()
        let router = NotificationRouter()
        var opened: [String] = []
        let notifier = UserActivityNotifier(poster: poster, router: router, open: { opened.append($0.absoluteString) })
        notifier.ready(name: "God of War", appID: 1_593_500)
        let spec = try #require(poster.posted.first)
        #expect(spec.title == "God of War is ready to play")
        #expect(spec.actionTitle == "Play")
        #expect(spec.category == UserActivityNotifier.readyCategory)
        #expect(spec.userInfo == ["appid": "1593500"])

        router.respond(category: spec.category, action: spec.action, userInfo: spec.userInfo)
        #expect(opened == ["steam://rungameid/1593500"])
        // A click on the banner itself opens Cartouche, it does not start the game
        router.respond(category: spec.category, action: UNNotificationDefaultActionIdentifier, userInfo: spec.userInfo)
        #expect(opened.count == 1)
    }

    @Test("A failed download names the game and Steam's reason, with Try Again")
    func downloadFailed() throws {
        let poster = RecordingPoster()
        let router = NotificationRouter()
        var opened: [String] = []
        let notifier = UserActivityNotifier(poster: poster, router: router, open: { opened.append($0.absoluteString) })
        notifier.downloadFailed(name: "God of War", appID: 1_593_500, reason: "Not enough disk space")
        let spec = try #require(poster.posted.first)
        #expect(spec.title == "God of War could not be downloaded")
        #expect(spec.body == "Not enough disk space")
        #expect(spec.actionTitle == "Try Again")
        router.respond(category: spec.category, action: spec.action, userInfo: spec.userInfo)
        #expect(opened == ["steam://install/1593500"])
    }

    @Test("Installs: installed and failed, each with Open, which reopens the sheet on that install")
    func installs() throws {
        let poster = RecordingPoster()
        let router = NotificationRouter()
        let notifier = UserInstallNotifier(poster: poster, router: router)
        var openedJobs: [UUID] = []
        notifier.onOpen = { openedJobs.append($0) }
        let job = UUID()
        notifier.installed(name: "Sample Game", job: job)
        notifier.failed(name: "Sample Game", job: job)
        #expect(poster.posted.map(\.title) == ["Sample Game is installed", "Sample Game could not be installed"])
        #expect(poster.posted.map(\.actionTitle) == ["Open", "Open"])
        for spec in poster.posted { router.respond(category: spec.category, action: spec.action, userInfo: spec.userInfo) }
        #expect(openedJobs == [job, job])
    }

    @Test("Every category shares the one delegate, so neither kind takes the other's clicks")
    func oneDelegate() throws {
        let poster = RecordingPoster()
        let router = NotificationRouter()
        var opened: [String] = []
        let downloads = UserActivityNotifier(poster: poster, router: router, open: { opened.append($0.absoluteString) })
        let installs = UserInstallNotifier(poster: poster, router: router)
        var openedJobs: [UUID] = []
        installs.onOpen = { openedJobs.append($0) }
        downloads.ready(name: "God of War", appID: 1_593_500)
        installs.installed(name: "Sample Game", job: UUID())
        for spec in poster.posted { router.respond(category: spec.category, action: spec.action, userInfo: spec.userInfo) }
        #expect(opened == ["steam://rungameid/1593500"])
        #expect(openedJobs.count == 1)
    }
}

@MainActor
@Suite("Install failure notification", .serialized, .enabled(if: rosettaAvailable, "Rosetta is not installed, so arch -x86_64 cannot run"))
struct InstallFailureNotificationTests {

    @Test("A background install that fails posts could not be installed; one in the open sheet does not")
    func failure() async throws {
        let fake = try FakeInstall("notify-unarc", behavior: "unarc")
        let notifier = RecordingInstallNotifier()
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: notifier)
        let job = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.enqueue(job)
        #expect(await waitFor { job.phase == .failed })
        #expect(notifier.posted == ["failed Sample Game"])

        let shown = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.isSheetPresented = true
        center.sheet.show(shown)
        center.enqueue(shown)
        #expect(await waitFor { shown.phase == .failed })
        #expect(notifier.posted == ["failed Sample Game"])
    }
}
