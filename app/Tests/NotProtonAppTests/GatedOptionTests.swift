import Foundation
import Testing

@testable import NotProtonApp

@Suite("Options that need a permission")
@MainActor
struct GatedOptionTests {

    func flow(_ tcc: FakeTCC, _ scratch: ScratchDefaults) -> PermissionFlow {
        PermissionFlow(center: makeCenter(tcc, scratch))
    }

    @Test("Downloads denied: the option turns back off with the message and the fix")
    func downloadsDenied() async {
        let scratch = ScratchDefaults()
        scratch.ledger.note(.denied, for: .downloads)
        let tcc = FakeTCC(deepOnly: FakeTCC.fileChecks)
        let flow = flow(tcc, scratch)
        await flow.center.refresh()
        let option = GatedOption(.downloads, flow: flow, context: .onboarding)

        option.set(true)

        #expect(!option.isOn)
        #expect(option.status == "Cartouche can't read Downloads. Allow it in System Settings.")
        #expect(option.phase == .denied)
        #expect(flow.asking == nil)
        #expect(tcc.requests.isEmpty)
        #expect(Permission.downloads.stillWorks == "Dragging an installer onto Cartouche still works.")
    }

    @Test("Downloads denied in macOS's own prompt turns the option back off the same way")
    func downloadsDeniedInPrompt() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC(deepOnly: FakeTCC.fileChecks)
        tcc.decide(.downloads, .denied)
        let flow = flow(tcc, scratch)
        let option = GatedOption(.downloads, flow: flow, context: .onboarding)

        option.set(true)
        #expect(flow.asking?.permission == .downloads)
        await flow.confirm()

        #expect(tcc.requests == [.downloads])
        #expect(!option.isOn)
        #expect(option.status == "Cartouche can't read Downloads. Allow it in System Settings.")
    }

    @Test("Each degraded feature names its permission, and says what keeps working where it can",
          arguments: [Permission.downloads, .removableVolumes, .notifications, .accessibility, .localNetwork])
    func messages(_ permission: Permission) async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC(deepOnly: FakeTCC.fileChecks)
        tcc.decide(permission, .denied)
        let flow = flow(tcc, scratch)
        let option = GatedOption(permission, flow: flow)
        option.target = URL(filePath: "/Volumes/Games")

        option.set(true)
        await flow.confirm()

        #expect(option.phase == .denied)
        let named = ["Downloads", "Removable Volumes", "Notifications", "Accessibility", "Local Network"]
        #expect(named.contains { option.status?.contains($0) == true }, "\(option.status ?? "-")")
        #expect(option.status?.contains("System Settings") == true)
        if permission != .accessibility { #expect(permission.stillWorks != nil) }
        snapshot(GatedOptionRow(option: option, title: permission.feature, subtitle: "").frame(width: 560),
                 named: "denied-\(permission.rawValue)")
    }

    @Test("Removable Volumes keeps the folder it was asked for")
    func removableTarget() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC(deepOnly: FakeTCC.fileChecks)
        tcc.decide(.removableVolumes, .granted)
        let flow = flow(tcc, scratch)
        let option = GatedOption(.removableVolumes, flow: flow)
        option.target = URL(filePath: "/Volumes/Games/ROMs")
        option.set(true)
        await flow.confirm()
        #expect(option.isOn)
        #expect(scratch.ledger.target(.removableVolumes)?.path(percentEncoded: false) == "/Volumes/Games/ROMs")
    }

    @Test("Local Network has no answer to read, so the option stays on until netplay meets a refusal")
    func localNetworkReportsLater() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC()
        let flow = flow(tcc, scratch)
        let option = GatedOption(.localNetwork, flow: flow)
        option.set(true)
        await flow.confirm()
        #expect(option.isOn)

        option.reportDenied()
        #expect(!option.isOn)
        #expect(option.status == "Cartouche can't use the local network. Allow Local Network in System Settings.")
        #expect(flow.center.state(.localNetwork) == .denied)
    }

    @Test("Fixed in System Settings: the message goes once Cartouche sees the permission")
    func fixedLater() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC([.accessibility: .notGranted])
        let flow = flow(tcc, scratch)
        let option = GatedOption(.accessibility, flow: flow)
        option.set(true)
        await flow.confirm()
        #expect(option.phase == .denied)

        flow.center.openSettings(for: .accessibility)
        tcc.set(.accessibility, .granted)
        await flow.center.applicationDidBecomeActive()

        #expect(option.phase == .off)
        #expect(option.status == nil)
        option.set(true)
        #expect(option.isOn)
    }

    @Test("Other options keep working when one permission is denied")
    func othersUnaffected() async {
        let scratch = ScratchDefaults()
        scratch.ledger.note(.denied, for: .downloads)
        let tcc = FakeTCC([.notifications: .granted], deepOnly: FakeTCC.fileChecks)
        let flow = flow(tcc, scratch)
        await flow.center.refresh()
        let downloads = GatedOption(.downloads, flow: flow)
        let notifications = GatedOption(.notifications, flow: flow)
        downloads.set(true)
        notifications.set(true)
        #expect(!downloads.isOn)
        #expect(notifications.isOn)
    }
}

