import Foundation
import CygnusGraph
import CygnusQuery

// One line shape for every tool, so an agent learns it once.
//
//   repo-relative/path.swift:42-58  send(_:to:) [core:function]  observed/compiler
//
// Path and line first, so it can be pasted straight into a read.
// Then what it is, then — always — the knowledge layer and how it was
// resolved. That last pair is invariant 9 enforced where it counts: a
// compiler-resolved caller and a text match must never look alike.

public enum Rendering {
    public static func declaration(_ entity: ResolvedEntity) -> String {
        let anchor = entity.version.anchors.first
        let path = anchor?.path ?? "(no anchor)"
        let range = anchor?.range
        let location = range.map { range in
            range.startLine == range.endLine
                ? "\(path):\(range.startLine)"
                : "\(path):\(range.startLine)-\(range.endLine)"
        } ?? path
        return "\(location)  \(entity.version.name) [\(entity.entity.kind.rawValue)]"
            + "  observed/syntactic"
    }

    public static func reference(_ reference: Lookups.Reference, callsOnly: Bool) -> String {
        let anchor = reference.source.version.anchors.first
        let line = anchor?.range?.startLine ?? 0
        let counts = callsOnly
            ? "\(reference.callCount) call(s)"
            : "\(reference.referenceCount) reference(s), \(reference.callCount) call(s)"
        return "\(anchor?.path ?? "?"):\(line)  \(reference.source.version.name)"
            + "  derived/compiler  \(counts)"
    }
}
