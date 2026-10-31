@const-start

; Shared BMS state and backend IDs. Protocol-specific globals live in adapters.
(def BMS-BACKEND-NONE 0)
(def BMS-BACKEND-OW 1)
(def BMS-BACKEND-SSBMS 2)
(def BMS-CAP-CHARGE 1)
(def BMS-CAP-FACTORY 2)
(def BMS-CAP-PAIRING 4)
(def bms-context-id -1)
(def bms-last-activity-time 0)
(def bms-valid nil)
(def bms-freshness-seconds 1.0)
; Normalized UI flags: temperature 0..3, empty 0x04, overcharged 0x08,
; charging reported 0x20, SoC calculation 0x40; -1 means not received yet.
(def bms-status -1)
(def bms-battery-type -1)
(def bms-battery-cycles -1)
(def bms-charge-state 0)
(def bms-can-id -1)
(def bms-is-charging nil)
(def bms-charger-just-plugged nil)
(def bms-charger-plug-in-time 0)

@const-end
