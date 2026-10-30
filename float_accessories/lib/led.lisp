; Appearance cache: the last look pushed to each segment, so a steady state costs
; no extension calls at all. Flat byte buffers rather than a tuple per segment -
; the compare runs on every segment every tick, and building a tuple would
; allocate at loop rate. Above @const-start deliberately: bufset cannot write a
; buffer that lives in the constant heap. Stride 8: fx, pal, spd, bri, fx-val,
; then the cycle time as a u16 at +6, where the stride keeps it 2-byte aligned.
(def seg-cache (bufcreate 64))
; Colours, u32 per segment, in their own buffer for the 4-byte slots.
(def seg-cache-col (bufcreate 32))
; Overlay (embedded highbeam) brightness per segment. u16 so the post-reset
; 0xFFFF cannot collide with a real 0..255 brightness - as a byte it would,
; and a highbeam that came up at full brightness would then be skipped.
(def seg-cache-ov (bufcreate 16))

; Intended appearance for this tick, same layout as seg-cache. Drawing writes here
; and nowhere else; seg-flush is the only caller of the lib and visits each segment
; once. That makes one-write-per-segment structural - as a convention it broke
; twice (the charging gauge, then the brake light), each writing a segment the mode
; had already written, so neither cache entry ever hit and the strip alternated.
(def seg-want-look (bufcreate 64))
(def seg-want-col (bufcreate 32))
; 1 = some rule expressed an intent for this segment this tick. Segments nobody
; claims are left exactly as they are rather than being blanked.
(def seg-want-set (bufcreate 8))

@const-start

; LED control over the esp_led_strip native lib. The lib owns the framebuffers,
; render thread and driver; this module runs the state machine (direction, idle,
; mall grab, brake light, charging) and sets per-segment appearance through the
; ext-esp_led-* extensions. Strips sharing a pin are chained by offset.
;
; A strip's timing config doubles as its enable: 0 = disabled, 1+ = preset + 1.
; Highbeam mode 1 drives a PWM pin, mode 2 drives LEDs embedded in the strip as
; overlay pixels, at the positions packed one per byte in highbeam-pos, mapped
; onto the configured min-max drive range.

; Every LED setting, copied into the RAM cache the loop reads. Each name is both
; the config key and the variable it lands in, so this is a list and a loop rather
; than 55 assignments that could drift. Quoted, so the list lives in the const
; heap. Adding one: put the key here, declare the variable in led-vars.lisp.
(def led-setting-keys '(
    ; general
    led-enabled led-on led-highbeam-on led-mode led-mode-idle
    led-mode-status led-mode-startup led-mode-button led-mode-footpad
    ; behaviour
    led-mall-grab-enabled led-brake-light-enabled led-brake-light-min-amps
    idle-timeout idle-timeout-shutoff led-startup-timeout led-loop-delay
    led-show-battery-charging
    ; brightness
    led-brightness led-brightness-highbeam led-brightness-idle
    led-brightness-status led-max-brightness led-dim-on-highbeam-ratio
    ; status
    led-status-pin led-status-num led-status-type led-status-white-output led-status-reversed
    led-status-timing
    ; front
    led-front-pin led-front-num led-front-type led-front-white-output led-front-reversed
    led-front-timing led-front-highbeam-mode led-front-highbeam-pos
    led-front-highbeam-min led-front-highbeam-max led-front-highbeam-pin
    ; rear
    led-rear-pin led-rear-num led-rear-type led-rear-white-output led-rear-reversed
    led-rear-timing led-rear-highbeam-mode led-rear-highbeam-pos
    led-rear-highbeam-min led-rear-highbeam-max led-rear-highbeam-pin
    ; footpad
    led-footpad-pin led-footpad-num led-footpad-type led-footpad-white-output led-footpad-reversed
    led-footpad-timing
    ; button
    led-button-pin led-button-timing
))

(defun load-led-settings ()
    (loopforeach k led-setting-keys (setvar k (get-config k))))

; ---- Segment setup ------------------------------------------------------
; Chain state, rebuilt on every led-setup-segments. Module-level so the per-strip
; work below can be one function called five times.
(def seg-idx 0)
(def pin-offsets nil) ; assoc pin -> next chain offset
(def pin-timings nil) ; assoc pin -> chain timing preset
(def pin-types nil)   ; assoc pin -> chain colour order

(defun next-offset (pin len) {
    (var entry (assoc pin-offsets pin))
    (var off (if (eq entry nil) 0 entry))
    (setq pin-offsets (acons pin (+ off len) pin-offsets))
    off
})

; Segments chained on one pin share one data line, so the whole chain uses the
; timing of the first strip defined on that pin. Config timing values are
; esp_led preset + 1 (0 = strip disabled).
(defun chain-timing (pin timing) {
    (var entry (assoc pin-timings pin))
    (if (eq entry nil) {
        (setq pin-timings (acons pin (- timing 1) pin-timings))
        (- timing 1)
    } entry)
})

; The chain's colour order, claimed by the first strip on the pin. Strips with a
; colour-order setting keep their own - the lib allows different byte orders along
; a chain, only pixel width has to agree. Recorded for the button LED, which has
; no setting of its own: hardcoded GRB behind an RGBW strip is exactly the
; disagreement the lib refuses, and it refuses the whole chain.
(defun chain-type (pin type) {
    (var entry (assoc pin-types pin))
    (if (eq entry nil) {
        (setq pin-types (acons pin type pin-types))
        type
    } entry)
})

; Logged unconditionally at DBG-LED: "my strip doesn't light up" is almost always
; a segment that was never defined because timing was 0, the pin was -1 or the
; LED count was 0 - and that is invisible from the outside.
(defun log-seg (i name pin type num off timing) {
    (dbg DBG-LED (str-merge "led seg " (str-from-n i "%d") " " name
        " pin " (str-from-n pin "%d")
        " type " (str-from-n type "%d")
        " n " (str-from-n num "%d")
        " off " (str-from-n off "%d")
        " tim " (str-from-n timing "%d")))
})

(defun log-skip (name pin num timing) {
    (if (dbg-active DBG-LED)
        (dbg DBG-LED (str-merge "led seg - " name
            " pin " (str-from-n pin "%d")
            " n " (str-from-n num "%d")
            " tim " (str-from-n timing "%d"))))
})

