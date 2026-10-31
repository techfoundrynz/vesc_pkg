@const-start

; Optional Float/Refloat protocol adapter. Core modules never call these names.
(def REFLOAT_MAGIC 101)
(def refloat-cmds '(
    (COMMAND_GET_INFO . 0)
    (COMMAND_GET_ALLDATA . 10)
    (COMMAND_LCM_POLL . 24)
    (COMMAND_HUMIDITY . 51)
))

(def discover-can-id -1)
(def refloat-humidity nil)
(def refloat-last-rediscover 0)
(def refloat-generation -1)
(defun refloat-active ()
    (and (integration-is 1) (= refloat-generation integration-generation)))

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
(defun refloat-can-devices-heard () {
    (var r (trap (can-list-devs)))
    (if (eq (ix r 0) 'exit-ok) (ix r 1) '())
})

; Blocking ping sweep - see the note above. Yields 20 ms between probes
; (rather than the old 5 ms) so the LED loop keeps a usable share while this
; runs; it only runs when passive discovery has already failed, so the extra
; wall-clock costs nothing in the common case.
(defun refloat-can-scan-range (from to) {
    (var found '())
    (looprange probe-id from to {
        (if (not (refloat-active)) (break))
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
(defunret refloat-try-can-devices (ids) {
    (loopforeach id ids {
        (if (not (refloat-active)) (return nil))
        (setq discover-can-id id)
        (dbg DBG-CAN (str-merge "can probe " (str-from-n id "%d")))
        (refloat-send id (list (assoc refloat-cmds 'COMMAND_GET_ALLDATA) 3))
        (yield 500000)
        (if (not (refloat-active)) (return nil))
        (if (>= can-id 0) (return t))
    })
    (return nil)
})

; Shared tail of a successful discovery.
; float-pkg-telemetry-rx already prints "Float package found on CAN id N"
; when it acquires, so this stays quiet.
(defunret refloat-finish-can-init (original-can-id) {
    (if (not (refloat-active)) (return 0))
    (var found (get-config 'can-id))
    (if (not-eq found original-can-id) (ext-facfg-store))
    (setq need-fetch-cells t)
    (setq need-fetch-limits t)
    (refloat-send found (list (assoc refloat-cmds 'COMMAND_HUMIDITY)))
    1
})

(defunret refloat-init-can () {
    (var original-can-id (get-config 'can-id ))
    (setq can-id -1)
    (var init-time (systime))

    ; Stage 1: the id that answered last time. One frame, no scanning.
    (if (>= original-can-id 0) {
        (dbg DBG-CAN (str-merge "can try stored id " (str-from-n original-can-id "%d")))
        (if (refloat-try-can-devices (list original-can-id))
            (return (refloat-finish-can-init original-can-id)))
    })

    ; Stage 2: passive. Free, and it covers the normal case. Polled for a few
    ; seconds because the ESC's first status message may not have arrived yet
    ; (it also catches an ESC that powers up slightly after this module).
    (loopwhile (and (refloat-active) (< (secs-since init-time) 5)) {
        (var heard (refloat-can-devices-heard))
        (if heard {
            (dbg DBG-CAN (str-merge "can heard " (to-str heard)))
            (if (refloat-try-can-devices heard)
                (return (refloat-finish-can-init original-can-id)))
        })
        (sleep 0.25)
    })

    (if (not (refloat-active)) (return 0))

    ; Stage 3: active scan - the last resort, because it stalls every lisp
    ; thread (see refloat-can-scan-range).
    (dbg-warn "can nothing heard, ping scanning")

    ; Low ids first: a controller id is nearly always small, and every
    ; probe costs ~10ms of frozen evaluator.
    (var scanned (refloat-can-scan-range 0 32))
    (if (refloat-try-can-devices scanned)
        (return (refloat-finish-can-init original-can-id)))
    (setq scanned (refloat-can-scan-range 32 254))
    (if (refloat-try-can-devices scanned)
        (return (refloat-finish-can-init original-can-id)))

    (return 0)
})

(defun refloat-send (can-id cmd) {
    (if (and (refloat-active) (>= can-id 0))
        (send-data (append (list REFLOAT_MAGIC) cmd) 2 can-id))
})


; ---- External LCM brightness --------------------------------------------
(def refloat-lcm-last-poll 0)

(defun poll-refloat-brightness () {
    (if (refloat-active) {
        (if (>= (secs-since refloat-lcm-last-poll) 0.1) {
            (setq refloat-lcm-last-poll (systime))
            (refloat-send can-id (list (assoc refloat-cmds 'COMMAND_LCM_POLL)))
        })
    } {
        (lighting-release)
    })
})

(defun refloat-brightness-rx (data) {
    ; Disabled LCM returns only the header. A full reply has three percentages
    ; at 11..13; optional extension payload after those bytes is ignored.
    (if (and (refloat-active)
             (>= (buflen data) 14)
             (<= (bufget-u8 data 11) 100) (<= (bufget-u8 data 12) 100)
             (<= (bufget-u8 data 13) 100))
        (lighting-override 1 (/ (bufget-u8 data 11) 100.0)
            (/ (bufget-u8 data 12) 100.0) (/ (bufget-u8 data 13) 100.0))
        (lighting-release))
})

(defun refloat-acquire () {
    (if (< can-id 0) {
        (setq can-id discover-can-id)
        (set-config 'can-id can-id)
        (bms-note-can-source (get-bms-val 'bms-can-id))
        (setq need-fetch-cells t)
        (setq need-fetch-limits t)
        (print (str-merge "Float package found on CAN id " (str-from-n can-id)))
    })
})

(defun refloat-telemetry-rx (data) {
    (var mode (bufget-u8 data 2))
    ; Validate each wire format before reading any fields or marking it fresh.
    (if (= mode 69) {
        (if (>= (buflen data) 4) {
            (refloat-acquire)
            (vehicle-publish 1 (list 15 0 0 nil 0 0 -1 0 0 0 0 0 -1 0 0 -1
                0.0 0.0 0.0 (bufget-u8 data 3)))
        })
    } {
        (var required (cond ((= mode 3) 54) ((= mode 2) 40)
                            ((or (= mode 0) (= mode 1)) 33) (t 0)))
        (if (and (> required 0) (>= (buflen data) required)) {
            (var adc1 (/ (bufget-u8 data 11) 50.0))
            (var adc2 (/ (bufget-u8 data 12) 50.0))
            (var sw-byte (bufget-u8 data 10))
            (var sw (bitwise-and sw-byte 0x07))
            (if (= sw 2) (setq sw 3)
                (if (and (= sw 1) (> adc2 adc1)) (setq sw 2)))
            (var voltage (/ (bufget-i16 data 22) 10.0))
            (var soc battery-percent-remaining)
            (if (and (= soc-type 1) (> series-cells 0))
                (setq soc (/ (estimate-soc (/ voltage series-cells) voltage-curve) 100.0))
                (if (and (= soc-type 0) (= mode 3))
                    (setq soc (min 1.0 (/ (bufget-u8 data 53) 200.0)))))
            (refloat-acquire)
            (vehicle-publish 1 (list
                (bitwise-and (bufget-u8 data 9) 0x0F) (shr (bufget-u8 data 9) 4)
                sw (= (bitwise-and sw-byte 0x08) 0x08)
                (/ (bufget-i16 data 19) 10.0) (/ (bufget-i16 data 7) 10.0)
                voltage (/ (bufget-i16 data 24) 10.0) (/ (bufget-i16 data 26) 10.0)
                (/ (bufget-i16 data 28) 10.0) (/ (bufget-i16 data 30) 10.0)
                (/ (- (bufget-u8 data 32) 128) 100.0)
                (if (>= mode 2) (bufget-f32 data 34) -1)
                (if (>= mode 2) (/ (bufget-u8 data 38) 2.0) 0)
                (if (>= mode 2) (/ (bufget-u8 data 39) 2.0) 0)
                (if (= mode 3) (bufget-u32 data 41) -1) soc adc1 adc2 0))
        })
    })
})

(defun refloat-rx (data) {
    (if (and (refloat-active) (>= (buflen data) 2)
             (= (bufget-u8 data 0) REFLOAT_MAGIC)) {
        (match (cossa refloat-cmds (bufget-u8 data 1))
            (COMMAND_LCM_POLL (refloat-brightness-rx data))
            (COMMAND_GET_ALLDATA
                (if (and (>= (buflen data) 3) (>= discover-can-id 0))
                    (refloat-telemetry-rx data)))
            (COMMAND_HUMIDITY (setq refloat-humidity t))
            (_ nil))
        t
    } nil)
})

(defun refloat-start () {
    (setq refloat-generation integration-generation)
    (setq refloat-humidity nil)
    (setq discover-can-id -1)
    (setq refloat-last-rediscover (secs-since 0))
    (if (and (!= (refloat-init-can) 1) (refloat-active))
        (dbg-warn "can no ESC found"))
})

(defun refloat-tick () {
    (if (and (< can-id 0) (> (- (secs-since 0) refloat-last-rediscover) 5)) {
        (setq refloat-last-rediscover (secs-since 0))
        (var heard (refloat-can-devices-heard))
        (if (and heard (refloat-try-can-devices heard))
            (refloat-finish-can-init -1))
    })
    (if (>= can-id 0) {
        (refloat-send can-id (list (assoc refloat-cmds 'COMMAND_GET_ALLDATA) 3))
        (poll-refloat-brightness)
        (if (and refloat-humidity (= (get-config 'humidity-enabled) 1))
            (refloat-send can-id (list (assoc refloat-cmds 'COMMAND_HUMIDITY) (to-byte hum))))
    })
})

(defun refloat-control (jsy jsx bt-c bt-z is-rev) {
    (can-cmd can-id
        (str-replace (to-str (list jsy jsx bt-c bt-z is-rev)) "(" "(set-remote-state "))
})

(defun refloat-stop () {
    (lighting-release)
    (setq refloat-humidity nil)
    (setq discover-can-id -1)
})

(integration-register 1 refloat-start refloat-tick refloat-rx refloat-control refloat-stop)

@const-end
