; Entry point: BMS service, backend manager and bundled adapters. Adapters only register
; callbacks here; hardware is opened by the selected backend's worker. To drop an
; adapter, remove its line below and its import in float_accessories.lisp.
; VESC Tool only bundles imports declared in float_accessories.lisp, so the
; matching (import ...) lines live there; this file owns the load order.
(read-eval-program bms-vars)
(read-eval-program bms)
(read-eval-program bms-backend)
(read-eval-program ow-bms-vars)
(read-eval-program ow-bms)
(read-eval-program ssbms)
(read-eval-program ssbms-uart)
(read-eval-program ssbms-ble)
