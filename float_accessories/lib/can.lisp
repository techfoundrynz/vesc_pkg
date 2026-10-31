@const-start
(def can-loop-delay)
(def fault-code 0)
(def pitch-angle 0)
(def roll-angle 0)
(def state 0)
(def sat-t 0)
(def switch-state 0)
(def handtest-mode nil)
(def sim-active nil)
(def rpm 0)
(def speed 0)
(def tot-current 0)
(def bat-current 0)
(def duty-cycle-now 0)
(def distance-abs -1)
(def fet-temp-filtered 0)
(def motor-temp-filtered 0)
(def odometer -1)
(def can-id -1)
(def bms-can-id -1)
(def bms-is-charging nil)
(def bms-charger-just-plugged nil)
(def bms-charger-plug-in-time 0)
(def vin -1)
(def last-running-state-time 0)
(def battery-percent-remaining 0.0)
(def footpad-adc1-t 0.0)
(def footpad-adc2-t 0.0)
(def series-cells -1)
(def refloat-humidity nil)
(def soc-type 0)
(def cell-type)
(def voltage-curve)
(def need-fetch-cells nil)
(def need-fetch-limits nil)
; ESC current limits as positive magnitudes, for phase/battery utilization. 0 = unknown,
; which drops that term until fetch-current-limits succeeds.
(def esc-motor-current-max 0)
(def esc-motor-current-min 0)
(def esc-bat-current-max 0)
(def esc-bat-current-min 0)
(def last-fetch-cells-time 0)

(def FLOAT_MAGIC 101)
(def FLOAT_ACCESSORIES_MAGIC 102)

(def float-cmds '(
    (COMMAND_GET_INFO . 0)
    (COMMAND_GET_ALLDATA . 10)
    (COMMAND_LCM_POLL . 24)
    (COMMAND_HUMIDITY . 51)
))

(def float-accessories-cmds '(
    (COMMAND_GET_INFO . 0)
    (COMMAND_RUN_LISP . 1)
    (COMMAND_BMS_STATUS . 2)
))

(def discover-can-id -1)

; ---- Refloat external LCM brightness ------------------------------------
; A full poll reply proves external LCM is configured; disabled replies contain
; only magic + command. Cache runtime targets, never overwrite local config.
(def refloat-lcm-valid nil)
(def refloat-lcm-time 0)
(def refloat-lcm-can-id -1)
(def refloat-lcm-last-poll 0)
(def refloat-lcm-brightness 0.0)
(def refloat-lcm-idle 0.0)
(def refloat-lcm-status 0.0)

(defun refloat-brightness-active ()
    (and (= led-follow-refloat 1) refloat-lcm-valid (not sim-active)
         (= refloat-lcm-can-id can-id)
         (< (secs-since refloat-lcm-time) 1.0)))