; Embedded highbeam positions, unpacked from the config int: one per byte, 255 =
; unused. Filtered against the strip rather than passed through - the lib
; type-errors on a position at or past the segment footprint, and an unhandled one
; took the LED loop down for good (respawned every second, strips dark). Reachable
; from the UI by lowering an LED count under a preset's positions. Two passes,
; because dropping one shrinks the footprint the rest are measured against.
; Duplicates are left alone: they cost one tail pixel the renderer never fills.
(defun hb-positions (packed num) {
    (var lst nil)
    (looprange k 0 4 {
        (var p (bitwise-and (shr packed (* k 8)) 0xFF))
        (if (!= p 0xFF) (setq lst (append lst (list p))))
    })
    ; Anything still out of range after two passes is caught by led-start's trap.
    (looprange k 0 2 {
        (var limit (+ num (length lst)))
        (var keep nil)
        (loopforeach p lst (if (< p limit) (setq keep (append keep (list p)))))
        (if (< (length keep) (length lst)) (dbg-warn "led hb pos range"))
        (setq lst keep)
    })
    lst
})

(defun overlay-def (seg ps) {
    (cond
        ((= (length ps) 1) (ext-esp_led-seg-overlay-def seg (ix ps 0)))
        ((= (length ps) 2) (ext-esp_led-seg-overlay-def seg (ix ps 0) (ix ps 1)))
        ((= (length ps) 3) (ext-esp_led-seg-overlay-def seg (ix ps 0) (ix ps 1) (ix ps 2)))
        ((= (length ps) 4) (ext-esp_led-seg-overlay-def seg (ix ps 0) (ix ps 1) (ix ps 2) (ix ps 3)))
    )
})

; Define one strip, or not. Returns the index it claimed, or -1 - what the seg-*
; globals want and what every seg- helper treats as absent. Configured means
; timing, pin and count are all set, so the skip logs all three. adopt-type is for
; the button LED alone: see chain-type.
(defun led-def-strip (name pin num type timing hb-mode hb-pos adopt-type) {
    (if (not (and (> timing 0) (>= pin 0) (> num 0))) {
        (log-skip name pin num timing)
        -1
    }{
        ; Overlay pixels sit inside the segment's footprint, so they have to be
        ; counted in the offset the next strip on this chain starts at.
        (var ps (if (= hb-mode 2) (hb-positions hb-pos num) nil))
        (var off (next-offset pin (+ num (length ps))))
        (var tim (chain-timing pin timing))
        (var chained (chain-type pin type))
        (var typ (if adopt-type chained type))
        (var i seg-idx)
        (if (dbg-active DBG-LED) {
            (log-seg i name pin typ num off tim)
            (if (= hb-mode 2)
                (dbg DBG-LED (str-merge "led hb " name
                    " pos " (to-str ps))))
        })
        (ext-esp_led-seg-def i pin typ num off tim)
        (if ps (overlay-def i ps))
        (setq seg-idx (+ seg-idx 1))
        i
    })
})

