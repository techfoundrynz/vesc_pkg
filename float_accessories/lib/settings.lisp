@const-start

; Configuration access. The config is a VESC custom config from the fa_cfg native
; lib (see conf/settings.xml), edited in VESC Tool's parameter UI and persisted by
; the firmware. Lisp uses dashed names ('led-front-pin); the lib treats - and _ as
; equal.

(defun get-config (name)
    (ext-facfg-get (sym2str name))
)

; Refused while test mode runs. Test mode drives the same telemetry globals as the
; CAN parser, so downstream paths that persist a setting fire too - the mall grab
; toggle would write led-on to NVS and keep it. Guarded here rather than at those
; callers: this is the one funnel every write goes through, and a consumer that has
; to ask about test mode is one the simulator is no longer transparent to.
(defun set-config (name value) {
    (if sim-active {
        (if (dbg-active DBG-CFG)
            (dbg DBG-CFG (str-merge "cfg refused (test mode) " (sym2str name))))
    }{
        (if (and (dbg-active DBG-CFG) (not-eq (ext-facfg-get (sym2str name)) value))
            (dbg DBG-CFG (str-merge "cfg " (sym2str name) " = " (to-str value))))
        (ext-facfg-set (sym2str name) value)
    })
})

(defun save-config () {
    (dbg DBG-CFG "cfg store")
    (ext-facfg-store)
    (send-status "Settings saved")
})

(defun restore-config () {
    (dbg-warn "cfg restore defaults")
    (ext-facfg-restore)
    (send-status "Settings restored")
})

(defun print-config ()
    (print "Configuration is in VESC Tool: Float Accessories")
)

; Applies runtime feature changes after the config was edited (from VESC
; Tool or from lisp). Starts/stops the feature loops to match the config.
(defun apply-config () {
    (dbg DBG-CFG "cfg apply")
    (integration-select (get-config 'integration))
    (setq led-on (get-config 'led-on))
    (setq led-highbeam-on (get-config 'led-highbeam-on))
    (setq led-brightness (get-config 'led-brightness))
    (setq led-brightness-highbeam (get-config 'led-brightness-highbeam))
    (setq led-brightness-idle (get-config 'led-brightness-idle))
    (setq led-brightness-status (get-config 'led-brightness-status))

    (if (or (!= (to-i soc-type) (get-config 'soc-type)) (!= (to-i cell-type) (get-config 'cell-type))) {
        (apply-battery-config (get-config 'soc-type) (get-config 'cell-type))
    })

    ; LED loop: reinit in place when running, spawn/stop on enable change
    (if (and (>= led-context-id 0) (!= (get-config 'led-enabled) 1)) {
        (dbg DBG-CFG "cfg stop led")
        (var start-time (systime))
        (setq led-exit-flag t)
        (loopwhile (and led-exit-flag (< (- (systime) start-time) 2000000))
            (yield 10000))
        (if led-exit-flag {
            (dbg-warn "led loop stuck")
            (send-msg "WARNING: LED loop did not exit in time.")
        })
        (setq led-context-id -1)
    })
    (if (and (>= led-context-id 0) (= (get-config 'led-enabled) 1)) {
        (dbg DBG-CFG "cfg reinit led")
        (setq led-reinit-flag t)
    })
    (if (and (= led-context-id -1) (= (get-config 'led-enabled) 1)) {
        (setq led-context-id (spawn led-loop))
        (dbg DBG-CFG "cfg start led")
    })

    ; BMS loop: restart to pick up new pins/settings
    (if (>= bms-context-id 0) {
        (dbg DBG-CFG "cfg stop bms")
        (var start-time (systime))
        (setq bms-exit-flag t)
        (loopwhile (and bms-exit-flag (< (- (systime) start-time) 2000000))
            (yield 10000))
        (if bms-exit-flag {
            (dbg-warn "bms loop stuck")
            (send-msg "WARNING: BMS loop did not exit in time.")
        })
    })
    (setq bms-context-id (if (= (get-config 'bms-enabled) 1) (spawn bms-loop) -1))

    ; Humidity loop
    (if (and (>= humidity-context-id 0) (!= (get-config 'humidity-enabled) 1)) {
        (dbg DBG-CFG "cfg stop hum")
        (var start-time (systime))
        (setq humidity-exit-flag t)
        (loopwhile (and humidity-exit-flag (< (- (systime) start-time) 2000000))
            (yield 10000))
        (if humidity-exit-flag {
            (dbg-warn "hum loop stuck")
            (send-msg "WARNING: Humidity loop did not exit in time.")
        })
        (setq humidity-context-id -1)
    })
    (if (and (= humidity-context-id -1) (= (get-config 'humidity-enabled) 1)) {
        (setq humidity-context-id (spawn humidity-loop))
        (dbg DBG-CFG "cfg start hum")
    })

    ; GNSS: restart to pick up new pins/type
    (if (>= gnss-context-id 0) {
        (dbg DBG-CFG "cfg stop gnss")
        (var start-time (systime))
        (setq gnss-exit-flag t)
        (loopwhile (and gnss-exit-flag (< (- (systime) start-time) 2000000))
            (yield 10000))
        (if gnss-exit-flag {
            (dbg-warn "gnss loop stuck")
            (send-msg "WARNING: GNSS loop did not exit in time.")
        })
        (setq gnss-context-id -1)
    })
    (if (= (get-config 'gnss-enabled) 1) {
        (setq gnss-context-id (spawn gnss-loop))
        (dbg DBG-CFG "cfg start gnss")
    })

    ; Pubmote loop
    (if (and (>= pubmote-context-id 0) (!= (get-config 'pubmote-enabled) 1)) {
        (dbg DBG-CFG "cfg stop rem")
        (var start-time (systime))
        (setq pubmote-exit-flag t)
        (loopwhile (and pubmote-exit-flag (< (- (systime) start-time) 2000000))
            (yield 10000))
        (if pubmote-exit-flag {
            (dbg-warn "rem loop stuck")
            (send-msg "WARNING: Pubmote loop did not exit in time.")
        })
        (setq pubmote-context-id -1)
    })
    (if (and (= pubmote-context-id -1) (= (get-config 'pubmote-enabled) 1)) {
        (setq pubmote-context-id (spawn pubmote-loop))
        (dbg DBG-CFG "cfg start rem")
    })

    ; Logging
    (if (= (get-config 'log-enabled) 1) {
        (if (= log-context-id -1) {
            (setq log-context-id (spawn log-loop))
        }{
            (start-log (get-config 'log-append-gnss) (get-config 'log-rate))
        })
    }{
        (stop-log)
    })
})

; Poll for config writes from VESC Tool and apply them.
(defun config-watch-loop ()
    (loopwhile t {
        (if (ext-facfg-changed) {
            (dbg DBG-CFG "cfg changed in VESC Tool")
            (send-status "Settings updated")
            (apply-config)
        })
        ; Debounced persist of live control changes: recv-control marks
        ; control-store-pending (a systime) instead of storing per slider
        ; sample; write the config once it has settled for ~0.75 s.
        (if (and control-store-pending (> (secs-since control-store-pending) 0.75)) {
            (setq control-store-pending nil)
            (dbg DBG-CFG "cfg store (control settled)")
            (ext-facfg-store)
        })
        (sleep 0.5)
    })
)

; Quick controls from the QML page (brightness / on-off), persisted.
(defun recv-control (in-led-on in-led-highbeam-on in-led-brightness in-led-brightness-highbeam in-led-brightness-idle in-led-brightness-status in-bms-charge-state) {
    ; Throttled: dragging a brightness slider calls this at the QML repeat
    ; rate, and an unthrottled line here would bury everything else.
    (if (dbg-tick DBG-CFG 'cfg-ctl 1.0)
        (dbg DBG-CFG (str-merge "ctl on " (str-from-n (to-i in-led-on) "%d")
            " hb " (str-from-n (to-i in-led-highbeam-on) "%d")
            " bri " (str-from-n (to-float in-led-brightness) "%.2f"))))
    (setq led-on (to-i in-led-on))
    (setq led-highbeam-on (to-i in-led-highbeam-on))
    (setq led-brightness (to-float in-led-brightness))
    (setq led-brightness-highbeam (to-float in-led-brightness-highbeam))
    (setq led-brightness-idle (to-float in-led-brightness-idle))
    (setq led-brightness-status (to-float in-led-brightness-status))

    (set-config 'led-on (to-i in-led-on))
    (set-config 'led-highbeam-on (to-i in-led-highbeam-on))
    (set-config 'led-brightness (to-float in-led-brightness))
    (set-config 'led-brightness-highbeam (to-float in-led-brightness-highbeam))
    (set-config 'led-brightness-idle (to-float in-led-brightness-idle))
    (set-config 'led-brightness-status (to-float in-led-brightness-status))
    ; Applied to RAM above; the LED loop picks it up on its next tick. Persist
    ; is deferred/debounced (config-watch-loop) so dragging a slider doesn't
    ; store the whole config to NVS on every sample - that was the lag.
    (setq control-store-pending (systime))

    (if (and (= (get-config 'bms-enabled) 1) (> bms-type 1) (!= bms-charge-state in-bms-charge-state) ) {
        (setq bms-charge-state (if (= bms-charge-state 1) 1 0))
        (setq bms-user-cmd 0x64)
    })
})

(defun bms-trigger-factory-init () {
    (if (and (= (get-config 'bms-enabled) 1) (> bms-type 1) (= bms-rs485-chip 1) ) {
        (setq bms-user-cmd 0x0e)
    } {
        (dbg-warn "bms factory init needs an enabled crypto BMS on an RS485 chip")
    })
})

(defun send-control () {
    (var config-string "control ")

    (setq config-string (
        str-merge
        config-string
        (str-from-n (to-i led-on) "%d ")
        (str-from-n (to-i led-highbeam-on) "%d ")
        (str-from-n led-brightness "%.2f ")
        (str-from-n led-brightness-highbeam "%.2f ")
        (str-from-n led-brightness-idle "%.2f ")
        (str-from-n led-brightness-status "%.2f ")
        (str-from-n (to-i bms-charge-state) "%d ")
    ))

    (send-data config-string)
})

(defun send-keys (key-list counter-list) {
    (print "Received key: ")
    (print key-list)
    (setq key-list (split-list key-list 4))
    (set-config 'bms-key-a (pack-bytes-to-uint32 (ix key-list 0)))
    (set-config 'bms-key-b (pack-bytes-to-uint32 (ix key-list 1)))
    (set-config 'bms-key-c (pack-bytes-to-uint32 (ix key-list 2)))
    (set-config 'bms-key-d (pack-bytes-to-uint32 (ix key-list 3)))
    (print "Received counter: ")
    (print counter-list)
    (setq counter-list (split-list counter-list 4))
    (set-config 'bms-counter-a (pack-bytes-to-uint32 (ix counter-list 0)))
    (set-config 'bms-counter-b (pack-bytes-to-uint32 (ix counter-list 1)))
    (set-config 'bms-counter-c (pack-bytes-to-uint32 (ix counter-list 2)))
    (set-config 'bms-counter-d (pack-bytes-to-uint32 (ix counter-list 3)))
    (save-config)
})

(defun accept-tos() {
    (set-config 'accept-tos 1)
    (ext-facfg-store)
})

(defun status () {
      ; Built as a list and joined once: accumulating with str-merge copies the
      ; growing string every step, which at the QML poll rate was the main source
      ; of lbm memory churn between GC cycles.
    ; GNSS: fix flag, seconds since the last sentence, hdop, speed (m/s).
    ; The firmware stamps the age on every decoded sentence (fix or not),
    ; so a fix additionally needs a non-zero position.
    (var gnss-ll (gnss-lat-lon))
    (var gnss-age-s (gnss-age))
    (var gnss-fix (if (and (< gnss-age-s 5.0) (or (!= (ix gnss-ll 0) 0.0) (!= (ix gnss-ll 1) 0.0))) 1 0))
    (send-data (str-join (list
        "float-stats"
        (str-from-n (integration-connection-state) "%d")
        (str-from-n (is-pubmote-connected) "%d")
        (str-from-n (if (< (secs-since bms-last-activity-time) 1) 1 0) "%d")
        (str-from-n bms-status "%d")
        (str-from-n bms-battery-type "%d")
        (str-from-n bms-battery-cycles "%d")
        (str-from-n (if (> (conf-get 'wifi-mode) 0) (wifi-get-chan) -1) "%d")
        (str-from-n hum "%.0f")
        (str-from-n hum-temp "%.2f")
        (str-from-n (get-bms-val 'bms-hum) "%.0f")
        (str-from-n (get-bms-val 'bms-temp-hum) "%.0f")
        (str-from-n (if log-running 1 0) "%d")
        (str-from-n gnss-fix "%d")
        (str-from-n (to-float (min gnss-age-s 9999.0)) "%.1f")
        (str-from-n (gnss-hdop) "%.1f")
        (str-from-n (gnss-speed) "%.2f")
    ) " "))

    (if (= (is-pubmote-connected) 1) {
        (send-data (str-merge "pubmote-info " (to-str (ix pubmote-version 0)) "." (to-str (ix pubmote-version 1)) "." (to-str (ix pubmote-version 2))))
    })
})

(defun input-state () {
    (send-data (str-join (list
        "input-state"
        (str-from-n (is-pubmote-connected) "%d")
        (str-from-n pubmote-last-jsy "%.3f")
        (str-from-n pubmote-last-jsx "%.3f")
        (str-from-n pubmote-last-bt-c "%d")
        (str-from-n pubmote-last-bt-z "%d")
        (str-from-n pubmote-last-is-rev "%d")
    ) " "))
})

; Live GNSS snapshot for the QML preview: fix flag, lat, lon, hdop,
; speed (m/s) and sentence age. Same source as the status row.
(defun gnss-state () {
    (var ll (gnss-lat-lon))
    (var age-s (gnss-age))
    (var fix (if (and (< age-s 5.0) (or (!= (ix ll 0) 0.0) (!= (ix ll 1) 0.0))) 1 0))
    (send-data (str-join (list
        "gnss-state"
        (str-from-n fix "%d")
        (str-from-n (ix ll 0) "%.6f")
        (str-from-n (ix ll 1) "%.6f")
        (str-from-n (gnss-hdop) "%.1f")
        (str-from-n (gnss-speed) "%.2f")
        (str-from-n (to-float (min age-s 9999.0)) "%.1f")
    ) " "))
})

@const-end
