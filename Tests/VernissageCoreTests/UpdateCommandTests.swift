import Foundation
import Testing
@testable import VernissageCore

struct UpdateCommandTests {
    @Test(
        arguments: [
            "server", "web", "push", "proxy", "caddy", "redis", "postgres", "minio"
        ]
    )
    func `Every supported component creates a nonempty update plan`(
        rawComponent: String
    ) throws {
        let component = try #require(UpdateComponent(rawValue: rawComponent))

        let plan = try ContainerUpdatePlanFactory(
            operatingSystem: .linux
        ).plan(for: component, context: makeContext())

        #expect(plan.component == component)
        #expect(plan.image.isEmpty == false)
        #expect(plan.preparationCommands.isEmpty == false)
        #expect(plan.containers.isEmpty == false)
    }

    @Test
    func `Server plan updates API and Jobs with reconstructed secrets`() throws {
        let plan = try ContainerUpdatePlanFactory(
            operatingSystem: .linux
        ).plan(for: .server, context: makeContext())

        #expect(plan.image == "mczachurski/vernissage-server:latest")
        #expect(plan.preparationCommands == [
            UpdateDockerCommand(
                arguments: [
                    "image", "pull", "mczachurski/vernissage-server:latest"
                ],
                description: "pull mczachurski/vernissage-server:latest"
            )
        ])
        #expect(plan.containers.map(\.service) == ["API", "Jobs"])

        let api = plan.containers[0]
        let jobs = plan.containers[1]
        #expect(api.environment["VERNISSAGE_DISABLEQUEUEJOBS"] == "true")
        #expect(api.environment["VERNISSAGE_DISABLESCHEDULEDJOBS"] == "true")
        #expect(jobs.environment["VERNISSAGE_DISABLEQUEUEJOBS"] == "false")
        #expect(jobs.environment["VERNISSAGE_DISABLESCHEDULEDJOBS"] == "false")
        #expect(api.environment["VERNISSAGE_CONNECTIONSTRING"]?.contains("database-secret") == true)
        #expect(api.environment["VERNISSAGE_QUEUEURL"]?.contains("redis-secret") == true)
        #expect(api.environment["VERNISSAGE_S3SECRETACCESSKEY"] == "storage-secret")
        #expect(api.createArguments.contains("host.docker.internal:host-gateway"))
        #expect(api.createArguments.suffix(8) == [
            "mczachurski/vernissage-server:latest",
            "serve", "--env", "production",
            "--hostname", "0.0.0.0", "--port", "8080"
        ])
    }

    @Test
    func `PostgreSQL plan preserves configured major tag and data volume`() throws {
        let plan = try ContainerUpdatePlanFactory(
            operatingSystem: .macOS
        ).plan(for: .postgres, context: makeContext())

        #expect(plan.image == "postgres:18")
        #expect(plan.containers[0].createArguments.contains("postgres:18"))
        #expect(plan.containers[0].createArguments.contains(
            "type=volume,source=vernissage-abcdefgh-postgres-data,target=/var/lib/postgresql"
        ))
        #expect(plan.containers[0].environment == [
            "POSTGRES_DB": "vernissage",
            "POSTGRES_USER": "vernissage",
            "POSTGRES_PASSWORD": "database-secret"
        ])
    }

    @Test
    func `External database cannot be updated`() {
        let context = makeContext()
        context.database = DatabaseConfiguration(
            mode: .existing,
            host: "postgres.example.com",
            port: 5432,
            database: "vernissage",
            username: "vernissage",
            password: Secret(value: "database-secret"),
            tlsMode: .require,
            localResources: nil
        )

        #expect(throws: ContainerUpdatePlanError.componentNotManaged(.postgres)) {
            try ContainerUpdatePlanFactory(
                operatingSystem: .linux
            ).plan(for: .postgres, context: context)
        }
    }

    @Test
    func `Proxy plan regenerates build files and preserves published port`() throws {
        let plan = try ContainerUpdatePlanFactory(
            operatingSystem: .macOS
        ).plan(for: .proxy, context: makeContext())

        #expect(plan.files.map(\.path) == [
            "/srv/vernissage/proxy/Dockerfile",
            "/srv/vernissage/proxy/nginx.conf"
        ])
        #expect(plan.files[1].contents.contains("vernissage-api.internal:8080"))
        #expect(plan.files[1].contents.contains("vernissage-web.internal:8080"))
        #expect(plan.files[1].contents.contains("vernissage-abcdefgh-minio:9000"))
        #expect(plan.files[1].contents.contains("location /static-resource/"))
        #expect(plan.preparationCommands.count == 2)
        #expect(plan.preparationCommands[0].arguments == [
            "image", "build", "--tag", "vernissage-proxy:abcdefgh",
            "/srv/vernissage/proxy"
        ])
        #expect(plan.containers[0].createArguments.contains("8080:8080"))
    }

    @Test
    func `MinIO plan rebuilds pinned source and preserves credentials and volume`() throws {
        let plan = try ContainerUpdatePlanFactory(
            operatingSystem: .linux
        ).plan(for: .minio, context: makeContext())

        #expect(plan.preparationCommands[0].standardInput?.contains(
            "github.com/minio/minio@RELEASE.2025-10-15T17-29-55Z"
        ) == true)
        #expect(plan.containers[0].environment == [
            "MINIO_ROOT_USER": "minio",
            "MINIO_ROOT_PASSWORD": "storage-secret"
        ])
        #expect(plan.containers[0].createArguments.contains(
            "type=volume,source=vernissage-abcdefgh-minio-data,target=/data"
        ))
    }

    @Test
    func `Current image skips container replacement`() throws {
        let plan = simplePlan(containerCount: 1)
        let runner = UpdateCommandRunner(results: [
            .success("pulled"),
            .success(digest("a")),
            .success(inspection(name: "api", digest: digest("a"), running: true))
        ])

        let result = try ContainerUpdateExecutor(
            commandRunner: runner,
            backupSuffix: { "backup01" },
            writeFile: { _ in }
        ).execute(plan)

        #expect(result.updatedServices.isEmpty)
        #expect(result.currentServices == ["API"])
        #expect(runner.invocations.count == 3)
    }

    @Test
    func `Running container is transactionally replaced and old container removed`() throws {
        let plan = simplePlan(containerCount: 1)
        let runner = UpdateCommandRunner(results: [
            .success("pulled"),
            .success(digest("b")),
            .success(inspection(name: "api", digest: digest("a"), running: true)),
            .success("api"),
            .success("renamed"),
            .success("created"),
            .success("api"),
            .success("removed")
        ])

        let result = try ContainerUpdateExecutor(
            commandRunner: runner,
            backupSuffix: { "backup01" },
            writeFile: { _ in }
        ).execute(plan)

        #expect(result.updatedServices == ["API"])
        #expect(result.currentServices.isEmpty)
        #expect(runner.invocations.map(\.arguments) == [
            ["image", "pull", "server:latest"],
            ["image", "inspect", "--format", "{{.Id}}", "server:latest"],
            [
                "container", "inspect", "--format",
                "[{{json .Name}},{{json .Image}},{{json .State.Running}}]", "api"
            ],
            ["container", "stop", "api"],
            ["container", "rename", "api", "api-update-backup01"],
            ["container", "create", "--name", "api", "server:latest"],
            ["container", "start", "api"],
            ["container", "rm", "api-update-backup01"]
        ])
        #expect(runner.invocations[5].environment == ["TOKEN": "secret"])
    }

    @Test
    func `Stopped container remains stopped after replacement`() throws {
        let plan = simplePlan(containerCount: 1)
        let runner = UpdateCommandRunner(results: [
            .success("pulled"),
            .success(digest("b")),
            .success(inspection(name: "api", digest: digest("a"), running: false)),
            .success("renamed"),
            .success("created"),
            .success("removed")
        ])

        _ = try ContainerUpdateExecutor(
            commandRunner: runner,
            backupSuffix: { "backup01" },
            writeFile: { _ in }
        ).execute(plan)

        #expect(runner.invocations.map(\.arguments).contains(["container", "stop", "api"]) == false)
        #expect(runner.invocations.map(\.arguments).contains(["container", "start", "api"]) == false)
    }

    @Test
    func `Failed startup removes new container and restores previous one`() {
        let plan = simplePlan(containerCount: 1)
        let runner = UpdateCommandRunner(results: [
            .success("pulled"),
            .success(digest("b")),
            .success(inspection(name: "api", digest: digest("a"), running: true)),
            .success("stopped"),
            .success("renamed"),
            .success("created"),
            .failure("new container failed to start"),
            .success("removed new"),
            .success("restored name"),
            .success("old started")
        ])

        let error = #expect(throws: ContainerUpdateExecutionError.self) {
            try ContainerUpdateExecutor(
                commandRunner: runner,
                backupSuffix: { "backup01" },
                writeFile: { _ in }
            ).execute(plan)
        }

        #expect(error?.localizedDescription.contains("previous container was restored") == true)
        #expect(runner.invocations.suffix(3).map(\.arguments) == [
            ["container", "rm", "--force", "api"],
            ["container", "rename", "api-update-backup01", "api"],
            ["container", "start", "api"]
        ])
    }

    @Test
    func `Missing selected container stops before replacement`() {
        let plan = simplePlan(containerCount: 1)
        let runner = UpdateCommandRunner(results: [
            .success("pulled"),
            .success(digest("b")),
            .failure("No such container: api")
        ])

        #expect(throws: ContainerUpdateExecutionError.containerInspectionFailed(
            details: "No such container: api"
        )) {
            try ContainerUpdateExecutor(
                commandRunner: runner,
                writeFile: { _ in }
            ).execute(plan)
        }
        #expect(runner.invocations.count == 3)
    }

    @Test
    func `Update command accepts implemented components and all`() throws {
        for rawComponent in UpdateComponent.allCases.map(\.rawValue) + ["all"] {
            let parsed = try VernissageCommand.parseAsRoot([
                "update", rawComponent, "--config", "/srv/vernissage/vernissage.yml"
            ])
            let command = try #require(parsed as? UpdateCommand)
            #expect(command.component.rawValue == rawComponent)
        }
    }

    @Test
    func `Update command rejects unknown targets`() {
        #expect(throws: (any Error).self) {
            try VernissageCommand.parseAsRoot(["update", "everything"])
        }
    }

    @Test
    func `All plans follow dependency order and group API and Jobs`() throws {
        let batch = try ContainerUpdatePlanFactory(operatingSystem: .linux)
            .batch(context: makeContext())

        #expect(batch.plans.map(\.component) == [
            .postgres, .redis, .minio, .server, .web, .push, .proxy, .caddy
        ])
        #expect(batch.skippedComponents.isEmpty)
        #expect(batch.plans.flatMap { $0.containers.map(\.service) } == [
            "PostgreSQL", "Redis", "MinIO", "API", "Jobs", "Web", "Push", "Proxy", "Caddy"
        ])
    }

    @Test
    func `All skips external dependencies and manual HTTPS`() throws {
        let context = makeContext()
        context.database = DatabaseConfiguration(
            mode: .existing, host: "postgres.example.com", port: 5432,
            database: "vernissage", username: "vernissage",
            password: Secret(value: "database-secret"), tlsMode: .require,
            localResources: nil
        )
        context.redis = RedisConfiguration(
            mode: .existing,
            url: Secret(value: "rediss://default:redis-secret@redis.example.com:6379/0"),
            username: "default", host: "redis.example.com", port: 6379, database: 0,
            password: Secret(value: "redis-secret"), usesTLS: true, localResources: nil
        )
        context.storage = StorageConfiguration(
            provider: .awsS3, address: "https://s3.example.com", region: "eu-central-1",
            bucket: "media", accessKeyId: "access-key",
            secretAccessKey: Secret(value: "storage-secret"), http1OnlyMode: false,
            localResources: nil
        )
        context.publicAccess = PublicAccessConfiguration(httpsMode: .manual)
        context.caddy = nil

        let batch = try ContainerUpdatePlanFactory(operatingSystem: .linux)
            .batch(context: context)

        #expect(batch.plans.map(\.component) == [.server, .web, .push, .proxy])
        #expect(batch.skippedComponents == [.postgres, .redis, .minio, .caddy])
    }

    @Test
    func `All rejects incomplete configuration instead of silently skipping it`() {
        let context = makeContext()
        context.caddy = nil
        #expect(throws: ServicesInventoryError.missingConfiguration("Caddy")) {
            try ContainerUpdatePlanFactory(operatingSystem: .linux).batch(context: context)
        }

        context.publicAccess = PublicAccessConfiguration(httpsMode: .manual)
        context.web = nil
        #expect(throws: ServicesInventoryError.missingConfiguration("Web")) {
            try ContainerUpdatePlanFactory(operatingSystem: .linux).batch(context: context)
        }
    }

    @Test
    func `All validates later plans before starting any update`() {
        let context = makeContext()
        context.server = nil
        #expect(throws: ContainerUpdatePlanError.missingConfiguration("server and domain")) {
            try ContainerUpdatePlanFactory(operatingSystem: .linux).batch(context: context)
        }
    }

    @Test
    func `Batch preflight inspects all containers before any preparation`() {
        let batch = ContainerUpdateBatch(
            plans: [simplePlan(containerCount: 2), batchWebPlan()], skippedComponents: []
        )
        let runner = UpdateCommandRunner(results: [.failure("No such container: web")])
        #expect(throws: ContainerUpdateExecutionError.containerInspectionFailed(
            details: "No such container: web"
        )) {
            try ContainerUpdateExecutor(
                commandRunner: runner,
                writeFile: { _ in Issue.record("Preflight must not write build files") }
            ).execute(batch)
        }
        #expect(runner.invocations.map(\.arguments) == [[
            "container", "inspect", "--format",
            "[{{json .Name}},{{json .Image}},{{json .State.Running}}]", "api", "jobs", "web"
        ]])
    }

    @Test
    func `Batch processes unchanged components in order and reports results`() throws {
        let runner = UpdateCommandRunner(results: [
            .success(batchInspection()),
            .success("pulled"), .success(digest("a")),
            .success(inspection(name: "api", digest: digest("a"), running: true)),
            .success("pulled"), .success(digest("a")),
            .success(inspection(name: "web", digest: digest("a"), running: false))
        ])
        var started: [UpdateComponent] = []
        var reported: [ContainerUpdateExecutionResult] = []
        let results = try ContainerUpdateExecutor(commandRunner: runner, writeFile: { _ in })
            .execute(
                ContainerUpdateBatch(
                    plans: [simplePlan(containerCount: 1), batchWebPlan()], skippedComponents: []
                ),
                willUpdate: { started.append($0) },
                didUpdate: { reported.append($0) }
            )

        #expect(started == [.server, .web])
        #expect(reported == results)
        #expect(results.map(\.currentServices) == [["API"], ["Web"]])
        #expect(runner.invocations.count == 7)
    }

    @Test
    func `Batch stops on failure and preserves completed component results`() throws {
        let server = simplePlan(containerCount: 1)
        let web = batchWebPlan()
        let push = ContainerUpdatePlan(
            component: .push, image: "push:latest", files: [], preparationCommands: [],
            containers: [ContainerReplacementSpecification(
                service: "Push", name: "push", createArguments: [], environment: [:]
            )]
        )
        let runner = UpdateCommandRunner(results: [
            .success(batchInspection() + "\n" + inspection(name: "push", digest: digest("a"), running: true)),
            .success("pulled"), .success(digest("b")),
            .success(inspection(name: "api", digest: digest("a"), running: true)),
            .success("stopped"), .success("renamed"), .success("created"),
            .success("started"), .success("removed"),
            .failure("registry unavailable")
        ])
        var reported: [ContainerUpdateExecutionResult] = []
        let error = #expect(throws: ContainerUpdateBatchError.self) {
            try ContainerUpdateExecutor(commandRunner: runner, writeFile: { _ in })
                .execute(
                    ContainerUpdateBatch(plans: [server, web, push], skippedComponents: []),
                    didUpdate: { reported.append($0) }
                )
        }

        #expect(error?.component == .web)
        #expect(error?.completed == [.server])
        #expect(error?.notAttempted == [.push])
        #expect(error?.localizedDescription.contains("registry unavailable") == true)
        #expect(error?.localizedDescription.contains("not rolled back") == true)
        #expect(reported.map(\.updatedServices) == [["API"]])
        #expect(runner.invocations.count == 10)
        #expect(runner.invocations.last?.arguments == ["image", "pull", "web:latest"])
    }

    private func batchWebPlan() -> ContainerUpdatePlan {
        ContainerUpdatePlan(
            component: .web, image: "web:latest", files: [],
            preparationCommands: [UpdateDockerCommand(
                arguments: ["image", "pull", "web:latest"], description: "pull web:latest"
            )],
            containers: [ContainerReplacementSpecification(
                service: "Web", name: "web",
                createArguments: ["--name", "web", "web:latest"], environment: [:]
            )]
        )
    }

    private func batchInspection() -> String {
        inspection(name: "api", digest: digest("a"), running: true) + "\n"
            + inspection(name: "web", digest: digest("a"), running: false)
    }

    private func simplePlan(containerCount: Int) -> ContainerUpdatePlan {
        let containers = (0..<containerCount).map { index in
            let name = index == 0 ? "api" : "jobs"
            let service = index == 0 ? "API" : "Jobs"
            return ContainerReplacementSpecification(
                service: service,
                name: name,
                createArguments: ["--name", name, "server:latest"],
                environment: ["TOKEN": "secret"]
            )
        }
        return ContainerUpdatePlan(
            component: .server,
            image: "server:latest",
            files: [],
            preparationCommands: [
                UpdateDockerCommand(
                    arguments: ["image", "pull", "server:latest"],
                    description: "pull server:latest"
                )
            ],
            containers: containers
        )
    }

    private func inspection(
        name: String,
        digest: String,
        running: Bool
    ) -> String {
        #"["/\#(name)","\#(digest)",\#(running)]"#
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }

    private func makeContext() -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.server = ServerConfiguration(domain: "social.example.com")
        context.database = DatabaseConfiguration(
            mode: .localContainer,
            host: "vernissage-abcdefgh-postgres",
            port: 5432,
            database: "vernissage",
            username: "vernissage",
            password: Secret(value: "database-secret"),
            tlsMode: .disable,
            localResources: LocalPostgreSQLResources(
                image: "postgres:18",
                containerName: "vernissage-abcdefgh-postgres",
                volumeName: "vernissage-abcdefgh-postgres-data",
                networkName: "vernissage-abcdefgh-network"
            )
        )
        context.redis = RedisConfiguration(
            mode: .localContainer,
            url: Secret(value: "redis://default:redis-secret@vernissage-abcdefgh-redis:6379/0"),
            username: "default",
            host: "vernissage-abcdefgh-redis",
            port: 6379,
            database: 0,
            password: Secret(value: "redis-secret"),
            usesTLS: false,
            localResources: LocalRedisResources(
                image: "redis:8.8.1-alpine",
                containerName: "vernissage-abcdefgh-redis",
                volumeName: "vernissage-abcdefgh-redis-data",
                networkName: "vernissage-abcdefgh-network"
            )
        )
        context.storage = StorageConfiguration(
            provider: .localMinIO,
            address: "http://vernissage-abcdefgh-minio:9000",
            region: nil,
            bucket: "vernissage",
            accessKeyId: "minio",
            secretAccessKey: Secret(value: "storage-secret"),
            http1OnlyMode: false,
            localResources: LocalMinIOResources(
                image: "vernissage/minio:RELEASE.2025-10-15T17-29-55Z",
                containerName: "vernissage-abcdefgh-minio",
                volumeName: "vernissage-abcdefgh-minio-data",
                networkName: "vernissage-abcdefgh-network"
            )
        )
        context.serverServices = ServerServicesConfiguration(
            image: "mczachurski/vernissage-server:latest",
            networkName: "vernissage-abcdefgh-network",
            apiContainerName: "vernissage-abcdefgh-api",
            jobsContainerName: "vernissage-abcdefgh-jobs",
            apiNetworkAlias: "vernissage-api.internal",
            jobsNetworkAlias: "vernissage-jobs.internal",
            baseAddress: "https://social.example.com",
            apiHealth: nil,
            jobsHealth: nil,
            databaseTables: nil
        )
        context.web = WebConfiguration(
            image: "mczachurski/vernissage-web:latest",
            containerName: "vernissage-abcdefgh-web",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-web.internal",
            allowedHosts: "social.example.com,*.social.example.com",
            cspImageSource: "https://media.example.com"
        )
        context.push = PushConfiguration(
            image: "mczachurski/vernissage-push:latest",
            containerName: "vernissage-abcdefgh-push",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-push.internal",
            endpoint: "http://vernissage-push.internal:3000/send",
            secretKey: Secret(value: "push-secret"),
            isEnabled: false
        )
        context.proxy = ProxyConfiguration(
            image: "vernissage-proxy:abcdefgh",
            containerName: "vernissage-abcdefgh-proxy",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-proxy.internal",
            hostPort: 8080,
            containerPort: 8080,
            apiUpstream: "vernissage-api.internal:8080",
            webUpstream: "vernissage-web.internal:8080",
            publicHTTPAddress: "http://social.example.com:8080",
            buildContextPath: "/srv/vernissage/proxy"
        )
        context.publicAccess = PublicAccessConfiguration(httpsMode: .development)
        context.caddy = CaddyConfiguration(
            image: "caddy:latest",
            containerName: "vernissage-abcdefgh-caddy",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-caddy.internal",
            dataVolumeName: "vernissage-abcdefgh-caddy-data",
            configVolumeName: "vernissage-abcdefgh-caddy-config",
            caddyfilePath: "/srv/vernissage/caddy/Caddyfile",
            publicHTTPSAddress: "https://social.example.com",
            localRootCertificatePath: "/srv/vernissage/caddy/root.crt"
        )
        return context
    }
}

private struct UpdateInvocation: Equatable {
    let arguments: [String]
    let environment: [String: String]
    let standardInput: String?
}

private enum UpdateCommandRunnerError: Error {
    case resultNotConfigured
}

private final class UpdateCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [UpdateInvocation] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String?
    ) throws -> CommandResult {
        invocations.append(
            UpdateInvocation(
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
        )
        guard results.isEmpty == false else {
            throw UpdateCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private extension CommandResult {
    static func success(_ output: String) -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "")
    }

    static func failure(_ error: String) -> CommandResult {
        CommandResult(exitCode: 1, standardOutput: "", standardError: error)
    }
}
