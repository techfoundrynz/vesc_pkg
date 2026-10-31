@const-start

; SSBMS / XJBMS core shared by the UART (ssbms-uart.lisp) and BLE
; (ssbms-ble.lisp) transports, which use the same frames under their own backend
; IDs. This file registers no backend.
; Protocol source: Indy Speed Control 3.8 reverse-engineering spec, 2026-10-31.
; Native helpers own bounded CRC/frame scanning; no protection-register writes.
(def SSBMS-POLL-SECONDS 0.5)
(def SSBMS-STALE-SECONDS 3.0)
(def ssbms-rx nil)
(def ssbms-tx nil)
(def ssbms-cells nil)
(def ssbms-status nil)
(def ssbms-cell-count 0)
(def ssbms-last-snapshot 0)
; Backend ID publishing through this core, set by the transport's loop.
(def ssbms-source BMS-BACKEND-SSBMS-UART)
; Transport read: (reg count destination) -> t once a valid reply is copied.
(def ssbms-transport-read nil)

(defun ssbms-active ()
    (bms-backend-active ssbms-source))

(defun ssbms-alloc () {
    (setq ssbms-rx (bufcreate 256))
    (setq ssbms-tx (bufcreate 8))
    (setq ssbms-cells (bufcreate 71))
    (setq ssbms-status (bufcreate 39))
})

; Core state only; transports close their own link first.
(defun ssbms-cleanup () {
    (setq ssbms-transport-read nil)
    (if ssbms-rx (free ssbms-rx))
    (if ssbms-tx (free ssbms-tx))
    (if ssbms-cells (free ssbms-cells))
    (if ssbms-status (free ssbms-status))
    (setq ssbms-rx nil)
    (setq ssbms-tx nil)
    (setq ssbms-cells nil)
    (setq ssbms-status nil)
    (setq ssbms-cell-count 0)
})

(defun ssbms-read (reg count destination)
    (and ssbms-transport-read (ssbms-transport-read reg count destination)))

(defun ssbms-reg (frame index) (bufget-u16 frame (+ 5 (* 2 index))))
(defun ssbms-temperature (index) (- (* (ssbms-reg ssbms-status index) 0.1) 273.15))

; Publish only complete cell+status cycles, never discovery or half a snapshot.
(defunret ssbms-publish () {
    (if (not (ssbms-active)) (return nil))
    (var total 0.0)
    (var lowest 100.0)
    (var highest 0.0)
    (looprange i 0 ssbms-cell-count {
        (var voltage (/ (ssbms-reg ssbms-cells i) 1000.0))
        ; Reject impossible telemetry before any shared value is changed.
        (if (> voltage 5.0) (return nil))
        (setq total (+ total voltage))
        (setq lowest (min lowest voltage))
        (setq highest (max highest voltage))
    })
    (var mosfet (ssbms-temperature 0))
    (var t1 (ssbms-temperature 1))
    (var t2 (ssbms-temperature 2))
    (if (or (< (min mosfet (min t1 t2)) -100.0) (> (max mosfet (max t1 t2)) 200.0)) (return nil))
    (var flags (+ (shl (ssbms-reg ssbms-status 12) 16) (ssbms-reg ssbms-status 13)))
    (var charging (!= (bitwise-and flags 0x80000) 0))
    (var allowed (= (bitwise-and flags 0xA91) 0))
    ; Register 7 is charging current, not a discharge-current measurement.
    ; VESC convention is negative charging. Ignore its value when not charging.
    (var current (if charging (- (/ (abs (bufget-i16 ssbms-status 19)) 1000.0)) 0.0))
    (bms-publish-value ssbms-source 'bms-cell-num ssbms-cell-count)
    (looprange i 0 ssbms-cell-count {
        (bms-publish-indexed ssbms-source 'bms-v-cell i (/ (ssbms-reg ssbms-cells i) 1000.0))
        ; A global balancing flag cannot identify individual balancing cells.
        (bms-publish-indexed ssbms-source 'bms-bal-state i 0)
    })
    (bms-publish-value ssbms-source 'bms-v-tot total)
    (bms-publish-value ssbms-source 'bms-v-cell-min lowest)
    (bms-publish-value ssbms-source 'bms-v-cell-max highest)
    ; The BMS has no SoC register. Estimate from the lowest cell and the local
    ; Cell Type curve, independent of the vehicle integration's SOC Estimator.
    (bms-publish-value ssbms-source 'bms-soc (/ (estimate-soc lowest voltage-curve) 100.0))
    (bms-publish-value ssbms-source 'bms-v-charge (if charging total 0.0))
    (bms-publish-value ssbms-source 'bms-i-in current)
    (bms-publish-value ssbms-source 'bms-i-in-ic current)
    (bms-publish-value ssbms-source 'bms-temp-adc-num 2)
    (bms-publish-indexed ssbms-source 'bms-temps-adc 0 t1)
    (bms-publish-indexed ssbms-source 'bms-temps-adc 1 t2)
    (bms-publish-value ssbms-source 'bms-temp-ic mosfet)
    (bms-publish-value ssbms-source 'bms-temp-cell-max (max t1 t2))
    (bms-publish-value ssbms-source 'bms-chg-allowed (if allowed 1 0))
    (bms-publish-status ssbms-source
        (if (!= (bitwise-and flags 0xA00) 0) 1 0)
        (!= (bitwise-and flags 0x80) 0) (!= (bitwise-and flags 1) 0) nil charging)
    (bms-publish-info ssbms-source 'charge-state (if allowed 1 0))
    (setq ssbms-last-snapshot (systime))
    (bms-mark-received ssbms-source)
    (bms-broadcast ssbms-source charging (!= (bitwise-and flags 0x800000) 0) allowed)
    (return t)
})

(defun ssbms-poll () {
    (if (= ssbms-cell-count 0)
        (if (ssbms-read 0x0200 1 ssbms-status) {
            (var count (bitwise-and (ssbms-reg ssbms-status 0) 255))
            (if (and (>= count 12) (<= count 32)) (setq ssbms-cell-count count))
        }))
    (if (> ssbms-cell-count 0)
        (if (and (ssbms-read 0x0020 ssbms-cell-count ssbms-cells)
                 (ssbms-read 0x0000 16 ssbms-status))
            (ssbms-publish)))
    (if (> (secs-since ssbms-last-snapshot) SSBMS-STALE-SECONDS) {
        (bms-reset-status)
        (setq ssbms-cell-count 0)
    })
})

; Shared session start once a transport is open: fresh snapshot timer and no
; leftover counters/metadata from a previously selected BMS.
(defun ssbms-begin () {
    (bms-set-freshness ssbms-source SSBMS-STALE-SECONDS)
    (setq ssbms-cell-count 0)
    (setq ssbms-last-snapshot (systime))
    (bms-publish-value ssbms-source 'bms-can-id (can-local-id))
    (loopforeach field '(bms-ah-cnt bms-wh-cnt bms-ah-cnt-chg-total
        bms-wh-cnt-chg-total bms-ah-cnt-dis-total bms-wh-cnt-dis-total
        bms-temp-hum bms-hum bms-pres bms-soh bms-data-version)
        (bms-publish-value ssbms-source field 0))
})

; One poll cycle, padded to SSBMS-POLL-SECONDS while staying cancellable.
(defun ssbms-cycle () {
    (var cycle-start (systime))
    (ssbms-poll)
    (loopwhile (and (ssbms-active) (< (secs-since cycle-start) SSBMS-POLL-SECONDS))
        (sleep 0.02))
})

@const-end
