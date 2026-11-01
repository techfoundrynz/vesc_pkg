@const-start

; Shared VESC Express LispBM BLE client for every adapter that connects out
; such as SSBMS BLE. The firmware has one client event queue that
; exactly one consumer may drain, connection attempts must not overlap, and
; (ble-client-connect nil) drops every outgoing peer. So adapters never touch
; the queue, scans or connects directly:
;
; - Events are drained atomically by whichever adapter polls, routed by the
;   connection field of (ble-client-event t) into per-adapter mailboxes, and
;   handed back in the documented default layouts (connection field removed).
; - One adapter at a time owns the scan or the pending connection attempt;
;   the others get 'busy and retry later.
; - Each adapter disconnects only its own peers, and is marked lost when its
;   peer disconnects, its mailbox overflows or the firmware drops an event.
;
; Owners are adapter symbols, such as 'ssbms. Requires LispBM role Client (2) or
; Client and server (3); callers check (express-ble-role) first.
(def BLEC-NONE 65535)
(def BLEC-BOX-MAX 64)
(def blec-started nil)
(def blec-links nil)      ; connection handle -> owner
(def blec-boxes nil)      ; owner -> queued events, oldest first
(def blec-alive nil)      ; owner -> predicate; absent once released
(def blec-lost-flags nil) ; owner -> t after a loss of state
(def blec-bases nil)      ; owner -> ble-client-dropped baseline
(def blec-scanner nil)    ; owner of the active scan
(def blec-connector nil)  ; owner of the pending connection attempt, or 'orphan
(def blec-errors nil)     ; owner -> (operation status), for connection diagnostics

(defun blec-without (alist key) {
    (var out nil)
    (loopforeach pair alist (if (not (eq (car pair) key)) (setq out (cons pair out))))
    out
})

(defun blec-put (alist key value) (acons key value (blec-without alist key)))

(defun blec-error (owner operation status) {
    (atomic (setq blec-errors (blec-put blec-errors owner (list operation status))))
    nil
})

