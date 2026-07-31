# Coverage

Coverage is observed data. Cygnus reads what a test run actually
produced — SPM's llvm-cov JSON export, under
`.build/<triple>/debug/codecov/` — and never invents a number. If no
artifact exists, the answer is "run your tests with coverage", not a
guess.

Turn on the **Coverage** toggle in the graph controls to draw it.

## What you see

- A **halo arc** on each node, red through green, for its line
  coverage.
- With **Expand** on, each node's functions orbit it as satellites,
  colored by their own region coverage — so a well-covered class with
  one untested function shows exactly which one.

## Run the suite from the graph

Running the suite from here executes the repo's test classes **one at
a time**, unioning the results after each. The halos fill in as the
run progresses rather than appearing at the end, which makes a long
suite legible while it runs. The test classes come from the analyzed
graph, so the repo must be analyzed first.

The run is cancellable, and a second request is ignored while one is
in flight.

## Per-test attribution

Select a single test class to attribute coverage to it alone: the
halos then show what *that test* covers, not what the whole suite
covers. This is the view that answers "is this test actually
exercising the thing it claims to".

One attribution is held at a time — attributing a new test replaces
the previous one.

## Test outcome colors

Test-to-code links are colored by the last run's outcome: green for
pass, red for fail, amber for partial. Verdicts are tracked per test
*method* as well as per class, so one failing method reddens only its
own links instead of condemning the whole class.
