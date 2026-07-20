import CygnusEngine
import CygnusStore

// CLI harness — the fastest way to exercise the engine without the
// app. Subcommands land with their phases: register (E2), index (E3),
// query (E3), watch (E5), verify (E5).

let usage = """
cygnus \(CygnusEngineInfo.version) — repository knowledge graph engine

usage: cygnus <command>

commands:
  register <path>   register a repository (E2)
  index             snapshot + analyze registered repositories (E3)
  query <kind>      query the graph: contains | deps (E3)
  watch             continuous incremental analysis (E5)
  verify            recompute from scratch, diff against incremental (E5)
  bench             interval-schema storage benchmark (E0 spike)
"""

switch CommandLine.arguments.dropFirst().first {
case "bench":
    try StoreBenchmark.run()
default:
    print(usage)
}
