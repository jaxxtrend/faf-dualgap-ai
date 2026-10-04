-- Builder conditions used by the DualGap builder groups. DualGap drives
-- engineers and factories itself; the stock builder manager only needs one
-- placeholder builder (AIBuilders/DualGapIdleBuilders.lua), and its
-- condition never fires. The managers call conditions as
-- func(aiBrain, unpack(args)), so the brain comes first.

-- Used by the placeholder builder that keeps the stock FactoryManager inert.
function Never(aiBrain)
    return false
end
