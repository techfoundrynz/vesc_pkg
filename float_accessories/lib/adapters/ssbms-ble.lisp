@const-start

; SSBMS / XJBMS over BLE, using the VESC Express LispBM GATT client. Requires
; VESC Express > Bluetooth > LispBM role Client (2) or Client and server (3).
; Same frames as UART: requests are written to ...0001 (without response when
; offered) and replies arrive as notifications on ...0002, possibly split at a
; small MTU. Read-only; reuses the SSBMS core in ssbms.lisp under its own ID.
; This backend is the only consumer of the firmware's shared client queue.
(def SSBMS-BLE-SCAN-MS 5000)
(def SSBMS-BLE-CONNECT-MS 10000)
(def SSBMS-BLE-SETUP-SECONDS 5.0)
(def SSBMS-BLE-REPLY-SECONDS 0.4)
(def SSBMS-BLE-RECONNECT-SECONDS 10.0)
(def SSBMS-BLE-RETRY-SECONDS 2.0)
(def SSBMS-BLE-NO-CONN -1)
(def ssbms-ble-svc-uuid [0x00 0x00 0x27 0x60 0x08 0xc2 0x11 0xe1 0x90 0x73 0x0e 0x8a 0xc7 0x2e 0x10 0x01])
(def ssbms-ble-cmd-uuid [0x00 0x00 0x27 0x60 0x08 0xc2 0x11 0xe1 0x90 0x73 0x0e 0x8a 0xc7 0x2e 0x00 0x01])
(def ssbms-ble-rsp-uuid [0x00 0x00 0x27 0x60 0x08 0xc2 0x11 0xe1 0x90 0x73 0x0e 0x8a 0xc7 0x2e 0x00 0x02])
; Upper-case "SSBMS" and "XJBMS"; advertised names match case-insensitively.
(def ssbms-ble-names (list [0x53 0x53 0x42 0x4d 0x53] [0x58 0x4a 0x42 0x4d 0x53]))
(def ssbms-ble-ready nil)
(def ssbms-ble-scanning nil)
(def ssbms-ble-conn -1)
(def ssbms-ble-lost nil)
(def ssbms-ble-dropped 0)
(def ssbms-ble-cmd -1)
(def ssbms-ble-rsp -1)
(def ssbms-ble-write-mode 0)
(def ssbms-ble-mtu 23)
(def ssbms-ble-used 0)
; Packed address of the connected peer, and a UI scan request from the page.
(def ssbms-ble-peer nil)
(def ssbms-ble-scan-requested nil)
; Set when the page picks a BMS: drop the link and reconnect to the new pin.
(def ssbms-ble-relink nil)

(defun ssbms-ble-bytes-eq (a b) {
    (var same (= (buflen a) (buflen b)))
    (var i 0)
    (loopwhile (and same (< i (buflen a))) {
        (setq same (= (bufget-u8 a i) (bufget-u8 b i)))
        (setq i (+ i 1))
    })
    same
})

(defun ssbms-ble-upper (c) (if (and (>= c 97) (<= c 122)) (- c 32) c))

(defun ssbms-ble-has (data start end pattern) {
    (var n (buflen pattern))
    (var found nil)
    (var i start)
    (loopwhile (and (not found) (<= (+ i n) end)) {
        (var k 0)
        (loopwhile (and (< k n) (= (ssbms-ble-upper (bufget-u8 data (+ i k))) (bufget-u8 pattern k)))
            (setq k (+ k 1)))
        (setq found (= k n))
        (setq i (+ i 1))
    })
    found
})

; Shortened (0x08) or complete (0x09) local name containing SSBMS or XJBMS.
; Scan responses arrive as separate results, so either packet can match.
(defun ssbms-ble-match-adv (adv) {
    (var size (buflen adv))
    (var i 0)
    (var found nil)
    (loopwhile (and (not found) (< (+ i 1) size)) {
        (var len (bufget-u8 adv i))
        (if (= len 0) (setq i size) {
            (var end (min size (+ i 1 len)))
            (var kind (bufget-u8 adv (+ i 1)))
            (if (or (= kind 8) (= kind 9))
                (loopforeach name ssbms-ble-names
                    (if (ssbms-ble-has adv (+ i 2) end name) (setq found t))))
            (setq i (+ i 1 len))
        })
    })
    found
})