; Define the esp_led segments from the config. Strips sharing a pin become one
; chain: each next strip on the pin gets the accumulated pixel offset. Chain
; order matches the original wiring convention: status, front, rear, then footpad
; and button.
(defun led-setup-segments () {
    (ext-esp_led-deinit)
    ; deinit/init resets the lib's segment state, so nothing the appearance
    ; cache remembers is true of the new segments.
    (seg-cache-reset)
    (setq seg-idx 0)
    (setq pin-offsets nil)
    (setq pin-timings nil)
    (setq pin-types nil)

    ; The button LED has no LED-count setting - it is always one pixel - and no
    ; colour-order setting, hence the 1 and the adopt-type flag.
    (setq seg-status (led-def-strip "status" led-status-pin led-status-num
        led-status-type led-status-timing 0 0 nil))
    (setq seg-front (led-def-strip "front" led-front-pin led-front-num
        led-front-type led-front-timing led-front-highbeam-mode led-front-highbeam-pos nil))
    (setq seg-rear (led-def-strip "rear" led-rear-pin led-rear-num
        led-rear-type led-rear-timing led-rear-highbeam-mode led-rear-highbeam-pos nil))
    (setq seg-footpad (led-def-strip "footpad" led-footpad-pin led-footpad-num
        led-footpad-type led-footpad-timing 0 0 nil))
    (setq seg-button (led-def-strip "button" led-button-pin 1
        TYPE-GRB led-button-timing 0 0 t))

    ; Whether the lib is actually rendering, which is not the same as having
    ; defined segments: init rejects a chain whose segments disagree on colour
    ; depth or timing, and every strip goes dark together when it does.
    (var started nil)
    (if (> seg-idx 0) {
        (var r (trap (ext-esp_led-init seg-idx)))
        (if (eq (ix r 0) 'exit-error)
            (dbg-err (str-merge "led init " (to-str (ix r 1))))
            {
                (setq started t)
                (dbg DBG-LED (str-merge "led init " (str-from-n seg-idx "%d") " segs"))
            })
    } {
        ; Lighting is enabled but nothing was configured - the loop will run and
        ; do nothing at all, which looks identical to a crash.
        (dbg-warn "led no strip configured")
    })

    ; Reverse flags have to go on after init, which is why they are not part of
    ; led-def-strip. The button LED is one pixel, so it has no flag.
    (if started {
        (ext-esp_led-fps 60)
        ; (ext-esp_led-refresh 250)
        ; Front and rear ease their colour instead of switching it, so a reversal
        ; crossfades white/red rather than swapping in one frame. The rate is
        ; 32nds of the remaining gap per 33 ms, and the render thread runs at
        ; 60 fps, so 10 settles a full white-to-red swing in about 0.5 s. Left
        ; instant everywhere else: the status bar's colours are information, and
        ; an alarm that fades in reads as a slow alarm.
        (if (>= seg-front 0) (ext-esp_led-seg-color-fade seg-front 10))
        (if (>= seg-rear 0) (ext-esp_led-seg-color-fade seg-rear 10))
        (if (>= seg-status 0) (ext-esp_led-seg-reverse seg-status led-status-reversed))
        (if (>= seg-front 0) (ext-esp_led-seg-reverse seg-front led-front-reversed))
        (if (>= seg-rear 0) (ext-esp_led-seg-reverse seg-rear led-rear-reversed))
        (if (>= seg-footpad 0) (ext-esp_led-seg-reverse seg-footpad led-footpad-reversed))
    })

    ; PWM highbeams (highbeam mode 1)
    (if (and (= led-front-highbeam-mode 1) (>= led-front-highbeam-pin 0)) {
        (pwm-start 1000 0.0 0 led-front-highbeam-pin 10)
    })
    (if (and (= led-rear-highbeam-mode 1) (>= led-rear-highbeam-pin 0)) {
        (pwm-start 1000 0.0 1 led-rear-highbeam-pin 10)
    })

    started
})

; Strip bring-up state. Globals rather than led-loop locals because setup()
; brings the strips up before the loop is spawned, and a loop respawned by
; its restart monitor must not deinit/reinit a strip that is already
; rendering - that shows up as a blink after every crash.
(def led-setup-done nil)
(def led-have-segs nil)

; Read the config into the cache, then define and start the segments. Called from
; setup() so the strips light as early as they can, and by led-loop for the cases
; setup() did not cover. Idempotent: a second caller gets the first one's result.
(defun led-start () {
    (if (not led-setup-done) {
        (load-led-settings)
        ; Trapped, and the flag is set either way. Leaving it clear so the next
        ; caller retries turned one config the lib refuses into a permanent
        ; deinit/redefine/throw cycle with the strips dark, because the LED
        ; loop's restart monitor respawns it every second. A settings change
        ; clears the flag through led-teardown and gets a real retry.
        (var r (trap (led-setup-segments)))
        (setq led-have-segs (if (eq (ix r 0) 'exit-error) {
            (dbg-err (to-str (ix r 1)))
            nil
        } (ix r 1)))
        (setq led-setup-done t)
    })
    led-have-segs
})

(defun led-teardown () {
    (setq led-setup-done nil)
    (ext-esp_led-deinit)
    (if (and (= led-front-highbeam-mode 1) (>= led-front-highbeam-pin 0)) (pwm-stop 0))
    (if (and (= led-rear-highbeam-mode 1) (>= led-rear-highbeam-pin 0)) (pwm-stop 1))
})

(defun bri255 (b) (to-i (* 255.0 (min (max b 0.0) 1.0))))

; Last PWM highbeam duty per channel, -1 = unknown.
(def hb-duty-front -1.0)
(def hb-duty-rear -1.0)

; Invalidate every entry. fx 0xFF is not a real effect id, so the first
; compare after this always misses and pushes. Must be called whenever the
; lib's own segment state is reset, i.e. around deinit/init.
(defun seg-cache-reset () {
    (bufclear seg-cache 0xFF)
    (bufclear seg-cache-ov 0xFF)
    ; Any intent recorded before a reinit describes segments that no longer
    ; exist, and flushing it would push a look at an index the new layout may
    ; not even define.
    (bufclear seg-want-set 0)
    (setq hb-duty-front -1.0)
    (setq hb-duty-rear -1.0)
})

; ---- Intent -------------------------------------------------------------
; Record what a segment should look like: no compare, no lib call. Call it from as
; many rules as you like - the last one wins, which is how precedence is
; expressed now.

; Resolve deliberate white by physical strip, independent of travel direction.
; RGB strips keep RGB white even if a saved RGBW preference is W only.
; The button has no white-output setting and retains its existing behaviour.
(defun strip-white (seg) {
    (var type TYPE-GRBW)
    (var mode 0)
    (cond
        ((= seg seg-front) {
            (setq type led-front-type) (setq mode led-front-white-output)
        })
        ((= seg seg-rear) {
            (setq type led-rear-type) (setq mode led-rear-white-output)
        })
        ((= seg seg-status) {
            (setq type led-status-type) (setq mode led-status-white-output)
        })
        ((= seg seg-footpad) {
            (setq type led-footpad-type) (setq mode led-footpad-white-output)
        })
    )
    (cond
        ((< type TYPE-GRBW) 0x00FFFFFFu32)
        ((= mode 1) 0xFF000000u32)
        ((= mode 2) 0x00FFFFFFu32)
        (t 0xFFFFFFFFu32)
    )
})

(defun seg-want (seg fx pal color spd bri val cyc) {
    (if (>= seg 0) {
        (if (= color 0xFFFFFFFFu32) (setq color (strip-white seg)))
        (var o (* seg 8))
        (bufset-u8 seg-want-look o fx)
        (bufset-u8 seg-want-look (+ o 1) pal)
        (bufset-u8 seg-want-look (+ o 2) spd)
        (bufset-u8 seg-want-look (+ o 3) bri)
        (bufset-u8 seg-want-look (+ o 4) val)
        (bufset-u16 seg-want-look (+ o 6) cyc)
        (bufset-u32 seg-want-col (* seg 4) color)
        (bufset-u8 seg-want-set seg 1)
    })
})

; Effects that ignore fx-val still have to pin it to something, or a value left
; over from a gauge would follow them into the cache compare. 0 for all of them.
; Same for the cycle time: 0 hands the segment back to spd, which is what
; everything that is not being matched against another strip wants.
(defun seg-want-fx (seg fx pal color spd bri)
    (seg-want seg fx pal color spd bri 0 0))

; The cycle time in ms replaces spd: one full cycle of the effect takes cyc
; whatever the strip's length, instead of spd's fixed pixel velocity. That is
; what puts strips of different lengths in step - a 10 LED front and a 15 LED
; rear start and finish a sweep together instead of beating against each other -
; and it is also the readable way to ask for "a sweep a second". Only the
; effects whose period follows the LED count need it (chase, comet, larson,
; wipe); the rest are already in step on spd alone.
(defun seg-want-cyc (seg fx pal color cyc bri)
    (seg-want seg fx pal color 0 bri 0 cyc))

(defun seg-want-off (seg) (seg-want seg FX-OFF 0 0 32 0 0 0))

; A fill bar. `color` 0 selects the lib's battery gradient (red when nearly
; empty, green when full); any other colour fills flat in that colour, and
; FX-GAUGE ignores the palette once a colour is set. The palette is 0 either way
; so one left over from another mode cannot recolor the bar.
(defun seg-want-bar (seg color level spd bri)
    (seg-want seg FX-GAUGE 0 color spd bri level 0))

(defun seg-want-gauge (seg level spd bri) (seg-want-bar seg 0 level spd bri))

