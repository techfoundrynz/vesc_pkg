@const-start

; Data starts after magic, nonce (encrypted types) and command.
(defun ow-at () (if ow-use-crypto 6 4))

(defun ow-crypt (nonce-high nonce-low data start-offset len) {
    (var restore-byte (bufget-u8 ow-counter 15))
    (bufset-u8 ow-counter 0 nonce-high)
    (bufset-u8 ow-counter 1 nonce-low)
    (aes-ctr-crypt ow-key ow-counter data start-offset len)
    (bufset-u8 ow-counter 15 restore-byte)
})

(defun ow-checksum (data start-offset end-offset)
    (ext-ow-checksum data start-offset end-offset))

; Send one command and wait for the BMS's ack. The payload is copied first:
; ow-construct-packet encrypts in place and the literals live in flash.
(defun ow-send (nonce-high nonce-low payload ack handshake) {
    (var data (bufcreate (buflen payload)))
    (bufcpy data 0 payload 0 (buflen payload))
    (var packet (ow-construct-packet nonce-high nonce-low data))
    (free data)
    (gpio-write ow-rs485-dere-pin 1)
    (uart-write packet)
    (sleep 0.005)
    (gpio-write ow-rs485-dere-pin 0)
    (sleep 0.005)
    (var ret (ow-recv-packets ack handshake))
    (free packet)
    ret
})

(defunret ow-set-charge-state (nonce-high nonce-low charge-state) {
    (if (< ow-charge-state 0) {
        (dbg-warn "bms no charge state yet")
        (return false)
    })
    (return (ow-send nonce-high nonce-low (if (= charge-state 0x1) [0x64 0x00] [0x64 0x01]) 0x15 -1))
})

(defun ow-factory-init-accept () (ow-send 0x00 0x01 [0x03 0x01] 0x0e 1))

; "05RMA"
(defun ow-factory-init () (ow-send 0x00 0x01 [0x05 0x52 0x4d 0x41] 0x0e 0))

(defunret ow-process-packet (data) {
    (if (!= (bufget-u8 data 2) (bufget-u8 ow-magic 2)) (return false))
    (if (!= (bufget-u16 data (- (buflen data) 2)) (ow-checksum data 0 (- (buflen data) 2))) (return false))
    (if ow-use-crypto
        (return (ow-crypt (bufget-u8 data 3) (bufget-u8 data 4) data 5 (- (buflen data) 7))))
    (return true)
})

(defun ow-construct-packet (nonce-high nonce-low payload) {
    (var n (buflen payload))
    (var packet (bufcreate (+ n 7)))
    (bufcpy packet 0 ow-magic 0 (buflen ow-magic))
    (bufset-u8 packet 3 nonce-high)
    (bufset-u8 packet 4 nonce-low)
    (ow-crypt nonce-high nonce-low payload 0 n)
    (bufcpy packet 5 payload 0 n)
    (bufset-u16 packet (+ n 5) (ow-checksum packet 0 (+ n 5)))
    packet
})

(defun ow-clamp-soc (soc) (max 0.01 (min 1.0 soc)))

