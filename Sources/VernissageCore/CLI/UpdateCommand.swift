import ArgumentParser

public struct UpdateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update one component or all installer-managed components."
    )

    @OptionGroup
    var configurationOptions: ConfigurationOptions

    @Argument(help: "Component to update: server, web, push, proxy, caddy, redis, postgres, minio, or all.")
    var component: UpdateTarget

    @Flag(name: .long, help: "Disable ANSI colors in terminal output.")
    var noColor = false

    public init() {}

    public mutating func run() throws {
        let console = Console.live(colorsEnabled: noColor == false)

        do {
            let context = try configurationOptions.loadContext()
            let factory = ContainerUpdatePlanFactory(
                operatingSystem: .current
            )
            let executor = ContainerUpdateExecutor(
                commandRunner: ProcessCommandRunner()
            )
            switch component {
            case .component(let selected):
                let plan = try factory.plan(for: selected, context: context)
                console.pending("Preparing the \(selected.rawValue) image…")
                let result = try executor.execute(plan)
                console.section("Vernissage container update")
                render(result, console: console)
            case .all:
                let batch = try factory.batch(context: context)
                console.section("Vernissage container updates")
                console.warning("No automatic database, object-storage, or volume backup is created.")
                for skipped in batch.skippedComponents {
                    console.info("Skipped \(skipped.rawValue): not managed by this installation.")
                }
                _ = try executor.execute(
                    batch,
                    willUpdate: { selected in
                        console.pending("Preparing the \(selected.rawValue) image…")
                    },
                    didUpdate: { result in render(result, console: console) }
                )
                console.success("All installer-managed components processed.")
                console.info("Run vernissagectl doctor with the same configuration to verify service health.")
            }
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    private func render(_ result: ContainerUpdateExecutionResult, console: Console) {
        for service in result.updatedServices {
            console.success("Updated \(service).")
        }
        for service in result.currentServices {
            console.info("\(service) already uses the prepared image.")
        }
        if result.updatedServices.isEmpty == false {
            console.value(label: "Image", value: result.image)
            if component != .all {
                console.warning("No automatic database, object-storage, or volume backup was created.")
            }
        }
    }
}
