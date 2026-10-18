import Foundation
import ServiceManagement

/// The part of `SMAppService` the login switch uses, so its logic can be
/// tested without adding a real login item to the Mac running the tests.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// "Open at login", backed by the system's own login item list.
///
/// The switch reads the live status rather than a saved setting: the user can
/// also turn the app off in System Settings > General > Login Items, and a
/// stored bool would then go on claiming it opens at login. Off by default,
/// since nothing is registered until the user asks.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    /// Why the last change didn't take, shown under the switch.
    @Published private(set) var errorMessage: String?

    private let service: LoginItemService
    private let openLoginItemsSettings: () -> Void

    init(service: LoginItemService = SMAppService.mainApp,
         openLoginItemsSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.service = service
        self.openLoginItemsSettings = openLoginItemsSettings
        status = service.status
    }

    /// Only true once macOS will actually open the app at login. A login item
    /// waiting for approval in System Settings doesn't count.
    var isEnabled: Bool { status == .enabled }

    /// Registered, but the user has switched it off (or not yet allowed it)
    /// in System Settings, which is the only place it can be turned back on.
    var needsApproval: Bool { status == .requiresApproval }

    /// Picks up changes made in System Settings while the app was running.
    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                // Already registered but disallowed: registering again does
                // nothing, so send the user to where it can be allowed.
                if service.status != .requiresApproval { try service.register() }
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
        if enabled && needsApproval { openSystemSettings() }
    }

    func openSystemSettings() {
        openLoginItemsSettings()
    }
}
