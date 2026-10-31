@const-start
; OW protocol state; no mutable buffers are allocated by importing this file.
; Grace period before waking a silent charge-only BMS.
(def OW-WAKEUP-GRACE-SECONDS 5.0)
(def ow-key-crc '(3141361152u32))  ;AES-128 ow-key. Offset in 6109: 0x12009
(def ow-counter-crc '(4092889840u32)) ;IV for ow-counter. Offset in 6109: 0x12019

(def ow-key nil)
(def ow-counter nil)
(def ow-magic nil)


(def ow-user-cmd -1)
(def ow-loop-delay)
(def ow-rs485-di-pin)
(def ow-rs485-ro-pin)
(def ow-rs485-dere-pin)
(def ow-wakeup-pin)
(def ow-use-crypto)
(def ow-override-soc 0)
(def ow-type 0)
(def ow-rs485-chip 0)
(def ow-charge-only 0)

;vars
(def ow-cell-count-uninit t)
(def ow-factory -1);TODO Check if bms is in ow-factory mode somehow and init if is. Probably have a timer at boot looking for packets to determine valid state when connected.
(def ow-is-charging -1)
(def ow-is-current-over-limit -1)
(def ow-is-battery-empty -1)
(def ow-is-battery-temp-out-of-range -1)
(def ow-is-battery-overcharged -1)
(def ow-serial -1)

(def ow-buf nil)
(def ow-exit-flag nil)
(def ow-status -1)
(def ow-charge-state 0)
(def ow-charge-target 0)
(def ow-uart-open nil)
@const-end
