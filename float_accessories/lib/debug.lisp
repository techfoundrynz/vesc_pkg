; Verbose diagnostics logger. dbg-mask is RAM only, never in the config: turning
; logging on is a debugging action, so it must not survive a power cycle, wear NVS
; or ship enabled. Resets to 0 on every boot.
;
; Every message is gated by a category bit, so one noisy subsystem can be watched
; without the others drowning it out:
;
;   (dbg DBG-LED "led: message")
;   (if (dbg-active DBG-LED) (dbg DBG-LED (str-merge ...)))   ; hot path
;   (if (dbg-tick DBG-CAN 'can-tel 2.0) (dbg DBG-CAN ...))    ; max 1 per 2 s
;
; str-merge is the expensive part (it allocates), which is why call sites in loops
; guard it rather than building a string to throw away. dbg-err / dbg-warn are
; never gated - a real failure always prints.
;
; A lisp print is synchronous and runs on the evaluator, so it costs the loop that
; emitted it and every other lisp thread with it. Turning DBG-LED on and watching
; the LED loop miss deadlines is partly watching the reporting. Judge loop timing
; with logging off; treat a rate measured with it on as a floor. Hence the lines
; below are throttled and edge-triggered rather than per-iteration.
;
; Message text is terse because every literal lives in the constant heap, which
; this package very nearly fills. See README.md for what the categories mean.
;
; Control it from the Diagnostics card, or the REPL: (dbg-on) (dbg-off)
; (dbg-add DBG-LED) (dbg-del DBG-LED) (dbg-set 12) (dbg-status) (diag).
;
; Naming: LispBM folds symbol case, so a function may not share a name with a
; DBG-* constant - (dbg-all) would BE the constant DBG-ALL.

; Throttle slots (key . last systime), created on first use. RAM, not const.
(def dbg-throttle nil)

@const-start

; ---- Categories ----------------------------------------------------------

(def DBG-CORE   1)    ; boot, threads, heartbeat, memory
(def DBG-CFG    2)    ; config reads/writes, apply-config, QML control
(def DBG-CAN    4)    ; CAN discovery, telemetry, settings sync
(def DBG-LED    8)    ; segment setup, mode/direction/highbeam decisions
(def DBG-BMS    16)   ; RS485 packets and decoded values
(def DBG-REM    32)   ; pubmote ESP-NOW / BLE link and pairing
(def DBG-GNSS   64)   ; GNSS init, fix state, position
(def DBG-HUM    128)  ; humidity sensor
(def DBG-SDLOG  256)  ; SD card logger
(def DBG-CMD    512)  ; inbound QML / CAN commands
(def DBG-ALL    1023)

; ---- State ---------------------------------------------------------------

; RAM only. 0 = silent (default on every boot).
(def dbg-mask 0)

; Per-loop iteration counters, reset by the heartbeat every second so they
; report a rate and can never overflow a fixnum. Only incremented while
; some category is enabled, so the cost with logging off is one integer
; compare per loop.
(def dbg-ticks-led 0)
(def dbg-ticks-can 0)
(def dbg-ticks-bms 0)
(def dbg-ticks-evt 0)

; Last-seen values for edge-triggered logging (only log on change, so a
; state machine sitting still doesn't produce a line per iteration).
(def dbg-prev-state -99)
(def dbg-prev-fault -99)
(def dbg-prev-switch -99)
(def dbg-prev-can-conn -1)
(def dbg-prev-bms-conn -1)
(def dbg-prev-led-mode -99)
(def dbg-prev-led-on -99)
(def dbg-prev-direction 0)
(def dbg-prev-hb -1)
(def dbg-prev-gnss-fix -1)

; LED loop phase timestamps, filled in by led-loop and read by its overrun
; report. Globals because the report sits outside the block that marks them.
(def dbg-led-t1 0.0)
(def dbg-led-t2 0.0)
(def dbg-led-t3 0.0)
; Missed LED deadlines since the last overrun report, so the throttled line
; says how often it is happening rather than just that it happened once.
(def dbg-led-overruns 0)

; ---- Core helpers --------------------------------------------------------

(defun dbg-active (cat) (!= (bitwise-and dbg-mask cat) 0))

; The (key . systime) pair itself, so dbg-due can write the timestamp back
; with setcdr instead of rebuilding the list.
(defunret dbg-cell (key) {
    (loopforeach c dbg-throttle
        (if (eq (car c) key) (return c)))
    (return nil)
})

; True at most once per `secs` for `key`; the first use is always due. The
; table is only touched once the category check has passed (see dbg-tick), so
; a disabled category costs nothing.
(defunret dbg-due (key secs) {
    (var cell (dbg-cell key))
    (if (not cell) {
        (setq dbg-throttle (cons (cons key (systime)) dbg-throttle))
        (return t)
    })
    (if (> (secs-since (cdr cell)) secs) {
        (setcdr cell (systime))
        (return t)
    })
    (return nil)
})

; Guard for log lines inside loops: category on AND the throttle is due.
; `and` short-circuits, so with the category off the throttle table is
; never read or written.
(defun dbg-tick (cat key secs) (and (dbg-active cat) (dbg-due key secs)))

(defun dbg (cat msg) (if (dbg-active cat) (print msg)))

; Always printed - a failure the user needs to see is not "verbose".
; One str-merge, not two print args: VESC print puts each argument on
; its own line, which split every warning across two lines.
(defun dbg-err (msg) (print (str-merge "ERR " msg)))
(defun dbg-warn (msg) (print (str-merge "WARN " msg)))

; Print one line from labels and values: integers as %d, floats as %g (keeps
; the precision that matters, e.g. fw 6.05), strings as they are.
(defun dbg-line (items) {
    (var parts nil)
    (loopforeach item items
        (setq parts (cons (if (number? item)
            (str-from-n item (if (eq (type-of item) 'type-float) "%g" "%d"))
            item) parts)))
    (print (str-join (reverse parts) " "))
})

; ---- Control -------------------------------------------------------------

(defun dbg-status () (print (str-merge "dbg mask " (str-from-n dbg-mask "%d"))))

; Push the current mask to the QML page (which has no other way to know it,
; since the flag is not part of the config it reads on connect).
(defun send-debug () (send-data (str-merge "debug " (str-from-n dbg-mask "%d"))))

(defun dbg-set (m) {
    (setq dbg-mask (bitwise-and (to-i m) DBG-ALL))
    (dbg-status)
    (send-debug)
})

(defun dbg-add (cat) (dbg-set (bitwise-or dbg-mask cat)))
; bitwise-or first so the bit is definitely set, then subtract it - clears
; the bit whether or not it was already on, without needing bitwise-not.
(defun dbg-del (cat) (dbg-set (- (bitwise-or dbg-mask cat) cat)))
; dbg-on / dbg-off, NOT dbg-all / dbg-none: LispBM folds symbol case, so a
; function named dbg-all is the same binding as the constant DBG-ALL and
; would silently overwrite it with a closure.
(defun dbg-on () (dbg-set DBG-ALL))
(defun dbg-off () (dbg-set 0))

; ---- Heartbeat -----------------------------------------------------------

; No memory reporting: VESC Express exposes no heap introspection at all.
; mem-num-free / mem-longest-free / mem-size / lbm-heap-state all live in
; lbm_runtime_extensions_init(), which the Express firmware never calls (see
; lispBM/src/extensions/runtime_extensions.c - they are gated on
; FULL_RTS_LIB and only wired up in the desktop REPL). Calling them here
; produced a trapped variable_not_bound every 10 s.

; Per-second loop-rate heartbeat. This is the cheapest way to see that a
; thread has died or stalled: a loop that stops ticking shows 0 here long
; before its symptom (frozen LEDs, stale telemetry) is obvious.
(defun dbg-loop () {
    (loop () t {
        (sleep 1.0)
        (if (dbg-active DBG-CORE)
            (dbg-line (list "hz led" dbg-ticks-led "can" dbg-ticks-can "bms" dbg-ticks-bms
                "rem" pubmote-loop-ticks "evt" dbg-ticks-evt)))
        ; Reset unconditionally so the counters stay bounded even if the
        ; category is toggled off mid-second.
        (setq dbg-ticks-led 0)
        (setq dbg-ticks-can 0)
        (setq dbg-ticks-bms 0)
        (setq pubmote-loop-ticks 0)
        (setq dbg-ticks-evt 0)
    })
})

; ---- One-shot report -----------------------------------------------------

; Everything worth knowing when someone reports "it doesn't work", printed
; whether or not verbose logging is on. Each block is trapped so a missing
; extension or an unbound var can't truncate the rest of the report.
(defun diag () {
    (print "--- fa diag ---")
    (trap (dbg-line (list "ver" (to-str (get-version)) "esp_led" (to-str esp_led-version)
        "fw" fw-num (sysinfo 'hw-target) "cpu" (sysinfo 'cpu-freq) "up" (secs-since 0))))
    (trap (dbg-line (list "canid" (get-config 'can-id) "self" (can-local-id)
        "provider" integration-id "canage" (secs-since can-last-activity-time))))
    (trap (dbg-line (list "cid led" led-context-id "can" can-context-id "bms" bms-context-id
        "rem" pubmote-context-id "gnss" gnss-context-id "hum" humidity-context-id
        "log" log-context-id)))
    (trap (dbg-line (list "state" state "fault" fault-code "sw" switch-state
        "vin" (to-float vin) "soc" (* 100.0 battery-percent-remaining) "cells" series-cells
        "rpm" (to-float rpm) "duty" (to-float duty-cycle-now))))
    (trap (dbg-line (list "seg st" seg-status "fr" seg-front "re" seg-rear "fp" seg-footpad
        "bt" seg-button "on" (to-i led-on) "hb" (to-i led-highbeam-on) "mode" led-mode
        "dir" direction)))
    (trap (dbg-line (list "bms age" (secs-since bms-last-activity-time)
        "backend" bms-active-backend "status" bms-status "v" (get-bms-val 'bms-v-tot))))
    (trap (dbg-line (list "rem conn" (is-pubmote-connected) "pair" pubmote-pairing-state
        "ble" (if pubmote-ble-paired 1 0)
        "ch" (if (> (conf-get 'wifi-mode) 0) (wifi-get-chan) -1))))
    (trap (dbg-line (list "gnss age" (gnss-age) "hdop" (gnss-hdop) (to-str (gnss-lat-lon))
        "hum" (to-float hum) "sdlog" (if log-running 1 0))))
    (dbg-status)
})

@const-end
