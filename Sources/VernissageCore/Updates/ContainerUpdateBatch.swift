import ArgumentParser
import Foundation

// Keep the CLI selector separate from components: "all" has no image of its own.
enum UpdateTarget: Equatable, ExpressibleByArgument {
    case component(UpdateComponent)
    case all

    init?(argument: String) {
        if argument == "all" {
            self = .all
        } else if let component = UpdateComponent(rawValue: argument) {
            self = .component(component)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .component(let component): component.rawValue
        case .all: "all"
        }
    }

    static var allValueStrings: [String] {
        UpdateComponent.allCases.map(\.rawValue) + ["all"]
    }
}

struct ContainerUpdateBatch {
    let plans: [ContainerUpdatePlan]
    let skippedComponents: [UpdateComponent]
}

extension ContainerUpdatePlanFactory {
    func batch(context: InstallationContext) throws -> ContainerUpdateBatch {
        // Validate the complete installation before treating any dependency as external.
        let services = try ServicesInventory().services(from: context)
        let managed = Set(services.filter(\.isManagedByInstaller).map(\.name))
        let ordered: [(UpdateComponent, String)] = [
            (.postgres, "PostgreSQL"), (.redis, "Redis"), (.minio, "S3 storage"),
            (.server, "API"), (.web, "Web"), (.push, "Push"),
            (.proxy, "Proxy"), (.caddy, "HTTPS")
        ]
        var plans: [ContainerUpdatePlan] = []
        var skipped: [UpdateComponent] = []
        for (component, service) in ordered {
            if managed.contains(service) {
                plans.append(try plan(for: component, context: context))
            } else {
                skipped.append(component)
            }
        }
        return ContainerUpdateBatch(plans: plans, skippedComponents: skipped)
    }
}

struct ContainerUpdateBatchError: LocalizedError {
    let component: UpdateComponent
    let completed: [UpdateComponent]
    let notAttempted: [UpdateComponent]
    let details: String

    var errorDescription: String? {
        let completedNames = completed.map(\.rawValue).joined(separator: ", ")
        let pendingNames = notAttempted.map(\.rawValue).joined(separator: ", ")
        return """
        Update of '\(component.rawValue)' failed. \
        Completed components: \(completedNames.isEmpty ? "none" : completedNames). \
        Not attempted: \(pendingNames.isEmpty ? "none" : pendingNames). \
        Earlier completed updates were not rolled back. Details: \(details)
        """
    }
}

extension ContainerUpdateExecutor {
    func execute(
        _ batch: ContainerUpdateBatch,
        willUpdate: (UpdateComponent) -> Void = { _ in },
        didUpdate: (ContainerUpdateExecutionResult) -> Void = { _ in }
    ) throws -> [ContainerUpdateExecutionResult] {
        // Verify every selected container before the first pull, build, or replacement.
        try verifyContainers(in: batch.plans)
        var results: [ContainerUpdateExecutionResult] = []
        for (index, plan) in batch.plans.enumerated() {
            willUpdate(plan.component)
            let result: ContainerUpdateExecutionResult
            do {
                result = try execute(plan)
            } catch {
                throw ContainerUpdateBatchError(
                    component: plan.component,
                    completed: results.map(\.component),
                    notAttempted: batch.plans.dropFirst(index + 1).map(\.component),
                    details: error.localizedDescription
                )
            }
            results.append(result)
            didUpdate(result)
        }
        return results
    }
}