(defun ow-parse-cell-voltage (data){
    (var at (ow-at))
    (var scale (if ow-use-crypto 10000.0 1000.0))
    (var cell-index 0)
    (var total-voltage 0)
    (var v-cell-min (/ (bufget-u16 data at) scale))
    (var v-cell-max v-cell-min)
    (if ow-cell-count-uninit {
        (bms-publish-value BMS-BACKEND-OW 'bms-cell-num (/ (- (buflen data) 8) 2))
        (setq ow-cell-count-uninit false)
    })
    ; Plain packets leave off the end 16th cell for a 15s BMS.
    (looprange k at (- (buflen data) (+ (if ow-use-crypto 0 2) 3)) {
        (if (eq (mod k 2) 0) {
            (var current-cell (/ (bufget-u16 data k) scale))
            (if (and (= cell-index 0) (= ow-override-soc 1))
                (bms-publish-value BMS-BACKEND-OW 'bms-soc (/ (estimate-soc current-cell voltage-curve) 100)))
            (bms-publish-indexed BMS-BACKEND-OW 'bms-v-cell cell-index current-cell)
            (setq cell-index (+ cell-index 1))
            (setq total-voltage (+ total-voltage current-cell))
            (setq v-cell-max (max v-cell-max current-cell))
            (setq v-cell-min (min v-cell-min current-cell))
        })
    })
    (bms-publish-value BMS-BACKEND-OW 'bms-v-tot total-voltage)
    (if (>= fw-num 6.06) {
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

(defun ow-parse-soc (data)
    (if (= ow-override-soc 0)
        (bms-publish-value BMS-BACKEND-OW 'bms-soc (ow-clamp-soc (/ (bufget-u8 data (ow-at)) 100.0)))))

(defun ow-parse-current (data) {
    ; Scaler 0.0366 (maybe 0.0378) encrypted; limit 32 A (maybe 32.7 A).
    (var current (* (bufget-i16 data (ow-at)) (if ow-use-crypto 0.0366 0.055)))
    (if (and (= ow-charge-only 0) (>= current (if ow-use-crypto 32.0 30.0))) {
        (if (= ow-is-current-over-limit 0)
            (dbg-warn (str-merge "bms current at limit " (str-from-n current "%.2f"))))
        (setq ow-is-current-over-limit 1)
    } (setq ow-is-current-over-limit 0))
    (bms-publish-value BMS-BACKEND-OW 'bms-i-in-ic current)
})

(defun ow-bit (mask) (if (= (bitwise-and ow-status mask) 0) 0 1))

; Status bits: 0x03 temperature, 0x04 empty, 0x08 overcharged, 0x20 charging,
; 0x40 SoC calculating (or balancing; seen while riding). -128 also observed.
(defun ow-parse-status (data) {
    (var prev-status ow-status)
    (setq ow-status (bufget-u8 data (ow-at)))
    (if (and (!= ow-status prev-status) (dbg-active DBG-BMS))
        (dbg DBG-BMS (str-from-n ow-status "bms status 0x%02x")))
    (setq ow-is-charging (ow-bit 0x20))
    (setq ow-is-battery-empty (ow-bit 0x4))
    (setq ow-is-battery-temp-out-of-range (ow-bit 0x3))
    (setq ow-is-battery-overcharged (ow-bit 0x8))
    (bms-publish-status BMS-BACKEND-OW
        (bitwise-and ow-status 0x03) (= ow-is-battery-empty 1)
        (= ow-is-battery-overcharged 1) (= (ow-bit 0x40) 1) (= ow-is-charging 1))
    (if (and (= ow-is-charging 1) (<= (get-bms-val 'bms-i-in-ic) -0.5))
        (bms-publish-value BMS-BACKEND-OW 'bms-v-charge (get-bms-val 'bms-v-tot)))
})

(defun ow-parse-temp (data) {
    (var at (ow-at))
    (bms-publish-value BMS-BACKEND-OW 'bms-temp-ic (bufget-i8 data (- (buflen data) 3)))
    (var t-cell-max (bufget-i8 data at))
    (looprange k at (- (buflen data) 3) {
        (var temp-val (bufget-i8 data k))
        (setq t-cell-max (max t-cell-max temp-val))
        (bms-publish-indexed BMS-BACKEND-OW 'bms-temps-adc (- k at) temp-val)
    })
    (bms-publish-value BMS-BACKEND-OW 'bms-temp-cell-max t-cell-max)
})

(defun ow-parse-serial (data) (setq ow-serial (bufget-u16 data (ow-at))))

(defun ow-parse-charger (data) {
    (setq ow-charge-state (bufget-u8 data (ow-at)))
    (bms-publish-info BMS-BACKEND-OW 'charge-state ow-charge-state)
})

; Types: 0 undefined, 1 A123 LiFePO4 or VTC6, 3 HG2, 4 30Q, 5 VTC5A, 6 VTC5D,
; 7 30Q6, 8 P28A, 9 VTC6A, 10 P42A, 11 40T3.
(defun ow-parse-battery-type (data)
    (bms-publish-info BMS-BACKEND-OW 'battery-type (bufget-u8 data (ow-at))))

(defun ow-parse-cycles-health (data) {
    (bms-publish-info BMS-BACKEND-OW 'cycles (bufget-u16 data (ow-at)))
    (bms-publish-value BMS-BACKEND-OW 'bms-soh (ow-clamp-soc (/ (bufget-u8 data (+ (ow-at) 2)) 100.0)))
})

; BMS commands with a parser. Also seen: 0x01 total voltage (not always
; emitted), 0x07/0x0a/0x0b/0x0c/0x12-0x14 static or unprocessed, 0x09/0x0f/
; 0x10/0x11/0x16 read by the controller but unknown. 0x64 is controller->BMS.
(def ow-parsers (list (cons 0x00 ow-parse-status) (cons 0x02 ow-parse-cell-voltage)
    (cons 0x03 ow-parse-soc) (cons 0x04 ow-parse-temp) (cons 0x05 ow-parse-current)
    (cons 0x06 ow-parse-serial) (cons 0x08 ow-parse-battery-type) (cons 0x0d ow-parse-cycles-health)))

; t when handled. Acks: 0x0e drives the factory-init handshake; 0x15 reports
; the charge state, and an ack still showing the old state is not a success.
(defunret ow-process-cmd (command data ack handshake) {
    (var parser (assoc ow-parsers command))
    (if parser {
        (parser data)
        (return true)
    })
    (if (= command 0x0e) {
        (if (and ack (= handshake 0)) (return (ow-factory-init-accept)))
        (if (and ack (= handshake 1)) {
            (dbg DBG-BMS "bms ack2")
            (if (!= (bufget-u16 data (ow-at)) 1) (return false))
            (send-msg "Success")
        })
        (return true)
    })
    (if (= command 0x15) {
        (var unchanged (and ack (= (bufget-u8 data (ow-at)) ow-charge-state)))
        (ow-parse-charger data)
        (return (not unchanged))
    })
    (if (dbg-active DBG-BMS) (dbg DBG-BMS (str-from-n command "bms cmd ? 0x%02x")))
    (return false)
})

(def ow-key-names '(bms-key-a bms-key-b bms-key-c bms-key-d))
(def ow-counter-names '(bms-counter-a bms-counter-b bms-counter-c bms-counter-d))

; Four config ints per 16-byte buffer, big-endian.
(defun ow-fill (buf names) {
    (var i 0)
    (loopforeach name names
        (loopforeach byte (unpack-uint32-to-bytes (get-config name)) {
            (bufset-u8 buf i byte)
            (setq i (+ i 1))
        }))
})

(defun ow-load-keys () {
    (ow-fill ow-key ow-key-names)
    (ow-fill ow-counter ow-counter-names)
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
                (var command (bufget-u8 packet (- (ow-at) 1)))

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

; Configure a pin, or report it: t when usable.
(defun ow-pin-ok (pin mode label)
    (if (and (>= pin 0) (eq (first (trap (gpio-configure pin mode))) 'exit-ok)) t {
        (dbg-err (str-merge "bms bad pin " label " " (str-from-n pin "%d")))
        (send-msg (str-merge "Invalid Pin: " label))
        nil
    }))

(defunret ow-init () {
    (uart-stop)
    (sleep 1)
    (if ow-exit-flag (return false))
    (if ow-use-crypto {
        (if (< fw-num 6.06) {
            (dbg-err "bms crypto needs fw 6.06")
            (send-msg "hw-express needs to be running 6.06")
            (return false)
        })
        (ow-load-keys)
        (if (eq (ow-verify-keys ow-key ow-counter ow-key-crc ow-counter-crc) false) {
            (dbg-err "bms bad keys - re-pair")
            (send-msg "Invalid keys")
            (return false)
        })
        (if (= ow-rs485-chip 1) {
            (if (not (and (ow-pin-ok ow-rs485-di-pin 'pin-mode-out "bms-rs485-di-pin")
                          (ow-pin-ok ow-rs485-dere-pin 'pin-mode-out "bms-rs485-dere-pin")))
                (return false))
            (gpio-write ow-rs485-dere-pin 0) ; receive mode
        })
    })
    (if (not (ow-pin-ok ow-rs485-ro-pin (if (= ow-rs485-chip 1) 'pin-mode-in 'pin-mode-in-pu) "rs485-ro-pin"))
        (return false))
    (if (and (= ow-charge-only 1) (>= ow-wakeup-pin 0)) {
        (if (not (ow-pin-ok ow-wakeup-pin 'pin-mode-out "bms-wakeup-pin")) (return false))
        (gpio-write ow-wakeup-pin 0)
    })
    (if ow-exit-flag (return false))
    ; UART 1: GNSS on the same Express must use it too.
    (uart-start 1 ow-rs485-ro-pin (if (= ow-rs485-chip 1) ow-rs485-di-pin -1) 115200)
    (setq ow-uart-open t)
    (bms-publish-value BMS-BACKEND-OW 'bms-temp-adc-num 4)
    (bufset-u8 ow-magic 2 (if ow-use-crypto 0xbb 0xaa))
    (yield 100000) ; let the UART settle
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
(defun ow-store (names bytes)
    (loopforeach name names {
        (set-config name (pack-bytes-to-uint32 (take bytes 4)))
        (setq bytes (drop bytes 4))
    }))

(defun ow-store-keys (key-list counter-list) {
    (ow-store ow-key-names key-list)
    (ow-store ow-counter-names counter-list)
    (save-config)
})

; Backend interface. Only this adapter knows UART ownership, private command
; IDs, encryption variants or the stored OW pairing format.
(defun ow-request-stop () (setq ow-exit-flag t))
(defun ow-cleanup () {
    (if ow-uart-open (uart-stop))
    (setq ow-uart-open nil)
    (loopforeach buf (list ow-buf ow-key ow-counter ow-magic) (if buf (free buf)))
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
