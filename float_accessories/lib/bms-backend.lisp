@const-start

; Registration is passive. Only one selected backend may own the BMS interface.
; Callbacks: run, request-stop, cleanup, command(command,value), capabilities.
(def bms-registry nil)
(def bms-worker-running nil)
(def bms-stop-requested nil)
(def bms-active-backend BMS-BACKEND-NONE)
(def bms-active-hooks nil)
(def bms-cleanup-failed nil)

(defun bms-register (id run request-stop cleanup command capabilities)
    (setq bms-registry (acons id (list run request-stop cleanup command capabilities) bms-registry)))

(defun bms-backend-active (id)
    (and (> id 0) (= id bms-active-backend) bms-worker-running bms-active-hooks
         (not bms-stop-requested) (not bms-cleanup-failed) (= (get-config 'bms-enabled) 1)
         (= (get-config 'bms-backend) id)))

(defun bms-backend-loop (hooks) {
    (var result (trap ((ix hooks 0))))
    (var cleanup (trap ((ix hooks 2))))
    (bms-reset-status)
    (if (eq (ix result 0) 'exit-error)
        (dbg-err (str-merge "bms backend " (to-str (ix result 1)))))
    (if (eq (ix cleanup 0) 'exit-error) {
        (setq bms-cleanup-failed t)
        (dbg-err (str-merge "bms cleanup " (to-str (ix cleanup 1))))
    })
    ; Unexpected exits park until stopped, without reviving an obsolete owner.
    (loopwhile (or (not bms-stop-requested) bms-cleanup-failed) (sleep 0.05))
    (atomic
        (setq bms-active-backend BMS-BACKEND-NONE)
        (setq bms-active-hooks nil)
        (setq bms-context-id -1)
        (setq bms-worker-running nil))
})

(defun bms-start-backend () {
    (if (not bms-worker-running) {
        (bms-reset-status)
        (setq bms-freshness-seconds 1.0)
        (setq bms-active-backend BMS-BACKEND-NONE)
        (setq bms-active-hooks nil)
        (setq bms-context-id -1)
        (var selected (get-config 'bms-backend))
        (if (and (= (get-config 'bms-enabled) 1) (> selected 0)) {
            (var hooks (assoc bms-registry selected))
            (if hooks {
                (setq bms-stop-requested nil)
                (setq bms-cleanup-failed nil)
                (setq bms-active-backend selected)
                (setq bms-active-hooks hooks)
                (setq bms-worker-running t)
                (setq bms-context-id (spawn bms-backend-loop hooks))
            } {
                (dbg-warn "bms backend unavailable")
            })
        })
    })
})

(defun bms-stop-backend () {
    (if bms-worker-running {
        (setq bms-stop-requested t)
        (var result (trap ((ix bms-active-hooks 1))))
        (if (eq (ix result 0) 'exit-error) (dbg-err "bms stop request failed"))
        (var start-time (systime))
        (loopwhile (and bms-worker-running (< (secs-since start-time) 2.0))
            (yield 10000))
        (if bms-worker-running {
            (dbg-warn "bms backend did not stop")
            (send-msg "BMS backend did not stop; replacement was not started.")
        })
    })
    (not bms-worker-running)
})

@const-end
