import Testing
@testable import WhatCable

// Pure-function tests for the "run some probes twice" plan builder. No
// subprocesses here (see TestKitRunnerOutputLimitTests.swift for the
// process-launching coverage); this only checks the plan TestKitRunner.run()
// hands to the execution loop.
@Suite("Test Kit execution plan")
struct TestKitExecutionPlanTests {
    @Test("The repeat list is exactly the registry snapshot")
    func repeatProbeListContent() {
        // Pinned to the probe rebuild: the snapshot is sampled at the start
        // and the end of every run, replacing the old 31, 32, 29 repeats.
        // Comparing repeatProbes against itself elsewhere in this file would
        // be tautological, so this test asserts the literal content instead.
        #expect(TestKitRunner.repeatProbes == [
            "50_registry_snapshot",
        ])
    }

    @Test("Default plan runs every probe once, then the repeat probes again at the end")
    func defaultPlanAppendsRepeatsAtTheEnd() {
        let plan = TestKitRunner.executionPlan()

        // Every probe from the main list appears once, submitted under its
        // own name, in the original order, before any repeat run starts.
        let firstPass = Array(plan.prefix(TestKitRunner.probeNames.count))
        #expect(firstPass.map(\.binaryName) == TestKitRunner.probeNames)
        #expect(firstPass.map(\.submissionName) == TestKitRunner.probeNames)

        // The repeat probes run again at the very end, in the declared
        // order, submitted under a distinct "_end" name so they
        // don't overwrite the first-position KV key.
        let secondPass = Array(plan.suffix(TestKitRunner.repeatProbes.count))
        #expect(secondPass.map(\.binaryName) == TestKitRunner.repeatProbes)
        #expect(secondPass.map(\.submissionName) == TestKitRunner.repeatProbes.map { "\($0)_end" })

        // Total run count is probes-once plus the extra repeats: this is
        // what the progress UI's "total" must match, or the counter gets
        // stuck short of 100% or overshoots it.
        #expect(plan.count == TestKitRunner.probeNames.count + TestKitRunner.repeatProbes.count)
    }

    @Test("Every repeat probe is a probe that actually exists in the main list")
    func repeatProbesAreAllInMainList() {
        // A typo in repeatProbes, or a future probe rename that forgets to
        // update this list, would silently produce a probe binary that
        // never exists on disk. TestKitRunner.run() would still "work": the
        // missing binary just gets logged as "not found" and lands in
        // noOutputProbes, with no build error and no obviously loud runtime
        // signal. This test is the guard the private CI's probe list parity
        // job deliberately does not cover (it only checks probeNames against
        // probes/test-kit/*.c, not repeatProbes against probeNames).
        for repeatProbe in TestKitRunner.repeatProbes {
            #expect(
                TestKitRunner.probeNames.contains(repeatProbe),
                "repeatProbes names \"\(repeatProbe)\", which is not in probeNames"
            )
        }
    }

    @Test("Every submission name in the plan is unique")
    func submissionNamesAreUnique() {
        let plan = TestKitRunner.executionPlan()
        let names = plan.map(\.submissionName)

        #expect(Set(names).count == names.count)
    }

    @Test("A repeat probe not present in the main list still gets both its binary name and an _end submission name")
    func repeatProbeIndependentOfMainList() {
        let plan = TestKitRunner.executionPlan(probeNames: ["01_walk_pd_tree"], repeatProbes: ["09_made_up_probe"])

        #expect(plan == [
            TestKitRunner.ProbeRun(binaryName: "01_walk_pd_tree", submissionName: "01_walk_pd_tree"),
            TestKitRunner.ProbeRun(binaryName: "09_made_up_probe", submissionName: "09_made_up_probe_end"),
        ])
    }

    @Test("An empty repeat list degrades to running every probe exactly once")
    func emptyRepeatListRunsOnce() {
        let plan = TestKitRunner.executionPlan(probeNames: ["01_walk_pd_tree", "03_hpm_deep_dive"], repeatProbes: [])

        #expect(plan.count == 2)
        #expect(plan.allSatisfy { $0.binaryName == $0.submissionName })
    }
}
