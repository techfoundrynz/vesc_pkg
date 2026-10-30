; Loaded after the real LED module by test_white_output.py.
(def test-ok t)
(defun expect (actual wanted) {
    (if (!= actual wanted) {
        (print (list 'unexpected actual 'wanted wanted))
        (setq test-ok nil)
    })
})

(setq seg-front 0)
(setq seg-rear 1)
(setq seg-status 2)
(setq seg-footpad 3)
(setq seg-button 4)

; All supported pixel types and all three choices, independently per strip.
(looprange type-id 0 5 {
    (setq led-front-type type-id)
    (setq led-rear-type type-id)
    (setq led-status-type type-id)
    (setq led-footpad-type type-id)
    (looprange white-mode 0 3 {
        (setq led-front-white-output white-mode)
        (setq led-rear-white-output white-mode)
        (setq led-status-white-output white-mode)
        (setq led-footpad-white-output white-mode)
        (var wanted (cond
            ((< type-id TYPE-GRBW) 0x00FFFFFFu32)
            ((= white-mode 1) 0xFF000000u32)
            ((= white-mode 2) 0x00FFFFFFu32)
            (t 0xFFFFFFFFu32)))
        (looprange segment 0 4 (expect (strip-white segment) wanted))
    })
})
(expect (strip-white seg-button) 0xFFFFFFFFu32)

(setq led-front-type TYPE-GRBW)
(setq led-rear-type TYPE-RGBW)
(setq led-front-white-output 1)
(setq led-rear-white-output 2)
(setq head-bri 25)
(setq tail-bri 25)
(setq head-seg seg-front)
(setq tail-seg seg-rear)

; White/Red, white strobes, rave headlights and fallback all use strip choices.
(apply-drive-mode 0)
(expect (bufget-u32 seg-want-col 0) 0xFF000000u32)
(expect (bufget-u32 seg-want-col 4) 0x00FF0000u32)
(apply-drive-mode 6)
(expect (bufget-u32 seg-want-col 0) 0xFF000000u32)
(expect (bufget-u32 seg-want-col 4) 0x00FFFFFFu32)
(apply-drive-mode 8)
(expect (bufget-u32 seg-want-col 0) 0xFF000000u32)
(expect (bufget-u32 seg-want-col 4) 0)
(apply-drive-mode 99)
(expect (bufget-u32 seg-want-col 0) 0xFF000000u32)

; Reversing direction uses the preference of the new physical head strip.
(setq head-seg seg-rear)
(setq tail-seg seg-front)
(apply-drive-mode 0)
(expect (bufget-u32 seg-want-col 4) 0x00FFFFFFu32)
(expect (bufget-u32 seg-want-col 0) 0x00FF0000u32)

; Deliberate colours and palette-driven effects pass through unchanged.
(seg-want-fx seg-front FX-SOLID 0 0x0000FFFFu32 32 25)
(expect (bufget-u32 seg-want-col 0) 0x0000FFFFu32)
(apply-drive-mode 5)
(expect (bufget-u32 seg-want-col 0) 0)
(expect (bufget-u32 seg-want-col 4) 0)

; Embedded highbeams use the same preference, preserving brightness caching.
(def overlay-calls 0)
(def overlay-color 0)
(defun ext-esp_led-seg-overlay (segment color brightness) {
    (setq overlay-calls (+ overlay-calls 1))
    (setq overlay-color color)
})
(bufclear seg-cache-ov 0xFF)
(seg-overlay-bri seg-front 25)
(expect overlay-color 0xFF000000u32)
(seg-overlay-bri seg-front 25)
(expect overlay-calls 1)
(seg-overlay-bri seg-rear 25)
(expect overlay-color 0x00FFFFFFu32)
(expect overlay-calls 2)

(check test-ok)
