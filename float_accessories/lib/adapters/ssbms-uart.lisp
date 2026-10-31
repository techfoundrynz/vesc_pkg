@const-start

; SSBMS / XJBMS UART transport: 115200 8N1 over the core in ssbms.lisp.
(def SSBMS-UART 1)
(def SSBMS-UART-BAUD 115200)
(def ssbms-uart-open nil)

(defunret ssbms-uart-init () {
    (var rx (get-config 'ssbms-uart-rx-pin))
    (var tx (get-config 'ssbms-uart-tx-pin))
    (if (or (< rx 0) (< tx 0) (= rx tx)) {
        (dbg-warn "SSBMS UART: set distinct RX and TX pins")
        (return nil)
    })
    ; Firmware uart-read/write have one global UART owner. NMEA uses that same
    ; interface even on another port; u-blox on a different port is independent.
    (if (and (= (get-config 'gnss-enabled) 1)
             (or (= (get-config 'gnss-uart-num) SSBMS-UART)
                 (= (get-config 'gnss-type) 1))) {
        (dbg-warn "SSBMS UART: conflicts with GNSS configuration")
        (return nil)
    })
    (if (not (ssbms-active)) (return nil))
    (ssbms-alloc)
    (setq ssbms-transport-read ssbms-uart-read)
    (setq ssbms-uart-open (uart-start SSBMS-UART rx tx SSBMS-UART-BAUD))
    (if (not ssbms-uart-open) (dbg-warn "SSBMS UART: start failed"))
    (return ssbms-uart-open)
})

; One request in flight. Accumulate fragmented reads, skip noise/bad CRCs and
; unrelated or wrong-sized replies. A timeout discards the partial transaction.
; All UART reads are bounded and nonblocking so cancellation stays prompt.
(defunret ssbms-uart-read (reg count destination) {
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

(defun ssbms-uart-cleanup () {
    (if ssbms-uart-open (uart-stop))
    (setq ssbms-uart-open nil)
    (ssbms-cleanup)
})

(defun ssbms-uart-loop () {
    (setq ssbms-source BMS-BACKEND-SSBMS-UART)
    (if (ssbms-uart-init) {
        (ssbms-begin)
        (loopwhile (ssbms-active) (ssbms-cycle))
    })
})

(bms-register BMS-BACKEND-SSBMS-UART ssbms-uart-loop (fn () nil) ssbms-uart-cleanup
    (fn (command value) nil) (fn () 0))

@const-end
