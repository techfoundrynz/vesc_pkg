; Entry point: QML/CAN command handling and the simulator.
; VESC Tool only bundles imports declared in float_accessories.lisp, so the
; matching (import ...) lines live there; this file owns the load order.
(read-eval-program commands)
(read-eval-program sim)
