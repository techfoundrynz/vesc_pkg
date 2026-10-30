@const-start

; LED state. Rendering is done by the esp_led_strip native lib; this module
; only keeps the configuration cache and the state-machine variables the
; LED loop uses to drive it.

; esp_led effect / palette / type / timing / turn-mode ids are defined once in
; the esp_led_strip library (../lib_esp_led_strip/esp_led_defs.lisp) and imported
; by float_accessories.lisp before this module, so they cannot drift from the
; lib's C enums.

(def led-loop-delay)
;config vars
(def led-enabled)
(def led-mode)
(def led-mode-idle)
(def led-mode-status)
(def led-mode-startup)
(def led-mode-button)
(def led-mode-footpad)
(def led-mall-grab-enabled)
(def led-brake-light-enabled)
(def led-brake-light-min-amps)
(def idle-timeout)
(def idle-timeout-shutoff)
(def led-status-pin)
(def led-status-num)
(def led-status-type)
(def led-status-white-output)
(def led-status-reversed)
(def led-status-timing)
(def led-front-pin)
(def led-front-num)
(def led-front-type)
(def led-front-white-output)
(def led-front-reversed)
(def led-front-timing)
(def led-front-highbeam-mode)
(def led-front-highbeam-pos)
(def led-front-highbeam-min)
(def led-front-highbeam-max)
(def led-rear-pin)
(def led-rear-num)
(def led-rear-type)
(def led-rear-white-output)
(def led-rear-reversed)
(def led-rear-timing)
(def led-rear-highbeam-mode)
(def led-rear-highbeam-pos)
(def led-rear-highbeam-min)
(def led-rear-highbeam-max)
(def led-button-pin)
(def led-button-timing)
(def led-footpad-pin)
(def led-footpad-num)
(def led-footpad-type)
(def led-footpad-white-output)
(def led-footpad-reversed)
(def led-footpad-timing)
(def led-startup-timeout)
(def led-dim-on-highbeam-ratio 0.0)
(def led-max-brightness)
(def led-show-battery-charging 0)
(def led-front-highbeam-pin)
(def led-rear-highbeam-pin)

;runtime vars
(def led-current-brightness 0.0)
(def direction 1)
(def led-mall-grab 0)

; Last time both footpads read engaged. update-status-leds stamps this every
; tick that switch-state is 3, so (secs-since footpad-ok-time) is how long a pad
; has been off - which is what the at-speed footpad warning debounces on.
(def footpad-ok-time 0)
; Last time the board was actually moving. The riding display is held for
; rpm-fast-hold after it drops below the threshold, so reversing - which passes
; through zero - does not fall back to the footpad bar for the crossing.
(def rpm-fast-time 0)
(def rpm-fast-hold 1.0)
; Long enough to ride out the blips a weight shift puts on one sensor. A feel
; constant, so it is tuned here rather than exposed as a setting.
(def footpad-warn-delay 0.25)

; ---- Loop state ---------------------------------------------------------
; Locals of what used to be one 380-line led-loop. Splitting it into phases means
; the values it carried between parts have to outlive one function. Each is written
; by one phase and read by later ones, in the order led-loop calls them.

; Set by led-loop before the phases run.
(def have-segs nil)
(def led-loop-delay-sec 0.02)
(def led-next-run-time 0)

; led-track-direction: commit window for a reversal.
(def prev-direction 1)
(def direction-change-start-time 0)
(def direction-change-window 0.25)

; led-track-mall-grab: footpad press timing while nose-up.
(def mall-grab-press-start 0)
(def mall-grab-press-active nil)

; led-decide: what the drawing phases render.
(def current-led-mode 0)
(def last-activity-sec 0.0)
(def can-activity-sec 0.0)
(def front-bri 0)
(def rear-bri 0)
(def status-bri 0)
(def aux-bri 0)
; head faces the direction of travel; tail trails it. Both are one of
; seg-front / seg-rear, chosen by `direction`, with brightnesses to match.
(def head-seg -1)
(def tail-seg -1)
(def head-bri 0)
(def tail-bri 0)
(def hb-front nil)
(def hb-rear nil)
(def hb-frac 0.0)
(def lights-off nil)
(def braking nil)

; esp_led segment index per strip, -1 when the strip is not present
(def seg-front -1)
(def seg-rear -1)
(def seg-status -1)
(def seg-footpad -1)
(def seg-button -1)

@const-end
