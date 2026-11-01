@const-start

; SSBMS / XJBMS over BLE, using the VESC Express LispBM GATT client. Requires
; VESC Express > Bluetooth > LispBM role Client (2) or Client and server (3).
; Same frames as UART: requests are written to ...0001 (without response when
; offered) and replies arrive as notifications on ...0002, possibly split at a
; small MTU. Read-only; reuses the SSBMS core in ssbms.lisp under its own ID.
; Scans, connects and events go through the shared client in ble-client.lisp
; (owner 'ssbms), so other BLE client adapters can run alongside.
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
(def ssbms-ble-conn -1)
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

; The saved pin is not a live connection. Report each real setup phase to the
; page and log it under BMS diagnostics; failures include the native status.
(defun ssbms-ble-progress (phase text) {
    (send-data (str-merge "ssbms-ble-progress " (str-from-n phase "%d") " " text))
    (dbg DBG-BMS (str-merge "SSBMS BLE: " text))
})

(defun ssbms-ble-failed (text) {
    (dbg-warn (str-merge "SSBMS BLE: " text "; " (to-str (assoc blec-errors 'ssbms))))
    (ssbms-ble-progress 0 text)
    nil
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

; Shortened/complete name or advertised 128-bit SSBMS service UUID.
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
            ; AD UUID lists use little-endian order, unlike the GATT events.
            (if (or (= kind 6) (= kind 7) (= kind 0x21)) {
                (var offset (+ i 2))
                (loopwhile (<= (+ offset 16) end) {
                    (var same t)
                    (looprange j 0 16
                        (if (!= (bufget-u8 adv (+ offset j)) (bufget-u8 ssbms-ble-svc-uuid (- 15 j))) (setq same nil)))
                    (if same (setq found t))
                    (setq offset (if (= kind 0x21) end (+ offset 16)))
                })
            })
            (setq i (+ i 1 len))
        })
    })
    found
})

(defun ssbms-ble-up () (and (ssbms-active) (blec-linked 'ssbms ssbms-ble-conn)))

; The pinned peer in packed form, or nil to stay idle until explicit selection.
(defun ssbms-ble-pinned ()
    (blec-config-peer 'ssbms-ble-paired-address-a 'ssbms-ble-paired-address-b))

; From the page: scan for the picker at the worker's next opportunity.
(defun ssbms-ble-interrupted () (or ssbms-ble-scan-requested ssbms-ble-relink))

; 'link: only the pinned address/type. 'list: "ssbms-found ..." per BMS.
(defunret ssbms-ble-scan (mode) {
    (var pinned (ssbms-ble-pinned))
    (if (and (eq mode 'link) (not pinned)) (return nil))
    (blec-reset 'ssbms)
    (dbg DBG-BMS (if (eq mode 'list) "SSBMS BLE: picker scan started (5 s)" "SSBMS BLE: saved peer scan started (5 s)"))
    (var result (blec-find 'ssbms SSBMS-BLE-SCAN-MS mode
        (fn (packed adv) {
            (var saved (and pinned (blec-bytes-eq packed pinned)))
            (var matched (if (eq mode 'link) saved (or saved (ssbms-ble-match-adv adv))))
            (if (dbg-active DBG-BMS)
                (dbg DBG-BMS (str-merge "SSBMS BLE: advertisement " (to-str packed)
                    " name " (or (blec-adv-name adv) "<unnamed>") " matched " (to-str matched) " data " (to-str adv))))
            matched
        }) ssbms-ble-interrupted "ssbms-found"))
    (dbg DBG-BMS (str-merge "SSBMS BLE: scan finished; result " (to-str result) " error " (to-str (assoc blec-errors 'ssbms))))
    (return result)
})

(defun ssbms-ble-request-scan ()
    (if (and ssbms-ble-ready (bms-backend-active BMS-BACKEND-SSBMS-BLE))
        (setq ssbms-ble-scan-requested t)
        (send-data "ssbms-scan-done -1")))

; Connect from the page: pin the BMS (0 0 forgets it), persist, and relink.
; Works with the backend stopped too, so a stale pin can always be forgotten.
(defun ssbms-ble-select (a b)
    (if (blec-select "ssbms-ble-selected" 'ssbms-ble-paired-address-a 'ssbms-ble-paired-address-b a b) {
        (setq ssbms-ble-relink t)
        (if (and ssbms-ble-ready (ssbms-active))
            (ssbms-ble-progress (if (and (= a 0) (= b 0)) 0 1) (if (and (= a 0) (= b 0))
                "Saved BMS cleared; press Scan to select a BMS" "BMS selection saved; waiting to connect"))
            (ssbms-ble-progress 0 "BLE backend is not running; save Config with SSBMS BLE enabled"))
    }))

(defun ssbms-ble-report (connected)
    (blec-report "ssbms-ble-link" connected ssbms-ble-conn ssbms-ble-peer ""))

; Scan, connect, exchange MTU, discover, and subscribe. t when ready to poll.
(defunret ssbms-ble-link () {
    (if (or (not (ssbms-active)) (not (ssbms-ble-pinned))) (return nil))
    (blec-reset 'ssbms)
    (ssbms-ble-progress 1 "Scanning for BMS")
    (var peer (ssbms-ble-scan 'link))
    (if (not peer) {
        (var reason (assoc blec-errors 'ssbms))
        (cond
            ((not reason) (ssbms-ble-progress 0 "No matching BMS found; retrying"))
            ((and (eq (car reason) 'scan) (list? (ix reason 1)) (eq (car (ix reason 1)) 'busy))
                (ssbms-ble-progress 0 (str-merge "Bluetooth busy; waiting to retry " (to-str reason))))
            (t (ssbms-ble-failed "BMS scan failed; retrying")))
        (return nil)
    })
    (if (or (not (ssbms-active)) (ssbms-ble-interrupted)) (return nil))
    (dbg DBG-BMS (str-merge "SSBMS BLE: peer " (to-str (ix peer 0)) " type " (to-str (ix peer 1))))
    (setq ssbms-ble-peer (blec-pack (ix peer 0) (ix peer 1)))
    (ssbms-ble-progress 2 "Connecting to BMS")
    (setq ssbms-ble-conn (or (blec-open-link 'ssbms peer SSBMS-BLE-CONNECT-MS) SSBMS-BLE-NO-CONN))
    (if (< ssbms-ble-conn 0) (return (ssbms-ble-failed "BLE connection failed; check BMS is awake and its phone app is disconnected")))
    (dbg DBG-BMS (str-merge "SSBMS BLE: connected, handle " (str-from-n ssbms-ble-conn "%d")))
    ; A 32-cell reply is 71 bytes. A small MTU is tolerated by reassembly.
    (ssbms-ble-progress 3 "Negotiating MTU")
    (setq ssbms-ble-mtu (blec-mtu 'ssbms ssbms-ble-conn SSBMS-BLE-SETUP-SECONDS))
    (if (not ssbms-ble-mtu) (return (ssbms-ble-failed "MTU exchange failed; retrying")))
    (dbg DBG-BMS (str-merge "SSBMS BLE: MTU " (str-from-n ssbms-ble-mtu "%d")))
    (ssbms-ble-progress 4 "Discovering BMS service and characteristics")
    (var found (blec-service 'ssbms ssbms-ble-conn (fn (uuid) (blec-bytes-eq uuid ssbms-ble-svc-uuid))
        SSBMS-BLE-SETUP-SECONDS))
    (if (not found) {
        (return (ssbms-ble-failed "BMS service discovery failed; retrying"))
    })
    (var chars (ix found 1))
    (var cmd-props 0)
    (setq ssbms-ble-cmd -1)
    (setq ssbms-ble-rsp -1)
    (loopforeach c chars {
        (if (blec-bytes-eq (ix c 4) ssbms-ble-cmd-uuid) {
            (setq ssbms-ble-cmd (ix c 1))
            (setq cmd-props (ix c 3))
        })
        (if (blec-bytes-eq (ix c 4) ssbms-ble-rsp-uuid) (setq ssbms-ble-rsp (ix c 1)))
    })
    (if (or (< ssbms-ble-cmd 0) (< ssbms-ble-rsp 0)) {
        (blec-error 'ssbms 'characteristics 'not-found)
        (return (ssbms-ble-failed "BMS characteristics not found; retrying"))
    })
    ; The app writes without response; fall back to acknowledged writes.
    (setq ssbms-ble-write-mode (if (!= (bitwise-and cmd-props 4) 0) 0 1))
    (dbg DBG-BMS (str-merge "SSBMS BLE: handles cmd/rsp " (str-from-n ssbms-ble-cmd "%d") "/"
        (str-from-n ssbms-ble-rsp "%d") " write-mode " (str-from-n ssbms-ble-write-mode "%d")))
    (ssbms-ble-progress 5 "Enabling BMS notifications")
    (if (not (blec-notify 'ssbms ssbms-ble-conn chars ssbms-ble-rsp (ix (ix found 0) 2) SSBMS-BLE-SETUP-SECONDS))
        (return (ssbms-ble-failed "Notification subscription failed; retrying")))
    (ssbms-ble-progress 6 "BLE connected; waiting for BMS data")
    (return t)
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
        (var event (blec-event 'ssbms))
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

(defun ssbms-ble-drop () {
    (blec-drop 'ssbms ssbms-ble-conn)
    (setq ssbms-ble-conn SSBMS-BLE-NO-CONN)
    (setq ssbms-ble-cmd -1)
    (setq ssbms-ble-rsp -1)
    (setq ssbms-ble-used 0)
})

(defunret ssbms-ble-init () {
    (if (not (ssbms-active)) (return nil))
    (if (not (and (blec-usable "SSBMS BLE") (blec-start))) {
        (ssbms-ble-progress 0 "Bluetooth client unavailable; check its role and reboot the Express")
        (return nil)
    })
    (ssbms-alloc)
    (setq ssbms-transport-read ssbms-ble-read)
    (setq ssbms-ble-ready t)
    (blec-open 'ssbms ssbms-active)
    (return t)
})

(defun ssbms-ble-loop () {
    (setq ssbms-source BMS-BACKEND-SSBMS-BLE)
    (if (ssbms-ble-init)
        (loop () (ssbms-active) {
            ; Unpaired backends do no background discovery. Only the picker
            ; may scan until the user selects a peer to reconnect to.
            (if (not (ssbms-ble-pinned)) {
                (ssbms-ble-progress 0 "No BMS saved; press Scan to select a BMS")
                (loop () (and (ssbms-active) (not (ssbms-ble-pinned)) (not ssbms-ble-scan-requested))
                    (sleep 0.05))
            })
            ; A picker scan runs while disconnected, so the link is dropped first.
            (setq ssbms-ble-relink nil)
            (if (and (ssbms-active) ssbms-ble-scan-requested) {
                (setq ssbms-ble-scan-requested nil)
                (send-data (str-merge "ssbms-scan-done " (str-from-n (ssbms-ble-scan 'list) "%d")))
            })
            (if (ssbms-ble-link) {
                (dbg DBG-BMS "ssbms ble linked")
                (ssbms-begin)
                (var reported 0)
                (var received nil)
                ; ssbms-poll handles the 3 s stale window; give up after 10 s.
                (loop () (and (ssbms-ble-up) (not (ssbms-ble-interrupted))
                        (< (secs-since ssbms-last-snapshot) SSBMS-BLE-RECONNECT-SECONDS)) {
                    (if (>= (secs-since reported) 1.0) {
                        (ssbms-ble-report t)
                        (setq reported (systime))
                    })
                    (ssbms-cycle)
                    (if (and (not received) (bms-connected)) {
                        (setq received t)
                        (ssbms-ble-progress 6 "BMS telemetry received")
                    })
                })
                (dbg DBG-BMS "ssbms ble lost")
                (ssbms-ble-progress 0 (if (ssbms-ble-interrupted) "BMS selection or scan changed"
                    "BMS link or telemetry lost; reconnecting"))
            })
            (ssbms-ble-drop)
            (ssbms-ble-report nil)
            (bms-reset-status)
            (setq ssbms-cell-count 0)
            (var started (systime))
            (loop () (and (ssbms-active) (not (ssbms-ble-interrupted))
                            (< (secs-since started) SSBMS-BLE-RETRY-SECONDS))
                (sleep 0.05))
        }))
})

(defun ssbms-ble-cleanup () {
    (if ssbms-ble-ready {
        (ssbms-ble-drop)
        (blec-release 'ssbms)
        (ssbms-ble-report nil)
        (ssbms-ble-progress 0 "SSBMS BLE backend stopped; check the Lisp console")
    })
    (setq ssbms-ble-ready nil)
    (ssbms-cleanup)
})

(bms-register BMS-BACKEND-SSBMS-BLE ssbms-ble-loop (fn () nil) ssbms-ble-cleanup
    (fn (command value) nil) (fn () 0))

@const-end
