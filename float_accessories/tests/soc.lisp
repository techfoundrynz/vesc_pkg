(def soc-test-ok t)
(defun expect-soc (v curve wanted) {
    (var actual (estimate-soc v curve))
    (if (not (number? actual)) {
        (setq soc-test-ok nil)
    } {
        (if (> (abs (- actual wanted)) 0.001) (setq soc-test-ok nil))
        ; Exercise the exact normalization used in the CAN and BMS handlers.
        (if (> (abs (- (/ actual 100) (/ wanted 100.0))) 0.00001)
            (setq soc-test-ok nil))
    })
})

; Every supported cell profile, plus the default for an unrecognized profile.
(looprange profile 0 10 {
    (var curve (get-voltage-curve profile))
    (expect-soc (+ (ix curve 0) 0.1) curve 100.0)
    (expect-soc (- (ix curve 10) 0.1) curve 0.0)
    (looprange i 0 11
        (expect-soc (ix curve i) curve (- 100 (* i 10))))
    (looprange i 1 11 {
        (var midpoint (/ (+ (ix curve (- i 1)) (ix curve i)) 2.0))
        (expect-soc midpoint curve (- 105 (* i 10)))
    })
})

; The reported failure: this previously returned nil, then (/ nil 100) failed.
(expect-soc 2.8 (get-voltage-curve 0) 6.666667)
(check soc-test-ok)