; ---- Flush --------------------------------------------------------------
; The only place that drives the lib. Each claimed segment is pushed at most once,
; and only when it differs from what the lib was last told, so a steady state
; still costs nothing. look and fx-val go out together - two calls that must not
; be split by another rule's write.
(defun seg-flush () {
    (looprange s 0 8 {
        (if (= (bufget-u8 seg-want-set s) 1) {
            (bufset-u8 seg-want-set s 0)
            (var o (* s 8))
            (var fx (bufget-u8 seg-want-look o))
            (var pal (bufget-u8 seg-want-look (+ o 1)))
            (var spd (bufget-u8 seg-want-look (+ o 2)))
            (var bri (bufget-u8 seg-want-look (+ o 3)))
            (var val (bufget-u8 seg-want-look (+ o 4)))
            (var cyc (bufget-u16 seg-want-look (+ o 6)))
            (var color (bufget-u32 seg-want-col (* s 4)))
            (if (or (!= (bufget-u8 seg-cache o) fx)
                    (!= (bufget-u8 seg-cache (+ o 1)) pal)
                    (!= (bufget-u8 seg-cache (+ o 2)) spd)
                    (!= (bufget-u8 seg-cache (+ o 3)) bri)
                    (!= (bufget-u8 seg-cache (+ o 4)) val)
                    (!= (bufget-u16 seg-cache (+ o 6)) cyc)
                    (!= (bufget-u32 seg-cache-col (* s 4)) color)) {
                ; One call, not five: seg-look sets the whole appearance under a
                ; single lock acquisition in the lib. The cycle time rides along
                ; as the 7th argument because the lib applies it before deciding
                ; how to restart the effect - pushed as its own call it would
                ; land one call too late to line this segment up with the others.
                (ext-esp_led-seg-look s fx pal color spd bri cyc)
                (ext-esp_led-seg-fx-val s val)
                (bufset-u8 seg-cache o fx)
                (bufset-u8 seg-cache (+ o 1) pal)
                (bufset-u8 seg-cache (+ o 2) spd)
                (bufset-u8 seg-cache (+ o 3) bri)
                (bufset-u8 seg-cache (+ o 4) val)
                (bufset-u16 seg-cache (+ o 6) cyc)
                (bufset-u32 seg-cache-col (* s 4) color)
            })
        })
    })
})

; Overlay pixels are always driven white here, so only the brightness varies
; and only that is cached.
(defun seg-overlay-bri (seg bri) {
    (if (>= seg 0) {
        (if (!= (bufget-u16 seg-cache-ov (* seg 2)) bri) {
            (ext-esp_led-seg-overlay seg (strip-white seg) bri)
            (bufset-u16 seg-cache-ov (* seg 2) bri)
        })
    })
})

(defun display-battery-charging ()
    (or bms-charger-just-plugged (and (= led-show-battery-charging 1) bms-is-charging (not (running-state))))
)

; Animation cycle times in ms, one per pattern drawn on more than one strip.
;
; The lib offers two ways to pace an effect. spd is pixel velocity: phase gains
; spd units per 33 ms and each effect divides that by its own period, so Hz =
; spd * 30.3 / period (strobe 128 units, felony 96, breathe 2048, rainbow 4096,
; larson 32 * (leds - 1)). A cycle time instead pins one period to a wall-clock
; time, which is what the constants below are.
;
; Two reasons the patterns here use them. Larson could not be expressed as a
; speed at all - its period follows the LED count, so at one spd a 10 LED front
; turned around while a 15 LED rear was still two thirds of the way out, and the
; two beat against each other. And the lib treats segments sharing a cycle time
; as one animation: it holds them in step and lets one that was pulled away
; rejoin the rest, which is what survives the brake light claiming the rear on
; its own. So the value doubles as the identity of the pattern's set, and every
; strip showing a pattern joins that set whatever its length - which is why each
; pattern gets its own number and no two share one. Where the same pattern is
; drawn from several places (rave rainbow on front and rear, plain rainbow on
; front, rear, footpad and button) they all name the same constant on purpose.
;
; Only larson is a new rate. The rest are the rates the old spd values already
; produced - period * 33 / spd, within 0.1% - so nothing changes speed. At the
; 60 fps this package sets, a cycle spans cycle_ms / 16.7 frames and two is
; Nyquist: strobe once ran at 30 Hz on 2 frames and felony was undersampled, so
; keep 6+ frames (100 ms) per cycle.
;
; The gauge is deliberately absent: its renderer reads spd itself as the
; pulse-or-not flag, so moving it to a cycle time would silently stop the
; charging pulse. Its period does not follow the LED count anyway, so strips
; showing it are already in step.
(def CYC-STROBE-ALARM  176) ; was spd 24 - 5.7 Hz, brake light and pushback
(def CYC-STROBE        211) ; was spd 20 - 4.7 Hz
(def CYC-RAINBOW-RAVE  614) ; was spd 220
(def CYC-FELONY        792) ; was spd 4 - 1.3 Hz red/blue alternation
(def CYC-LARSON       1000) ; chosen: 1.0 s per sweep on every strip
(def CYC-BREATHE      1056) ; was spd 64
(def CYC-RAINBOW      4224) ; was spd 32
(def CYC-RAINBOW-SLOW 16896) ; was spd 8 - trans pride