; CCCD 0x2902, reported either as 16-bit or in Bluetooth Base UUID form.
(defun ssbms-ble-cccd (uuid) {
    (var size (buflen uuid))
    (var at (if (= size 16) 2 0))
    (and (or (= size 2) (= size 16))
         (or (= size 2) (and (= (bufget-u8 uuid 0) 0) (= (bufget-u8 uuid 1) 0)))
         (= (bufget-u8 uuid at) 0x29) (= (bufget-u8 uuid (+ at 1)) 0x02))
})

; Single queue consumer. A dropped event or our peer's disconnect invalidates
; the session; the loop then tears down and rediscovers from scratch.
(defun ssbms-ble-event () {
    (var event (ble-client-event))
    (var dropped (ble-client-dropped))
    (if (> dropped ssbms-ble-dropped) {
        (setq ssbms-ble-dropped dropped)
        (setq ssbms-ble-lost t)
    })
    (if (and event (eq (ix event 0) 'ble-disconnected) (= (ix event 1) ssbms-ble-conn)) {
        (setq ssbms-ble-conn SSBMS-BLE-NO-CONN)
        (setq ssbms-ble-lost t)
    })
    event
})

(defun ssbms-ble-up ()
    (and (ssbms-active) (not ssbms-ble-lost) (>= ssbms-ble-conn 0)))

; One event of this kind, or nil on timeout, cancellation or session loss.
(defunret ssbms-ble-wait (kind seconds) {
    (var started (systime))
    (loopwhile (and (ssbms-active) (not ssbms-ble-lost) (< (secs-since started) seconds)) {
        (var event (ssbms-ble-event))
        (if event
            (if (eq (ix event 0) kind) (return event))
            (sleep 0.01))
    })
    (return nil)
})

; Discovery records up to ble-procedure-done for this operation, or 'fail.
(defunret ssbms-ble-collect (kind operation seconds) {
    (var records nil)
    (var started (systime))
    (loopwhile (and (ssbms-active) (not ssbms-ble-lost) (< (secs-since started) seconds)) {
        (var event (ssbms-ble-event))
        (if event {
            (if (eq (ix event 0) kind) (setq records (cons event records)))
            (if (and (eq (ix event 0) 'ble-procedure-done) (= (ix event 1) operation))
                (return (if (= (ix event 2) 0) (reverse records) 'fail)))
        } (sleep 0.01))
    })
    (return 'fail)
})

; Local name field (0x08/0x09) as a string, or nil.
(defunret ssbms-ble-adv-name (adv) {
    (var size (buflen adv))
    (var i 0)
    (loopwhile (< (+ i 1) size) {
        (var len (bufget-u8 adv i))
        (if (= len 0) (return nil))
        (var end (min size (+ i 1 len)))
        (if (and (or (= (bufget-u8 adv (+ i 1)) 8) (= (bufget-u8 adv (+ i 1)) 9)) (> end (+ i 2))) {
            (var name (bufcreate (- end i 1)))
            (bufcpy name 0 adv (+ i 2) (- end i 2))
            (return name)
        })
        (setq i (+ i 1 len))
    })
    (return nil)
})

; Address bytes 0-5, address type, then 1: the two config ints
; ssbms-ble-paired-address-a/b, read big-endian as int32 at offsets 0 and 4.
(defun ssbms-ble-pack (address type) {
    (var packed (bufcreate 8))
    (bufcpy packed 0 address 0 6)
    (bufset-u8 packed 6 type)
    (bufset-u8 packed 7 1)
    packed
})

; The pinned peer in packed form, or nil to accept the first SSBMS/XJBMS.
(defun ssbms-ble-pinned () {
    (var packed (bufcreate 8))
    (bufset-i32 packed 0 (get-config 'ssbms-ble-paired-address-a))
    (bufset-i32 packed 4 (get-config 'ssbms-ble-paired-address-b))
    (if (= (bufget-u8 packed 7) 1) packed nil)
})

(defun ssbms-ble-seen (packed seen) {
    (var found nil)
    (loopforeach other seen (if (ssbms-ble-bytes-eq packed other) (setq found t)))
    found
})

; Active scan. 'link returns the pinned peer, or the first SSBMS/XJBMS when
; none is pinned, as (address type). 'list reports each SSBMS/XJBMS to the UI
; as "ssbms-found a b rssi name" and returns how many were found.
(defun ssbms-ble-scan (mode) {
    (var pinned (if (eq mode 'link) (ssbms-ble-pinned) nil))
    (var found nil)
    (var seen nil)
    (var done (not (eq (ble-client-scan SSBMS-BLE-SCAN-MS) t)))
    (setq ssbms-ble-scanning (not done))
    (var started (systime))
    (loopwhile (and (not done) (ssbms-active)
                    (< (secs-since started) (+ 1.0 (/ SSBMS-BLE-SCAN-MS 1000.0)))) {
        (var event (ssbms-ble-event))
        (if event {
            (if (eq (ix event 0) 'ble-scan-done) {
                (setq ssbms-ble-scanning nil)
                (setq done t)
            })
            (if (eq (ix event 0) 'ble-scan-result) {
                (var packed (ssbms-ble-pack (ix event 1) (ix event 2)))
                (var named (ssbms-ble-match-adv (ix event 4)))
                (if (eq mode 'link) {
                    ; A pinned peer matches on address alone, from either packet.
                    (if (if pinned (ssbms-ble-bytes-eq packed pinned) named)
                        (setq found (list (ix event 1) (ix event 2))))
                    (setq done (or found (ssbms-ble-interrupted)))
                } (if (and named (not (ssbms-ble-seen packed seen))) {
                    (setq seen (cons packed seen))
                    (send-data (str-merge "ssbms-found "
                        (str-from-n (bufget-i32 packed 0) "%d") " "
                        (str-from-n (bufget-i32 packed 4) "%d") " "
                        (str-from-n (ix event 3) "%d") " " (ssbms-ble-adv-name (ix event 4))))
                }))
            })
        } (sleep 0.01))
    })
    ; Cancellation produces no ble-scan-done, so do not wait for one.
    (if ssbms-ble-scanning (ble-client-scan 0))
    (setq ssbms-ble-scanning nil)
    (if (eq mode 'link) found (length seen))
})

; From the page: scan for the picker at the worker's next opportunity.
(defun ssbms-ble-interrupted () (or ssbms-ble-scan-requested ssbms-ble-relink))

(defun ssbms-ble-request-scan ()
    (if (bms-backend-active BMS-BACKEND-SSBMS-BLE)
        (setq ssbms-ble-scan-requested t)
        (send-data "ssbms-scan-done -1")))

; Connect from the page: pin the BMS (0 0 forgets it), persist, and relink.
; Replies "ssbms-ble-selected 1|0 a b"; 0 means nothing was saved. Works with
; the backend stopped too, so a stale pin can always be forgotten; the relink
; flag is cleared when the worker next starts a link.
(defun ssbms-ble-select (a b) {
    (set-config 'ssbms-ble-paired-address-a a)
    (set-config 'ssbms-ble-paired-address-b b)
    ; set-config refuses writes in test mode; only report what stuck.
    (var ok (and (= (get-config 'ssbms-ble-paired-address-a) a)
                 (= (get-config 'ssbms-ble-paired-address-b) b)
                 (ext-facfg-store)))
    (if ok (setq ssbms-ble-relink t))
    (send-data (str-merge "ssbms-ble-selected " (if ok "1 " "0 ")
        (str-from-n a "%d") " " (str-from-n b "%d")))
})

; Link state for the page: connected, packed address ints, RSSI in dBm.
(defun ssbms-ble-report (connected) {
    (var rssi (if connected (ble-client-connect ssbms-ble-conn) nil))
    (send-data (str-merge "ssbms-ble-link " (if connected "1 " "0 ")
        (str-from-n (if connected (bufget-i32 ssbms-ble-peer 0) 0) "%d") " "
        (str-from-n (if connected (bufget-i32 ssbms-ble-peer 4) 0) "%d") " "
        (str-from-n (if (number? rssi) rssi 0) "%d")))
})

; Scan, connect, exchange MTU, discover, and subscribe. t when ready to poll.
(defunret ssbms-ble-link () {
    (var peer (ssbms-ble-scan 'link))
    (if (not peer) (return nil))
    (setq ssbms-ble-peer (ssbms-ble-pack (ix peer 0) (ix peer 1)))
    ; Scan floods may drop results; only post-scan losses invalidate a link.
    (setq ssbms-ble-dropped (ble-client-dropped))
    (setq ssbms-ble-lost nil)
    (if (not (eq (ble-client-connect (ix peer 0) (ix peer 1) SSBMS-BLE-CONNECT-MS) t)) (return nil))
    (var event (ssbms-ble-wait 'ble-connect-result (+ 1.0 (/ SSBMS-BLE-CONNECT-MS 1000.0))))
    (if (or (not event) (!= (ix event 2) 0) (= (ix event 1) 65535)) (return nil))
    (setq ssbms-ble-conn (ix event 1))
    ; A 32-cell reply is 71 bytes. A small MTU is tolerated by reassembly.
    (setq ssbms-ble-mtu 23)
    (if (not (eq (ble-client-exchange-mtu ssbms-ble-conn) t)) (return nil))
    (setq event (ssbms-ble-wait 'ble-mtu-result SSBMS-BLE-SETUP-SECONDS))
    (if (not event) (return nil))
    (if (= (ix event 2) 0) (setq ssbms-ble-mtu (ix event 1)))
    (if (not (eq (ble-client-discover-services ssbms-ble-conn) t)) (return nil))
    (var services (ssbms-ble-collect 'ble-service 4 SSBMS-BLE-SETUP-SECONDS))
    (if (eq services 'fail) (return nil))
    (var service nil)
    (loopforeach s services
        (if (ssbms-ble-bytes-eq (ix s 3) ssbms-ble-svc-uuid) (setq service s)))
    (if (not service) {
        (dbg-warn "SSBMS BLE: BMS service not found")
        (return nil)
    })
    (var last (ix service 2))
    (if (not (eq (ble-client-discover-chars (ix service 1) last ssbms-ble-conn) t)) (return nil))
    (var chars (ssbms-ble-collect 'ble-characteristic 5 SSBMS-BLE-SETUP-SECONDS))
    (if (eq chars 'fail) (return nil))
    (var cmd-props 0)
    (setq ssbms-ble-cmd -1)
    (setq ssbms-ble-rsp -1)
    (loopforeach c chars {
        (if (ssbms-ble-bytes-eq (ix c 4) ssbms-ble-cmd-uuid) {
            (setq ssbms-ble-cmd (ix c 1))
            (setq cmd-props (ix c 3))
        })
        (if (ssbms-ble-bytes-eq (ix c 4) ssbms-ble-rsp-uuid) (setq ssbms-ble-rsp (ix c 1)))
    })
    (if (or (< ssbms-ble-cmd 0) (< ssbms-ble-rsp 0)) {
        (dbg-warn "SSBMS BLE: BMS characteristics not found")
        (return nil)
    })
    ; The app writes without response; fall back to acknowledged writes.
    (setq ssbms-ble-write-mode (if (!= (bitwise-and cmd-props 4) 0) 0 1))
    ; Descriptors follow the reply value handle up to the next declaration.
    (var end last)
    (loopforeach c chars
        (if (and (> (ix c 2) ssbms-ble-rsp) (<= (ix c 2) end)) (setq end (- (ix c 2) 1))))
    (if (<= end ssbms-ble-rsp) (return nil))
    (if (not (eq (ble-client-discover-descriptors ssbms-ble-rsp end ssbms-ble-conn) t)) (return nil))
    (var descriptors (ssbms-ble-collect 'ble-descriptor 6 SSBMS-BLE-SETUP-SECONDS))
    (if (eq descriptors 'fail) (return nil))
    (var cccd -1)
    (loopforeach d descriptors (if (ssbms-ble-cccd (ix d 2)) (setq cccd (ix d 1))))
    (if (< cccd 0) (return nil))
    (if (not (eq (ble-client-subscribe cccd 1 ssbms-ble-conn) t)) (return nil))
    (setq event (ssbms-ble-wait 'ble-write-result SSBMS-BLE-SETUP-SECONDS))
    (return (and event (= (ix event 2) 0)))
})

; Transport read for the SSBMS core: one request in flight; notifications
; are appended until the native scanner finds a CRC-valid matching reply.
(defunret ssbms-ble-read (reg count destination) {
    (if (not (ssbms-ble-up)) (return nil))
    (ext-ssbms-request ssbms-tx reg count)
    (setq ssbms-ble-used 0)
    (if (not (eq (ble-client-write ssbms-ble-cmd ssbms-tx ssbms-ble-write-mode ssbms-ble-conn) t))
        (return nil))
    (var started (systime))
    (loopwhile (and (ssbms-ble-up) (< (secs-since started) SSBMS-BLE-REPLY-SECONDS)) {
        (var event (ssbms-ble-event))
        (if event {
            (if (and (eq (ix event 0) 'ble-notification) (= (ix event 1) ssbms-ble-rsp)
                     (= (ix event 2) 0)) {
                (var data (ix event 3))
                (var n (min 256 (buflen data)))
                ; Restart reassembly rather than overflow on a stray burst.
                (if (> (+ ssbms-ble-used n) 256) (setq ssbms-ble-used 0))
                (bufcpy ssbms-rx ssbms-ble-used data 0 n)
                (setq ssbms-ble-used (+ ssbms-ble-used n))
                (var offset (ext-ssbms-scan ssbms-rx ssbms-ble-used reg count))
                (if (>= offset 0) {
                    (bufcpy destination 0 ssbms-rx offset (+ 7 (* 2 count)))
                    (return t)
                })
            })
        } (sleep 0.005))
    })
    (return nil)
})

; Cancel any scan or link and wait briefly for our disconnect, so a late event
; cannot hit a reused connection handle in the next session.
(defun ssbms-ble-drop () {
    (if ssbms-ble-scanning (ble-client-scan 0))
    (setq ssbms-ble-scanning nil)
    (var handle ssbms-ble-conn)
    (setq ssbms-ble-conn SSBMS-BLE-NO-CONN)
    (ble-client-connect nil)
    (if (>= handle 0) {
        (var started (systime))
        (var gone nil)
        (loopwhile (and (not gone) (< (secs-since started) 1.0)) {
            (var event (ble-client-event))
            (if event
                (setq gone (and (eq (ix event 0) 'ble-disconnected) (= (ix event 1) handle)))
                (sleep 0.01))
        })
    })
    (setq ssbms-ble-cmd -1)
    (setq ssbms-ble-rsp -1)
    (setq ssbms-ble-used 0)
})

(defunret ssbms-ble-init () {
    (if (not (ssbms-active)) (return nil))
    (if (< (express-ble-role) 2) {
        (dbg-warn "SSBMS BLE: set Express BLE LispBM role to Client or Client and server")
        (return nil)
    })
    (ssbms-alloc)
    (setq ssbms-transport-read ssbms-ble-read)
    (setq ssbms-ble-ready t)
    ; Client links and queued events survive Lisp reloads; start clean.
    (ssbms-ble-drop)
    (loopwhile (ble-client-event) nil)
    (setq ssbms-ble-dropped (ble-client-dropped))
    (setq ssbms-ble-lost nil)
    (return t)
})

(defun ssbms-ble-loop () {
    (setq ssbms-source BMS-BACKEND-SSBMS-BLE)
    (if (ssbms-ble-init)
        (loopwhile (ssbms-active) {
            ; A picker scan runs while disconnected, so the link is dropped first.
            (if ssbms-ble-scan-requested {
                (setq ssbms-ble-scan-requested nil)
                (send-data (str-merge "ssbms-scan-done " (str-from-n (ssbms-ble-scan 'list) "%d")))
            })
            (setq ssbms-ble-relink nil)
            (if (ssbms-ble-link) {
                (dbg DBG-BMS "ssbms ble linked")
                (ssbms-begin)
                (var reported 0)
                ; ssbms-poll handles the 3 s stale window; give up after 10 s.
                (loopwhile (and (ssbms-ble-up) (not (ssbms-ble-interrupted))
                        (< (secs-since ssbms-last-snapshot) SSBMS-BLE-RECONNECT-SECONDS)) {
                    (if (>= (secs-since reported) 1.0) {
                        (ssbms-ble-report t)
                        (setq reported (systime))
                    })
                    (ssbms-cycle)
                })
                (dbg DBG-BMS "ssbms ble lost")
            })
            (ssbms-ble-drop)
            (ssbms-ble-report nil)
            (bms-reset-status)
            (setq ssbms-cell-count 0)
            (var started (systime))
            (loopwhile (and (ssbms-active) (not (ssbms-ble-interrupted))
                            (< (secs-since started) SSBMS-BLE-RETRY-SECONDS))
                (sleep 0.05))
        }))
})

(defun ssbms-ble-cleanup () {
    (if ssbms-ble-ready (ssbms-ble-drop))
    (setq ssbms-ble-ready nil)
    (ssbms-cleanup)
})

(bms-register BMS-BACKEND-SSBMS-BLE ssbms-ble-loop (fn () nil) ssbms-ble-cleanup
    (fn (command value) nil) (fn () 0))

@const-end
