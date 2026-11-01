@const-start

; Shared vehicle state, independent of any controller package.
(def fault-code 0)
(def pitch-angle 0)
(def roll-angle 0)
(def state 0)
(def sat-t 0)
(def switch-state 0)
(def handtest-mode nil)
(def sim-active nil)
(def rpm 0)
(def speed 0)
(def tot-current 0)
(def bat-current 0)
(def duty-cycle-now 0)
(def distance-abs -1)
(def fet-temp-filtered 0)
(def motor-temp-filtered 0)
(def odometer -1)
(def can-id -1)
(def vin -1)
(def last-running-state-time 0)
(def battery-percent-remaining 0.0)
(def footpad-adc1-t 0.0)
(def footpad-adc2-t 0.0)
(def series-cells -1)
(def soc-type 0)
(def cell-type)
(def voltage-curve)
(def need-fetch-cells nil)
(def need-fetch-limits nil)
; ESC current limits as positive magnitudes, for phase/battery utilization. 0 = unknown,
; which drops that term until fetch-current-limits succeeds.
(def esc-motor-current-max 0)
(def esc-motor-current-min 0)
(def esc-bat-current-max 0)
(def esc-bat-current-min 0)
(def last-fetch-cells-time 0)


(defun phase-utilization () {
    (var braking (< tot-current 0))
    (var lim (if braking esc-motor-current-min esc-motor-current-max))
    (var u (if (> lim 0) (min 1.0 (/ (abs tot-current) lim)) 0.0))
    (if braking (- u) u)
})

(defun battery-utilization () {
    (var regen (< bat-current 0))
    (var lim (if regen esc-bat-current-min esc-bat-current-max))
    (var u (if (> lim 0) (min 1.0 (/ (abs bat-current) lim)) 0.0))
    (if regen (- u) u)
})

(defun get-voltage-curve (cell-type)
    (cond
        ((= cell-type 0) { ; Linear
            (list 4.20 4.05 3.90 3.75 3.60 3.45 3.30 3.15 3.00 2.85 2.7)
        })
        ((= cell-type 1) { ; P28A
            (list 4.14 4.09 3.98 3.88 3.77 3.69 3.63 3.55 3.45 3.24 2.9)
        })
        ((= cell-type 2) { ; P30B
           (list 4.14 4.09 3.98 3.88 3.77 3.69 3.63 3.55 3.45 3.24 2.9)
        })
        ((= cell-type 3) { ; P42A
            (list 4.14 4.05 3.91 3.83 3.74 3.65 3.57 3.48 3.38 3 2.8)
        })
        ((= cell-type 4) { ; P45B
            (list 4.14 4.08 4.00 3.91 3.82 3.73 3.64 3.56 3.45 3.23 2.9)
        })
        ((= cell-type 5) { ; P50B
            (list 4.15 4.047 3.96 3.88 3.79 3.70 3.595 3.466 3.29 3.03 2.85)
        })
        ((= cell-type 6) { ; DG40
            (list 4.15 4.02 3.91 3.83 3.75 3.61 3.49 3.35 3.17 2.81 2.7)
        })
        ((= cell-type 7) { ; 50S
            (list 4.15 4.04 3.90 3.82 3.74 3.64 3.52 3.38 3.16 3.0 2.9)
        })
        ((= cell-type 8) { ; VTC6
            (list 4.14 4.00 3.9 3.8 3.7 3.6 3.5 3.4 3.3 3.1 2.8)
        })
        (true { ; Any other value we return Linear
            (list 4.20 4.05 3.90 3.75 3.60 3.45 3.30 3.15 3.00 2.85 2.7)
        })
    )
)


; Provider callbacks: start, tick, receive, control, stop. Registration does not
; activate a provider. Removing an adapter's import leaves the core functional.
(def integration-registry nil)
(def integration-id 0)
(def integration-generation 0)
(def integration-hooks nil)
(def integration-start-pending nil)
(def vehicle-valid nil)
(def integration-ever-connected nil)

(defun integration-register (id start tick rx control stop)
    (setq integration-registry (acons id (list start tick rx control stop) integration-registry)))

(defun integration-is (id)
    (and (> id 0) (= integration-id id) (not (eq integration-hooks nil))))

(defun integration-selected () (or sim-active (> integration-id 0)))

(defun vehicle-fresh ()
    (and (or vehicle-valid (and sim-active (>= can-id 0)))
         (< (secs-since can-last-activity-time) 1.0)))

; Stable provider-independent connection states for LEDs and clients:
; 0 standalone, 1 awaiting first valid snapshot, 2 connected, 3 link lost.
(defun integration-connection-state ()
    (cond ((not (integration-selected)) 0)
          ((vehicle-fresh) 2)
          (integration-ever-connected 3)
          (t 1)))

(defun integration-connecting ()
    (and (integration-selected) (not (vehicle-fresh))))

(defun battery-data-fresh ()
    (or (vehicle-fresh)
        (bms-connected)))