; Head/tail pattern per LED mode. head-seg faces the direction of travel.
(defun apply-drive-mode (mode) {
    (cond
        ((= mode 0) { ; White / Red
            (seg-want-fx head-seg FX-SOLID 0 0xFFFFFFFFu32 32 head-bri)
            (seg-want-fx tail-seg FX-SOLID 0 0x00FF0000u32 32 tail-bri)
        })
        ((= mode 1) { ; Battery
            (seg-want-gauge head-seg (to-i (* 255.0 battery-percent-remaining)) (if bms-is-charging 32 0) head-bri)
            (seg-want-gauge tail-seg (to-i (* 255.0 battery-percent-remaining)) (if bms-is-charging 32 0) tail-bri)
        })
        ((= mode 2) { ; Cyan / Magenta
            (seg-want-fx head-seg FX-SOLID 0 0x0000FFFFu32 32 head-bri)
            (seg-want-fx tail-seg FX-SOLID 0 0x00FF00FFu32 32 tail-bri)
        })
        ((= mode 3) { ; Blue / Green
            (seg-want-fx head-seg FX-SOLID 0 0x000000FFu32 32 head-bri)
            (seg-want-fx tail-seg FX-SOLID 0 0x0000FF00u32 32 tail-bri)
        })
        ((= mode 4) { ; Yellow / Green
            (seg-want-fx head-seg FX-SOLID 0 0x00FFFF00u32 32 head-bri)
            (seg-want-fx tail-seg FX-SOLID 0 0x0000FF00u32 32 tail-bri)
        })
        ((= mode 5) { ; Rainbow - the same set as the footpad and button bars,
                      ; which draw this pattern too
            (seg-want-cyc head-seg FX-RAINBOW PAL-RGBW 0 CYC-RAINBOW head-bri)
            (seg-want-cyc tail-seg FX-RAINBOW PAL-RGBW 0 CYC-RAINBOW tail-bri)
        })
        ((= mode 6) { ; Strobe - 4.7 Hz, ~13 frames per flash cycle
            (seg-want-cyc head-seg FX-STROBE 0 0xFFFFFFFFu32 CYC-STROBE head-bri)
            (seg-want-cyc tail-seg FX-STROBE 0 0xFFFFFFFFu32 CYC-STROBE tail-bri)
        })
        ((= mode 7) { ; Rave
            (seg-want-cyc head-seg FX-RAINBOW PAL-NEON 0 CYC-RAINBOW-RAVE head-bri)
            (seg-want-cyc tail-seg FX-RAINBOW PAL-NEON 0 CYC-RAINBOW-RAVE tail-bri)
        })
        ((= mode 8) { ; Rave directional - the tail shares mode 7's rave set, so
                      ; switching between the two modes does not restart it
            (seg-want-fx head-seg FX-SOLID 0 0xFFFFFFFFu32 32 head-bri)
            (seg-want-cyc tail-seg FX-RAINBOW PAL-NEON 0 CYC-RAINBOW-RAVE tail-bri)
        })
        ((= mode 9) { ; Knight Rider - the sweep every strip takes 1.0 s over,
                      ; whatever its length. The trade is pixel velocity: the
                      ; longer strip's eye moves faster.
            (seg-want-cyc head-seg FX-LARSON 0 0x00FF0000u32 CYC-LARSON head-bri)
            (seg-want-cyc tail-seg FX-LARSON 0 0x00FF0000u32 CYC-LARSON tail-bri)
        })
        ((= mode 10) { ; Felony - 1.3 Hz red/blue alternation, ~48 frames. As a
                       ; speed this was spd 4 and getting coarse: the next steps
                       ; down were 0.95 and 0.63 Hz, with 0 not an option (the
                       ; lib reads 0 as "unset"). A cycle time has none of that
                       ; problem, being ms rather than a 1..255 divisor.
            (seg-want-cyc head-seg FX-FELONY 0 0 CYC-FELONY head-bri)
            (seg-want-cyc tail-seg FX-FELONY 0 0 CYC-FELONY tail-bri)
        })
        ((= mode 11) { ; Trans pride (slow rainbow sweep)
            (seg-want-cyc head-seg FX-RAINBOW PAL-RGBW 0 CYC-RAINBOW-SLOW head-bri)
            (seg-want-cyc tail-seg FX-RAINBOW PAL-RGBW 0 CYC-RAINBOW-SLOW tail-bri)
        })
        (t { ; unknown mode: same as White / Red
            (seg-want-fx head-seg FX-SOLID 0 0xFFFFFFFFu32 32 head-bri)
            (seg-want-fx tail-seg FX-SOLID 0 0x00FF0000u32 32 tail-bri)
        })
    )
})

; Footpad split: the bar halves at its midpoint and the half matching the engaged
; sensor lights - FX-TURN's solid styles are exactly that split. Status Bar Style
; swaps them for a bar mounted the other way round. Shared by the stationary
; display (cyan) and the riding warning (red).
(defun status-footpad-split (color bri) {
    (var swap (!= led-mode-status 0))
    (seg-want seg-status FX-TURN 0 color 0 bri
        (cond
            ((= switch-state 3) TURN-HAZARD-SOLID)
            ((= switch-state 1) (if swap TURN-RIGHT-SOLID TURN-LEFT-SOLID))
            (t (if swap TURN-LEFT-SOLID TURN-RIGHT-SOLID)))
        0)
})

; True once a pad has been off long enough to be worth showing. A weight shift
; drops a single sensor for a few ticks at a time and must not flash the bar, so
; only a release that persists past footpad-warn-delay counts.
(defun footpad-released () {
    (and (!= state 5)
         (!= switch-state 3)
         (> (secs-since footpad-ok-time) footpad-warn-delay))
})

; While riding. Three things compete for the bar and this is their order.
(defun status-riding (bri) {
    (cond
        ; Pushback/tiltback is actually pulling back - the most urgent thing the
        ; bar can say. 5.7 Hz on ~11 frames; it once ran at 47 Hz on 1.3 frames,
        ; undersampled into an erratic shimmer, so the one branch that has to
        ; read as an alarm did not. Same set as the brake light: braking under
        ; pushback then flashes the bar and the rear strip together.
        ((> sat-t 2)
            (seg-want-cyc seg-status FX-STROBE 0 0x00FF0000u32 CYC-STROBE-ALARM bri))

                ; Footpad off while riding. Was unreachable: the duty bar owned
                ; everything above 250 erpm, and the fault states (8, 9) only
                ; appear once the board has already stopped.
        ((footpad-released)
            (if (= switch-state 0)
                ; Neither sensor engaged - there is no half to point at, and the
                ; split would light both and read as "both down", the opposite of
                ; what is happening.
                (seg-want-fx seg-status FX-SOLID 0 0x00FF0000u32 32 bri)
                (status-footpad-split 0x00FF0000u32 bri)))

        ; Duty cycle bar, the normal riding display.
        (t {
            (var duty (abs duty-cycle-now))
            (seg-want-bar seg-status
                (cond ((> duty 0.8) 0x00FF0000u32) ((> duty 0.6) 0x00FFFF00u32) (t 0x0000FF00u32))
                (to-i (* 255.0 duty)) 0 bri)
        })
    )
})

; The status bar. Driven every tick regardless of the master LEDs-On switch - it
; is diagnostic, so turning the lights off must not blind you. First match wins.
(defun led-draw-status () {
    ; Stamped every tick both pads are down, so footpad-released can measure how
    ; long one has been off. Outside the cond because it has to run on every tick
    ; regardless of which branch draws - including while the board is stationary,
    ; so that stepping on resets the clock before the rider sets off.
    (if (= switch-state 3) (setq footpad-ok-time (systime)))
    (if (> (abs rpm) 250.0) (setq rpm-fast-time (systime)))

    (cond
        (handtest-mode
            (seg-want-bar seg-status 0x000000FFu32
                (cond ((= switch-state 3) 255)
                      ((or (= switch-state 1) (= switch-state 2)) 128)
                      (t 16))
                0 status-bri))

        ((= state 15) ; disabled
            (seg-want-fx seg-status FX-SOLID 0 0x00FF0000u32 32 status-bri))

        ((or (>= can-activity-sec 1) (< can-id 0)) ; connecting
            (seg-want-cyc seg-status FX-BREATHE 0 0x000000FFu32 CYC-BREATHE status-bri))


        ((and (running-state)
              (or (> (abs rpm) 250.0)
                  (< (secs-since rpm-fast-time) rpm-fast-hold)))
            (status-riding status-bri))

        ((or (= switch-state 1) (= switch-state 2) (= switch-state 3))
            (status-footpad-split 0x0000FFFFu32 status-bri))

        (t
            (seg-want-gauge seg-status (to-i (* 255.0 battery-percent-remaining))
                (if bms-is-charging 32 0) status-bri))
    )
})

