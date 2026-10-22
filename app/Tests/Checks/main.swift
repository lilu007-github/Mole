import Foundation

// Usage: run-checks [filter]   e.g. run-checks parser, run-checks ai/trash
Task { @MainActor in
    ParsingChecks.register()
    AIChecks.register()
    LiveChecks.register()
    let status = await Checks.run(filter: CommandLine.arguments.dropFirst().first)
    removeFixtures()
    exit(status)
}
RunLoop.main.run()
