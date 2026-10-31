; Test mode. Fakes the telemetry globals float-pkg-telemetry-rx writes, so the
; LED state machine cannot tell the difference.
;
; The twelve sim-in-* globals below are the whole state - nothing composes with them
; or overrides them. Presets live in the QML panel and act by filling the
; controls, so what reaches the board is only ever a set of values.
;
; REPL: (sim-on) / (sim-off) / (sim-status), then setq any sim-in-* value, or
; (sim-load 1 3 2 1500.0 0.35 0.30 0.20 0.55 0.0 nil nil t) for all twelve. Re-applied every
; tick, so a setq holds until something changes it.

@const-start

; sim-active is declared in can.lisp, beside the stand-down that reads it.
(def sim-tid nil)
; 0 is a valid can-id, which is the point: led.lisp reads can-id < 0 as "no ESC".
(def sim-can-id 0)

; state: 0 startup, 1 running, 2 tiltback, 3 wheelslip, 4 darkride, 5 flywheel,
;        6-13 faults, 15 disabled. running-state is 1..5.
; switch: footpad 0 none, 1 left, 2 right, 3 both.
; sat: above 2 strobes the status bar (tiltback actually pulling back).
; rpm: signed, sets direction; duty bar appears above 250.
; pitch: above 70 while not running is mall grab.
; phase / bat: -1..1 utilization, negative = braking / regen. The currents are
;   derived from these against the fake limits below.
; link: nil = no can-id and a stale link, i.e. "connecting".
(def sim-in-state 0)
(def sim-in-switch 0)
(def sim-in-sat 2)
(def sim-in-rpm 0.0)
(def sim-in-duty 0.0)
(def sim-in-phase 0.0)
(def sim-in-bat 0.0)
(def sim-in-batt 0.55)
(def sim-in-pitch 0.0)
(def sim-in-charging nil)
(def sim-in-handtest nil)
(def sim-in-link t)

; Stand-in ESC current limits (amps), unequal so braking/regen visibly use the
; min ones. Cleared on exit; a real ESC's are fetched again on rediscovery.
(def SIM-MOTOR-MAX 100.0)
(def SIM-MOTOR-MIN 80.0)
(def SIM-BAT-MAX 50.0)
(def SIM-BAT-MIN 20.0)

; One packet per preset. Twelve separate setqs would walk the board through
; eleven states nobody chose.
(defun sim-load (st sw sat r duty phase bat batt pitch chg hand link) {
    (setq sim-in-state st)
    (setq sim-in-switch sw)
    (setq sim-in-sat sat)
    (setq sim-in-rpm r)
    (setq sim-in-duty duty)
    (setq sim-in-phase phase)
    (setq sim-in-bat bat)
    (setq sim-in-batt batt)
    (setq sim-in-pitch pitch)
    (setq sim-in-charging chg)
    (setq sim-in-handtest hand)
    (setq sim-in-link link)
})

; Atomic because the LED loop is another context on the same evaluator and must
; not see a half-applied tick: led-draw-status stamps footpad-ok-time on
; switch-state 3, so one mis-sampled tick reset the at-speed debounce and flashed
; the duty bar for 250 ms. No loop macros in here - they expand to call-cc.
(defun sim-apply () {
    (atomic
    (setq state           sim-in-state)
    (setq switch-state    sim-in-switch)
    (setq sat-t           sim-in-sat)
    (setq rpm             sim-in-rpm)
    (setq duty-cycle-now  sim-in-duty)
    (setq battery-percent-remaining sim-in-batt)
    (setq pitch-angle     sim-in-pitch)
    (setq bms-is-charging sim-in-charging)
    (setq handtest-mode   sim-in-handtest)

    ; Derived, not settable: keeps the telemetry page and pubmote feed consistent,
    ; and stops the panel describing an impossible board. Unread by led.lisp.
    (setq speed (/ sim-in-rpm 100.0))
    (setq vin (+ 40.0 (* 20.0 sim-in-batt)))
    (setq roll-angle 0.0)
    (setq esc-motor-current-max SIM-MOTOR-MAX)
    (setq esc-motor-current-min SIM-MOTOR-MIN)
    (setq esc-bat-current-max SIM-BAT-MAX)
    (setq esc-bat-current-min SIM-BAT-MIN)
    (setq tot-current (* sim-in-phase (if (< sim-in-phase 0) SIM-MOTOR-MIN SIM-MOTOR-MAX)))
    (setq bat-current (* sim-in-bat (if (< sim-in-bat 0) SIM-BAT-MIN SIM-BAT-MAX)))
    (setq fet-temp-filtered (+ 30.0 (* 25.0 sim-in-duty)))
    (setq motor-temp-filtered (+ 28.0 (* 30.0 sim-in-duty)))
    ; Not simulated: no LED branch reads it, and state covers the fault displays.
    (setq fault-code 0)

    (if sim-in-link {
        (setq integration-ever-connected t)
        (setq can-id sim-can-id)
        (setq can-last-activity-time (systime))
    }{
        ; Left stale on purpose - that is what produces "connecting".
        (setq can-id -1)
    })
    )
})

