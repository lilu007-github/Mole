import Foundation

// Usage: run-checks [filter]   e.g. run-checks parser, run-checks ai/trash
setvbuf(stdout, nil, _IOLBF, 0) // print each result as it happens, even through a pipe
Task { @MainActor in
    ParsingChecks.register()
    AIChecks.register()
    HistoryChecks.register()
    PurgeChecks.register()
    UninstallChecks.register()
    ToolChecks.register()
    ProcessChecks.register()
    WhitelistChecks.register()
    ExternalChecks.register()
    UpdateChecks.register()
    StartupChecks.register()
    ProcessDetailChecks.register()
    NotifierChecks.register()
    LiveChecks.register()
    let status = await Checks.run(filter: CommandLine.arguments.dropFirst().first)
    removeFixtures()
    exit(status)
}
RunLoop.main.run()
