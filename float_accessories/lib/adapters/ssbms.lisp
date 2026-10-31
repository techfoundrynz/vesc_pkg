@const-start

; SSBMS / XJBMS UART: 115200 8N1, same frames as the BLE UART bridge.
; Protocol source: Indy Speed Control 3.8 reverse-engineering spec, 2026-10-31.
; Native helpers own bounded CRC/frame scanning; no protection-register writes.
(def SSBMS-UART 1)
(def SSBMS-BAUD 115200)
(def SSBMS-POLL-SECONDS 0.5)
(def SSBMS-STALE-SECONDS 3.0)
(def ssbms-uart-open nil)
(def ssbms-rx nil)
(def ssbms-tx nil)
(def ssbms-cells nil)
(def ssbms-status nil)
(def ssbms-cell-count 0)
(def ssbms-last-snapshot 0)

(defun ssbms-active ()
    (bms-backend-active BMS-BACKEND-SSBMS))

(defun ssbms-cleanup () {
    (if ssbms-uart-open (uart-stop))
    (setq ssbms-uart-open nil)
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

(defunret ssbms-init () {
    (var rx (get-config 'ssbms-rx-pin))
    (var tx (get-config 'ssbms-tx-pin))
    (if (or (< rx 0) (< tx 0) (= rx tx)) {
        (dbg-warn "SSBMS: set distinct RX and TX pins")
        (return nil)
    })
    ; Firmware uart-read/write have one global UART owner. NMEA uses that same
    ; interface even on another port; u-blox on a different port is independent.
    (if (and (= (get-config 'gnss-enabled) 1)
             (or (= (get-config 'gnss-uart-num) SSBMS-UART)
                 (= (get-config 'gnss-type) 1))) {
        (dbg-warn "SSBMS: UART conflicts with GNSS configuration")
        (return nil)
    })
    (if (not (ssbms-active)) (return nil))
    (setq ssbms-rx (bufcreate 256))
    (setq ssbms-tx (bufcreate 8))
    (setq ssbms-cells (bufcreate 71))
    (setq ssbms-status (bufcreate 39))
    (setq ssbms-uart-open (uart-start SSBMS-UART rx tx SSBMS-BAUD))
    (if (not ssbms-uart-open) (dbg-warn "SSBMS: UART start failed"))
    (return ssbms-uart-open)
})

; One request in flight. Accumulate fragmented reads, skip noise/bad CRCs and
; unrelated or wrong-sized replies. A timeout discards the partial transaction.
; All UART reads are bounded and nonblocking so cancellation stays prompt.
(defunret ssbms-read (reg count destination) {
    (if (not (ssbms-active)) (return nil))
    ; Drain at most the firmware's 512-byte RX ring before issuing a new read.
    (looprange i 0 2 (uart-read ssbms-rx 256 0 nil 0))
    (ext-ssbms-request ssbms-tx reg count)
    (if (not (uart-write ssbms-tx)) (return nil))
    (var started (systime))
    (var used 0)
    (loopwhile (and (ssbms-active) (< (secs-since started) 0.3) (< used 256)) {
        (setq used (+ used (uart-read ssbms-rx (min 64 (- 256 used)) used nil 0)))
        (var offset (ext-ssbms-scan ssbms-rx used reg count))
        (if (and (>= offset 0) (ssbms-active)) {
            (bufcpy destination 0 ssbms-rx offset (+ 7 (* 2 count)))
            (return t)
        })
        (sleep 0.005)
    })
    (return nil)
})

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
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-cell-num ssbms-cell-count)
    (looprange i 0 ssbms-cell-count {
        (bms-publish-indexed BMS-BACKEND-SSBMS 'bms-v-cell i (/ (ssbms-reg ssbms-cells i) 1000.0))
        ; A global balancing flag cannot identify individual balancing cells.
        (bms-publish-indexed BMS-BACKEND-SSBMS 'bms-bal-state i 0)
    })
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-v-tot total)
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-v-cell-min lowest)
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-v-cell-max highest)
    ; The BMS has no SoC register. Estimate from the lowest cell and the local
    ; Cell Type curve, independent of the vehicle integration's SOC Estimator.
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-soc (/ (estimate-soc lowest voltage-curve) 100.0))
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-v-charge (if charging total 0.0))
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-i-in current)
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-i-in-ic current)
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-temp-adc-num 2)
    (bms-publish-indexed BMS-BACKEND-SSBMS 'bms-temps-adc 0 t1)
    (bms-publish-indexed BMS-BACKEND-SSBMS 'bms-temps-adc 1 t2)
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-temp-ic mosfet)
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-temp-cell-max (max t1 t2))
    (bms-publish-value BMS-BACKEND-SSBMS 'bms-chg-allowed (if allowed 1 0))
    (bms-publish-status BMS-BACKEND-SSBMS
        (if (!= (bitwise-and flags 0xA00) 0) 1 0)
        (!= (bitwise-and flags 0x80) 0) (!= (bitwise-and flags 1) 0) nil charging)
    (bms-publish-info BMS-BACKEND-SSBMS 'charge-state (if allowed 1 0))
    (setq ssbms-last-snapshot (systime))
    (bms-mark-received BMS-BACKEND-SSBMS)
    (bms-broadcast BMS-BACKEND-SSBMS charging (!= (bitwise-and flags 0x800000) 0) allowed)
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

(defun ssbms-loop () {
    (if (ssbms-init) {
        (bms-set-freshness BMS-BACKEND-SSBMS SSBMS-STALE-SECONDS)
        (setq ssbms-cell-count 0)
        (setq ssbms-last-snapshot (systime))
        (bms-publish-value BMS-BACKEND-SSBMS 'bms-can-id (can-local-id))
        ; Clear unavailable counters/metadata left by a previously selected BMS.
        (loopforeach field '(bms-ah-cnt bms-wh-cnt bms-ah-cnt-chg-total
            bms-wh-cnt-chg-total bms-ah-cnt-dis-total bms-wh-cnt-dis-total
            bms-temp-hum bms-hum bms-pres bms-soh bms-data-version)
            (bms-publish-value BMS-BACKEND-SSBMS field 0))
        (loopwhile (ssbms-active) {
            (var cycle-start (systime))
            (ssbms-poll)
            (loopwhile (and (ssbms-active) (< (secs-since cycle-start) SSBMS-POLL-SECONDS))
                (sleep 0.02))
        })
    })
})

(bms-register BMS-BACKEND-SSBMS ssbms-loop (fn () nil) ssbms-cleanup
    (fn (command value) nil) (fn () 0))

@const-end
