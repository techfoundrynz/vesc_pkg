(import "fa_cfg/fa_cfg_esp32c3.bin" 'facfg-esp32c3)
(import "../lib_esp_led_strip/esp_led_strip/esp_led_strip_esp32c3.bin" 'esp_led-esp32c3)
(import "fa_cfg/fa_cfg_esp32c6.bin" 'facfg-esp32c6)
(import "../lib_esp_led_strip/esp_led_strip/esp_led_strip_esp32c6.bin" 'esp_led-esp32c6)
(import "fa_cfg/fa_cfg_esp32s3.bin" 'facfg-esp32s3)
(import "../lib_esp_led_strip/esp_led_strip/esp_led_strip_esp32s3.bin" 'esp_led-esp32s3)
(import "fa_cfg/fa_cfg_esp32s31.bin" 'facfg-esp32s31)
(import "../lib_esp_led_strip/esp_led_strip/esp_led_strip_esp32s31.bin" 'esp_led-esp32s31)

@const-start
; Boot state protocol, shared with QML's numbered boot states:
; 1 loading code, 2 loading native libraries, 3 creating image,
; 4 starting accessories, 5 ready, 6 image creation failed.
(def fa-boot-state 1)
(defun fa-boot-status ()
    (send-data (str-merge "fa-boot-state " (str-from-n fa-boot-state "%d"))))
(defun fa-set-boot-state (state) {
    (setq fa-boot-state state)
    (fa-boot-status)
})
(fa-boot-status)

; Every bundled file must be imported here: VESC Tool ignores imports inside
; imported files. The firmware binds each tag when its line runs, so all
; imports come first and lib/entry/*.lisp then evaluate them per feature.
; core
(import "lib/debug.lisp" 'debug)
(import "lib/version-gen.lisp" 'version-gen)
(import "lib/utils.lisp" 'utils)
(import "lib/settings-vars.lisp" 'settings-vars)
(import "lib/settings.lisp" 'settings)
(import "lib/ble-client.lisp" 'ble-client)
; bms
(import "lib/bms-vars.lisp" 'bms-vars)
(import "lib/bms.lisp" 'bms)
(import "lib/bms-backend.lisp" 'bms-backend)
(import "lib/adapters/ow-bms-vars.lisp" 'ow-bms-vars)
(import "lib/adapters/ow-bms.lisp" 'ow-bms)
(import "lib/adapters/ssbms.lisp" 'ssbms)
(import "lib/adapters/ssbms-uart.lisp" 'ssbms-uart)
(import "lib/adapters/ssbms-ble.lisp" 'ssbms-ble)
; vehicle
(import "lib/vehicle.lisp" 'vehicle)
(import "lib/lighting-control.lisp" 'lighting-control)
(import "lib/can.lisp" 'can)
(import "lib/adapters/refloat.lisp" 'refloat-adapter)
; telemetry
(import "lib/logger.lisp" 'logger)
(import "lib/gnss.lisp" 'gnss)
(import "lib/humidity.lisp" 'humidity)
; led
(import "../lib_esp_led_strip/esp_led_defs.lisp" 'esp_led-defs)
(import "../lib_esp_led_strip/esp_led_version.lisp" 'esp_led-version-defs)
(import "lib/led-vars.lisp" 'led-vars)
(import "lib/led.lisp" 'led)
; pubmote
(import "pubmote/pubmote-consts.lisp" 'pubmote-consts)
(import "pubmote/pubmote-vars.lisp" 'pubmote-vars)
(import "pubmote/pubmote-utils.lisp" 'pubmote-utils)
(import "pubmote/pubmote.lisp" 'pubmote)
; app
(import "lib/commands.lisp" 'commands)
(import "lib/sim.lisp" 'sim)
; feature entry points
(import "lib/entry/core.lisp" 'entry-core)
(import "lib/entry/bms.lisp" 'entry-bms)
(import "lib/entry/vehicle.lisp" 'entry-vehicle)
(import "lib/entry/telemetry.lisp" 'entry-telemetry)
(import "lib/entry/led.lisp" 'entry-led)
(import "lib/entry/pubmote.lisp" 'entry-pubmote)
(import "lib/entry/app.lisp" 'entry-app)

(read-eval-program entry-core)
(print "FA loaded core")
(read-eval-program entry-bms)
(print "FA loaded bms")
(read-eval-program entry-vehicle)
(print "FA loaded vehicle")
(read-eval-program entry-telemetry)
(print "FA loaded telemetry")
(read-eval-program entry-led)
(print "FA loaded led")
(read-eval-program entry-pubmote)
(print "FA loaded pubmote")
(read-eval-program entry-app)
(print "FA loaded app")

(defun load-native-libs () {
    (check-platform)
    (var target (sysinfo 'hw-target))
    (var libs (cond
        ((= (str-cmp target "esp32c3") 0) (list facfg-esp32c3 esp_led-esp32c3))
        ((= (str-cmp target "esp32c6") 0) (list facfg-esp32c6 esp_led-esp32c6))
        ((= (str-cmp target "esp32s3") 0) (list facfg-esp32s3 esp_led-esp32s3))
        ((= (str-cmp target "esp32s31") 0) (list facfg-esp32s31 esp_led-esp32s31))
        (t nil)
    ))
    (if (eq libs nil) {
        (exit-error (str-merge "No native libs for target " target " (supported: esp32c3, esp32c6, esp32s3, esp32s31)"))
    })
    (var r-cfg (trap (load-native-lib (ix libs 0))))
    (if (eq (ix r-cfg 0) 'exit-error)
        (exit-error (str-merge "fa_cfg load: " (to-str (ix r-cfg 1)))))
    (var r-probe (trap (ext-facfg-get "led-enabled")))
    (if (eq (ix r-probe 0) 'exit-error)
        (exit-error (str-merge "fa_cfg unavailable: " (to-str (ix r-probe 1)))))

    (var r-led (trap (load-native-lib (ix libs 1))))
    (if (eq (ix r-led 0) 'exit-error)
        (dbg-err (str-merge "esp_led load: " (to-str (ix r-led 1)))))
    (dbg DBG-CORE (str-merge "libs loaded, esp_led " (to-str esp_led-version)))
})

; Boot timings: the time spent in each of the three phases of boot, and the total time
(def boot-t-main 0.0)
(def boot-t-libs 0.0)
(def boot-t-led 0.0)

(defun main () (run-main t))

; A saved image must reload native code, whose executable addresses can change.
; The first parse has already loaded it before saving the extension table.
(defun run-main (reload-libs) {
    (setq boot-t-main (secs-since 0))
    (if reload-libs {
        (fa-set-boot-state 2)
        (load-native-libs)
    })
    (fa-set-boot-state 4)
    (setup)
    (init)
    (fa-set-boot-state 5)
    (print (str-merge "Boot " (str-from-n (secs-since 0) "%.3f") "s"
        " (code " (str-from-n boot-t-main "%.3f")
        " libs " (str-from-n (- boot-t-libs boot-t-main) "%.3f")
        " led " (str-from-n (- boot-t-led boot-t-libs) "%.3f")
        " rest " (str-from-n (- (secs-since 0) boot-t-led) "%.3f") ")"))
})
; Native loops avoid a persistent macro closure per monitor on the small C3 heap.
(defun spawn-with-restart (name stack-size func) {
    (var monitor-fn (fn ()
        (loop () t {
            (if stack-size
                (spawn-trap stack-size func)
                (spawn-trap func))
            (dbg DBG-CORE (str-merge "spawn " name))
            (recv   ((exit-error (? tid) (? e)) {
                        ; Always printed: a worker dying is the single most
                        ; useful thing to see, and it is followed by a >=1 s
                        ; blackout of whatever that loop drives.
                        (dbg-err (str-merge name " " (to-str e)))
                    })
                    ((exit-ok (? tid) (? v)) {
                        (dbg DBG-CORE (str-merge "exit " name))
                    }))
            (sleep 1.0)
        })
    ))
    (if stack-size
        (spawn stack-size monitor-fn)
        (spawn monitor-fn))
})

; The event handler must be registered with the worker thread's id each time it
; is (re)spawned: events are delivered to the registered thread's mailbox, and
; a recv only consumes matching messages. Registering the monitor thread (whose
; recv only matches exit messages) would silently swallow every event.
(defun spawn-event-handler-with-restart () {
    (spawn (fn ()
        (loop () t {
            (event-register-handler (spawn-trap event-handler))
            (dbg DBG-CORE "spawn event-handler")
            (recv   ((exit-error (? tid) (? e))
                        (dbg-err (str-merge "event-handler " (to-str e)))
                    )
                    ((exit-ok (? tid) (? v)) 'ok))
            (sleep 1.0)
        })
    ))
})

(defun check-platform () {
    ; fw-num is a global (settings-vars.lisp): bms.lisp gates two crypto
    ; paths on it, and as a local `var` here it was unbound by the time the
    ; BMS loop read it.
    (setq fw-num (+ (first (sysinfo 'fw-ver)) (* (second (sysinfo 'fw-ver)) 0.01)))
    (if (!= (str-cmp (to-str (sysinfo 'hw-type)) "hw-express") 0) {
        (exit-error "Not running on hw-express")
    })

    (if (< fw-num 7.00) (exit-error "hw-express needs to be running 7.00"))
})

(defun setup () {
    (check-platform)
    (print (str-merge "Float Accessories " (to-str (get-version))
        " on " (sysinfo 'hw-target)
        " fw " (str-from-n fw-num "%.2f")))

    (setq led-last-activity-time (systime))

    (setq boot-t-libs (secs-since 0))
    (integration-select (get-config 'integration))
    (apply-battery-config (get-config 'soc-type) (get-config 'cell-type))

    (setq led-on (get-config 'led-on))
    (setq led-highbeam-on (get-config 'led-highbeam-on))
    (setq led-brightness (get-config 'led-brightness))
    (setq led-brightness-highbeam (get-config 'led-brightness-highbeam))
    (setq led-brightness-idle (get-config 'led-brightness-idle))
    (setq led-brightness-status (get-config 'led-brightness-status))

    ; Lighting first, and synchronously. Everything after this either spawns a
    ; thread competing for the evaluator or blocks it outright (CAN discovery,
    ; BMS/GNSS UART, humidity I2C), so anything started before the strips are
    ; defined delays the first frame. Defining them here also gets the lib's own
    ; FreeRTOS render thread running before the loop has had a slice.
    (if (= (get-config 'led-enabled) 1) {
        (var r (trap (led-start)))
        (if (eq (ix r 0) 'exit-error)
            (dbg-err (str-merge "led start " (to-str (ix r 1)))))
        (setq led-context-id (spawn-with-restart "led-loop" nil led-loop))
    })
    (setq boot-t-led (secs-since 0))

    (spawn-event-handler-with-restart)
    (enable-app-data-events)
    (event-enable 'event-esp-now-rx)
})

; Always inject the pubmote callbacks. Its own form, not part of init: init is
; the last thing defined, with the least Lisp heap left, and a top-level form
; and its expansion are both live while it is defined.
(defun init-pubmote ()
    (pubmote-setup (list
        (cons 'vehicle-type PUBMOTE_VEHICLE_ONEWHEEL)
        (cons 'on-control (fn (jsy jsx bt-c bt-z is-rev)
            (remote-input jsy jsx bt-c bt-z is-rev)))
        (cons 'get-telemetry (fn ()
            (list fault-code pitch-angle roll-angle state switch-state vin rpm speed tot-current duty-cycle-now (phase-utilization) (battery-utilization) distance-abs fet-temp-filtered motor-temp-filtered odometer battery-percent-remaining)))
        (cons 'send-msg send-msg)
        (cons 'get-config get-config)
        (cons 'set-config set-config)
        (cons 'save-config (fn () (ext-facfg-store)))
        (cons 'on-pairing-state (fn (state) (send-data (str-merge "pairing-status " (to-str state)))))
        (cons 'log (fn (level text)
            (cond ((= level PUBMOTE_LOG_ERROR) (dbg-err text))
                  ((= level PUBMOTE_LOG_WARN) (dbg-warn text))
                  ((= level PUBMOTE_LOG_INFO) (print text))
                  (t (dbg DBG-REM text)))))
        (cons 'log-active (fn () (dbg-active DBG-REM))))))

(defun init () {
    ; The heartbeat thread first, so a crash in any loop spawned below is
    ; visible as a dead tick counter straight away.
    (spawn-with-restart "dbg-loop" nil dbg-loop)

    ; The LED loop is not spawned here - setup() brings the strips up and
    ; starts it before any of this, so the lights are already on while CAN
    ; discovery and the rest of the peripherals come up behind them.
    (setq can-context-id (spawn-with-restart "can-loop" nil can-loop))
    (init-pubmote)
    (if (= (get-config 'pubmote-enabled) 1){
        (setq pubmote-context-id (spawn-with-restart "pubmote-loop" nil pubmote-loop))
    })
    (bms-start-backend)

    (if (= (get-config 'humidity-enabled) 1) (setq humidity-context-id (spawn-with-restart "humidity-loop" nil humidity-loop)))

    (if (= (get-config 'gnss-enabled) 1) (setq gnss-context-id (spawn-with-restart "gnss-loop" nil gnss-loop)))


    (if (= (get-config 'log-enabled) 1) (setq log-context-id (spawn-with-restart "log-loop" 50 log-loop)))

    (spawn-with-restart "config-watch" nil config-watch-loop)
})

@const-end

; Register native extension names before saving the table. Otherwise each warm
; boot appends their names to flash again. main reloads/rebinds their executable
; code on image boots; this first start reuses the libraries just loaded here.
(fa-set-boot-state 2)
(load-native-libs)
(fa-set-boot-state 3)
(print "FA saving startup image")
{
(var image-result (trap (image-save)))
(if (or (eq (ix image-result 0) 'exit-error) (not (ix image-result 1))) {
    (fa-set-boot-state 6)
    (exit-error "Could not save startup image")
})
}
(print "FA startup image saved")
(run-main nil)