(defun blec-wait-error (owner operation)
    (blec-error owner operation (cond ((blec-lost owner) 'events-lost)
        ((not (blec-alive-p owner)) 'stopped) (t 'timeout))))

(defun blec-request-error (owner operation result)
    (blec-error owner operation (if (eq result 'busy) (list 'busy blec-scanner blec-connector) result)))

(defun blec-mark-lost (owner) (setq blec-lost-flags (blec-put blec-lost-flags owner t)))

(defun blec-deliver (owner event)
    (if (and owner (assoc blec-alive owner)) {
        (var box (append (assoc blec-boxes owner) (list event)))
        ; An owner that stops polling loses state rather than memory.
        (if (> (length box) BLEC-BOX-MAX) {
            (setq box (cdr box))
            (blec-mark-lost owner)
        })
        (setq blec-boxes (blec-put blec-boxes owner box))
    }))

(defun blec-route (event) {
    (var kind (ix event 0))
    (var plain (cons kind (cdr (cdr event))))
    (cond
        ((or (eq kind 'ble-scan-result) (eq kind 'ble-scan-done)) {
            (blec-deliver blec-scanner plain)
            (if (eq kind 'ble-scan-done) (setq blec-scanner nil))
        })
        ((eq kind 'ble-connect-result) {
            (var owner blec-connector)
            (var handle (ix event 2))
            (setq blec-connector nil)
            (if (and (= (ix event 3) 0) (!= handle BLEC-NONE))
                ; A link nobody waits for any more is closed straight away.
                (if (and owner (assoc blec-alive owner))
                    (setq blec-links (acons handle owner blec-links))
                    (ble-client-connect nil handle)))
            (blec-deliver owner plain)
        })
        (t {
            (var owner (assoc blec-links (ix event 1)))
            (if (eq kind 'ble-disconnected) {
                (setq blec-links (blec-without blec-links (ix event 1)))
                (if owner (blec-mark-lost owner))
            })
            (blec-deliver owner plain)
        }))
})

(defun blec-pump ()
    (atomic (loopwhile (blec-route-next) nil)))

(defun blec-route-next () {
    (var event (ble-client-event t))
    (if event { (blec-route event) t } nil)
})

; Once per Lisp session: client links and queued events survive a Lisp reload,
; so drop them and wait briefly for the disconnects before anyone connects.
; Trapped, so a failing client can never leave blec-started at 'starting and
; park the next caller forever; it is simply retried by the next caller.
(defun blec-start () {
    (loopwhile (eq blec-started 'starting) (sleep 0.05))
    (if (not blec-started) {
        (setq blec-started 'starting)
        (var r (trap {
            (loopwhile (ble-client-event) nil)
            (ble-client-connect nil)
            (var started (systime))
            (loopwhile (and (ble-client-connect t) (< (secs-since started) 1.0)) {
                (loopwhile (ble-client-event) nil)
                (sleep 0.01)
            })
            (loopwhile (ble-client-event) nil)
        }))
        (setq blec-started (eq (car r) 'exit-ok))
    })
    (eq blec-started t)
})

; t when the client really works. The config role alone is not enough: a role
; saved but not yet applied by a reboot reads as Client while the client
; extensions still only raise errors.
(defun blec-usable (tag)
    (cond
        ((< (express-ble-role) 2) {
            (dbg-warn (str-merge tag ": set Express BLE LispBM role to Client or Client and server"))
            nil
        })
        ((not (eq (car (trap (ble-client-dropped))) 'exit-ok)) {
            (dbg-warn (str-merge tag ": reboot the VESC Express to start the Bluetooth client"))
            nil
        })
        (t t)))

; Register an owner. alive is polled by the waits below; nil stops them.
(defun blec-open (owner alive) (atomic
    (setq blec-alive (blec-put blec-alive owner alive))
    (setq blec-boxes (blec-put blec-boxes owner nil))
    (setq blec-lost-flags (blec-without blec-lost-flags owner))
    (setq blec-bases (blec-put blec-bases owner (ble-client-dropped)))))

; Start a new session: forget earlier losses, including drops during scans.
(defun blec-reset (owner) (atomic
    (setq blec-errors (blec-without blec-errors owner))
    (setq blec-lost-flags (blec-without blec-lost-flags owner))
    (setq blec-bases (blec-put blec-bases owner (ble-client-dropped)))))

(defun blec-lost (owner) (assoc blec-lost-flags owner))

; Next event for this owner, or nil.
(defun blec-event (owner) {
    (blec-pump)
    (var dropped (ble-client-dropped))
    (atomic {
        (if (> dropped (or (assoc blec-bases owner) 0)) {
            (setq blec-bases (blec-put blec-bases owner dropped))
            (blec-mark-lost owner)
        })
        (var box (assoc blec-boxes owner))
        (if box (setq blec-boxes (blec-put blec-boxes owner (cdr box))))
        (if box (car box) nil)
    })
})

(defun blec-busy (owner)
    (or blec-connector (and blec-scanner (not (eq blec-scanner owner)))))

; t when accepted, 'busy while another owner scans or connects, else the
; firmware error.
(defun blec-scan (owner ms) (atomic
    (if (blec-busy owner) 'busy {
        ; A matched advertisement can end a scan before its queued completion
        ; is consumed. Do not let that old completion end the next scan.
        (loopwhile (blec-route-next) nil)
        (var kept nil)
        (loopforeach event (assoc blec-boxes owner)
            (if (not (or (eq (car event) 'ble-scan-result) (eq (car event) 'ble-scan-done)))
                (setq kept (cons event kept))))
        (setq blec-boxes (blec-put blec-boxes owner (reverse kept)))
        (var result (ble-client-scan ms))
        (if (eq result t) (setq blec-scanner owner))
        result
    })))

; Cancellation produces no ble-scan-done, so nobody waits for one.
(defun blec-scan-stop (owner) (atomic
    (if (eq blec-scanner owner) {
        (ble-client-scan 0)
        (setq blec-scanner nil)
    })))

(defun blec-connect (owner address type ms) (atomic
    (if (blec-busy owner) 'busy {
        ; Connecting cancels our own scan.
        (if (eq blec-scanner owner) (setq blec-scanner nil))
        (var result (ble-client-connect address type ms))
        (if (eq result t) (setq blec-connector owner))
        result
    })))

; Give up a pending attempt we no longer wait for; a late success is closed.
(defun blec-abandon (owner) (atomic
    (if (eq blec-connector owner) (setq blec-connector 'orphan))))

(defun blec-release (owner) (atomic
    (if (eq blec-scanner owner) {
        (ble-client-scan 0)
        (setq blec-scanner nil)
    })
    (if (eq blec-connector owner) (setq blec-connector 'orphan))
    (loopforeach pair blec-links (if (eq (cdr pair) owner) (ble-client-connect nil (car pair))))
    (setq blec-alive (blec-without blec-alive owner))
    (setq blec-boxes (blec-without blec-boxes owner))))

(defun blec-alive-p (owner) {
    (var alive (assoc blec-alive owner))
    (and alive (alive))
})

(defun blec-ok (owner started seconds)
    (and (blec-alive-p owner) (not (blec-lost owner)) (< (secs-since started) seconds)))

; Our link on this handle is up: not lost and not disconnected.
(defun blec-linked (owner handle)
    (and (>= handle 0) (not (blec-lost owner)) (eq (assoc blec-links handle) owner)))

; One event of this kind, or nil on timeout, release or session loss.
(defunret blec-wait (owner kind seconds) {
    (var started (systime))
    (loopwhile (blec-ok owner started seconds) {
        (var event (blec-event owner))
        (if event
            (if (eq (ix event 0) kind) (return event))
            (sleep 0.01))
    })
    (return (blec-wait-error owner kind))
})

; Discovery records up to ble-procedure-done for this operation, or 'fail.
(defunret blec-collect (owner kind operation seconds) {
    (var records nil)
    (var started (systime))
    (loopwhile (blec-ok owner started seconds) {
        (var event (blec-event owner))
        (if event {
            (if (eq (ix event 0) kind) (setq records (cons event records)))
            (if (and (eq (ix event 0) 'ble-procedure-done) (= (ix event 1) operation))
                (return (if (= (ix event 2) 0) (reverse records)
                    { (blec-error owner kind (ix event 2)) 'fail })))
        } (sleep 0.01))
    })
    (blec-wait-error owner kind)
    (return 'fail)
})

; Shared byte and GATT helpers.
(defun blec-bytes-eq (a b) {
    (var same (= (buflen a) (buflen b)))
    (var i 0)
    (loopwhile (and same (< i (buflen a))) {
        (setq same (= (bufget-u8 a i) (bufget-u8 b i)))
        (setq i (+ i 1))
    })
    same
})

; 16-bit UUID, including its full Bluetooth Base UUID representation.
(def blec-uuid-base [0 0 0 0 0 0 0x10 0 0x80 0 0 0x80 0x5f 0x9b 0x34 0xfb])
(defunret blec-uuid16 (uuid value) {
    (var size (buflen uuid))
    (if (= size 2) (return (= (bufget-u16 uuid 0) value)))
    (if (!= size 16) (return nil))
    (looprange i 0 16
        (if (and (or (< i 2) (> i 3)) (!= (bufget-u8 uuid i) (bufget-u8 blec-uuid-base i))) (return nil)))
    (return (= (bufget-u16 uuid 2) value))
})
(defun blec-cccd (uuid) (blec-uuid16 uuid 0x2902))

; Local name field (0x08/0x09) as a string, or nil.
(defunret blec-adv-name (adv) {
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

; Peer address as stored in two config ints: address bytes 0-5, address type,
; then 1 when paired, read big-endian as int32 at offsets 0 and 4.
(defun blec-pack (address type) {
    (var packed (bufcreate 8))
    (bufcpy packed 0 address 0 6)
    (bufset-u8 packed 6 type)
    (bufset-u8 packed 7 1)
    packed
})

; The paired peer from two config keys in packed form, or nil.
(defun blec-config-peer (key-a key-b) {
    (var packed (bufcreate 8))
    (bufset-i32 packed 0 (get-config key-a))
    (bufset-i32 packed 4 (get-config key-b))
    (if (= (bufget-u8 packed 7) 1) packed nil)
})

(defun blec-seen (packed seen) {
    (var found nil)
    (loopforeach other seen (if (blec-bytes-eq packed other) (setq found t)))
    found
})

; Persist a paired peer (0 0 forgets it) and reply "<tag> 1|0 a b". t when
; the write stuck: set-config refuses writes in test mode.
(defun blec-select (tag key-a key-b a b) {
    (set-config key-a a)
    (set-config key-b b)
    (var ok (and (= (get-config key-a) a) (= (get-config key-b) b) (ext-facfg-store)))
    (send-data (str-merge tag (if ok " 1 " " 0 ") (str-from-n a "%d") " " (str-from-n b "%d")))
    ok
})

; Link state for a page: "<tag> 1|0 a b rssi" plus extra, with the packed
; peer address as two ints and the RSSI in dBm.
(defun blec-report (tag connected handle peer extra) {
    (var rssi (if connected (ble-client-connect handle) nil))
    (send-data (str-merge tag (if connected " 1 " " 0 ")
        (str-from-n (if connected (bufget-i32 peer 0) 0) "%d") " "
        (str-from-n (if connected (bufget-i32 peer 4) 0) "%d") " "
        (str-from-n (if (number? rssi) rssi 0) "%d") extra))
})

; Active scan for one owner; (matcher packed-address adv) picks peers. 'link
; returns the first match as (address type), stopping early once (stop) is t.
; 'list sends "<tag> a b rssi name" once per address and returns the count, or
; -2 when another owner holds the scanner.
(defun blec-find (owner ms mode matcher stop tag) {
    (var found nil)
    (var seen nil)
    (var result (blec-scan owner ms))
    (var accepted (eq result t))
    (if (not accepted) (blec-request-error owner 'scan result))
    (var done (not accepted))
    (var started (systime))
    (loopwhile (and (not done) (blec-alive-p owner) (< (secs-since started) (+ 1.0 (/ ms 1000.0)))) {
        (var event (blec-event owner))
        (if event {
            (if (eq (ix event 0) 'ble-scan-done) {
                (setq done t)
                (if (!= (ix event 1) 0) {
                    (setq accepted nil)
                    (blec-error owner 'scan (ix event 1))
                })
            })
            (if (eq (ix event 0) 'ble-scan-result) {
                (var packed (blec-pack (ix event 1) (ix event 2)))
                (if (matcher packed (ix event 4))
                    (if (eq mode 'link)
                        (setq found (list (ix event 1) (ix event 2)))
                        (if (not (blec-seen packed seen)) {
                            (setq seen (cons packed seen))
                            (send-data (str-merge tag " "
                                (str-from-n (bufget-i32 packed 0) "%d") " "
                                (str-from-n (bufget-i32 packed 4) "%d") " "
                                (str-from-n (ix event 3) "%d") " " (or (blec-adv-name (ix event 4)) "Bluetooth device")))
                        })))
                (if (and (eq mode 'link) (or found (stop))) (setq done t))
            })
        } (sleep 0.01))
    })
    (blec-scan-stop owner)
    (if (eq mode 'link) found (if accepted (length seen) -2))
})

; Connect to a found (address type) in a fresh session (drops during the scan
; do not count). The connection handle, or nil.
(defunret blec-open-link (owner peer ms) {
    (blec-reset owner)
    (var result (blec-connect owner (ix peer 0) (ix peer 1) ms))
    (if (not (eq result t)) (return (blec-request-error owner 'connect result)))
    (var event (blec-wait owner 'ble-connect-result (+ 1.0 (/ ms 1000.0))))
    (if (not event) (return nil))
    (if (or (!= (ix event 2) 0) (= (ix event 1) BLEC-NONE))
        (return (blec-error owner 'connect (ix event 2))))
    (return (ix event 1))
})

; Negotiated MTU (23 when the peer refuses), or nil on failure.
(defunret blec-mtu (owner conn seconds) {
    (var result (ble-client-exchange-mtu conn))
    (if (not (eq result t)) (return (blec-request-error owner 'mtu result)))
    (var event (blec-wait owner 'ble-mtu-result seconds))
    (if (not event) (return nil))
    (return (if (= (ix event 2) 0) (ix event 1) 23))
})

; The service whose UUID satisfies (predicate uuid) and its characteristics, as
; (service chars), or nil when it is missing or discovery failed.
(defunret blec-service (owner conn predicate seconds) {
    (var result (ble-client-discover-services conn))
    (if (not (eq result t)) (return (blec-request-error owner 'services result)))
    (var services (blec-collect owner 'ble-service 4 seconds))
    (if (eq services 'fail) (return nil))
    (var service nil)
    (loopforeach s services (if (predicate (ix s 3)) (setq service s)))
    (if (not service) (return (blec-error owner 'service 'not-found)))
    (setq result (ble-client-discover-chars (ix service 1) (ix service 2) conn))
    (if (not (eq result t)) (return (blec-request-error owner 'characteristics result)))
    (var chars (blec-collect owner 'ble-characteristic 5 seconds))
    (return (if (eq chars 'fail) nil (list service chars)))
})

; Give up our scan or attempt and close our link on this handle, waiting
; briefly for the disconnect so a late event cannot hit a reused handle.
(defun blec-drop (owner handle) {
    (blec-scan-stop owner)
    (blec-abandon owner)
    (blec-pump)
    (if (and (>= handle 0) (eq (assoc blec-links handle) owner)) {
        (ble-client-connect nil handle)
        (var started (systime))
        (var gone nil)
        (loopwhile (and (not gone) (< (secs-since started) 1.0)) {
            (var event (blec-event owner))
            (if event
                (setq gone (and (eq (ix event 0) 'ble-disconnected) (= (ix event 1) handle)))
                (sleep 0.01))
        })
    })
})

; Subscribe to notifications on the characteristic value handle. Its
; descriptors run up to the next declaration or the service end.
(defunret blec-descriptors (owner conn chars handle last seconds) {
    (var end last)
    (loopforeach c chars
        (if (and (> (ix c 2) handle) (<= (ix c 2) end)) (setq end (- (ix c 2) 1))))
    (if (<= end handle) { (blec-error owner 'descriptors 'invalid-range) (return 'fail) })
    (var result (ble-client-discover-descriptors handle end conn))
    (if (not (eq result t)) { (blec-request-error owner 'descriptors result) (return 'fail) })
    (return (blec-collect owner 'ble-descriptor 6 seconds))
})

(defunret blec-subscribe (owner conn cccd seconds) {
    (if (< cccd 0) (return (blec-error owner 'cccd 'not-found)))
    (var result (ble-client-subscribe cccd 1 conn))
    (if (not (eq result t)) (return (blec-request-error owner 'subscribe result)))
    (var event (blec-wait owner 'ble-write-result seconds))
    (if (not event) (return nil))
    (if (or (!= (ix event 1) cccd) (!= (ix event 2) 0))
        (return (blec-error owner 'subscribe (list (ix event 1) (ix event 2)))))
    (return t)
})

(defunret blec-notify (owner conn chars handle last seconds) {
    (var descriptors (blec-descriptors owner conn chars handle last seconds))
    (if (eq descriptors 'fail) (return nil))
    (var cccd -1)
    (loopforeach d descriptors (if (blec-cccd (ix d 2)) (setq cccd (ix d 1))))
    (return (blec-subscribe owner conn cccd seconds))
})

(defun blec-read (owner conn handle long-read seconds) {
    (if (and (>= handle 0) (eq (if long-read (ble-client-read-long handle conn) (ble-client-read handle conn)) t)) {
        (var event (blec-wait owner 'ble-read-result seconds))
        (if (and event (= (ix event 1) handle) (= (ix event 2) 0)) (ix event 3) nil)
    } nil)
})

@const-end
