# Float Accessories

<H3>About</H3>

A VESC Express package for BMS, Pubmote, GNSS and LED control, with optional Refloat integration for one-wheeled balance vehicles.

<H3>Integration</H3>

Select <b>Refloat</b> (the default) for vehicle telemetry and remote-control
forwarding, or <b>Standalone</b> to run local lighting and accessories
without ESC discovery or polling. Standalone lighting keeps the selected riding
effect and brightness, defaults to the front direction, and supports local
on/off and highbeam controls. Ride-dependent features require fresh vehicle
telemetry. A connected BMS can still supply battery and charging information.

The bundled Refloat adapter is isolated from the lighting core. See
<a href='LED.md'>LED.md</a> for the provider interface and standalone behavior.

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
  <li>New LED backend</li>
  <li>GNSS receiver support (u-blox or NMEA over UART) - feeds the SD log position and the CAN GNSS broadcast</li>
  <li>Diagnostics card on the Config tab: per-area verbose logging plus a one-shot system report. The flag is held in RAM only, so it never persists and resets on reboot.</li>
</ul>

