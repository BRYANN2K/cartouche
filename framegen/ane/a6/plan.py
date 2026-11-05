# Which compute unit Core ML picks for each operation of a compiled model
import sys, collections, coremltools as ct
from coremltools.models.compute_plan import MLComputePlan
plan = MLComputePlan.load_from_path(path=sys.argv[1], compute_units=ct.ComputeUnit.CPU_AND_NE)
program = plan.model_structure.program
counts, off = collections.Counter(), collections.Counter()
for fn in program.functions.values():
    for op in fn.block.operations:
        usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
        if usage is None:
            continue
        dev = type(usage.preferred_compute_device).__name__.replace("ML", "").replace("ComputeDevice", "")
        counts[dev] += 1
        if dev != "NeuralEngine":
            off[op.operator_name] += 1
print("ops by device:", dict(counts))
print("off the ANE:", dict(off))
