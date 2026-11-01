# BMS backends

Reference for the Float Accessories BMS service and its backends: shared
service and lifecycle in `lib/bms.lisp` and `lib/bms-backend.lisp`, adapters
under `lib/adapters/`, and native framing helpers under `native/`. Backend
selection is independent of the LED module and the vehicle integration.

The BMS enable flag remains separate from `bms_backend`: **None** (0, default),
**OW** (1), **SSBMS UART** (2) or **SSBMS BLE** (3). Config → BMS contains the backend selector,
OW-specific settings, and the SSBMS UART RX/TX GPIO settings
(`ssbms_uart_rx_pin`, `ssbms_uart_tx_pin`). These pins default to -1
(unassigned); ESP RX connects to SSBMS TX and ESP TX to SSBMS RX. SSBMS BLE
needs no pins. With BMS disabled or None selected, no BMS worker starts.
Backend switching waits for the old worker to release its UART or BLE link; a
timeout prevents starting a second owner.
This backend selection is independent of the main integration setting.

Both SSBMS transports share the protocol core in `lib/adapters/ssbms.lisp`
(polling, decoding, publishing), which registers no backend. Each transport is a
thin adapter that opens its link, installs its read function and registers its
own backend ID: `ssbms-uart.lisp` and `ssbms-ble.lisp`. To drop one, remove its
line from `lib/entry/bms.lisp` and its import in `float_accessories.lisp`; the
core stays as long as either transport is kept.

SSBMS UART (`lib/adapters/ssbms-uart.lisp`) uses UART 1 at 115200 baud, 8 data bits, no parity, one stop bit. The
user confirmed its BLE module is a UART bridge using identical frames. Pin
configuration must assign distinct RX/TX GPIOs. A GNSS configuration sharing
UART 1, or using the global Lisp UART API for NMEA on any port, prevents SSBMS
UART from starting. u-blox on a different UART is independent.

SSBMS BLE (`lib/adapters/ssbms-ble.lisp`) uses the VESC Express LispBM GATT
client, so it needs Express firmware with `ble-client-*` and the Bluetooth
LispBM role set to Client (2) or Client and server (3); the built-in VESC Tool
BLE service can stay enabled. Client access goes through `lib/ble-client.lisp`.
With a pinned BMS it actively scans for that
address and address type only. With none pinned it stays idle until Scan is
pressed; the picker lists local names containing SSBMS or XJBMS
(case-insensitive), without connecting. Selecting Connect saves that peer.
It then connects, exchanges MTU,
discovers service `00002760-08c2-11e1-9073-0e8ac72e1001`, subscribes to the
`…0002` reply notifications and writes requests to `…0001` without response
(acknowledged writes if the BMS does not offer that). Notifications are
appended until the same native scanner finds a complete CRC-valid reply, so a
small MTU that splits a 71-byte 32-cell reply still works. Replies time out
after 400 ms. The backend is the sole consumer of the firmware's client event
queue; a dropped event or disconnect tears down the link. With no complete
snapshot for 10 s it disconnects, waits 2 s and rescans. Pairing is not used.
Everything after the transport (polling, validation, publication, staleness and
CAN) is the shared SSBMS core under backend ID 3.

Pinning protects the ESC from using a nearby pack's cells for its limits. The
pinned peer is stored in `ssbms_ble_paired_address_a` (address bytes 0-3, big-endian)
and `ssbms_ble_paired_address_b` (bytes 4-5, address type 0 public / 1 random, then 1
when pinned); `0`/`0` means not pinned. The SSBMS BLE card's Scan button sends
`(ssbms-ble-request-scan)`. The backend drops any link, scans for five seconds,
reports each SSBMS/XJBMS once as `ssbms-found a b rssi name` and finishes with
`ssbms-scan-done count` (`-1` when the backend is not running, `-2` when the
scanner is busy or its request failed). Connect sends
`(ssbms-ble-select a b)`: the device writes and stores the two ints itself,
drops any link and reconnects to the new pin. This works with the backend
stopped, so a stale pin can always be forgotten. It answers
`ssbms-ble-selected 1|0 a b` (0 when nothing was saved, such as test mode
refusing the write). The UI shows a pinned address as "Saved BMS", with
Forget, whether or not it is currently connected. This is an address preference,
not Bluetooth bonding. Forget is `(ssbms-ble-select 0 0)`; it drops the link
and returns to idle until another Scan and selection. While
connected it sends `ssbms-ble-link 1 a b rssi` once a second and
`ssbms-ble-link 0 0 0 0` after a link ends.

Enable BMS diagnostics in the UI or run `(dbg-add DBG-BMS)` in the Lisp console
to trace scanning, peer address/type, connection handle, MTU, service discovery,
characteristic handles, notification subscription and the first complete telemetry
snapshot. Missing advertisements and a busy shared scanner are normal retry
states, reported only through progress and BMS debug logging. Actual scan or
connection setup failures emit warnings even when BMS debug logging is off. Warnings
include the operation and native status, or a reason such as `timeout`,
`events-lost`, `not-found` or `(busy scanner-owner connector-owner)`. An `orphan`
connector means an earlier attempt is still awaiting its firmware completion.
For example, `(connect 9)` is an immediate connection request rejection;
`(ble-connect-result timeout)` means no completion arrived before the deadline.

