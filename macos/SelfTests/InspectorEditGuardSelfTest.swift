import Foundation

@main
struct InspectorEditGuardSelfTest {
    @MainActor static func main() async {
        let guardrail = InspectorEditGuard()
        var navigations = 0
        guardrail.request { navigations += 1 }
        precondition(navigations == 1)
        guardrail.dirty = true
        guardrail.request { navigations += 1 }
        precondition(guardrail.needsDecision && navigations == 1)
        guardrail.cancel()
        precondition(guardrail.dirty && navigations == 1)
        guardrail.save = { false }
        guardrail.request { navigations += 1 }
        await guardrail.saveAndContinue()
        precondition(guardrail.dirty && guardrail.error != nil && navigations == 1)
        guardrail.save = { true }
        await guardrail.saveAndContinue()
        precondition(!guardrail.dirty && navigations == 2)
        var discarded = false
        guardrail.dirty = true
        guardrail.discard = { discarded = true }
        guardrail.request { navigations += 1 }
        guardrail.discardAndContinue()
        precondition(discarded && !guardrail.dirty && navigations == 3)
        guardrail.dirty = true
        let cancelledQuit = Task { await guardrail.resolveBeforeTermination() }
        while !guardrail.needsDecision { await Task.yield() }
        guardrail.cancel()
        let cancelResult = await cancelledQuit.value
        precondition(!cancelResult && guardrail.dirty)
        let savedQuit = Task { await guardrail.resolveBeforeTermination() }
        while !guardrail.needsDecision { await Task.yield() }
        guardrail.save = { false }
        await guardrail.saveAndContinue()
        precondition(guardrail.needsDecision && guardrail.dirty)
        guardrail.save = { true }
        await guardrail.saveAndContinue()
        let saveResult = await savedQuit.value
        precondition(saveResult && !guardrail.dirty)
        guardrail.dirty = true
        let discardedQuit = Task { await guardrail.resolveBeforeTermination() }
        while !guardrail.needsDecision { await Task.yield() }
        guardrail.discardAndContinue()
        let discardResult = await discardedQuit.value
        precondition(discardResult && !guardrail.dirty)
        print("Termination guard passed: cancel, failed save, saved quit and discarded quit")
        print("InspectorEditGuardSelfTest passed: clean, cancel, failed save retains draft, confirmed save, discard")
    }
}