(defun vehicle-refresh-battery () {
    (if (and (not (vehicle-fresh)) (battery-data-fresh))
        (setq battery-percent-remaining (min 1.0 (max 0.0 (bms-soc)))))
})

(defun running-state ()
    (and (vehicle-fresh) (>= state 1) (<= state 5)))

; Reset only vehicle-owned data. BMS/charger state belongs to its own subsystem.
(defun vehicle-reset-state () (atomic
    (setq vehicle-valid nil)
    (setq state 0)
    (setq sat-t 0)
    (setq switch-state 0)
    (setq handtest-mode nil)
    (setq fault-code 0)
    (setq pitch-angle 0)
    (setq roll-angle 0)
    (setq rpm 0)
    (setq speed 0)
    (setq vin -1)
    (setq tot-current 0)
    (setq bat-current 0)
    (setq duty-cycle-now 0)
    (setq footpad-adc1-t 0.0)
    (setq footpad-adc2-t 0.0)
    (setq distance-abs -1)
    (setq fet-temp-filtered 0)
    (setq motor-temp-filtered 0)
    (setq odometer -1)
    (setq battery-percent-remaining 0.0)))

(defun integration-select (id) {
    (var hooks (assoc integration-registry id))
    (var selected (if hooks id 0))
    (if (!= selected integration-id) {
        ; Revoke ownership before calling stop: late packets cannot publish.
        (var old-hooks integration-hooks)
        (setq integration-generation (+ integration-generation 1))
        (setq integration-id 0)
        (setq integration-hooks nil)
        (if old-hooks ((ix old-hooks 4)))
        (vehicle-reset-state)
        (setq integration-ever-connected nil)
        (lighting-release)
        (setq can-id -1)
        (setq can-last-activity-time 0)
        (setq need-fetch-cells nil)
        (setq need-fetch-limits nil)
        (setq series-cells -1)
        (setq esc-motor-current-max 0)
        (setq esc-motor-current-min 0)
        (setq esc-bat-current-max 0)
        (setq esc-bat-current-min 0)
        (setq integration-id selected)
        (setq integration-hooks hooks)
        (setq integration-start-pending (not (eq hooks nil)))
    })
})

; Normalized snapshot contract: state, saturation, footpads, handtest, pitch,
; roll, volts, erpm, km/h, phase A (braking negative), battery A, duty,
; distance, FET C, motor C, odometer, SoC fraction, ADC1 V, ADC2 V, fault.
; State IDs: 0 idle, 1/2 riding, 3 wheelslip, 4 upside-down, 5 flywheel,
; 6..13 fault, 15 disabled. Footpads: 0 none, 1 left, 2 right, 3 both.
(defun vehicle-publish (source values) {
    (if (and (integration-is source) (not sim-active) (= (length values) 20))
        (atomic
            (setq state (ix values 0))
            (setq sat-t (ix values 1))
            (setq switch-state (ix values 2))
            (setq handtest-mode (ix values 3))
            (setq pitch-angle (ix values 4))
            (setq roll-angle (ix values 5))
            (setq vin (ix values 6))
            (setq rpm (ix values 7))
            (setq speed (ix values 8))
            (setq tot-current (ix values 9))
            (setq bat-current (ix values 10))
            (setq duty-cycle-now (ix values 11))
            (setq distance-abs (ix values 12))
            (setq fet-temp-filtered (ix values 13))
            (setq motor-temp-filtered (ix values 14))
            (setq odometer (ix values 15))
            (setq battery-percent-remaining (ix values 16))
            (setq footpad-adc1-t (ix values 17))
            (setq footpad-adc2-t (ix values 18))
            (setq fault-code (ix values 19))
            (setq can-last-activity-time (systime))
            (setq vehicle-valid t)
            (setq integration-ever-connected t)))
})

(defun integration-step () {
    (if (not sim-active) {
        (var hooks integration-hooks)
        (var generation integration-generation)
        (if hooks {
            (if integration-start-pending {
                (setq integration-start-pending nil)
                ((ix hooks 0))
            })
            ; A config change may have replaced the provider during discovery.
            (if (and (eq hooks integration-hooks) (= generation integration-generation))
                ((ix hooks 1)))
        })
        (if (and vehicle-valid (not (vehicle-fresh))) (vehicle-reset-state))
    })
})

(defun integration-receive (data)
    (if (and integration-hooks (not sim-active) (not integration-start-pending))
        ((ix integration-hooks 2) data)
        nil))

(defun integration-control (jsy jsx bt-c bt-z is-rev)
    (if (and integration-hooks (vehicle-fresh) (not sim-active))
        ((ix integration-hooks 3) jsy jsx bt-c bt-z is-rev)))

; Pubmote input and its live UI snapshot.
(defun remote-input (jsy jsx bt-c bt-z is-rev) {
    (setq remote-last-jsy jsy)
    (setq remote-last-jsx jsx)
    (setq remote-last-bt-c bt-c)
    (setq remote-last-bt-z bt-z)
    (setq remote-last-is-rev is-rev)
    (integration-control jsy jsx bt-c bt-z is-rev)
})

@const-end
