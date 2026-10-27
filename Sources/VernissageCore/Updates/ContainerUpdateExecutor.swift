import Foundation

struct ContainerUpdateExecutionResult: Equatable {
    let component: UpdateComponent
    let image: String
    let updatedServices: [String]
    let currentServices: [String]
}

enum ContainerUpdateExecutionError: LocalizedError, Equatable {
    case filePreparationFailed(path: String, details: String)
    case imagePreparationFailed(action: String, details: String)
    case imageInspectionFailed(image: String, details: String)
    case containerInspectionFailed(details: String)
    case invalidInspectionResponse(String)
    case replacementFailed(details: String, rollbackDetails: String?)
    case cleanupFailed(details: String, backupContainers: [String])

    var errorDescription: String? {
        switch self {
        case .filePreparationFailed(let path, let details):
            return "The update could not prepare '\(path)'. No container was changed. Details: \(details)"
        case .imagePreparationFailed(let action, let details):
            return "Docker could not \(action). No container was changed. Details: \(details)"
        case .imageInspectionFailed(let image, let details):
            return "Docker could not inspect the prepared image '\(image)'. No container was changed. Details: \(details)"
        case .containerInspectionFailed(let details):
            return "Docker could not inspect the containers selected for update. No container was changed. Details: \(details)"
        case .invalidInspectionResponse(let details):
            return "Docker returned an invalid update inspection response. No container was changed. Details: \(details)"
        case .replacementFailed(let details, let rollbackDetails):
            if let rollbackDetails {
                return "The new container could not be installed and automatic rollback was incomplete. Details: \(details). Rollback: \(rollbackDetails)"
            }
            return "The new container could not be installed. The previous container was restored. Details: \(details)"
        case .cleanupFailed(let details, let backupContainers):
            return "The update succeeded, but Docker could not remove the temporary old containers: \(backupContainers.joined(separator: ", ")). Remove them manually after verification. Details: \(details)"
        }
    }
}

struct ContainerUpdateExecutor {
    private struct ExistingContainer: Equatable {
        let name: String
        let imageDigest: String
        let wasRunning: Bool
    }

    private let commandRunner: any CommandRunning
    private let backupSuffix: () -> String
    private let writeFile: (UpdateFile) throws -> Void

    init(
        commandRunner: any CommandRunning,
        backupSuffix: @escaping () -> String = {
            String(UUID().uuidString.lowercased().prefix(8))
        },
        writeFile: @escaping (UpdateFile) throws -> Void = Self.writeUpdateFile
    ) {
        self.commandRunner = commandRunner
        self.backupSuffix = backupSuffix
        self.writeFile = writeFile
    }

