; Entry point: Vehicle state, lighting control and CAN. The refloat adapter is optional:
; remove its line below and its import for a standalone-only package.
; VESC Tool only bundles imports declared in float_accessories.lisp, so the
; matching (import ...) lines live there; this file owns the load order.
(read-eval-program vehicle)
(read-eval-program lighting-control)
(read-eval-program can)
(read-eval-program refloat-adapter)
