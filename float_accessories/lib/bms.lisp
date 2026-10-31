@const-start

; Public BMS service. Adapters publish normalized VESC BMS values after their
; own wire validation. Only the selected, running backend may publish/command.
(defun bms-connected ()
    (and (bms-backend-active bms-active-backend) bms-valid
         (< (secs-since bms-last-activity-time) bms-freshness-seconds)))

(defun bms-set-freshness (source seconds)
    (if (and (bms-backend-active source) (> seconds 0) (<= seconds 3.0))
        (setq bms-freshness-seconds seconds)))

(defun bms-reset-status () {
    (setq bms-valid nil)
    (setq bms-status -1)
    (setq bms-battery-type -1)
    (setq bms-battery-cycles -1)
    (setq bms-charge-state 0)
    (setq bms-last-activity-time 0)
    (setq bms-is-charging nil)
    (setq bms-charger-just-plugged nil)
})

(defun bms-mark-received (source)
    (if (bms-backend-active source) {
        (setq bms-last-activity-time (systime))
        (setq bms-valid t)
        t
    } nil))

; Scalar values use VESC units (V, A, degrees C, SoC fraction). Indexed values
; are per-cell voltages or temperatures. Publication alone does not mark fresh:
; the adapter acknowledges the fully processed packet with bms-mark-received.
(defun bms-publish-value (source field value)
    (if (bms-backend-active source) (set-bms-val field value)))
(defun bms-publish-indexed (source field index value)
    (if (bms-backend-active source) (set-bms-val field index value)))

(defun bms-publish-info (source field value) {
    (if (bms-backend-active source)
        (match field
            (battery-type (setq bms-battery-type value))
            (cycles (setq bms-battery-cycles value))
            (charge-state (setq bms-charge-state value))
            (_ nil)))
})

(defun bms-publish-status (source temperature empty overcharged calculating charging) {
    (if (bms-backend-active source)
        (setq bms-status (+ (bitwise-and temperature 3)
            (if empty 4 0) (if overcharged 8 0)
            (if charging 32 0) (if calculating 64 0))))
})

(defun bms-capabilities ()
    (if (bms-backend-active bms-active-backend) ((ix bms-active-hooks 4)) 0))

(defun bms-command (command value) {
    (var capability (match command
        (charge-control BMS-CAP-CHARGE)
        (factory-init BMS-CAP-FACTORY)
        (pairing BMS-CAP-PAIRING)
        (_ 0)))
    (if (and (> capability 0) (!= (bitwise-and (bms-capabilities) capability) 0))
        ((ix bms-active-hooks 3) command value)
        nil)
})

