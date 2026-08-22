# edge_asic_power_ctrl.v

## Purpose and ownership

`edge_asic_power_ctrl` owns the blocking `edge.asic.power` transaction between
the instruction-facing E3/E4 platform and the physical accelerator power
domain. It drives a level-sensitive power-enable control and synchronizes the
external ready status through two flops. E3 and E4 may implement different
physical wake latencies; the architectural command completes from status, not
from a hard-coded cycle count.

## Command lifetime

Power-on asserts `asic_power_enable` and holds the command pending until the
synchronized `asic_power_ready` is high. Power-off first waits for Tensor,
ACTU, CMPU, and DMA to become idle, then deasserts enable and waits for ready
to fall. Repeating an already satisfied state completes without toggling the
control. Only one power command may be outstanding and completion is a
one-cycle pulse.

`asic_ready` is the synchronized physical status. Product composition uses
this same signal to block every ordinary accelerator command and every DTCM
client request while the domain is off or transitioning. Power commands alone
bypass that dispatch gate, preventing startup deadlock.

## Validation

The focused Verilator test delays both ready edges, checks that commands remain
pending, verifies busy accelerator work postpones power-off, and covers
idempotent on/off requests without duplicate responses.
