@const-start

(defun ow-crypt (nonce-high nonce-low data start-offset len) {
    (var restore-byte (bufget-u8 ow-counter 15))
    (bufset-u8 ow-counter 0 nonce-high)
    (bufset-u8 ow-counter 1 nonce-low)
    (aes-ctr-crypt ow-key ow-counter data start-offset len)
    (bufset-u8 ow-counter 15 restore-byte)
})

(defun ow-checksum (data start-offset end-offset)
    (ext-ow-checksum data start-offset end-offset))

(defunret ow-set-charge-state (nonce-high nonce-low charge-state) {
    (if (>= ow-charge-state 0){
        (var payload (bufcreate 2))
        (bufset-u8 payload 0 0x64)
        (bufset-u8 payload 1 (if (= charge-state 0x1) 0x00 0x01))
        (var packet (ow-construct-packet nonce-high nonce-low payload))
        (free payload)
        (gpio-write ow-rs485-dere-pin 1)
        (uart-write packet)
        (sleep 0.005)
        (gpio-write ow-rs485-dere-pin 0)
        (sleep 0.005)
        (var ret (ow-recv-packets 0x15 -1))
        (free packet)
        (return ret)
    }{
        (dbg-warn "bms no charge state yet")
        (return false)
    })
})

(defunret ow-factory-init-accept () {
    (var init-payload2 (bufcreate 2))
    (bufset-u8 init-payload2 0 0x03)
    (bufset-u8 init-payload2 1 0x01)
    (var init-packet2 (ow-construct-packet 0x00 0x01 init-payload2))
    (free init-payload2)
    (gpio-write ow-rs485-dere-pin 1)
    (uart-write init-packet2)
    (sleep 0.005)
    (gpio-write ow-rs485-dere-pin 0)
    (sleep 0.005)
    (var ret (ow-recv-packets 0x0e 1))
    (free init-packet2)
    (return ret)
})

(defunret ow-factory-init () {
    (var init-payload (bufcreate 4))
    (bufset-u8 init-payload 0 0x05)
    (bufset-u8 init-payload 1 0x52)
    (bufset-u8 init-payload 2 0x4d)
    (bufset-u8 init-payload 3 0x41);05RMA
    (var init-packet (ow-construct-packet 0x00 0x01 init-payload))
    (free init-payload)
    (gpio-write ow-rs485-dere-pin 1)
    (uart-write init-packet)
    (sleep 0.005)
    (gpio-write ow-rs485-dere-pin 0)
    (sleep 0.005)
    (var ret (ow-recv-packets 0x0e 0))
    (free init-packet)
    (return ret)
})
(defunret ow-process-packet (data) {
    (if (!=(bufget-u8 data 2) (bufget-u8 ow-magic 2)){
        (return false)
    })
    (var packet-checksum (bufget-u16 data (- (buflen data) 2)))
    (var calc-checksum (ow-checksum data 0 (- (buflen data) 2)))
    (if (!= packet-checksum calc-checksum){
        (return false)
    })
    (if ow-use-crypto {
        (return (ow-crypt (bufget-u8 data 3) (bufget-u8 data 4) data 5 (- (buflen data) 7)))
    })
    (return true)
})

(defunret ow-construct-packet (nonce-high nonce-low payload) {
    (var packet (bufcreate (+ (buflen payload) 7)))
    (bufcpy packet 0 ow-magic 0 (buflen ow-magic))
    (bufset-u8 packet 3 nonce-high)
    (bufset-u8 packet 4 nonce-low)
    (ow-crypt nonce-high nonce-low payload 0 (buflen payload))
    (bufcpy packet 5 payload 0 (buflen payload))
    (var calc-checksum  (ow-checksum packet 0 (- (buflen packet) 2)))
    (bufset-u8 packet (+ (buflen payload) 5) (shr calc-checksum 8))
    (bufset-u8 packet (+ (buflen payload) 6) (bitwise-and calc-checksum 0xFF))
    (return packet)
})