@Suite("When permissions are asked")
@MainActor
struct PermissionMomentTests {

    @Test("Notifications are not asked at launch, only after the first download or install, after the explanation")
    func notificationsAfterFirstFinish() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC([.notifications: .undetermined])
        tcc.decide(.notifications, .granted)
        let flow = PermissionFlow(center: makeCenter(tcc, scratch))
        await flow.center.refresh()

        NotificationOffer.offer(after: .launch, flow: flow)
        #expect(flow.asking == nil)
        #expect(tcc.requests.isEmpty)

        NotificationOffer.offer(after: .installFinished, flow: flow)
        #expect(flow.asking?.permission == .notifications, "no explanation before the prompt")
        #expect(tcc.requests.isEmpty)
        await flow.confirm()
        #expect(tcc.requests == [.notifications])

        NotificationOffer.offer(after: .downloadFinished, flow: flow)
        #expect(flow.asking == nil, "offered twice")
    }

    @Test("The offer rule")
    func rule() {
        #expect(!NotificationOffer.shouldOffer(after: .launch, state: .notAsked, offeredBefore: false))
        #expect(NotificationOffer.shouldOffer(after: .downloadFinished, state: .notAsked, offeredBefore: false))
        #expect(NotificationOffer.shouldOffer(after: .installFinished, state: .notAsked, offeredBefore: false))
        #expect(!NotificationOffer.shouldOffer(after: .installFinished, state: .notAsked, offeredBefore: true))
        #expect(!NotificationOffer.shouldOffer(after: .installFinished, state: .denied, offeredBefore: false))
    }

    @Test("Starting the app's permission layer asks macOS for nothing")
    func launchAsksNothing() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC()
        let center = makeCenter(tcc, scratch)
        center.watchActivation()
        await center.refresh()
        await center.applicationDidBecomeActive()
        #expect(tcc.requests.isEmpty)
    }

    @Test("Onboarding can ask only App Management and Downloads, and neither needs a relaunch")
    func onboardingPermissions() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC()
        let flow = PermissionFlow(center: makeCenter(tcc, scratch))
        var asked: [Permission] = []
        for permission in Permission.allCases {
            flow.start(permission, context: .onboarding, attempt: { .denied }) { outcome in
                if outcome != .refused { asked.append(permission) }
            }
            if flow.asking != nil {
                asked.append(permission)
                flow.notNow()
            }
        }
        // Each one that was let through shows up twice: the sheet, then Not Now
        #expect(Set(asked) == [.appManagement, .downloads])
        #expect(Permission.allCases.filter(\.askedInOnboarding).allSatisfy { !$0.needsRelaunch })
        #expect(tcc.requests.isEmpty)
    }
}
