@const-start
(def can-loop-delay)

; Edge-triggered telemetry logging.
; Only logs on change so a board sitting still produces no output, but every
; state / fault / footpad / link transition is timestamped in the console.
(defun dbg-can-transitions () {
    (if (dbg-active DBG-CAN) {
        (var conn (if (vehicle-fresh) 1 0))
        (if (!= conn dbg-prev-can-conn) {
            (setq dbg-prev-can-conn conn)
            (dbg DBG-CAN (if (= conn 1) "can up" "can down"))
        })
        (if (!= state dbg-prev-state) {
            (setq dbg-prev-state state)
            (dbg DBG-CAN (str-merge "can state " (str-from-n state "%d")))
        })
        (if (!= switch-state dbg-prev-switch) {
            (setq dbg-prev-switch switch-state)
            (dbg DBG-CAN (str-merge "can sw " (str-from-n switch-state "%d")
                " adc " (str-from-n (to-float footpad-adc1-t) "%.2f")
                " " (str-from-n (to-float footpad-adc2-t) "%.2f")))
        })
    })
    ; A fault is worth printing even with DBG-CAN off, but only on the edge.
    (if (!= fault-code dbg-prev-fault) {
        (setq dbg-prev-fault fault-code)
        (if (!= fault-code 0)
            (dbg-warn (str-merge "can fault " (str-from-n fault-code "%d")))
            (dbg DBG-CAN "can fault clear"))
    })
})