The page receives `ssbms-ble-progress phase message`: phases 1–5 cover scanning,
connecting, MTU, discovery and subscription; 6 means the BLE transport is ready;
0 means stopped or failed. A saved address alone does not imply Connecting or
Connected. Connected requires a live link to that address; after a failed attempt
the row offers Retry. A 20-second page watchdog clears stale Connecting progress
and directs the user to the Lisp console; backend retry timing is independent.

The BMS Config section shows an SSBMS Telemetry card for a connected UART or
BLE BMS. It displays pack voltage, estimated SoC, every cell voltage, minimum,
maximum and spread, charging current, charge permission and battery/MOSFET
temperatures. While that section is open, `(ssbms-state)` requests a snapshot
once per second. Its age comes from the last complete BMS update, rather than
the UI request time, and continues increasing between responses. Readings older
than three seconds are marked stale. If BLE remains linked while telemetry
stops, the last complete sample remains visible with its age; disconnecting or
stopping the backend clears it. A new link shows a waiting message until its
first complete sample arrives.

For either transport, the adapter reads the cell count (12–32), then complete
cells + 16-register status cycles twice per second. There is one read
outstanding at a time, with a 300 ms request timeout and bounded nonblocking
reads over UART (400 ms over BLE). Native scanning accepts only CRC-valid
replies with the requested register and byte count, including fragmented or
noisy input. Metadata or a partial cycle cannot mark
a connection fresh or trigger a CAN broadcast. After three seconds without a
complete snapshot the connection expires and cell count discovery restarts.

Published data includes cells, sum/min/max voltage, MOSFET and battery
temperatures, charging current (negative in VESC convention), charge-allowed,
and normalized faults/charging. SoC is estimated from the lowest cell using
the configured Cell Type curve. No discharge-current sensor, SoH, battery
model, cycle count or energy counters are documented; unavailable counters and
SoH are zero, model/cycles stay unknown. The global balancing flag is carried
in CAN status; individual balancing cells are not fabricated. Protection,
factory, pairing and storage-mode writes are not exposed.

SSBMS CAN publication uses the shared `bms-broadcast` helper so charging and
balancing flags are accurate despite firmware 7.00 lacking corresponding Lisp
setters. It emits the VESC BMS packets, contiguous cell/temperature sequences,
and firmware-compatible float32_auto values only for fresh snapshots.

The protocol is based on the Indy Speed Control 3.8 reverse-engineering spec
(2026-10-31), including its verified CRC/frame vectors. Register scaling and
current sign still need testing with an actual SSBMS.

`lib/bms.lisp` is the shared service: connection freshness, normalized status,
charging detection, and public commands. `lib/bms-backend.lisp` owns selection
and worker lifecycle. OW framing, encryption, pairing, UART pins and buffers
live in `lib/adapters/ow-bms.lisp` and `ow-bms-vars.lisp`.

A backend registers `(bms-register id run request-stop cleanup command capabilities)`.
Imports only register callbacks; buffers and hardware are acquired by `run`.
`request-stop` must wake or cancel the worker promptly; `cleanup` releases its
resources before the manager acknowledges shutdown. Failed cleanup prevents a
replacement from taking ownership. Adapters remain statically imported; only
the enabled, selected backend runs. Adapters load from `lib/entry/bms.lisp`;
removing an adapter's line there and its `import` in `float_accessories.lisp`
leaves the service usable; selecting an unavailable backend starts no worker.

Adapters publish scalar/indexed VESC BMS values through `bms-publish-value` and
`bms-publish-indexed`, metadata through `bms-publish-info`, and normalized flags
through `bms-publish-status`. They call `bms-mark-received` only after validating
and processing a complete packet/snapshot. Default freshness is one second;
SSBMS requests three seconds through `bms-set-freshness`. Freshness does not
depend on receiving OW status flags. Publication from a backend
that no longer owns the service is ignored.

The shared command API is `bms-request-charge`, `bms-request-factory-init`, and
`bms-pair`. Capability bits gate charge control (1), factory initialization (2)
and pairing (4); unsupported commands return nil. SSBMS advertises no write
capabilities. Protocol branches remain in adapters rather than settings, vehicle
state or the CAN loop.

Native sources live under `native/ssbms/` (XMODEM CRC, read-frame building and
stream validation), `native/ow_bms/` (FM/OW checksum and marker scanning), and
`native/bms_extensions.c` (checked Lisp wrappers and CAN float encoding). They
link into the existing FA native image built by `fa_cfg/Makefile`; there is no
additional library allocation. OW AES already runs in firmware C; lifecycle,
polling, settings and command sequencing remain in its Lisp adapter.
