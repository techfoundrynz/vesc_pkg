@const-start

(defun max (a b)
    (if (> a b) a b)
)

(defun min (a b)
    (if (< a b) a b)
)

(defun print-hex (data)
    (print
        (map (fn (x) (bufget-u8 data x)) (range (buflen data)))
    )
)

; Dispatch handlers are wrapped in trap so a malformed packet can never kill
; the event thread - an unhandled eval error would otherwise cost a >=1s
; control/telemetry blackout while the restart monitor respawns it.
(defun dispatch-trapped (name res)
    (if (eq (ix res 0) 'exit-error)
        (dbg-err (str-merge name " " (to-str (ix res 1))))
    )
)

(defun event-handler ()
    (loop () t
        (recv
            ((event-esp-now-rx (? src) (? des) (? data) (? rssi)) {
                (if (!= dbg-mask 0) (setq dbg-ticks-evt (+ dbg-ticks-evt 1)))
                (if (dbg-tick DBG-REM 'rem-rx 2.0)
                    (dbg DBG-REM (str-merge "rem rx " (str-from-n (buflen data) "%d")
                        " rssi " (str-from-n rssi "%d"))))
                (dispatch-trapped "pubmote-rx" (trap (pubmote-rx src des data rssi)))
            })
            ((event-data-rx . (? data)) {
                (if (!= dbg-mask 0) (setq dbg-ticks-evt (+ dbg-ticks-evt 1)))
                (dispatch-trapped "command-rx" (trap (command-rx data)))
            })
            (_ nil)
        )
    )
)

(defun send-msg (text)
    (send-data (str-merge "msg " text))
)

(defun send-status (text)
    (send-data (str-merge "status " text))
)

; VESC Express "Bluetooth Mode LBM" (saved value): 0 Disabled, 1 Server,
; 2 Client, 3 Client & Server; -1 when the firmware has no such setting.
(defun express-ble-role () {
    (var role (trap (conf-get 'ble-mode-lbm)))
    (if (and (eq (ix role 0) 'exit-ok) (number? (ix role 1))) (ix role 1) -1)
})

; Add the client role for SSBMS BLE, keeping Server when it is selected.
; Saved to flash; the firmware applies Bluetooth roles after a reboot.
(defun express-ble-enable-client () {
    (var role (express-ble-role))
    (if (or (= role 0) (= role 1)) {
        (conf-set 'ble-mode-lbm (if (= role 1) 3 2))
        (conf-store)
        (send-status "Bluetooth role saved, reboot to apply")
    })
})

(defun mklist (len val)
    (map (fn (x) val) (range len))
)

(defun split-list (lst n)
    (if (eq lst nil)
        nil
        (cons (take lst n) (split-list (drop lst n) n))
    )
)

(defunret pack-bytes-to-uint32 (byte-list) {
  (return (to-u32 (+ (shl (to-u32 (ix byte-list 0)) 24)
                     (shl (to-u32 (ix byte-list 1)) 16)
                     (shl (to-u32 (ix byte-list 2)) 8)
                     (to-u32 (ix byte-list 3)))))
})
(defunret unpack-uint32-to-bytes (packed-value) {
  (return (list (to-byte (bitwise-and (shr packed-value 24) 0xFF))
                (to-byte (shr (bitwise-and packed-value 0xFF0000) 16))
                (to-byte (shr (bitwise-and packed-value 0xFF00) 8))
                (to-byte (bitwise-and packed-value 0xFF))))
})

(defun apply-battery-config (new-soc-type new-cell-type) {
    (setq soc-type new-soc-type)
    (setq cell-type new-cell-type)
    ;(setq series-cells (get-config 'series-cells))
    (setq voltage-curve (get-voltage-curve cell-type))
    (print (str-merge "Cell info: type=" (str-from-n cell-type) " soc-type=" (str-from-n soc-type) " series-cells=" (str-from-n series-cells)))
    ; A voltage-curve SoC with an unknown cell count silently reports nonsense (vin / -1), which shows up as a stuck battery gauge.
    (if (and (= (to-i soc-type) 1) (< series-cells 1))
        (dbg-warn "curve SoC but cell count unknown"))
})

(defun estimate-soc (v voltage-curve) {
    (var n (length voltage-curve))
    (var socs (list 100 90 80 70 60 50 40 30 20 10 0))
    (cond
        ((>= v (ix voltage-curve 0)) 100.0)
        ((<= v (ix voltage-curve (- n 1))) 0.0)
        (t {
            (var result 0.0)
            ; looprange excludes its upper bound: use n to include the final
            ; 10%-to-0% interval. Return a number even if no interval matches.
            (looprange i 1 n {
                (if (and (>= v (ix voltage-curve i)) (<= v (ix voltage-curve (- i 1)))) {
                    (var v1 (ix voltage-curve (- i 1)))
                    (var v2 (ix voltage-curve i))
                    (var s1 (ix socs (- i 1)))
                    (var s2 (ix socs i))
                    (setq result (+ s1 (* (/ (- v v1) (- v2 v1)) (- s2 s1))))
                    (break)
                })
            })
            result
        })
    )
})

(defun get-var (i) i)

(defun get-version () pkg-version)

(defun is-pubmote-connected ()
    (if (= (get-config 'pubmote-enabled) 1) (pubmote-connected) 0)
)

@const-end
