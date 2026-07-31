# CI Flow

The repository's build pipeline drawn as a flowchart. The source is
the repo's own files — no configuration, no fixtures.

- A **fastlane** Fastfile becomes CI trigger to lane to actions, with
  sub-lane calls wired across.
- A **Makefile** becomes default goal to target to recipe commands,
  with prerequisite targets wired as dependency edges.

Fastlane is preferred when both exist. Variable and pattern targets
(`$(TARGET)`, `%.o`) are kept verbatim so the graph stays connected
rather than silently dropping edges.

## Running a build

Press **Run** to start the pipeline for real. The flow animates as it
happens: each node lights up when its work runs, turns green when it
completes, and turns red on failure. Progress is paced by the build's
actual output, not a timer.

Only Makefile flows are runnable. A fastlane lane can sign and upload
a build, and that is not something a button press should do by
accident — run those from the terminal, deliberately.

## Navigation

- **Scroll** to zoom.
- **Drag** to pan.
- **Click** to select a node.

The view draws only when something changes — a new flow, a resize, a
pan, a zoom, a selection, or a frame of build animation — so it costs
nothing while idle.

VoiceOver reads a summary of the whole flow, including its counts.
