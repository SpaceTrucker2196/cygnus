---
title: Visualization Ideas from Kill It With Fire
summary: Views worth building, drawn from Bellotti's legacy-modernization book — plus the critique it levels at whole-system graphs like ours.
updated: 2026-07-31
---

# Visualization Ideas from *Kill It With Fire*

Source: Marianne Bellotti, *Kill It With Fire* (No Starch, 2021). Page
numbers below are the print pages. The book is about modernizing aging
systems, so its questions are exactly the questions
[[graph-projections]] should be able to answer.

## The critique to sit with first

Bellotti explicitly warns against the thing cygnus is: "Good
modernization work needs to suppress that impulse to create elegant
comprehensive architectures up front" (p. 78). And on dependency
mapping, a footnote is blunt — "Dependency trees can be quite
complicated, and traversing the whole graph is a lot of work without a
lot of payoff. Make a list of the application's direct dependencies
and what those packages depend on, and then accept the risk that there
might be a problem in nodes further down and move on" (p. 68).

That is a real argument against the whole-graph render as the default
view. It does not say the graph is worthless; it says the *scoped*
question beats the comprehensive picture. Every idea below narrows the
graph to answer one question, which is the shape the book endorses.

## 1. Depth-limited neighborhood ("two levels down")

The book's actual instruction is "Map its dependencies two levels
down" (p. 68). Our focus mode lights a node's neighborhood but does
not bound it by hops.

Add a hop-depth control (1, 2, 3, all) to focus mode. Small change on
data we already have, and it turns the graph into the artifact the
book actually asks for.

## 2. Request-path tracing

"Attempt to trace the flow of data through the application to complete
one request" (p. 68). Today you can focus a node, but you cannot ask
"how does A reach B".

Pick two nodes, render the paths between them, dim everything else.
Computable now from the existing edges — shortest path plus the
alternates. This is the missing verb: the graph answers *what connects
to what* but not *how does this get there*.

## 3. Ownership overlay and responsibility gaps

The strongest idea in the book for us, and the one needing new
evidence. "There are parts of the system with shared ownership, parts
that no one is responsible for at all, parts where responsibilities
are split in unintuitive ways. When looking for bad technology, debt,
or security issues, the most productive places to mine are gaps
between what two components of the same organization officially own"
(p. 98).

`git log` is evidence we already shell out for. Author facts are
**observed**; ownership concentration is **derived**; "this is a
responsibility gap" is **inferred** — the layering in
[[knowledge-graph]] holds cleanly.

Encodings that fit the existing grammar: single-author regions (the
book's "20 percent projects", p. 99), code whose only authors have
stopped committing, and boundaries where two owners interleave. The
last one is the payload — a seam between owners is where debt
collects.

## 4. Overgrowth: the auxiliary software layer

"Overgrowth is a particular type of coupling between the software and
the layers of abstraction making up the platform on which it runs"
(p. 64) — shell scripts, build files, CI config, the things that must
be migrated *before* the application can be.

We already parse Makefiles and Fastfiles for [[renderers]], and we
throw that structure away outside the CI Flow tab. Promote build and CI
files to first-class graph nodes coupled to the code they build, and
"what else has to move if this moves" becomes visible. Cheap, because
the parsing exists.

## 5. Pattern-versus-Role disagreement

"Artificial consistency means restricting design patterns and
solutions to a small pool that can be standardized and repeated
throughout the entire architecture in a way that does not provide
technical value… it focuses on consistency of form and classification
over functionality" (p. 35).

Our **Pattern** grouping reads naming convention; **Role** infers
structure from fan-in/fan-out. The book's warning is precisely that
these can diverge. Render the disagreement directly: highlight nodes
whose name says one thing and whose structure says another. A file
named `…Service` that is structurally a Leaf is either misnamed or
misplaced, and both are worth knowing.

## 6. Partial-migration front

"Technical debt… is a product of subpar trade-offs: partial
migrations, quick patches, and out-of-date or unnecessary
dependencies" (p. 39). Partial migrations are visible in the import
graph: two modules serving the same role, with files importing one,
the other, or both.

Show the migration front — what has moved, what has not, and which
files straddle both. The straddlers are the work. This turns a vague
"we're mid-migration" into a countable set.

## 7. Change over revisions, not just the current state

"The measurable problem… is objective and irrefutable" (p. 78), and
positive results should not be tied to feature launches.

We store immutable revisions and the CLI already has `diff <r1> <r2>`
([[cli]]), but the app only ever draws *now*. Show the delta between
two revisions on the graph, and trend a chosen metric — cycle count,
coverage, orphan count — across revisions. That is what makes a
modernization effort legible while it is happening, and it is mostly
plumbing we already own.

## 8. Forgotten and lost code

The book devotes a section to "Forgotten and Lost Systems" (p. 111).
Unreachable subgraphs — nodes with no path from any entry point — are
computable from what we have and are the graph equivalent.

Pair it with the ownership overlay from idea 3: unreachable *and*
unowned is the strongest deletion candidate a codebase can offer.

## Where these fit the 4+1 model

The book recommends Kruchten's 4+1 architectural view model for
projecting impact (p. 173): logical (how end users experience it),
process (what runs, in what order), development (the code structure),
physical (hardware and network), plus scenarios.

Cygnus renders the **development** view, and CI Flow is a partial
**process** view. Logical and physical are absent. That is not
necessarily a gap to close — it is a statement of what we are, and
worth being deliberate about.