(defun ow-parse-voltage (data){
    ;(bms-publish-value BMS-BACKEND-OW 'bms-v-tot (/ (bufget-u8 data (if ow-use-crypto 6 4)) 100.0))
    ;(print data)
})

(defun ow-parse-cell-voltage (data){
    (var cell-index 0)
    (var total-voltage 0)
    (var v-cell-min (/ (bufget-u16 data (if ow-use-crypto 6 4)) (if ow-use-crypto 10000.0 1000.0)))
    (var v-cell-max v-cell-min)
    (if ow-cell-count-uninit {
        (bms-publish-value BMS-BACKEND-OW 'bms-cell-num (/ (- (buflen data) 8) 2))
        (setq ow-cell-count-uninit false)
    })

    (looprange k (if ow-use-crypto 6 4) (- (buflen data) (+ (if ow-use-crypto 0 2) 3)) { ;Need to leave off end 16th cell for 15s BMS
        (if (eq (mod k 2) 0) {
            (var current-cell (/ (bufget-u16 data k) (if ow-use-crypto 10000.0 1000.0)))
            (if (and (= cell-index 0) (= ow-override-soc 1)) {
                (bms-publish-value BMS-BACKEND-OW 'bms-soc (/ (estimate-soc current-cell voltage-curve) 100))
            })
            (bms-publish-indexed BMS-BACKEND-OW 'bms-v-cell cell-index current-cell)
            (setq cell-index (+ cell-index 1))
            (setq total-voltage (+ total-voltage current-cell))
            (if (> current-cell v-cell-max) (setq v-cell-max current-cell))
            (if (< current-cell v-cell-min) (setq v-cell-min current-cell))
        })
    })
    (bms-publish-value BMS-BACKEND-OW 'bms-v-tot total-voltage)
    (if (>= fw-num 6.06){
        (bms-publish-value BMS-BACKEND-OW 'bms-v-cell-min v-cell-min)
        (bms-publish-value BMS-BACKEND-OW 'bms-v-cell-max v-cell-max)
    })
    (if (dbg-tick DBG-BMS 'bms-val 5.0)
        (dbg DBG-BMS (str-merge "bms v " (str-from-n (to-float total-voltage) "%.2f")
            " n " (str-from-n cell-index "%d")
            " min " (str-from-n v-cell-min "%.3f")
            " max " (str-from-n v-cell-max "%.3f")
            " soc " (str-from-n (* 100 (get-bms-val 'bms-soc)) "%.0f")
            " A " (str-from-n (get-bms-val 'bms-i-in-ic) "%.2f"))))
})

(defun ow-parse-soc (data){
    (if (= ow-override-soc 0) {
        (var soc (/ (bufget-u8 data (if ow-use-crypto 6 4)) 100.0))
        (if (> soc 1.0) (setq soc 1.0))
        (if (< soc 0.01) (setq soc 0.01))
        (bms-publish-value BMS-BACKEND-OW 'bms-soc soc)
    })
})

(defun ow-parse-current (data) {
    (var current-scaler (if ow-use-crypto 0.0366 0.055)); Current scaler. 0.0366 or 0.0378 not sure...
    ;maybe look at tot-current from controller and then calculate scaler and take average to see which is closer?
    (var current-limit (if ow-use-crypto 32.0 30.0)) ;Limit 32A or 32.7A, not sure.
    (var current (* (bufget-i16 data (if ow-use-crypto 6 4)) current-scaler))

    (if (and (not ow-charge-only) (>= current current-limit)) {
        (if (= ow-is-current-over-limit 0)
            (dbg-warn (str-merge "bms current at limit " (str-from-n current "%.2f"))))
        (setq ow-is-current-over-limit 1)
    }{
        (setq ow-is-current-over-limit 0)
    })
    (bms-publish-value BMS-BACKEND-OW 'bms-i-in-ic current)
})

(defun ow-parse-status (data) {
    (var prev-status ow-status)
    (setq ow-status (bufget-u8 data (if ow-use-crypto 6 4)))
    (if (and (!= ow-status prev-status) (dbg-active DBG-BMS))
        (dbg DBG-BMS (str-from-n ow-status "bms status 0x%02x")))
    (setq ow-is-charging (if (= (bitwise-and ow-status 0x20) 0) 0 1))
    (setq ow-is-battery-empty (if (= (bitwise-and ow-status 0x4) 0) 0 1))
    (setq ow-is-battery-temp-out-of-range (if (= (bitwise-and ow-status 0x3) 0) 0 1))
    (setq ow-is-battery-overcharged (if (= (bitwise-and ow-status 0x8) 0) 0 1))
    (var is-soc-calculating (if (= (bitwise-and ow-status 0x40) 0) 0 1)) ;maybe or could be if balancing? Not sure cuz it came on while riding
    (bms-publish-status BMS-BACKEND-OW
        (bitwise-and ow-status 0x03) (= ow-is-battery-empty 1)
        (= ow-is-battery-overcharged 1) (= is-soc-calculating 1) (= ow-is-charging 1))
    ;well also observed -128 but have no clue what that means
    (if (= ow-is-charging 1) (if (<= (get-bms-val 'bms-i-in-ic) -0.5) (bms-publish-value BMS-BACKEND-OW 'bms-v-charge (get-bms-val 'bms-v-tot) ) ) )
})

(defun ow-parse-temp (data) {
    (bms-publish-value BMS-BACKEND-OW 'bms-temp-ic (bufget-i8 data (- (buflen data) 3)))
    (var t-cell-max (bufget-i8 data (if ow-use-crypto 6 4)))
    (looprange k (if ow-use-crypto 6 4) (- (buflen data) 3) {
        (var temp-val (bufget-i8 data k))
        (if (> temp-val t-cell-max) (setq t-cell-max temp-val))
        (bms-publish-indexed BMS-BACKEND-OW 'bms-temps-adc (- k (if ow-use-crypto 6 4)) temp-val)
    })
    (bms-publish-value BMS-BACKEND-OW 'bms-temp-cell-max t-cell-max)
})

(defun ow-parse-serial (data) {
    (setq ow-serial (bufget-u16 data (if ow-use-crypto 6 4)))
})

(defun ow-parse-charger (data) {
    (setq ow-charge-state (bufget-u8 data (if ow-use-crypto 6 4)))
    (bms-publish-info BMS-BACKEND-OW 'charge-state ow-charge-state)
})

(defun ow-parse-battery-type (data) {
    ;(var battery-types '((UNDEFINED . 0) (A123_LiFePO4 . 1) (VTC6 . 1) (HG2 . 3) (30Q . 4) (VTC5A . 5) (VTC5D . 6) (30Q6 . 7) (P28A . 8) (VTC6A . 9) (P42A . 10) (40T3 . 11) ))
    (bms-publish-info BMS-BACKEND-OW 'battery-type (bufget-u8 data (if ow-use-crypto 6 4)))
})

(defun ow-parse-cycles-health (data) {
    (bms-publish-info BMS-BACKEND-OW 'cycles (bufget-u16 data (if ow-use-crypto 6 4)))
    ;TODO No way to set SoH in Lisp?
    (var soh (/ (bufget-u8 data (if ow-use-crypto 8 6)) 100.0))
    (if (> soh 1.0) (setq soh 1.0))
    (if (< soh 0.01) (setq soh 0.01))
    (bms-publish-value BMS-BACKEND-OW 'bms-soh soh)
})

(defunret ow-process-cmd (command data ack handshake) {
    (cond
        ((= command 0x00) {
            (ow-parse-status data)
        })
        ;((= command 0x01) {
            ;(ow-parse-voltage data);donno why this doesn't get emmited sometimes
        ;})
        ((= command 0x02) {
            (ow-parse-cell-voltage data)
        })
        ((= command 0x03) {
            (ow-parse-soc data)
        })
        ((= command 0x04) {
            (ow-parse-temp data)
        })
        ((= command 0x05) {
            (ow-parse-current data)
        })
        ((= command 0x06) {
            (ow-parse-serial data)
        })
        ;((= command 0x07) { ; acknowleged as valid packet by controller but no processing ;Emitted by BMS
            ;static maybe these next bytes have to do with firmware build or hardware?
        ;})
        ((= command 0x08) {
            (ow-parse-battery-type data)
        })
        ;((= command 0x09) { ;looked at by controller
        ;})
        ;((= command 0x0A) { ; acknowleged as valid packet by controller but no processing. Sent during bms startup?
        ;})
        ;((= command 0x0B) { ;Emitted by BMS
            ;static
        ;})
        ;((= command 0x0C) { ; acknowleged as valid packet by controller but no processing ;Emitted by BMS. Seems to be all 0 unless on charger.
        ;})
        ((= command 0x0D) {
            (ow-parse-cycles-health data)
        })
        ((= command 0x0E) {
            (if ack {
                (if (= handshake 0) {
                ;(print "first ack");
                    (return (ow-factory-init-accept))
                })
                (if (= handshake 1) {
                (dbg DBG-BMS "bms ack2")
                    (if (!= (bufget-u16 data (if ow-use-crypto 6 4)) 1) { (return false)})
                    (send-msg "Success")
                    (return true)
                })

            })
        })
        ;((= command 0x0F) { ; Looked at by controller ;Emitted by BMS
        ;    ;error?
        ;})
        ;((= command 0x10) { ; looked at by controller ;Emitted by BMS
        ;    ;unknown maybe error code logs?
        ;})
        ;((= command 0x11) { ; looked at by controller
        ;})
        ;((= command 0x12) { ; acknowleged as valid packet by controller but no processing ;Emitted by BMS
        ;})
        ;((= command 0x13) { ;Emitted by BMS
        ;})
        ;((= command 0x14) { ;Emitted by BMS
        ;})
        ((= command 0x15) {
            (if (and ack (= (bufget-u8 data (if ow-use-crypto 6 4)) ow-charge-state)) {(ow-parse-charger data) (return false)})
            (ow-parse-charger data)
        })
        ;((= command 0x16) { ; looked at by controller ;Emitted by BMS
            ;unknown last byte changes
        ;})
        ;So in bms recv we know there's no valid commands above 0x16 (command 0x64 is special and gets sent from controller to BMS)
        ;((= command 0x64) { ;Sent by controller. Should be recieved by BMS and update 0x15
            ;ow-charge-state cmd
            ;(print "charge state cmd")
        ;})
        (t {
            (if (dbg-active DBG-BMS)
                (dbg DBG-BMS (str-from-n command "bms cmd ? 0x%02x")))
            (return false)
        })
        )
    (return true)
})

(defun ow-load-keys () {
    (var key-list (append (unpack-uint32-to-bytes (get-config 'bms-key-a)) (unpack-uint32-to-bytes (get-config 'bms-key-b)) (unpack-uint32-to-bytes (get-config 'bms-key-c)) (unpack-uint32-to-bytes (get-config 'bms-key-d))))
    (var counter-list (append (unpack-uint32-to-bytes (get-config 'bms-counter-a)) (unpack-uint32-to-bytes (get-config 'bms-counter-b)) (unpack-uint32-to-bytes (get-config 'bms-counter-c)) (unpack-uint32-to-bytes (get-config 'bms-counter-d))))
    (looprange i 0  (length key-list){
        (bufset-u8 ow-key i (ix key-list i))
    })
    (looprange i 0  (length counter-list){
        (bufset-u8 ow-counter i (ix counter-list i))
    })
})

(defunret ow-verify-keys (ow-key ow-counter ow-key-crc ow-counter-crc) {
    (var key-crc-calc (crc32 ow-key 0))
    (var counter-crc-calc (crc32 ow-counter 0))
    (looprange i 0 (length ow-key-crc) {
        (if (and (= (ix ow-key-crc i) key-crc-calc) (= (ix ow-counter-crc i) counter-crc-calc)) (return true))
    })
    ; Gated: this dumps the raw AES ow-key, so it must not appear in a console
    ; log someone pastes into a support thread unless they asked for it.
    (if (dbg-active DBG-BMS) {
        (dbg DBG-BMS (str-merge "bms ow-key crc " (to-str key-crc-calc) " " (to-str counter-crc-calc)))
        (print ow-key)
    })
    (return false)
})

(defunret ow-recv-packets (cmd-ack handshake) {
    (var read-timeout (if (= cmd-ack 0x0e)
        1.0  ; 1 second for ow-factory init
        0.5)) ; 500ms for other commands like charge state
    (var bytes-read (uart-read ow-buf (buflen ow-buf) nil nil read-timeout))
    ;(print ow-buf)
    (var found-packet nil)
    (var start 0)
    (loopwhile (>= (- bytes-read start) (if ow-use-crypto 12 10)) {  ; Check against minimum packet size
        ; Look for ow-magic bytes
        (if (and (= (bufget-u8 ow-buf start) (bufget-u8 ow-magic 0))
                 (= (bufget-u8 ow-buf (+ start 1)) (bufget-u8 ow-magic 1))
                 (= (bufget-u8 ow-buf (+ start 2)) (bufget-u8 ow-magic 2))) {
            ; Keep the original marker-delimited framing, scanned natively.
            (var packet-end (ext-ow-find-magic ow-buf bytes-read (+ start 3) ow-magic))

            ; Create a new buffer for the packet
            (var packet-length (- packet-end start))
            (var packet (bufcreate packet-length))
            (bufcpy packet 0 ow-buf start packet-length)
            ; Process the packet
            (if (ow-process-packet packet) {
                (var command (bufget-u8 packet (if ow-use-crypto 5 3))) ; Adjust for crypto/non-crypto

                ; Gated: the BMS emits packets continuously, so this line
                ; used to print several times a second forever and made the
                ; lisp console unusable for anything else.
                (if (dbg-active DBG-BMS)
                    (dbg DBG-BMS (str-merge (str-from-n command "bms cmd 0x%02x")
                        " len " (str-from-n packet-length "%d"))))
                (if (and (>= cmd-ack 0) (= command cmd-ack)) {
                    (var result (ow-process-cmd command packet t handshake))
                    (if (bms-mark-received BMS-BACKEND-OW) (setq found-packet t))
                    (free packet)
                    (return result)
                })
                (if (ow-process-cmd command packet nil -1)
                    (if (bms-mark-received BMS-BACKEND-OW) (setq found-packet t)))
            })
            (free packet)
            (setq start packet-end) ; Move start to the end of the processed packet
        } {
            (setq start (+ start 1)) ; Move to the next byte if ow-magic bytes not found
        })
    })
    (if found-packet
        (send-bms-can)
        ; No ow-magic bytes anywhere in the read: wrong pins, wrong BMS type or
        ; the crypto/plain ow-magic byte does not match what the BMS speaks.
        (if (dbg-tick DBG-BMS 'bms-rx 5.0)
            (dbg DBG-BMS (str-merge "bms no packet in " (str-from-n bytes-read "%d")))))
    (return (< cmd-ack 0));if we're looking for an ack we failed to find one
})

(defunret ow-init () {
    (uart-stop)
    (sleep 1)
    (if ow-exit-flag (return false))
    (if ow-use-crypto{
        (if (< fw-num 6.06){
            (dbg-err "bms crypto needs fw 6.06")
            (send-msg "hw-express needs to be running 6.06")
            (return false)
        })
        (ow-load-keys)
        (if (eq (ow-verify-keys ow-key ow-counter ow-key-crc ow-counter-crc) false){
            (dbg-err "bms bad keys - re-pair")
            (send-msg "Invalid keys")
            (return false)
        })
        (if (= ow-rs485-chip 1){
            (if (or (< ow-rs485-di-pin 0) (not-eq (first (trap (gpio-configure ow-rs485-di-pin 'pin-mode-out))) 'exit-ok)){
                (dbg-err (str-merge "bms bad di pin " (str-from-n ow-rs485-di-pin "%d")))
                (send-msg "Invalid Pin: bms-rs485-di-pin")
                (return false)
            })
            (if (or (< ow-rs485-dere-pin 0) (not-eq (first (trap (gpio-configure ow-rs485-dere-pin 'pin-mode-out))) 'exit-ok)){
                (dbg-err (str-merge "bms bad dere pin " (str-from-n ow-rs485-dere-pin "%d")))
                (send-msg "Invalid Pin: bms-rs485-dere-pin")
                (return false)
            })
        (gpio-write ow-rs485-dere-pin 0); disable transit mode
        })
    })
    (if (>= ow-rs485-ro-pin 0){
        (var ret)
        (if (= ow-rs485-chip 1) {
            (setq ret (first (trap (gpio-configure ow-rs485-ro-pin 'pin-mode-in))))
        }{
            (setq ret (first (trap (gpio-configure ow-rs485-ro-pin 'pin-mode-in-pu))))
        })
        (if (not-eq ret 'exit-ok) {
            (dbg-err (str-merge "bms bad ro pin " (str-from-n ow-rs485-ro-pin "%d")))
            (send-msg "Invalid Pin: rs485-ro-pin")
            (return false)
        })
    }{
        (dbg-err "bms ro pin not set")
        (send-msg "Invalid Pin: rs485-ro-pin")
        (return false)
    })
    (if (and (= ow-charge-only 1) (>= ow-wakeup-pin 0)){
        (if (not-eq (first (trap (gpio-configure ow-wakeup-pin 'pin-mode-out))) 'exit-ok) {
            (dbg-err (str-merge "bms bad wakeup pin " (str-from-n ow-wakeup-pin "%d")))
            (send-msg "Invalid Pin: bms-wakeup-pin")
            (return false)
        })
        (gpio-write ow-wakeup-pin 0)
    })

    (if ow-exit-flag (return false))
    (uart-start 1 ow-rs485-ro-pin (if (= ow-rs485-chip 1) ow-rs485-di-pin -1) 115200);If GNSS is connected UART 1 must be used
    (setq ow-uart-open t)
    (bms-publish-value BMS-BACKEND-OW 'bms-temp-adc-num 4)
    (bufset-u8 ow-magic 2 (if ow-use-crypto 0xbb 0xaa))
    (yield 100000);Gotta make sure uart is ready
    ;now we're cookin'
    (dbg DBG-BMS "bms init ok")
    (return true)
})

(defun ow-load-settings (){
    (setq ow-rs485-di-pin (get-config 'bms-rs485-di-pin))
    (setq ow-rs485-ro-pin (get-config 'bms-rs485-ro-pin))
    (setq ow-rs485-dere-pin (get-config 'bms-rs485-dere-pin))
    (setq ow-wakeup-pin (get-config 'bms-wakeup-pin))
    (setq ow-override-soc (get-config 'bms-override-soc))
    (setq ow-type (get-config 'bms-type))
    (setq ow-use-crypto nil)
    (if (> ow-type 1) (setq ow-use-crypto t))
    (setq ow-rs485-chip (get-config 'bms-rs485-chip))
    (setq ow-loop-delay (get-config 'bms-loop-delay))
    (setq ow-charge-only (get-config 'bms-charge-only))
    (dbg DBG-BMS (str-merge "bms type " (str-from-n ow-type "%d")
        " chip " (str-from-n ow-rs485-chip "%d")
        " pins " (str-from-n ow-rs485-di-pin "%d")
        " " (str-from-n ow-rs485-ro-pin "%d")
        " " (str-from-n ow-rs485-dere-pin "%d")
        " " (str-from-n ow-wakeup-pin "%d")
        " hz " (str-from-n ow-loop-delay "%d")))
})

(defunret ow-bms-run () {
    (setq ow-exit-flag bms-stop-requested)
    (setq ow-user-cmd -1)
    (setq ow-status -1)
    (setq ow-charge-state 0)
    (setq ow-charge-target 0)
    (setq ow-cell-count-uninit t)
    (setq ow-key (bufcreate 16))
    (setq ow-counter (bufcreate 16))
    (setq ow-magic (bufcreate 3))
    (bufset-u8 ow-magic 0 0xff)
    (bufset-u8 ow-magic 1 0x55)
    (if ow-exit-flag (return nil))
    (ow-load-settings)
    (if (= ow-type 0) {
        (dbg-warn "bms type None - parked")
        (loopwhile (not ow-exit-flag) (sleep 1))
        (setq ow-exit-flag nil)
        (return nil)
    })
    (if (and (> ow-type 0) (ow-init)) {

        (var next-run-time (secs-since 0))  ; Set first run time
        (var loop-start-time 0)
        (var loop-end-time 0)
        (setq ow-buf (bufcreate (get-config 'bms-buff-size)))
        (if (< ow-loop-delay 1) {
            (dbg-warn "bms bad rate, using 20Hz")
            (setq ow-loop-delay 20)
        })
        (var bms-loop-delay-sec (/ 1.0 ow-loop-delay))
        (loopwhile t{
        (if (!= dbg-mask 0) (setq dbg-ticks-bms (+ dbg-ticks-bms 1)))
        (setq loop-start-time (secs-since 0))

            (if ow-exit-flag {
                    (break)
            })
            ;lets check if there's a user command
            (if (!= ow-user-cmd -1) {
                 (dbg DBG-BMS (str-from-n ow-user-cmd "bms user cmd 0x%02x"))
                 (if (and (= ow-rs485-chip 1) ow-use-crypto (< (secs-since bms-last-activity-time) 1)) {
                    (loopwhile (and (not ow-exit-flag)
                        (not (if (= ow-user-cmd 0x0e) (ow-factory-init) (ow-set-charge-state 0x00 0x01 ow-charge-target)))) {(sleep 0.01)})
                 }{
                    ;error
                    (dbg-err "bms not connected")
                    (send-msg "BMS not connected")
                 })
                 (setq ow-user-cmd -1)
            }{
                (ow-recv-packets -1 -1)
            })
            (if (dbg-active DBG-BMS) {
                (var conn (if (< (secs-since bms-last-activity-time) 1) 1 0))
                (if (!= conn dbg-prev-bms-conn) {
                    (setq dbg-prev-bms-conn conn)
                    (dbg DBG-BMS (if (= conn 1) "bms up" "bms down"))
                })
            })
            (if (and (= ow-charge-only 1) (>= ow-wakeup-pin 0)) {
                (if (and (> (secs-since bms-last-activity-time) OW-WAKEUP-GRACE-SECONDS) (vehicle-fresh) (not (running-state))) { ;also check can bus has fresh data and float pacakge state is not running just incase someone with discharge enabled configures the bms-wakeup-button for some reason.
                    (dbg DBG-BMS "bms wakeup pulse")
                    (gpio-write ow-wakeup-pin 1)
                    (yield 10000)
                    (gpio-write ow-wakeup-pin 0)
                })
            })
            (setq loop-end-time (secs-since 0))
            (var actual-loop-time (- loop-end-time loop-start-time))

            (var time-to-wait (- next-run-time (secs-since 0)))
            (if (> time-to-wait 0) {
                (yield (* time-to-wait 1000000))
            }{
                (setq next-run-time (secs-since 0))
            })
            (setq next-run-time (+ next-run-time bms-loop-delay-sec))
        })
        (free ow-buf)
        (setq ow-buf nil)
        (setq ow-exit-flag nil)
    } {
        (dbg-warn "bms init failed - parked")
        ; Park rather than return: spawn-with-restart would otherwise respawn
        ; this every second forever, repeating the init errors and the "Invalid
        ; Pin" dialog at 1 Hz. Same pattern gnss-loop already uses.
        (loopwhile (not ow-exit-flag) (sleep 1))
        (setq ow-exit-flag nil)
    })
    (return t)
})
(defun ow-store-keys (key-list counter-list) {
    (setq key-list (split-list key-list 4))
    (set-config 'bms-key-a (pack-bytes-to-uint32 (ix key-list 0)))
    (set-config 'bms-key-b (pack-bytes-to-uint32 (ix key-list 1)))
    (set-config 'bms-key-c (pack-bytes-to-uint32 (ix key-list 2)))
    (set-config 'bms-key-d (pack-bytes-to-uint32 (ix key-list 3)))
    (setq counter-list (split-list counter-list 4))
    (set-config 'bms-counter-a (pack-bytes-to-uint32 (ix counter-list 0)))
    (set-config 'bms-counter-b (pack-bytes-to-uint32 (ix counter-list 1)))
    (set-config 'bms-counter-c (pack-bytes-to-uint32 (ix counter-list 2)))
    (set-config 'bms-counter-d (pack-bytes-to-uint32 (ix counter-list 3)))
    (save-config)
})



; Backend interface. Only this adapter knows UART ownership, private command
; IDs, encryption variants or the stored OW pairing format.
(defun ow-request-stop () (setq ow-exit-flag t))
(defun ow-cleanup () {
    (if ow-uart-open (uart-stop))
    (setq ow-uart-open nil)
    (if ow-buf (free ow-buf))
    (if ow-key (free ow-key))
    (if ow-counter (free ow-counter))
    (if ow-magic (free ow-magic))
    (setq ow-buf nil)
    (setq ow-key nil)
    (setq ow-counter nil)
    (setq ow-magic nil)
    (setq ow-user-cmd -1)
})

(defun ow-capabilities () {
    (if (> (get-config 'bms-type) 1)
        (+ BMS-CAP-PAIRING
            (if (= (get-config 'bms-rs485-chip) 1)
                (+ BMS-CAP-CHARGE BMS-CAP-FACTORY) 0))
        0)
})

(defunret ow-valid-pairing (bytes) {
    (if (!= (length bytes) 16) (return nil))
    (loopforeach value bytes
        (if (or (not (number? value)) (< value 0) (> value 255)) (return nil)))
    (return t)
})

(defun ow-command (command value) {
    (match command
        (charge-control
            (if (and (bms-connected) (or (= value 0) (= value 1))) {
                (setq ow-charge-target value)
                (setq ow-user-cmd 0x64)
                t
            } nil))
        (factory-init
            (if (bms-connected) { (setq ow-user-cmd 0x0e) t } nil))
        (pairing
            (if (and (= (length value) 2)
                     (ow-valid-pairing (ix value 0)) (ow-valid-pairing (ix value 1))) {
                (ow-store-keys (ix value 0) (ix value 1))
                t
            } nil))
        (_ nil))
})

(bms-register BMS-BACKEND-OW ow-bms-run ow-request-stop ow-cleanup
    ow-command ow-capabilities)

@const-end