    func execute(_ plan: ContainerUpdatePlan) throws -> ContainerUpdateExecutionResult {
        try prepareFiles(plan.files)
        try prepareImage(plan.preparationCommands)
        let newImageDigest = try inspectImage(plan.image)
        let existing = try inspectContainers(plan.containers.map(\.name))
        let existingByName = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.name, $0) }
        )

        let replacements = plan.containers.filter {
            existingByName[$0.name]?.imageDigest != newImageDigest
        }
        let current = plan.containers.filter {
            existingByName[$0.name]?.imageDigest == newImageDigest
        }
        guard replacements.isEmpty == false else {
            return ContainerUpdateExecutionResult(
                component: plan.component,
                image: plan.image,
                updatedServices: [],
                currentServices: current.map(\.service)
            )
        }

        let suffix = backupSuffix()
        let backupNames = Dictionary(
            uniqueKeysWithValues: replacements.map {
                ($0.name, "\($0.name)-update-\(suffix)")
            }
        )
        var renamed: [ContainerReplacementSpecification] = []
        var created: [ContainerReplacementSpecification] = []

        do {
            let runningNames = replacements.compactMap { replacement in
                existingByName[replacement.name]?.wasRunning == true
                    ? replacement.name
                    : nil
            }
            if runningNames.isEmpty == false {
                try requireSuccess(
                    ["container", "stop"] + runningNames,
                    action: "stop the old containers"
                )
            }

            for replacement in replacements {
                guard let backupName = backupNames[replacement.name] else {
                    continue
                }
                try requireSuccess(
                    ["container", "rename", replacement.name, backupName],
                    action: "rename \(replacement.name) before replacement"
                )
                renamed.append(replacement)
            }

            for replacement in replacements {
                try requireSuccess(
                    ["container", "create"] + replacement.createArguments,
                    action: "create the new \(replacement.name) container",
                    environment: replacement.environment
                )
                created.append(replacement)
            }

            let namesToStart = replacements.compactMap { replacement in
                existingByName[replacement.name]?.wasRunning == true
                    ? replacement.name
                    : nil
            }
            if namesToStart.isEmpty == false {
                try requireSuccess(
                    ["container", "start"] + namesToStart,
                    action: "start the new containers"
                )
            }
        } catch {
            let rollbackDetails = rollback(
                replacements: replacements,
                renamed: renamed,
                created: created,
                backupNames: backupNames,
                existingByName: existingByName
            )
            throw ContainerUpdateExecutionError.replacementFailed(
                details: error.localizedDescription,
                rollbackDetails: rollbackDetails
            )
        }

        let backups = replacements.compactMap { backupNames[$0.name] }
        do {
            try requireSuccess(
                ["container", "rm"] + backups,
                action: "remove the temporary old containers"
            )
        } catch {
            throw ContainerUpdateExecutionError.cleanupFailed(
                details: error.localizedDescription,
                backupContainers: backups
            )
        }

        return ContainerUpdateExecutionResult(
            component: plan.component,
            image: plan.image,
            updatedServices: replacements.map(\.service),
            currentServices: current.map(\.service)
        )
    }

    func verifyContainers(in plans: [ContainerUpdatePlan]) throws {
        _ = try inspectContainers(plans.flatMap { $0.containers.map(\.name) })
    }

    private func prepareFiles(_ files: [UpdateFile]) throws {
        for file in files {
            do {
                try writeFile(file)
            } catch {
                throw ContainerUpdateExecutionError.filePreparationFailed(
                    path: file.path,
                    details: error.localizedDescription
                )
            }
        }
    }

    private func prepareImage(_ commands: [UpdateDockerCommand]) throws {
        for command in commands {
            let result: CommandResult
            do {
                result = try commandRunner.run(
                    "docker",
                    arguments: command.arguments,
                    environment: command.environment,
                    standardInput: command.standardInput
                )
            } catch {
                throw ContainerUpdateExecutionError.imagePreparationFailed(
                    action: command.description,
                    details: error.localizedDescription
                )
            }
            guard result.succeeded else {
                throw ContainerUpdateExecutionError.imagePreparationFailed(
                    action: command.description,
                    details: commandFailureDetails(result)
                )
            }
        }
    }

    private func inspectImage(_ image: String) throws -> String {
        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: ["image", "inspect", "--format", "{{.Id}}", image],
                environment: [:],
                standardInput: nil
            )
        } catch {
            throw ContainerUpdateExecutionError.imageInspectionFailed(
                image: image,
                details: error.localizedDescription
            )
        }
        guard result.succeeded else {
            throw ContainerUpdateExecutionError.imageInspectionFailed(
                image: image,
                details: commandFailureDetails(result)
            )
        }
        let digest = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digest.isEmpty == false else {
            throw ContainerUpdateExecutionError.imageInspectionFailed(
                image: image,
                details: "Docker returned an empty image identifier"
            )
        }
        return digest
    }

    private func inspectContainers(_ names: [String]) throws -> [ExistingContainer] {
        let format = "[{{json .Name}},{{json .Image}},{{json .State.Running}}]"
        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: ["container", "inspect", "--format", format] + names,
                environment: [:],
                standardInput: nil
            )
        } catch {
            throw ContainerUpdateExecutionError.containerInspectionFailed(
                details: error.localizedDescription
            )
        }
        guard result.succeeded else {
            throw ContainerUpdateExecutionError.containerInspectionFailed(
                details: commandFailureDetails(result)
            )
        }

        do {
            let documents = try result.standardOutput
                .split(whereSeparator: \Character.isNewline)
                .map { line -> ExistingContainer in
                    let values = try JSONDecoder().decode(
                        [InspectionValue].self,
                        from: Data(line.utf8)
                    )
                    guard values.count == 3,
                          case .string(let rawName) = values[0],
                          case .string(let imageDigest) = values[1],
                          case .boolean(let wasRunning) = values[2] else {
                        throw ContainerUpdateExecutionError.invalidInspectionResponse(
                            String(line)
                        )
                    }
                    return ExistingContainer(
                        name: rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName,
                        imageDigest: imageDigest,
                        wasRunning: wasRunning
                    )
                }
            guard documents.count == names.count else {
                throw ContainerUpdateExecutionError.invalidInspectionResponse(
                    "Docker returned \(documents.count) containers for \(names.count) requested names"
                )
            }
            return documents
        } catch let error as ContainerUpdateExecutionError {
            throw error
        } catch {
            throw ContainerUpdateExecutionError.invalidInspectionResponse(
                error.localizedDescription
            )
        }
    }

    private func rollback(
        replacements: [ContainerReplacementSpecification],
        renamed: [ContainerReplacementSpecification],
        created: [ContainerReplacementSpecification],
        backupNames: [String: String],
        existingByName: [String: ExistingContainer]
    ) -> String? {
        var failures: [String] = []

        if created.isEmpty == false {
            let removal = runBestEffort(
                ["container", "rm", "--force"] + created.map(\.name)
            )
            if let removal {
                failures.append("remove new containers: \(removal)")
            }
        }

        for replacement in renamed.reversed() {
            guard let backupName = backupNames[replacement.name] else {
                continue
            }
            if let rename = runBestEffort([
                "container", "rename", backupName, replacement.name
            ]) {
                failures.append("restore \(replacement.name): \(rename)")
            }
        }

        let namesToRestart = replacements.compactMap { replacement in
            existingByName[replacement.name]?.wasRunning == true
                ? replacement.name
                : nil
        }
        if namesToRestart.isEmpty == false,
           let restart = runBestEffort(["container", "start"] + namesToRestart) {
            failures.append("restart old containers: \(restart)")
        }

        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    private func requireSuccess(
        _ arguments: [String],
        action: String,
        environment: [String: String] = [:]
    ) throws {
        let result = try commandRunner.run(
            "docker",
            arguments: arguments,
            environment: environment,
            standardInput: nil
        )
        guard result.succeeded else {
            throw UpdateDockerCommandError.failed(
                action: action,
                details: commandFailureDetails(result)
            )
        }
    }

    private func runBestEffort(_ arguments: [String]) -> String? {
        do {
            let result = try commandRunner.run(
                "docker",
                arguments: arguments,
                environment: [:],
                standardInput: nil
            )
            return result.succeeded ? nil : commandFailureDetails(result)
        } catch {
            return error.localizedDescription
        }
    }

    private func commandFailureDetails(_ result: CommandResult) -> String {
        if result.standardError.isEmpty == false {
            return result.standardError
        }
        if result.standardOutput.isEmpty == false {
            return result.standardOutput
        }
        return "docker exited with code \(result.exitCode)"
    }

    private static func writeUpdateFile(_ file: UpdateFile) throws {
        let url = URL(fileURLWithPath: file.path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try file.contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum UpdateDockerCommandError: LocalizedError {
    case failed(action: String, details: String)

    var errorDescription: String? {
        switch self {
        case .failed(let action, let details):
            return "Docker could not \(action). Details: \(details)"
        }
    }
}

private enum InspectionValue: Decodable {
    case string(String)
    case boolean(Bool)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .boolean(try container.decode(Bool.self))
        }
    }
}