(defun sim-loop () {
    ; 20 Hz, matching the CAN poll it stands in for, and well inside the 1 s
    ; staleness threshold led.lisp measures.
    (loopwhile sim-active {
        (sim-apply)
        (sleep 0.05)
    })
    (sim-restore)
    (setq sim-tid nil)
})

(defun sim-on () {
    (if sim-active
        (print "sim already on")
        {
            (setq sim-active t)
            (setq sim-tid (spawn sim-loop))
            (print "sim on")
            (print "(sim-status) state, (sim-off) stop, (setq sim-in-rpm 1500.0) etc")
        })
})

; Clearing the flag rather than killing the thread: the loop exits next tick and
; does the restore itself, which keeps that ordering deterministic.
(defun sim-off () {
    (if sim-active {
        (setq sim-active nil)
        (print "sim off")
    }
        (print "sim already off"))
})

; Back to can.lisp's declared defaults, so leaving test mode looks like a board
; that has not heard from an ESC rather than one frozen mid-preset. All of them,
; not just the risky ones - though two are worse than stale, because with no ESC
; or BMS nothing else ever writes them: bms-is-charging (kept the charging gauge
; up, and counts as activity, so the idle timeout and shutoff never fired again)
; and pitch-angle (kept mall grab latched, same side effect).
(defun sim-restore () {
    (setq integration-ever-connected nil)
    (setq vehicle-valid nil)
    (setq state 0)
    (setq switch-state 0)
    (setq sat-t 0)
    (setq rpm 0)
    (setq duty-cycle-now 0)
    (setq battery-percent-remaining 0.0)
    (setq pitch-angle 0)
    (setq roll-angle 0)
    (setq bms-is-charging nil)
    (setq fault-code 0)
    (setq handtest-mode nil)
    (setq speed 0)
    (setq vin -1)
    (setq tot-current 0)
    (setq bat-current 0)
    (setq esc-motor-current-max 0)
    (setq esc-motor-current-min 0)
    (setq esc-bat-current-max 0)
    (setq esc-bat-current-min 0)
    (setq fet-temp-filtered 0)
    (setq motor-temp-filtered 0)
    (setq can-id -1)
    ; Stale, not fresh: the link is genuinely down, and a leftover timestamp would
    ; have the LED loop treat zeroed telemetry as live for up to a second.
    (setq can-last-activity-time 0)
})

(defun sim-status () {
    (if sim-active
        (print (str-merge "sim on"
            " st " (str-from-n sim-in-state "%d")
            " sw " (str-from-n sim-in-switch "%d")
            " sat " (str-from-n sim-in-sat "%d")
            " rpm " (str-from-n (to-float sim-in-rpm) "%.0f")
            " duty " (str-from-n (to-float sim-in-duty) "%.2f")
            " phase " (str-from-n (to-float sim-in-phase) "%.2f")
            " bat " (str-from-n (to-float sim-in-bat) "%.2f")
            " batt " (str-from-n (to-float sim-in-batt) "%.2f")
            " pitch " (str-from-n (to-float sim-in-pitch) "%.0f")
            (if sim-in-charging " chg" "")
            (if sim-in-handtest " hand" "")
            (if sim-in-link " link" " nolink")))
        (print "sim off"))
})

@const-end