(defun poll-refloat-brightness () {
    (if (= led-follow-refloat 1) {
        (if (>= (secs-since refloat-lcm-last-poll) 0.1) {
            (setq refloat-lcm-last-poll (systime))
            (float-cmd can-id (list (assoc float-cmds 'COMMAND_LCM_POLL)))
        })
    } {
        (setq refloat-lcm-valid nil)
    })
})

(defun refloat-brightness-rx (data) (atomic {
    ; 2 header + 3 state + 6 telemetry + 3 brightness bytes. Extra payload
    ; pairs belong to LCM extensions and are intentionally ignored here.
    (setq refloat-lcm-valid nil)
    (if (and (= led-follow-refloat 1) (>= (buflen data) 14)) {
        (var ride (bufget-u8 data 11))
        (var idle (bufget-u8 data 12))
        (var status (bufget-u8 data 13))
        (if (and (<= ride 100) (<= idle 100) (<= status 100)) {
            (setq refloat-lcm-brightness (/ ride 100.0))
            (setq refloat-lcm-idle (/ idle 100.0))
            (setq refloat-lcm-status (/ status 100.0))
            (setq refloat-lcm-time (systime))
            (setq refloat-lcm-can-id can-id)
            (setq refloat-lcm-valid t)
        })
    })
}))
; ---- End Refloat brightness ---------------------------------------------

(defun running-state (){
    (let ret (and (>= state 1) (<= state 5)))
})

; Edge-triggered telemetry logging.
; Only logs on change so a board sitting still produces no output, but every
; state / fault / footpad / link transition is timestamped in the console.
(defun dbg-can-transitions () {
    (if (dbg-active DBG-CAN) {
        (var conn (if (< (secs-since can-last-activity-time) 1) 1 0))
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

; Every node polls the ESC for itself. There is no master: at the two or
; three nodes a board realistically carries, the bus cost of each asking its
; own questions is far cheaper than the coordination a single poller needed.
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
    ; init-can returns 1/0, and 0 is truthy in lisp - compare explicitly.
    (if (!= (init-can) 1) (dbg-warn "can no ESC found"))
    ; Discovery can take seconds; without this the first pass reports the
    ; whole of it as a loop overrun.
    (setq next-run-time (secs-since 0))
    (var last-rediscover (secs-since 0))
    (loopwhile t {
        (if (!= dbg-mask 0) (setq dbg-ticks-can (+ dbg-ticks-can 1)))

        (setq loop-start-time (secs-since 0))
        (if (not sim-active) {
            ; Discovery failed (or the ESC was powered up later). Keep looking,
            ; but only with the passive probe - it reads the CAN status table and
            ; blocks nobody. The ping sweep is never repeated here: it stalls the
            ; whole lisp evaluator and would restart the LED stutter every 5 s.
            (if (and (< can-id 0) (> (- (secs-since 0) last-rediscover) 5)) {
                (setq last-rediscover (secs-since 0))
                (var heard (can-devices-heard))
                (if heard {
                    (dbg DBG-CAN (str-merge "can heard " (to-str heard)))
                    (if (try-can-devices heard) (finish-can-init -1))
                })
            })
            ; Only poll once an ESC has actually been found: can-id is -1 until
            ; then, and sending to id -1 at 20 Hz puts frames on the bus that
            ; nothing can ack.
            (if (>= can-id 0) {
                (float-cmd can-id (list (assoc float-cmds 'COMMAND_GET_ALLDATA) 3))
                (poll-refloat-brightness)
                (if (and refloat-humidity (get-config 'humidity-enabled)) (float-cmd can-id (list (assoc float-cmds 'COMMAND_HUMIDITY) (to-byte hum))))
            })

            (if (or (>= bms-can-id 0) (< (secs-since bms-last-activity-time) 1)){
                (var prev-charging-state bms-is-charging)
                (setq bms-is-charging (and (> (get-bms-val 'bms-v-charge) 10.0) (> (abs(get-bms-val 'bms-i-in-ic)) 0.1)))

                (if (and bms-is-charging (not prev-charging-state)){
                        (dbg DBG-CAN "can charger in")
                        (setq bms-charger-just-plugged t)
                        (setq bms-charger-plug-in-time (secs-since 0))
                })
                (if (and prev-charging-state (not bms-is-charging))
                    (dbg DBG-CAN "can charger out"))
                ; Check if we're within 5 seconds of initial plug-in and charging started
                (if (not (and bms-charger-just-plugged (<= (- (secs-since 0) bms-charger-plug-in-time) 5))){
                    ; Reset the flag if more than 5 seconds have passed
                    (setq bms-charger-just-plugged nil)
                })
            })

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
            (if (< can-id 0) (max can-loop-delay-sec 0.25) can-loop-delay-sec)))
    })
})

(defun fetch-series-cells () {
    (if (>= can-id 0) {
        (var cells 0)
        (if (> (get-bms-val 'bms-can-id) -1) (setq cells (get-bms-val 'bms-cell-num)))
        (if (= cells 0) {
            (print "No BMS info; querying ESC for series cells...")
            (var response)
            
            ; Spawn thread to receive CAN response
            (loopwhile-thd 35 (eq response nil) {
                (setq response (canmsg-recv 0 5)) ; Blocks until message or 'timeout
            })

            ; Send ESC query
            (can-cmd can-id (str-merge
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
            (if (not (eq response 'timeout)) {
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
    (if (>= can-id 0) {
        (var response)
        (loopwhile-thd 35 (eq response nil) {
            (setq response (canmsg-recv 1 5))
        })

        ; Amps x10 as i16, scales applied - those are what the ESC enforces
        (can-cmd can-id (str-merge
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

        (if (not (eq response 'timeout)) {
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

; Current as a fraction of the ESC limit, -1..1, 0 while the limits are
; unknown. Negative means braking or regen, measured against the min limit.
; Refloat's tot-current is already braking-negative in either direction.
(defun phase-utilization () {
    (var braking (< tot-current 0))
    (var lim (if braking esc-motor-current-min esc-motor-current-max))
    (var u (if (> lim 0) (min 1.0 (/ (abs tot-current) lim)) 0.0))
    (if braking (- u) u)
})

(defun battery-utilization () {
    (var regen (< bat-current 0))
    (var lim (if regen esc-bat-current-min esc-bat-current-max))
    (var u (if (> lim 0) (min 1.0 (/ (abs bat-current) lim)) 0.0))
    (if regen (- u) u)
})

(defun get-voltage-curve (cell-type)
    (cond
        ((= cell-type 0) { ; Linear
            (list 4.20 4.05 3.90 3.75 3.60 3.45 3.30 3.15 3.00 2.85 2.7)
        })
        ((= cell-type 1) { ; P28A
            (list 4.14 4.09 3.98 3.88 3.77 3.69 3.63 3.55 3.45 3.24 2.9)
        })
        ((= cell-type 2) { ; P30B
           (list 4.14 4.09 3.98 3.88 3.77 3.69 3.63 3.55 3.45 3.24 2.9)
        })
        ((= cell-type 3) { ; P42A
            (list 4.14 4.05 3.91 3.83 3.74 3.65 3.57 3.48 3.38 3 2.8)
        })
        ((= cell-type 4) { ; P45B
            (list 4.14 4.08 4.00 3.91 3.82 3.73 3.64 3.56 3.45 3.23 2.9)
        })
        ((= cell-type 5) { ; P50B
            (list 4.15 4.047 3.96 3.88 3.79 3.70 3.595 3.466 3.29 3.03 2.85)
        })
        ((= cell-type 6) { ; DG40
            (list 4.15 4.02 3.91 3.83 3.75 3.61 3.49 3.35 3.17 2.81 2.7)
        })
        ((= cell-type 7) { ; 50S
            (list 4.15 4.04 3.90 3.82 3.74 3.64 3.52 3.38 3.16 3.0 2.9)
        })
        ((= cell-type 8) { ; VTC6
            (list 4.14 4.00 3.9 3.8 3.7 3.6 3.5 3.4 3.3 3.1 2.8)
        })
        (true { ; Any other value we return Linear
            (list 4.20 4.05 3.90 3.75 3.60 3.45 3.30 3.15 3.00 2.85 2.7)
        })
    )
)

; --- CAN discovery --------------------------------------------------------
;
; Staged cheapest-first, because can-ping blocks: it waits on a semaphore for up
; to 10 ms inside a lisp extension, and extensions run on the evaluator, so it
; stalls every lisp thread - not just this one. Sweeping 0..254 that way held the
; LED loop at 2-10 Hz for the first minute after boot, and an interleaved sleep
; does not help because the 10 ms is not ours to yield.
;
; So: stored id -> nodes already heard -> narrow ping scan -> full scan. Normally
; only the first two run and nothing blocks.

; Nodes that have sent a CAN status message. comm_can keeps that table
; anyway, so reading it costs nothing and blocks nobody. Trapped because it
; is the one extension here that a much older firmware might not have.
(defun can-devices-heard () {
    (var r (trap (can-list-devs)))
    (if (eq (ix r 0) 'exit-ok) (ix r 1) '())
})

; Blocking ping sweep - see the note above. Yields 20 ms between probes
; (rather than the old 5 ms) so the LED loop keeps a usable share while this
; runs; it only runs when passive discovery has already failed, so the extra
; wall-clock costs nothing in the common case.
(defun can-scan-range (from to) {
    (var found '())
    (looprange probe-id from to {
        (if (can-ping probe-id) {
            (print (str-merge "Found CAN device at ID: " (str-from-n probe-id)))
            (setq found (append found (list probe-id)))
        })
        (sleep 0.02)
    })
    found
})

; Ask each candidate whether it runs the Float/Refloat package. The answer
; arrives asynchronously on the event thread (float-pkg-telemetry-rx), which
; is what sets can-id in the config - so all we do here is send and wait.
(defunret try-can-devices (ids) {
    (loopforeach id ids {
        (setq discover-can-id id)
        (dbg DBG-CAN (str-merge "can probe " (str-from-n id "%d")))
        (float-cmd id (list (assoc float-cmds 'COMMAND_GET_ALLDATA) 3))
        (yield 500000)
        (if (>= (get-config 'can-id) 0) (return t))
    })
    (return nil)
})

; Shared tail of a successful discovery.
; float-pkg-telemetry-rx already prints "Float package found on CAN id N"
; when it acquires, so this stays quiet.
(defun finish-can-init (original-can-id) {
    (var found (get-config 'can-id))
    (if (not-eq found original-can-id) (ext-facfg-store))
    (fetch-series-cells)
    (float-cmd found (list (assoc float-cmds 'COMMAND_HUMIDITY)))
    (apply-battery-config (get-config 'soc-type) (get-config 'cell-type))
    1
})

(defunret init-can () {
    (var original-can-id (get-config 'can-id ))
    (set-config 'can-id -1)
    (var init-time (systime))

    ; Stage 1: the id that answered last time. One frame, no scanning.
    (if (>= original-can-id 0) {
        (dbg DBG-CAN (str-merge "can try stored id " (str-from-n original-can-id "%d")))
        (if (try-can-devices (list original-can-id))
            (return (finish-can-init original-can-id)))
    })

    ; Stage 2: passive. Free, and it covers the normal case. Polled for a few
    ; seconds because the ESC's first status message may not have arrived yet
    ; (it also catches an ESC that powers up slightly after this module).
    (loopwhile (< (secs-since init-time) 5) {
        (var heard (can-devices-heard))
        (if heard {
            (dbg DBG-CAN (str-merge "can heard " (to-str heard)))
            (if (try-can-devices heard)
                (return (finish-can-init original-can-id)))
        })
        (sleep 0.25)
    })

    ; Stage 3: active scan - the last resort, because it stalls every lisp
    ; thread (see can-scan-range).
    (dbg-warn "can nothing heard, ping scanning")

    ; Low ids first: a controller id is nearly always small, and every
    ; probe costs ~10ms of frozen evaluator.
    (var scanned (can-scan-range 0 32))
    (if (try-can-devices scanned)
        (return (finish-can-init original-can-id)))
    (setq scanned (can-scan-range 32 254))
    (if (try-can-devices scanned)
        (return (finish-can-init original-can-id)))

    (return 0)
})

(defun float-cmd (can-id cmd) {
    (send-data (append (list FLOAT_MAGIC) cmd) 2 can-id)
})

(defun float-accessories-command-rx (data) {
    (if (dbg-active DBG-CMD)
        (dbg DBG-CMD (str-merge "cmd " (to-str (cossa float-accessories-cmds (bufget-u8 data 1))))))
    (match (cossa float-accessories-cmds (bufget-u8 data 1))
        ;(COMMAND_GET_INFO {
        ;})
        (COMMAND_RUN_LISP {
            (var payload-len (- (buflen data) 2))
            (var payload (bufcreate payload-len))
            (bufcpy payload 0 data 2 payload-len)
            ; Trapped and logged: a typo in a QML-sent expression used to
            ; kill the event thread, costing a >=1s control blackout with
            ; nothing in the console to say why.
            (if (dbg-active DBG-CMD) (dbg DBG-CMD (str-merge "cmd " (to-str payload))))
            (var res (trap (eval (read payload))))
            (if (eq (ix res 0) 'exit-error)
                (dbg-err (str-merge "cmd " (to-str (ix res 1)) " in " (to-str payload))))
            (free payload)
        })
        (COMMAND_BMS_STATUS {
            (var send-buffer (bufcreate 3))
            (bufset-u8 send-buffer 0 FLOAT_ACCESSORIES_MAGIC)
            (bufset-u8 send-buffer 1 (assoc float-accessories-cmds 'COMMAND_BMS_STATUS))
            (bufset-u8 send-buffer 2 bms-status)
            (send-data send-buffer 2 can-id)
            (free send-buffer)
        })
        (_ (if (dbg-active DBG-CMD)
               (dbg DBG-CMD (str-merge "cmd ? " (str-from-n (bufget-u8 data 1) "%d"))))) ; Ignore other commands
    )
})

(defun float-pkg-telemetry-rx (data) {
    ; LCM replies must not make the motor telemetry appear fresh or participate
    ; in ESC discovery. They only update the brightness cache.
    (if (= (bufget-u8 data 1) (assoc float-cmds 'COMMAND_LCM_POLL)) {
        (refloat-brightness-rx data)
    } {
    (var time-since-last-can (- (systime) can-last-activity-time))
    (setq can-last-activity-time (systime))
    (match (cossa float-cmds (bufget-u8 data 1))
        (COMMAND_GET_ALLDATA {
            (if (or (< can-id 0) (> time-since-last-can 5000000)) {
                (print (str-merge "Float package found on CAN id " (str-from-n discover-can-id)))
                (set-config 'can-id discover-can-id)
                (setq can-id discover-can-id)
                (setq bms-can-id (get-bms-val 'bms-can-id))
                ; Only re-fetch if cells aren't already known and we haven't tried recently
                (if (and (< series-cells 1) (> (secs-since last-fetch-cells-time) 10)) {
                    (setq need-fetch-cells t)
                })
                (setq need-fetch-limits t)
            })
            (if  (> (buflen data) 3){
                (var mode (bufget-u8 data 2))

                (if (= mode 69) {
                    (setq fault-code (bufget-u8 data 3))
                }{
                    (setq fault-code 0)
                    ; A short frame means the ESC answered with a mode the
                    ; parser below cannot read - worth seeing, since the
                    ; symptom is telemetry that never updates.
                    (if (and (< (buflen data) 32) (dbg-tick DBG-CAN 'can-frame 5.0))
                        (dbg-warn (str-merge "can short telem frame "
                            (str-from-n (buflen data) "%d"))))
                    (if (>= (buflen data) 32) {
                        (setq roll-angle (/ (to-float (bufget-i16 data 7)) 10))
                        (var state-byte (bufget-u8 data 9))
                        (setq state (bitwise-and state-byte 0x0F))
                        (setq sat-t (shr state-byte 4))
                        (var switch-state-byte (bufget-u8 data 10))
                        (setq switch-state (bitwise-and switch-state-byte 0x07))
                        ;(var beep-reason-t (shr switch-state-byte 4))
                        (setq handtest-mode (= (bitwise-and switch-state-byte 0x08) 0x08))
                        (setq footpad-adc1-t (/ (to-float (bufget-u8 data 11)) 50))
                        (setq footpad-adc2-t (/ (to-float (bufget-u8 data 12)) 50))
                        (if (= switch-state 2) {
                            (setq switch-state 3)
                        })
                        (if (= switch-state 1) {
                            (if (> footpad-adc2-t footpad-adc1-t) {
                                (setq switch-state 2)
                            })
                        })
                        (setq pitch-angle (/ (to-float (bufget-i16 data 19)) 10))
                        (setq vin (/ (to-float (bufget-i16 data 22)) 10))
                        (if (= soc-type 1) { ; Use voltage curve
                            (setq battery-percent-remaining (/ (estimate-soc (/ vin series-cells) voltage-curve) 100))
                        })
                        (setq rpm (/ (to-float  (bufget-i16 data 24)) 10))
                        (setq speed (/ (to-float (bufget-i16 data 26)) 10))
                        (setq tot-current (/ (to-float (bufget-i16 data 28)) 10))
                        (setq bat-current (/ (to-float (bufget-i16 data 30)) 10))
                        (setq duty-cycle-now (/ (to-float (- (bufget-u8 data 32) 128)) 100))
                        (if (>= mode 2) {
                            (setq distance-abs (bufget-f32 data 34))
                            (setq fet-temp-filtered (/ (bufget-u8 data 38) 2.0))
                            (setq motor-temp-filtered (/ (bufget-u8 data 39) 2.0))
                        })
                        (if (>= mode 3) {
                            (setq odometer (bufget-u32 data 41))
                            
                            (if (= soc-type 0) { ; Ignore if using custom curves
                                (setq battery-percent-remaining (/ (to-float (bufget-u8 data 53)) 200))
                            })
                        })
                    })
                })
            })
        })
        (COMMAND_HUMIDITY {
            (setq refloat-humidity t)
        })
        (_ nil)
    )
    })
})
@const-end

