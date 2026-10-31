@const-start

; Provider-independent, temporary brightness override. Local config is never
; modified. A provider must renew its lease; disable/disconnect releases it.
(def lighting-source 0)
(def lighting-time 0)
(def lighting-ride 0.0)
(def lighting-idle 0.0)
(def lighting-status 0.0)

(defun lighting-release () (setq lighting-source 0))

(defun lighting-override-active ()
    (and (> lighting-source 0) (integration-is lighting-source)
         (not sim-active) (< (secs-since lighting-time) 1.0)))

(defun lighting-override (source ride idle status) {
    (if (and (integration-is source)
             (>= ride 0.0) (<= ride 1.0) (>= idle 0.0) (<= idle 1.0)
             (>= status 0.0) (<= status 1.0))
        (atomic
            (setq lighting-ride ride)
            (setq lighting-idle idle)
            (setq lighting-status status)
            (setq lighting-time (systime))
            (setq lighting-source source)))
})

@const-end