; Transport housekeeping; controller protocols live in optional adapters.
(defun can-loop (){
    (setq can-loop-delay (get-config 'can-loop-delay))
    (var next-run-time (secs-since 0))
    (var loop-start-time 0)
    (var loop-end-time 0)
    (if (< can-loop-delay 1) {
        (dbg-warn "can bad rate, using 30Hz")
        (setq can-loop-delay 30)
    })
    (var can-loop-delay-sec (/ 1.0 can-loop-delay))
    ; Discovery can take seconds; without this the first pass reports the
    ; whole of it as a loop overrun.
    (setq next-run-time (secs-since 0))
    (loopwhile t {
        (if (!= dbg-mask 0) (setq dbg-ticks-can (+ dbg-ticks-can 1)))

        (setq loop-start-time (secs-since 0))
        (if (not sim-active) {
            (integration-step)
            (bms-service-step)
            (vehicle-refresh-battery)

            (if need-fetch-cells {
                (setq need-fetch-cells nil)
                (setq last-fetch-cells-time (secs-since 0))
                (fetch-series-cells)
                (apply-battery-config (get-config 'soc-type) (get-config 'cell-type))
            })

            (if need-fetch-limits {
                (setq need-fetch-limits nil)
                (fetch-current-limits)
            })
        })

        (setq loop-end-time (secs-since 0))
        (var actual-loop-time (- loop-end-time loop-start-time))

        (dbg-can-transitions)
        (if (dbg-tick DBG-CAN 'can-tel 2.0)
            (dbg DBG-CAN (str-merge "can age " (str-from-n (secs-since can-last-activity-time) "%.2f")
                " vin " (str-from-n (to-float vin) "%.1f")
                " soc " (str-from-n (* 100.0 battery-percent-remaining) "%.0f")
                " rpm " (str-from-n (to-float rpm) "%.0f")
                " kmh " (str-from-n (to-float speed) "%.1f")
                " A " (str-from-n (to-float tot-current) "%.1f")
                " duty " (str-from-n (to-float duty-cycle-now) "%.2f")
                " fet " (str-from-n (to-float fet-temp-filtered) "%.0f")
                " work " (str-from-n actual-loop-time "%.4f"))))

        (var time-to-wait (- next-run-time (secs-since 0)))
        (if (> time-to-wait 0) {
            (yield (* time-to-wait 1000000))
        } {
            ; Overrun: the poll took longer than the configured period, so
            ; the effective CAN rate is below what the user set.
            (if (dbg-tick DBG-CAN 'can-overrun 5.0)
                (dbg-warn (str-merge "can overrun " (str-from-n (- 0 time-to-wait) "%.4f"))))
            (setq next-run-time (secs-since 0))
        })
        (setq next-run-time (+ next-run-time
            can-loop-delay-sec))
    })
})

(defun fetch-series-cells () {
    (var target can-id)
    (var generation integration-generation)
    (if (>= target 0) {
        (var cells (bms-cell-count))
        (if (= cells 0) {
            (print "No BMS info; querying ESC for series cells...")
            (var response)
            
            ; Spawn thread to receive CAN response
            (loopwhile-thd 35 (eq response nil) {
                (setq response (canmsg-recv 0 5)) ; Blocks until message or 'timeout
            })

            ; Send ESC query
            (can-cmd target (str-merge
                "(progn "
                "(var resp (array-create 4)) "
                "(bufset-i32 resp 0 (conf-get 'si-battery-cells)) "
                "(canmsg-send " (str-from-n (can-local-id)) " 0 resp) "
                "(free resp))"
            ))

            ; Busy wait until thread updates response
            (loopwhile (eq response nil) {
                (sleep 0.01) ; Light spin, prevent CPU hammering
            })

            ; Evaluate the response
            (if (and (= generation integration-generation) (= target can-id)
                     (not (eq response 'timeout)) (>= (buflen response) 4)) {
                (setq series-cells (bufget-i32 response 0))
                (print (str-merge "Battery cells (from ESC): " (str-from-n series-cells)))
            } {
                (print "ESC query for series cells timed out")
            })
        } {
            (setq series-cells cells)
            (print (str-merge "Battery cells (from BMS): " (str-from-n series-cells)))
        })
    })
})

; Same request/response shape as fetch-series-cells, on CAN slot 1 so the
; two can never pick up each other's reply.
(defun fetch-current-limits () {
    (var target can-id)
    (var generation integration-generation)
    (if (>= target 0) {
        (var response)
        (loopwhile-thd 35 (eq response nil) {
            (setq response (canmsg-recv 1 5))
        })

        ; Amps x10 as i16, scales applied - those are what the ESC enforces
        (can-cmd target (str-merge
            "(progn "
            "(var resp (array-create 8)) "
            "(bufset-i16 resp 0 (to-i (* 10 (conf-get 'l-current-max) (conf-get 'l-current-max-scale)))) "
            "(bufset-i16 resp 2 (to-i (* 10 (conf-get 'l-current-min) (conf-get 'l-current-min-scale)))) "
            "(bufset-i16 resp 4 (to-i (* 10 (conf-get 'l-in-current-max)))) "
            "(bufset-i16 resp 6 (to-i (* 10 (conf-get 'l-in-current-min)))) "
            "(canmsg-send " (str-from-n (can-local-id)) " 1 resp) "
            "(free resp))"
        ))

        (loopwhile (eq response nil) {
            (sleep 0.01)
        })

        (if (and (= generation integration-generation) (= target can-id)
                 (not (eq response 'timeout)) (>= (buflen response) 8)) {
            (setq esc-motor-current-max (abs (/ (bufget-i16 response 0) 10.0)))
            (setq esc-motor-current-min (abs (/ (bufget-i16 response 2) 10.0)))
            (setq esc-bat-current-max (abs (/ (bufget-i16 response 4) 10.0)))
            (setq esc-bat-current-min (abs (/ (bufget-i16 response 6) 10.0)))
            (print (str-merge "ESC current limits: motor "
                (str-from-n esc-motor-current-max "%.0f") "/-" (str-from-n esc-motor-current-min "%.0f")
                " A, battery " (str-from-n esc-bat-current-max "%.0f") "/-" (str-from-n esc-bat-current-min "%.0f") " A"))
        } {
            (print "ESC query for current limits timed out")
        })
    })
})


@const-end