(defun update-aux-leds (bri) {
    (if (>= seg-footpad 0) {
        ; Rainbow is the only mode led-mode-footpad offers, so no branch yet.
        ; Same set as LED mode 5, so a footpad bar and the drive strips run one
        ; rainbow between them rather than three that happen to look alike.
        (seg-want-cyc seg-footpad FX-RAINBOW PAL-RGBW 0 CYC-RAINBOW bri)
    })
    (if (>= seg-button 0) {
        (if (= led-mode-button 1)
            (seg-want-gauge seg-button (to-i (* 255.0 battery-percent-remaining)) (if bms-is-charging 32 0) bri)
            (seg-want-cyc seg-button FX-RAINBOW PAL-RGBW 0 CYC-RAINBOW bri)
        )
    })
})

; ---- Tick phases --------------------------------------------------------
; led-loop was one ~380 line body doing four jobs; each is a phase below and
; led-loop is the running order. They share per-tick state through the loop-state
; globals in led-vars.lisp. The draw- phases only record intent; seg-flush drives
; the lib once at the end of the tick.

(defun led-tick-start (t-start) {
    (if (!= dbg-mask 0) (setq dbg-ticks-led (+ dbg-ticks-led 1)))
    ; Seed the phase marks so a phase that does not run (LEDs off, no segments)
    ; reports 0 for its slice instead of a stale timestamp.
    (if (dbg-active DBG-LED) {
        (setq dbg-led-t1 t-start)
        (setq dbg-led-t2 t-start)
        (setq dbg-led-t3 t-start)
    })
})

; Rebuild the segments in place after a settings change.
(defun led-handle-reinit () {
    (if led-reinit-flag {
        (dbg DBG-LED "led reinit")
        (led-teardown)
        (setq have-segs (led-start))
        (if (< led-loop-delay 1) (setq led-loop-delay 50))
        (setq led-loop-delay-sec (/ 1.0 led-loop-delay))
        (setq led-reinit-flag nil)
    })
})

; ---- Input tracking -----------------------------------------------------

; Which way the board is travelling, with a commit window so a rock or a bit of
; rollback does not swap the headlight. Wheelslip (3) is ignored outright.
(defun led-track-direction () {
    (var idle-rpm-darkride 100)
    (if (= state 4) ; RUNNING_UPSIDEDOWN
        (setq idle-rpm-darkride (* idle-rpm-darkride -1))
    )
    (if (!= state 3) {
        (var current-direction direction)
        (if (> rpm idle-rpm-darkride) (setq current-direction 1))
        (if (< rpm (* idle-rpm-darkride -1)) (setq current-direction -1))
        (if (!= current-direction prev-direction) {
            (if (= direction-change-start-time 0) {
                (setq direction-change-start-time (systime))
            }{
                (if (>= (secs-since direction-change-start-time) direction-change-window) {
                    (setq direction current-direction)
                    (setq prev-direction current-direction)
                    (setq direction-change-start-time 0)
                    (if (!= direction dbg-prev-direction) {
                        (setq dbg-prev-direction direction)
                        (dbg DBG-LED (str-merge "led dir " (str-from-n direction "%d")
                            " rpm " (str-from-n (to-float rpm) "%.0f")))
                    })
                })
            })
        }{
            ; Settled before the window elapsed - drop the pending change, or the
            ; timestamp survives the blip and the next real reversal commits on
            ; its first tick.
            (setq direction-change-start-time 0)
        })
    })
})

