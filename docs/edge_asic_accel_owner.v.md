# edge_asic_accel_owner.v

## Purpose and ownership

`edge_asic_accel_owner` accepts the serialized ASIC32 command boundary emitted
by a strictly in-order scalar core. The
EX instruction remains the sole architectural owner while downstream is
stalled, so the leaf forwards its stable instruction and already-read capture
operand directly to `edge_accel_pipe`.

## Handshake and state

`req_ready` follows `cmd_ready` while no response pulse is active. A request is
accepted exactly when the downstream command fires. The leaf registers one
response for the following cycle so the lite core can first record request
acceptance and then observe completion. Illegal decode becomes `resp_error`;
getcsr-style `cmd_result_valid` selects the returned value, while setup, start
and sync commands return zero.

There is no queue, operand snapshot RAM, sequence ID, epoch, redirect cleanup,
or response-ready channel. Backpressure is safe because the in-order core holds
the request payload stable until `req_ready`. Start completion means the unit
accepted the command; a later sync command provides execution ordering.

## Validation

The focused test holds downstream ready low, checks payload stability, accepts
one request without duplication, checks the one-cycle response, then covers
result and illegal responses.

The E3 `edge_lite_accel_dispatch_tb.v` integration test composes the owner with the maintained
`edge_accel_pipe` and proves one response and one unit command for Tensor,
ACTU, CMPU and DMA setup/start/sync traffic plus a getcsr value. Sequence and
epoch inputs are fixed to zero because no lite command can overlap another.
