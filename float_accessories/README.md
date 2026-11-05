# Float Accessories

<H3>About</H3>

A VESC Express package for BMS, Pubmote, GNSS and LED control, with optional Refloat integration for one-wheeled balance vehicles.

<H3>Credits</H3>

Special Thanks: Benjamin Vedder, surfdado, NuRxG, Siwoz, lolwheel (OWIE), ThankTheMaker (rESCue), 4_fools (avaspark), auden_builds (pubmote)
gr33tz: outlandnish, exphat, datboig42069
Beta Testers: Pickles

<H3>Support Future Work</H3>

Support me on Patreon: <a href='https://patreon.com/SylerTheCreator'>https://patreon.com/SylerTheCreator</a>

Buy me a coffee: <a href='https://venmo.com/sylerclayton'>https://venmo.com/sylerclayton</a>

My Blog: <a href='https://sylerclayton.com'>https://sylerclayton.com</a>

<H3>Release Notes</H3>

<ul>
  <li>Native libraries are bundled for ESP32-C3, ESP32-C6, ESP32-S3 and ESP32-S31 only, to leave flash for the startup image. Other chips report an unsupported-target error.</li>
  <li>New LED backend</li>
  <li>SSBMS support over UART (115200 baud, configurable RX/TX pins) or BLE (VESC Express LispBM BLE client; set the Express Bluetooth LispBM role to Client): read-only cell, temperature and charging telemetry, estimated SoC, and VESC BMS CAN reporting.</li>
  <li>Standalone mode runs local lighting and accessories without Refloat discovery, telemetry polling or remote-control forwarding.</li>
  <li>GNSS receiver support (u-blox or NMEA over UART) - feeds the SD log position and the CAN GNSS broadcast</li>
  <li>Diagnostics card on the Config tab: per-area verbose logging plus a one-shot system report. The flag is held in RAM only, so it never persists and resets on reboot.</li>
</ul>

<H3>Building</H3>

- `make`: universal package (`float_accessories.vescpkg`) plus separate C3, C6, S3 and S31 packages.
- `make float_accessories.vescpkg`: universal package only.
- `make PACKAGE_TARGET=esp32c3`: C3 package.
- `make PACKAGE_TARGET=esp32c6`: C6 package.
- `make PACKAGE_TARGET=esp32s3`: S3 package.
- `make PACKAGE_TARGET=esp32s31`: S31 package.
