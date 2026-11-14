import Foundation
import NRVLDiscovery
import NRVLPersistence
import NRVLServices
import Observation

@MainActor @Observable
final class AppModel {
    enum Storage: Equatable {
        case opening
        case ready(path: String, auditEntries: Int, brokenAuditEntryID: Int64?)
        case failed(String)
    }

    var selection: SidebarSection? = .overview
    private(set) var storage: Storage = .opening
    private(set) var database: AppDatabase?
    private(set) var inventory: InventoryModel?
    private(set) var integrations: IntegrationsModel?
    private(set) var traffic: TrafficModel?
    private(set) var access: AccessControlModel?
    private(set) var qos: QoSModel?
    private(set) var alerts: AlertsModel?
    private(set) var reports: ReportsModel?
    let telemetry = TelemetryModel()
    private var telemetryStarted = false

    func start() async {
        if !telemetryStarted {   // needs no database, so it runs even if storage fails
            telemetryStarted = true
            Task { await telemetry.run() }
        }
        guard database == nil else { return }
        do {
            let db = try AppDatabase.onDisk()
            database = db
            let registryURL = Bundle.main.url(forResource: "oui", withExtension: "tsv")
            let registry = await Task.detached { registryURL.flatMap(OUIRegistry.init(contentsOf:)) }.value
            telemetry.metrics = db.metrics
            try? await db.metrics.prune()
            let integrationService = IntegrationService(database: db)
            let inventory = InventoryModel(database: db, registry: registry, integrations: integrationService)
            self.inventory = inventory
            let integrations = IntegrationsModel(service: integrationService) { await inventory.scan() }
            self.integrations = integrations
            let access = AccessControlModel(engine: AccessControlEngine(database: db, provider: integrationService),
                                            inventory: inventory, integrations: integrations)
            self.access = access
            qos = QoSModel(engine: QoSEngine(database: db, provider: integrationService), integrations: integrations)
            let alerts = AlertsModel(database: db, inventory: inventory, telemetry: telemetry, integrations: integrations)
            self.alerts = alerts
            await alerts.load()
            reports = ReportsModel(database: db, integrations: integrations)
            inventory.afterScan = {
                await access.reconcile()
                await alerts.evaluate()
            }
            traffic = TrafficModel(metrics: db.metrics)
            Task { await inventory.run() }   // app lifetime, not window lifetime
            try await db.audit.append(action: "app.launch", target: "NRVL Network", outcome: .succeeded)
            storage = .ready(path: try AppDatabase.defaultURL().path,
                             auditEntries: try await db.audit.count(),
                             brokenAuditEntryID: try await db.audit.firstBrokenEntryID())
        } catch {
            storage = .failed(error.localizedDescription)
        }
    }
}
