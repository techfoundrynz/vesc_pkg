@const-start

(def FLOAT_ACCESSORIES_MAGIC 102)

(def float-accessories-cmds '(
    (COMMAND_GET_INFO . 0)
    (COMMAND_RUN_LISP . 1)
    (COMMAND_BMS_STATUS . 2)
))

(defun float-accessories-command-rx (data) {
    (if (dbg-active DBG-CMD)
        (dbg DBG-CMD (str-merge "cmd " (to-str (cossa float-accessories-cmds (bufget-u8 data 1))))))
    (match (cossa float-accessories-cmds (bufget-u8 data 1))
        ;(COMMAND_GET_INFO {
        ;})
        (COMMAND_RUN_LISP {
            (var payload-len (- (buflen data) 2))
            (var payload (bufcreate payload-len))
            (bufcpy payload 0 data 2 payload-len)
            ; Trapped and logged: a typo in a QML-sent expression used to
            ; kill the event thread, costing a >=1s control blackout with
            ; nothing in the console to say why.
            (if (dbg-active DBG-CMD) (dbg DBG-CMD (str-merge "cmd " (to-str payload))))
            (var res (trap (eval (read payload))))
            (if (eq (ix res 0) 'exit-error)
                (dbg-err (str-merge "cmd " (to-str (ix res 1)) " in " (to-str payload))))
            (free payload)
        })
        (COMMAND_BMS_STATUS {
            (var send-buffer (bufcreate 3))
            (bufset-u8 send-buffer 0 FLOAT_ACCESSORIES_MAGIC)
            (bufset-u8 send-buffer 1 (assoc float-accessories-cmds 'COMMAND_BMS_STATUS))
            (bufset-u8 send-buffer 2 bms-status)
            (if (>= can-id 0) (send-data send-buffer 2 can-id)
                (send-data send-buffer))
            (free send-buffer)
        })
        (_ (if (dbg-active DBG-CMD)
               (dbg DBG-CMD (str-merge "cmd ? " (str-from-n (bufget-u8 data 1) "%d"))))) ; Ignore other commands
    )
})



(defun command-rx (data) {
    (if (< (buflen data) 2) {
        (dbg DBG-CMD "cmd short packet")
    } {
        (var magic-byte (bufget-u8 data 0))

        ; Route to Pubmote BLE RX handler
        (if (= magic-byte PUBMOTE_MAGIC) {
            (pubmote-ble-rx data)
        })

        ; Route to Accessories QML command handler
        (if (= magic-byte FLOAT_ACCESSORIES_MAGIC) {
            (float-accessories-command-rx data)
        })

        ; Optional providers recognize their own packet namespaces.
        (var handled (integration-receive data))

        ; Anything else is a packet meant for someone else (or a mismatched
        ; QML page). Logging it is the only way to tell those two apart.
        (if (and (!= magic-byte PUBMOTE_MAGIC)
                 (!= magic-byte FLOAT_ACCESSORIES_MAGIC)
                 (not handled)
                 (dbg-tick DBG-CMD 'cmd-rx 2.0))
            (dbg DBG-CMD (str-merge "cmd unrouted magic "
                (str-from-n magic-byte "%d"))))
    })
})

@const-end
