import Testing
import Foundation
@testable import CygnusKit

struct CIFlowTests {
    private let fastfile = """
    default_platform(:ios)

    platform :ios do
      desc "Push a new beta build to TestFlight"
      lane :beta do
        sign
        build_app(scheme: "App")
        version = get_version_number
        upload_to_testflight
      end

      lane :release do
        build_app(scheme: "App")
        if ENV["NOTARIZE"]
          notarize
        end
        upload_to_app_store
      end

      private_lane :sign do
        match(type: "appstore")
      end
    end
    """

    @Test func parsesLaneStepsSkippingKeywordsAndAssignments() {
        let lanes = FastlaneFlowBuilder.parseLanes(fromFastfile: fastfile)
        #expect(lanes.map(\.name) == ["beta", "release", "sign"])

        let beta = lanes[0]
        // `version = get_version_number` is an assignment — skipped;
        // control keywords (`if`, `end`) never appear as steps.
        #expect(beta.steps == ["sign", "build_app", "upload_to_testflight"])

        let release = lanes[1]
        #expect(release.steps == ["build_app", "notarize", "upload_to_app_store"])
        #expect(!release.steps.contains("if"))
        #expect(!release.steps.contains("end"))
    }

    @Test func mapsCITriggersToLanes() {
        let byLane = FastlaneFlowBuilder.triggers(
            from: ["deploy.yml: bundle exec fastlane ios beta",
                   "release.yml: fastlane ios release"],
            laneNames: ["beta", "release", "sign"])
        #expect(byLane["beta"] == ["deploy.yml"])
        #expect(byLane["release"] == ["release.yml"])
        #expect(byLane["sign"] == nil)
    }

    @Test func buildsLaidOutFlowWithLaneCallEdge() {
        let info = FastlaneInfo(
            lanes: [], appfile: [],
            ciInvocations: ["deploy.yml: bundle exec fastlane ios beta"])
        let flow = FastlaneFlowBuilder.build(info: info, fastfileText: fastfile)

        #expect(!flow.isEmpty)
        // Trigger sits at column 0, lane at column 1, steps rightward.
        let trigger = flow.nodes.first { $0.kind == .trigger }
        #expect(trigger?.label == "deploy.yml")
        #expect(trigger?.column == 0)
        let betaLane = flow.nodes.first { $0.id == "lane:beta" }
        #expect(betaLane?.column == 1)

        // `sign` inside beta is a call to a real lane → laneCall node
        // plus an edge into that lane's node.
        let signCall = flow.nodes.first { $0.kind == .laneCall && $0.label == "sign" }
        #expect(signCall != nil)
        #expect(flow.edges.contains { $0.from == signCall?.id && $0.to == "lane:sign" })

        // The trigger wires into its lane.
        #expect(flow.edges.contains { $0.from == trigger?.id && $0.to == "lane:beta" })
    }

    @Test func emptyWhenNoLanes() {
        let info = FastlaneInfo(lanes: [], appfile: [], ciInvocations: [])
        let flow = FastlaneFlowBuilder.build(info: info, fastfileText: "default_platform(:ios)\n")
        #expect(flow.isEmpty)
    }
}