(defun bms-request-charge (state)
    (if (and (or (= state 0) (= state 1)) (!= state bms-charge-state))
        (bms-command 'charge-control state)
        nil))
(defun bms-request-factory-init () (bms-command 'factory-init nil))
(defun bms-pair (key-bytes counter-bytes)
    (bms-command 'pairing (list key-bytes counter-bytes)))

; Bridge an external CAN BMS without coupling its discovery to a protocol.
(defun bms-note-can-source (id)
    (setq bms-can-id (if (and (>= id 0) (= id (can-local-id))) -1 id)))
(defun bms-cell-count ()
    (if (> (get-bms-val 'bms-can-id) -1) (get-bms-val 'bms-cell-num) 0))
(defun bms-soc () (min 1.0 (max 0.0 (get-bms-val 'bms-soc))))

; Explicit CAN broadcasting lets adapters supply charging/balancing flags:
; firmware 7.00 exposes no Lisp setters for those two bms_values members.
; Only fresh complete snapshots are broadcast. No stale keepalive is generated.
(defun bms-can-send (buffer packet byte-count) {
    (var id (+ (shl packet 8) (can-local-id)))
    (if (= byte-count 8) (can-send-eid id buffer) {
        (var short-buffer (bufcreate byte-count))
        (bufcpy short-buffer 0 buffer 0 byte-count)
        (can-send-eid id short-buffer)
        (free short-buffer)
    })
})
(defun bms-can-pair (buffer packet value-a value-b) {
    (ext-bms-can-pair buffer value-a value-b)
    (bms-can-send buffer packet 8)
})
(defun bms-broadcast (source charging balancing allowed) {
    (if (and (bms-backend-active source) (bms-connected)) {
        (var buffer (bufcreate 8))
        (bms-can-pair buffer 38 (get-bms-val 'bms-v-tot) (get-bms-val 'bms-v-charge))
        (bms-can-pair buffer 39 (get-bms-val 'bms-i-in) (get-bms-val 'bms-i-in-ic))
        (bms-can-pair buffer 40 (get-bms-val 'bms-ah-cnt) (get-bms-val 'bms-wh-cnt))
        (var cells (get-bms-val 'bms-cell-num))
        (var index 0)
        (loopwhile (< index cells) {
            (bufset-u8 buffer 0 index)
            (bufset-u8 buffer 1 cells)
            (var n (min 3 (- cells index)))
            (looprange j 0 n
                (bufset-i16 buffer (+ 2 (* j 2)) (to-i (* 1000.0 (get-bms-val 'bms-v-cell (+ index j))))))
            (bms-can-send buffer 41 (+ 2 (* n 2)))
            (setq index (+ index n))
        })
        (bufclear buffer)
        (bufset-u8 buffer 0 cells)
        (looprange j 0 cells
            (if (!= (get-bms-val 'bms-bal-state j) 0) {
                (var byte-index (- 7 (to-i (/ j 8))))
                (bufset-u8 buffer byte-index
                    (bitwise-or (bufget-u8 buffer byte-index) (shl 1 (mod j 8))))
            }))
        (bms-can-send buffer 42 8)
        (var temperatures (get-bms-val 'bms-temp-adc-num))
        (setq index 0)
        (loopwhile (< index temperatures) {
            (bufset-u8 buffer 0 index)
            (bufset-u8 buffer 1 temperatures)
            (var n (min 3 (- temperatures index)))
            (looprange j 0 n
                (bufset-i16 buffer (+ 2 (* j 2)) (to-i (* 100.0 (get-bms-val 'bms-temps-adc (+ index j))))))
            (bms-can-send buffer 43 (+ 2 (* n 2)))
            (setq index (+ index n))
        })
        (bufclear buffer)
        (bufset-i16 buffer 4 (to-i (* 100.0 (get-bms-val 'bms-temp-ic))))
        (bms-can-send buffer 44 8)
        (bufset-i16 buffer 0 (to-i (* 1000.0 (get-bms-val 'bms-v-cell-min))))
        (bufset-i16 buffer 2 (to-i (* 1000.0 (get-bms-val 'bms-v-cell-max))))
        (bufset-u8 buffer 4 (to-i (* 255.0 (get-bms-val 'bms-soc))))
        (bufset-u8 buffer 5 (to-i (* 255.0 (get-bms-val 'bms-soh))))
        (bufset-i8 buffer 6 (to-i (min 127 (max -128 (get-bms-val 'bms-temp-cell-max)))))
        (bufset-u8 buffer 7 (+ (if charging 1 0) (if balancing 2 0) (if allowed 4 0)))
        (bms-can-send buffer 45 8)
        (bms-can-pair buffer 53 (get-bms-val 'bms-ah-cnt-chg-total) (get-bms-val 'bms-wh-cnt-chg-total))
        (bms-can-pair buffer 54 (get-bms-val 'bms-ah-cnt-dis-total) (get-bms-val 'bms-wh-cnt-dis-total))
        (free buffer)
    })
})

(defun bms-service-step () {
    ; Preserve the existing charging heuristic and five-second plug-in window,
    ; using normalized BMS values from the selected backend or external CAN BMS.
    (if (or (bms-connected) (and (= bms-active-backend BMS-BACKEND-NONE) (>= bms-can-id 0))) {
        (var previous bms-is-charging)
        (setq bms-is-charging
            (if (and (bms-connected) (>= bms-status 0))
                (!= (bitwise-and bms-status 32) 0)
                (and (> (get-bms-val 'bms-v-charge) 10.0)
                    (> (abs (get-bms-val 'bms-i-in-ic)) 0.1))))
        (if (and bms-is-charging (not previous)) {
            (dbg DBG-BMS "bms charger in")
            (setq bms-charger-just-plugged t)
            (setq bms-charger-plug-in-time (secs-since 0))
        })
        (if (and previous (not bms-is-charging)) (dbg DBG-BMS "bms charger out"))
    } {
        (setq bms-is-charging nil)
    })
    (if (not (and bms-charger-just-plugged
                  (<= (- (secs-since 0) bms-charger-plug-in-time) 5)))
        (setq bms-charger-just-plugged nil))
})

@const-end