; Mall grab: board held nose-up while not riding. Short press of the footpad
; toggles the LEDs, long press toggles the highbeam.
(defun led-track-mall-grab () {
    (if (and (not (running-state)) (> pitch-angle 70)) {
        (setq led-mall-grab (if (= led-mall-grab-enabled 1) 1 0))
        (if (= switch-state 3) {
            (if (not mall-grab-press-active) {
                (setq mall-grab-press-start (systime))
                (setq mall-grab-press-active t)
            })
        }{
            (if mall-grab-press-active {
                (var short-press (< (secs-since mall-grab-press-start) 1))
                (if short-press
                    (setq led-on (if (= led-on 1) 0 1))
                    (setq led-highbeam-on (if (= led-highbeam-on 1) 0 1))
                )
                ; To the config, not just the cache: apply-config reloads both
                ; on every settings write, so a cache-only toggle reverted
                ; itself. Persisted via control-store-pending, so a burst of
                ; presses costs one NVS write.
                (if short-press
                    (set-config 'led-on led-on)
                    (set-config 'led-highbeam-on led-highbeam-on)
                )
                (setq control-store-pending (systime))
                (dbg DBG-LED (str-merge "led mallgrab press on " (str-from-n (to-i led-on) "%d")
                    " hb " (str-from-n (to-i led-highbeam-on) "%d")))
            })
            ; Outside the branch above so a release always disarms, whether or
            ; not it was allowed to act on it.
            (setq mall-grab-press-active nil)
        })
    }{
        (setq led-mall-grab 0)
        (setq mall-grab-press-active nil)
    })
})

; What counts as the board being in use, for the idle timeouts.
(defun led-track-activity () {
    (if (or (running-state) (= led-mall-grab 1) (display-battery-charging)) {
        (setq led-last-activity-time (systime))
    }{
        (setq direction 1)
    })
})

; ---- Decide ------------------------------------------------------------
; Everything the drawing phases need, nothing drawn. The lib eases brightness
; (ext-esp_led-fade), so targets are set directly.
(defun led-decide () {
    (setq last-activity-sec (secs-since led-last-activity-time))
    (setq can-activity-sec (secs-since can-last-activity-time))

    ; Mode and brightness. Later rules override earlier ones.
    (setq current-led-mode led-mode)
    (setq led-current-brightness (min led-brightness led-max-brightness))
    (if (= led-mall-grab 1)
        (setq led-current-brightness (min led-brightness-status led-max-brightness)))
    (if (and (>= last-activity-sec idle-timeout) (<= can-activity-sec 1)) {
        (setq current-led-mode led-mode-idle)
        (setq led-current-brightness (min led-brightness-idle led-max-brightness))
    })
    (if (= state 5)
        (setq led-current-brightness (min led-brightness-idle led-max-brightness)))
    (if (and (<= (secs-since 0) led-startup-timeout) (not (running-state)))
        (setq current-led-mode led-mode-startup))

    ; Highbeams: the strip facing the direction of travel lights its highbeam
    ; (mode 1 = PWM pin, mode 2 = embedded overlay pixels) and the rest of that
    ; strip dims by the configured ratio (0 = fully off, like the original).
    (var highbeam-active (and (= led-on 1) (= led-highbeam-on 1) (running-state) (!= state 5)))
    (setq hb-front (and highbeam-active (>= direction 0) (> led-front-highbeam-mode 0)))
    (setq hb-rear (and highbeam-active (< direction 0) (> led-rear-highbeam-mode 0)))
    (setq hb-frac (min led-brightness-highbeam led-max-brightness))

    (setq front-bri (bri255 (* led-current-brightness (if hb-front led-dim-on-highbeam-ratio 1.0))))
    (setq rear-bri (bri255 (* led-current-brightness (if hb-rear led-dim-on-highbeam-ratio 1.0))))
    (setq status-bri (bri255 (min led-brightness-status led-max-brightness)))
    (setq aux-bri (bri255 led-current-brightness))

    ; head faces the direction of travel. Paired with its brightness, so the
    ; physical front strip always gets front-bri whichever way round it is.
    (setq head-seg (if (> direction 0) seg-front seg-rear))
    (setq tail-seg (if (> direction 0) seg-rear seg-front))
    (setq head-bri (if (> direction 0) front-bri rear-bri))
    (setq tail-bri (if (> direction 0) rear-bri front-bri))

    ; Means "the shutoff branch runs", carrying the branches that outrank it -
    ; otherwise a long handtest kept front and rear breathing while the footpad
    ; went dark. The aux strips honour it too, hence deciding it here.
    (setq lights-off (and (!= state 15)
                          (not handtest-mode)
                          (> last-activity-sec idle-timeout-shutoff)
                          (< can-activity-sec 1)
                          (!= state 5)))

    (setq braking (and (= led-brake-light-enabled 1)
                       (running-state)
                       (!= state 5)
                       (<= tot-current led-brake-light-min-amps)))
})

; Edge-triggered: the effective mode and the on/off state are what people
; actually ask about ("why did my lights change?"), and they only move a handful
; of times per ride.
(defun led-dbg-report () {
    (if (dbg-active DBG-LED) {
        (if (!= current-led-mode dbg-prev-led-mode) {
            (setq dbg-prev-led-mode current-led-mode)
            (dbg DBG-LED (str-merge "led mode " (str-from-n current-led-mode "%d")
                " idle " (str-from-n last-activity-sec "%.1f")
                " bri " (str-from-n led-current-brightness "%.2f")))
        })
        (if (!= (to-i led-on) dbg-prev-led-on) {
            (setq dbg-prev-led-on (to-i led-on))
            (dbg DBG-LED (if (= led-on 1) "led on" "led off"))
        })
        (var hb (+ (if hb-front 1 0) (if hb-rear 2 0)))
        (if (!= hb dbg-prev-hb) {
            (setq dbg-prev-hb hb)
            (dbg DBG-LED (str-merge "led hb " (str-from-n hb "%d")
                " " (str-from-n hb-frac "%.2f")))
        })
        (if (dbg-due 'led-state 5.0)
            (dbg DBG-LED (str-merge "led bri " (str-from-n front-bri "%d")
                " " (str-from-n rear-bri "%d")
                " " (str-from-n status-bri "%d")
                " dir " (str-from-n direction "%d")
                " mg " (str-from-n led-mall-grab "%d")
                " age " (str-from-n can-activity-sec "%.2f"))))
    })
})

; ---- Draw --------------------------------------------------------------

; Highbeam drive. Not part of the intent buffer: the PWM pin and the lib's
; overlay channel are separate from a segment's look, and each already has its
; own single writer and its own change guard.
; Mode 1: a highbeam on its own PWM pin, which is hardware the strip lib knows
; nothing about. Driven outside the have-segs gate for that reason - it used to be
; inside, so a chain the lib refused (one wrongly-typed strip does it) left the
; PWM highbeam stuck at the 0.0 duty pwm-start gave it, with nothing wrong with
; the highbeam itself. Channel 0 is front, 1 is rear, matching led-setup-segments.
(defun led-draw-highbeam-pwm () {
    (if (and (= led-front-highbeam-mode 1) (>= led-front-highbeam-pin 0)) {
        (var d (if hb-front hb-frac 0.0))
        (if (!= d hb-duty-front) {
            (pwm-set-duty d 0)
            (setq hb-duty-front d)
        })
    })
    (if (and (= led-rear-highbeam-mode 1) (>= led-rear-highbeam-pin 0)) {
        (var d (if hb-rear hb-frac 0.0))
        (if (!= d hb-duty-rear) {
            (pwm-set-duty d 1)
            (setq hb-duty-rear d)
        })
    })
})

; Mode 2: LEDs embedded in the strip as overlay pixels, so this one does need the
; segments. Their brightness is mapped onto the configured min-max range because
; embedded bars need a minimum drive before they light at all. The overlay channel
; is separate from the segment's effect, so it is unaffected by the strip dimming
; under it.
(defun led-draw-highbeam-overlay () {
    (if (= led-front-highbeam-mode 2) {
        (seg-overlay-bri seg-front
            (if hb-front (bri255 (+ led-front-highbeam-min (* (- led-front-highbeam-max led-front-highbeam-min) hb-frac))) 0))
    })
    (if (= led-rear-highbeam-mode 2) {
        (seg-overlay-bri seg-rear
            (if hb-rear (bri255 (+ led-rear-highbeam-min (* (- led-rear-highbeam-max led-rear-highbeam-min) hb-frac))) 0))
    })
})

; Front and rear. The cond picks a base appearance; later rules override it by
; recording a later intent. Branches drive head/tail, which are front/rear
; ordered by `direction` with brightnesses to match.
(defun led-draw-drive () {
    (cond
        ; Charging outranks every other base appearance, which is why it is
        ; first in a first-match cond. It used to be a pass that ran after this
        ; cond, which is how it outranked things then - and why it flickered.
        ((display-battery-charging) {
            (seg-want-gauge head-seg (to-i (* 255.0 battery-percent-remaining)) 32 head-bri)
            (seg-want-gauge tail-seg (to-i (* 255.0 battery-percent-remaining)) 32 tail-bri)
        })
        ((= state 15) {
            (seg-want-fx head-seg FX-SOLID 0 0x00FF0000u32 32 head-bri)
            (seg-want-fx tail-seg FX-SOLID 0 0x00FF0000u32 32 tail-bri)
        })
        (handtest-mode {
            (seg-want-cyc head-seg FX-BREATHE 0 0x000000FFu32 CYC-BREATHE head-bri)
            (seg-want-cyc tail-seg FX-BREATHE 0 0x000000FFu32 CYC-BREATHE tail-bri)
        })
        (lights-off {
            (seg-want-off head-seg)
            (seg-want-off tail-seg)
        })
        ((and (or (= current-led-mode 1) (= led-mall-grab 1)) (< can-activity-sec 1)) {
            (seg-want-gauge head-seg (to-i (* 255.0 battery-percent-remaining)) (if bms-is-charging 32 0) head-bri)
            (seg-want-gauge tail-seg (to-i (* 255.0 battery-percent-remaining)) (if bms-is-charging 32 0) tail-bri)
        })
        ((= current-led-mode 1)
            (apply-drive-mode 0))
        (t {
            (apply-drive-mode current-led-mode)
        })
    )

    ; Brake light. After the cond, so its tail intent replaces the base
    ; appearance - no sentinel, no second write. 5.7 Hz; it once ran at 47 Hz,
    ; past Nyquist, and shimmered instead of flashing. Shares the alarm set with
    ; the status bar's pushback strobe, which is the same pattern.
    (if braking
        (seg-want-cyc tail-seg FX-STROBE 0 0x00FF0000u32 CYC-STROBE-ALARM tail-bri))
})

(defun led-draw-aux () {
    (if lights-off {
        (seg-want-off seg-footpad)
        (seg-want-off seg-button)
    } (update-aux-leds aux-bri))
})

; Master LEDs-off. The status bar is deliberately not included: it is
; diagnostic, so turning the lights off must not blind you.
(defun led-draw-all-off () {
    (seg-want-off seg-front)
    (seg-want-off seg-rear)
    (seg-want-off seg-footpad)
    (seg-want-off seg-button)
})

; ---- Pace --------------------------------------------------------------

(defun led-tick-pace (t-start) {
    (var work (- (secs-since 0) t-start))
    (var time-to-wait (- led-next-run-time (secs-since 0)))
    (if (> time-to-wait 0)
        (yield (* time-to-wait 1000000))
        {
        ; Not keeping up: effects stutter. A small `work` with a large overrun
        ; means the evaluator is being held by another thread rather than this
        ; loop being slow. Reported past a quarter-period only, with a miss
        ; count, so scheduler jitter does not read like a stall.
            (setq dbg-led-overruns (+ dbg-led-overruns 1))
            (if (and (> (- 0 time-to-wait) (* led-loop-delay-sec 0.25))
                     (dbg-tick DBG-LED 'led-loop 5.0)) {
                (dbg-warn (str-merge "led overrun " (str-from-n (- 0 time-to-wait) "%.4f")
                    " n " (str-from-n dbg-led-overruns "%d")
                    " want " (str-from-n led-loop-delay-sec "%.4f")
                    " work " (str-from-n work "%.4f")
                    " decide " (str-from-n (- dbg-led-t1 t-start) "%.4f")
                    " status " (str-from-n (- dbg-led-t2 dbg-led-t1) "%.4f")
                    " drive " (str-from-n (- dbg-led-t3 dbg-led-t2) "%.4f")))
                (setq dbg-led-overruns 0)
            })
            (setq led-next-run-time (secs-since 0))
        }
    )
    (setq led-next-run-time (+ led-next-run-time led-loop-delay-sec))
})

; ---- The loop ----------------------------------------------------------

(defun led-loop () {
    (setq have-segs (led-start))
    (dbg DBG-LED (str-merge "led start mode " (str-from-n led-mode "%d")
        " idle " (str-from-n led-mode-idle "%d")
        " hz " (str-from-n led-loop-delay "%d")))
    ; A zero rate would divide by zero here and put the loop into a
    ; crash/restart cycle with the LEDs stuck on the last frame.
    (if (< led-loop-delay 1) {
        (dbg-warn "led bad rate, using 50Hz")
        (setq led-loop-delay 50)
    })
    (setq led-loop-delay-sec (/ 1.0 led-loop-delay))
    ; Seeded like the activity timestamps in setup(): left at 0 the footpad
    ; warning would measure against the epoch and read as "off since boot", so a
    ; board powered up mid-ride with a pad lifted would warn on the first tick
    ; instead of after footpad-warn-delay.
    (setq footpad-ok-time (systime))
    (setq led-next-run-time (secs-since 0))
    (setq prev-direction 1)
    (setq direction-change-start-time 0)
    (setq mall-grab-press-active nil)

    (loopwhile t {
        (var t-start (secs-since 0))
        (led-tick-start t-start)

        (if led-exit-flag {
            (break)
        })
        (led-handle-reinit)

        (led-track-direction)
        (led-track-mall-grab)
        (led-track-activity)

        ; Decide, then drive the PWM highbeam, both outside the have-segs gate:
        ; led-decide only reads telemetry and writes loop-state globals (with no
        ; segments head/tail land on -1, which every seg- helper skips), and a PWM
        ; highbeam is its own GPIO that works whether or not the strips do.
        (led-decide)
        (led-draw-highbeam-pwm)

        (if have-segs {
            (led-draw-highbeam-overlay)
            (led-dbg-report)

            (setq dbg-led-t1 (secs-since 0))
            (led-draw-status)
            (setq dbg-led-t2 (secs-since 0))

            (if (= led-on 1) {
                (led-draw-drive)
                (led-draw-aux)
            }
                (led-draw-all-off))
            (setq dbg-led-t3 (secs-since 0))

            ; Everything above only recorded intent. This is the one point in
            ; the tick where the lib is driven, and it visits each segment once.
            (seg-flush)
        })

        (led-tick-pace t-start)
    })

    (led-teardown)
    (setq led-exit-flag nil)
})

@const-end
