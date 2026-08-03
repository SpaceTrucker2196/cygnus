import Foundation

// Running a CI-flow build and animating it live. Only Makefile flows
// are runnable for now — a fastlane lane can sign and upload, so those
// aren't started from a button. The build runs the default goal with
// security-scoped access; streamed output feeds CIFlowBuildTracker,
// which lights up the flow node by node.

extension WorkspaceStore {
    public func buildProgress(for id: UUID) -> BuildProgress {
        builds[id] ?? BuildProgress()
    }

    /// The pipeline to chart and run: a projection of the graph once
    /// the repo has been analyzed, the capability scan's file parse
    /// until then. The projection is the real thing — the fallback
    /// only covers the window before a first snapshot exists, and the
    /// differential tests in CIFlowProjectionTests are the proof the
    /// two draw the same chart.
    public func ciFlow(for id: UUID) -> CIFlow? {
        if case .ready(let snapshot)? = states[id],
           let flow = CIFlow.projected(from: snapshot) {
            return flow
        }
        return factoryState(for: id).caps.ciFlow
    }

    /// Whether Run is offered: a non-empty Makefile flow that isn't
    /// already building.
    public func canBuild(_ id: UUID) -> Bool {
        guard let flow = ciFlow(for: id) else { return false }
        return flow.source == .make && !flow.isEmpty && buildProgress(for: id).phase != .running
    }

    /// Start the build for a repo's Make flow and stream it into the
    /// animation. No-op if it can't run.
    public func startBuild(for id: UUID, locator: ToolLocator = .resolve()) {
        guard canBuild(id),
              let flow = ciFlow(for: id),
              let root = repoURL(id) else { return }
        guard let makePath = locator.path(for: .make) else {
            var failed = BuildProgress()
            failed.phase = .failed
            failed.append("make executable not found")
            builds[id] = failed
            return
        }

        let goal = Self.defaultGoal(of: flow)
        var tracker = CIFlowBuildTracker(flow: flow)
        tracker.start()
        var progress = BuildProgress()
        progress.phase = .running
        progress.command = "make" + (goal.map { " \($0)" } ?? "")
        progress.nodeStates = tracker.states
        progress.activeNodeID = tracker.activeID
        buildTrackers[id] = tracker
        builds[id] = progress

        let runner = BuildStreamRunner()
        buildRunners[id] = runner
        let args = goal.map { [$0] } ?? []
        let env = Self.buildEnvironment(locator: locator)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await RepoAccess.withAccess(to: root) { root in
                    let stream = runner.stream(executable: makePath, arguments: args,
                                               workingDirectory: root, environment: env)
                    for await event in stream {
                        await self.handleBuildEvent(event, for: id)
                    }
                }
            } catch {
                self.markBuildFailed(id, message: "\(error)")
            }
            self.buildRunners[id] = nil
        }
    }

    public func cancelBuild(for id: UUID) {
        buildRunners[id]?.cancel()
        buildRunners[id] = nil
        buildTrackers[id] = nil
        if var progress = builds[id], progress.phase == .running {
            progress.phase = .failed
            progress.activeNodeID = nil
            progress.append("build cancelled")
            builds[id] = progress
        }
    }

    func handleBuildEvent(_ event: BuildEvent, for id: UUID) {
        guard var progress = builds[id], progress.phase == .running else { return }
        switch event {
        case .line(let line):
            progress.append(line)
            if var tracker = buildTrackers[id] {
                tracker.consume(line: line)
                progress.nodeStates = tracker.states
                progress.activeNodeID = tracker.activeID
                buildTrackers[id] = tracker
            }
        case .finished(let code):
            if var tracker = buildTrackers[id] {
                tracker.finish(exitCode: code)
                progress.nodeStates = tracker.states
            }
            progress.activeNodeID = nil
            progress.phase = code == 0 ? .succeeded : .failed
            buildTrackers[id] = nil
        case .failed(let message):
            progress.append(message)
            progress.phase = .failed
            progress.activeNodeID = nil
            buildTrackers[id] = nil
        }
        builds[id] = progress
    }

    private func markBuildFailed(_ id: UUID, message: String) {
        guard var progress = builds[id], progress.phase == .running else { return }
        progress.append(message)
        progress.phase = .failed
        progress.activeNodeID = nil
        buildTrackers[id] = nil
        builds[id] = progress
    }

    /// The goal to run: the target the entry (trigger) points at, else
    /// the first lane/target in the flow.
    public static func defaultGoal(of flow: CIFlow) -> String? {
        if let entry = flow.nodes.first(where: { $0.kind == .trigger }),
           let edge = flow.edges.first(where: { $0.from == entry.id }),
           let target = flow.nodes.first(where: { $0.id == edge.to }) {
            return target.label
        }
        return flow.nodes.first(where: { $0.kind == .lane })?.label
    }

    /// A minimal build environment: pinned PATH (so the compiler and
    /// its tools resolve), non-interactive, no colour codes to muddy
    /// the line parser.
    private static func buildEnvironment(locator: ToolLocator) -> [String: String] {
        var env: [String: String] = [
            "PATH": locator.searchDirectories.joined(separator: ":"),
            "CLICOLOR": "0",
            "TERM": "dumb",
        ]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SDKROOT", "DEVELOPER_DIR"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        return env
    }
}
