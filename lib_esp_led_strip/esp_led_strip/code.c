/*
	Copyright 2026 VESC project

	This file is part of the VESC firmware.

	The VESC firmware is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    The VESC firmware is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

// ext-esp_led-*: segmented addressable-LED strip engine as a native library.
//
// Lisp sets segment / effect state; a render thread animates, applies
// brightness and auto-white, and pushes pixels through the firmware rgbled
// driver - rgbled_init per pin at start, rgbled_update(pin, ...) per changed
// group per frame. The firmware drives every strip from ONE RMT channel,
// re-routed per update, so a frame's wire time is the sum over the groups
// that changed. That is the ceiling a high ext-esp_led-fps hits first.
//
// The RISC-V targets execute in place from flash: no writable globals (all
// state hangs off ARG) and no libm, so the effect math is integer only.
//
// Colors are packed 0xWWRRGGBB ints, like the color-* extensions.

#include "express/vesc_c_if.h"

#include <string.h>

HEADER

#define esp_led_SEG_MAX     8
#define esp_led_OV_MAX      8   // overlay pixels per segment

// Frame pacing. The loop sleeps the frame time minus the work it just did,
// and advances the phase by measured elapsed time - so animations keep
// real-world speed at any frame rate, and when the loop falls behind.
#define esp_led_FRAME_MS_DEF   33   // ~30 fps, the default target
#define esp_led_FRAME_MS_MIN   5    // 200 fps ceiling - the lisp VM, wifi and
                                    // bluetooth share this core on the C3/C6
#define esp_led_FRAME_MS_MAX   200  // 5 fps floor

// Phase (and the fade rate) is counted per this much real time, so spd keeps
// the meaning it had when the frame was a fixed 33 ms.
#define esp_led_PHASE_REF_MS   33

// Starting speed, and the fallback for spd 0 - which reads as "unset", not
// "stopped", so a segment never given a speed still animates.
#define esp_led_SPD_DEF        32

// Starting brightness ease: 32nds of the remaining gap closed per
// PHASE_REF_MS. 15/32 is ~47%, ~0.2 s to settle; 0 would be instant.
#define esp_led_FADE_DEF       15

// A late frame advances the phase by the time it missed, capped here: a long
// stall should resume the animation, not teleport it.
#define esp_led_CATCHUP_MS_MAX 250

// Quiet time before a keepalive retransmit, so a pixel corrupted by line
// noise heals. Timed, not counted in frames, so it holds at any frame rate.
#define esp_led_REFRESH_MS_DEF 2000

// Effects. gen_defs.py mirrors these ids into esp_led_defs.lisp; a stale
// mirror selects the wrong effect silently.
enum {
	FX_OFF = 0,   // all pixels off (ignores the colour) - the zeroed default
	FX_CUSTOM,    // consumer-supplied pixels (ext-esp_led-seg-pixel / -pixels)
	FX_SOLID,     // full strip of the segment colour (or palette if colour = 0)
	FX_BREATHE,
	FX_CHASE,
	FX_RAINBOW,
	FX_SPARKLE,
	FX_COMET,
	FX_GAUGE,     // fill by the fx_val param; battery gradient when color = 0
	FX_STROBE,    // hard on/off flash
	FX_LARSON,    // bouncing eye with tail (knight rider)
	FX_FELONY,    // halves alternate red/blue
	FX_THEATER,   // marquee - every third pixel, marching
	FX_WIPE,      // fill end-to-end, then wipe to black
	FX_WAVES,     // overlapping slow waves (pacifica-like)
	FX_CANDLE,    // warm uneven flicker
	FX_HEARTBEAT, // thump-thump double pulse
	FX_TURN,      // turn signal - the fx_val param selects the mode (see below)
};

// Turn-signal mode in seg.fx_val for FX_TURN. The strip splits at its centre;
// a mode picks a side and a style. Laid out so (mode-1)/3 is the side and
// (mode-1)%3 the style: 0 solid, 1 blink, 2 sweep centre -> edge.
enum {
	TURN_OFF = 0,
	TURN_LEFT_SOLID,   TURN_LEFT_BLINK,   TURN_LEFT_SWEEP,
	TURN_RIGHT_SOLID,  TURN_RIGHT_BLINK,  TURN_RIGHT_SWEEP,
	TURN_HAZARD_SOLID, TURN_HAZARD_BLINK, TURN_HAZARD_SWEEP,
};

// Color byte layouts on the wire
enum {
	TYPE_GRB = 0,
	TYPE_RGB,
	TYPE_GRBW,
	TYPE_RGBW,
	TYPE_WRGB,  // white first (WS2814 and friends)
};

// Wire timing presets, forwarded to the firmware driver and never switched on
// here - the enum exists for the lisp mirror.
enum {
	TIMING_GENERIC = 0,
	TIMING_WS2812B,
	TIMING_WS2815,
	TIMING_SK6812,
	TIMING_SK6815,
};

// 4 anchor colors interpolated across pos 0..255. The PAL_<NAME> tag is the
// canonical id; gen_defs.py mirrors it as the row's position + 1, because
// seg_palette_at reserves 0 for the custom palette. Keep the rows in id order.
typedef struct { uint32_t c[4]; } palette_t;
static const palette_t palettes[] = {
	{{0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF}}, // PAL_RGBW      rgbw-ish
	{{0xFF0000, 0xFF8000, 0xFFFF00, 0xFF0000}}, // PAL_FIRE      fire
	{{0x0000FF, 0x00FFFF, 0x00FF80, 0x0000FF}}, // PAL_OCEAN     ocean
	{{0xFF00FF, 0x8000FF, 0x0080FF, 0xFF00FF}}, // PAL_NEON      neon
	{{0xFFFFFF, 0xFF4000, 0x400000, 0x000000}}, // PAL_EMBER     ember
	{{0x00FF00, 0xFFFF00, 0xFF0000, 0x00FF00}}, // PAL_TRAFFIC   traffic
	{{0xFFFFFF, 0x000000, 0xFFFFFF, 0x000000}}, // PAL_STROBE    strobe
	{{0x1030FF, 0xFFFFFF, 0x1030FF, 0x001040}}, // PAL_POLICE    police-blue
	{{0x0B1D51, 0xFF6A00, 0xFFD700, 0x2A0E4F}}, // PAL_SUNSET    sunset
	{{0x000000, 0x8B0000, 0xFF4500, 0xFFFFE0}}, // PAL_LAVA      lava
	{{0x01411F, 0x00FFB2, 0x7A00FF, 0x013220}}, // PAL_AURORA    aurora
	{{0x013220, 0x2E8B57, 0x9ACD32, 0x013220}}, // PAL_FOREST    forest
	{{0x8000FF, 0xFF4000, 0xFF00A0, 0x0040FF}}, // PAL_PARTY     party
	{{0x001F5C, 0x00BFFF, 0xFFFFFF, 0x001F5C}}, // PAL_ICE       ice
	{{0xFF6A00, 0x1A001A, 0x8000FF, 0x000000}}, // PAL_HALLOWEEN halloween
	{{0xFF0000, 0x00FF00, 0xFFC000, 0x0000FF}}, // PAL_CHRISTMAS christmas (c9)
	{{0xFFB3BA, 0xBAFFC9, 0xBAE1FF, 0xFFFFBA}}, // PAL_PASTEL    pastel
	{{0xFF2E6A, 0xFFC0CB, 0xFFF0F5, 0xC71585}}, // PAL_SAKURA    sakura
};
#define PALETTE_COUNT ((int)(sizeof(palettes) / sizeof(palettes[0])))

typedef struct {
	bool defined;
	bool on;
	uint8_t pin;
	uint8_t type;      // TYPE_*
	uint8_t timing;    // wire timing preset, 0 = generic
	uint16_t len;      // pixels
	bool reverse;
	bool auto_white;   // Derive the white channel from the common RGB part
	uint8_t fx;
	uint8_t pal;
	uint8_t bri;       // per-segment brightness target 0..255
	uint8_t bri_cur;   // eased current brightness
	uint8_t spd;       // 0..255
	uint8_t size;      // chase head / comet tail length
	// Per-effect parameter: gauge fill 0..255, turn-signal mode (TURN_ enum).
	// Effects with no parameter ignore it.
	uint8_t fx_val;
	uint16_t offset;   // pixel offset within the pin's chain
	uint32_t color;    // packed 0xWWRRGGBB - the target
	// Eased current colour and its rate, same units as the brightness fade.
	// 0 (the default) lands colour changes instantly. Rendering reads
	// color_cur; everything that sets an appearance writes color.
	uint32_t color_cur;
	uint8_t color_fade;
	uint32_t phase;    // effect position, advanced by elapsed real time
	uint16_t phase_rem; // sub-unit phase carried between frames (render_thd)
	// Fixed cycle time in ms, the alternative to spd; 0 (the default) leaves
	// spd driving the phase. See fx_period and render_thd.
	uint16_t cycle_ms;

	// Overlay pixels: LEDs at fixed segment-relative positions (e.g. embedded
	// highbeams) showing ov_color at ov_bri while the effect pixels flow
	// around them. They extend the footprint to len + ov_count.
	uint8_t ov_count;
	uint8_t ov_idx[esp_led_OV_MAX];
	uint32_t ov_color;
	uint8_t ov_bri;

	// FX_CUSTOM pixel buffer (len packed colors), so a consumer can run its own
	// effect and still get brightness and channel pooling. NULL until custom
	// mode is entered.
	uint32_t *manual;

	// Custom palette (used when pal == 0), set via ext-esp_led-seg-palette.
	uint32_t cpal[4];

	int group;         // pin group index, assigned at init
} seg_t;

// Segments sharing a pin form one chain (their offsets place them along it),
// rendered into one buffer and sent once per frame. The driver transmits
// asynchronously from the caller's memory, so a long chain can still be on
// the wire when the next frame renders - hence the double buffer.
typedef struct {
	uint8_t pin;
	uint8_t colors;      // bytes per pixel of the chain
	uint8_t timing;      // wire timing preset of the chain
	uint16_t chain_len;  // pixels
	uint8_t *txbuf[2];   // chain_len * colors bytes each
	uint8_t cur;         // buffer rendered and transmitted this frame
	uint32_t quiet_ms;   // ms since the last transmission
} group_t;

typedef struct {
	lib_thread thread;
	lib_mutex lock;
	volatile bool running;

	seg_t seg[esp_led_SEG_MAX];
	int seg_count;

	group_t group[esp_led_SEG_MAX];
	int group_count;

	uint8_t master_bri;  // target
	uint8_t master_cur;  // eased current
	uint8_t fade;        // gap fraction closed per esp_led_PHASE_REF_MS in
	                     // 32nds, 0 = instant
	uint16_t frame_ms;   // target frame time, set by ext-esp_led-fps
	uint32_t refresh_ms; // unchanged-frame refresh interval, 0 = every frame

	uint16_t buf_len;    // pixels the work buffer holds
	uint32_t *work;      // packed 0xWWRRGGBB, buf_len entries
} esp_led_t;

static esp_led_t *state(void) {
	return (esp_led_t*)ARG;
}

// ---- Color helpers ------------------------------------------------------

static uint32_t pack(uint32_t r, uint32_t g, uint32_t b, uint32_t w) {
	return (w << 24) | (r << 16) | (g << 8) | b;
}

// Walk channels instead of unrolling them: S3 loads this code into scarce IRAM.
static uint32_t scale(uint32_t c, uint32_t num) { // num 0..255
	uint32_t result = 0;
	for (unsigned int shift = 0; shift < 32; shift += 8) {
		result |= ((((c >> shift) & 0xFF) * num) / 255) << shift;
	}
	return result;
}

// Interpolate a position 0..255 across 4 anchor colours (wrapping).
static uint32_t interp4(const uint32_t *c, uint8_t pos) {
	uint32_t a = c[pos / 64];
	uint32_t b = c[(pos / 64 + 1) % 4];
	uint32_t f = pos % 64;
	uint32_t result = 0;
	for (unsigned int shift = 0; shift < 24; shift += 8) {
		result |= ((((a >> shift) & 0xFF) * (63 - f)
			+ ((b >> shift) & 0xFF) * f) / 63) << shift;
	}
	return result;
}

static uint32_t palette_at(uint8_t pal, uint8_t pos) {
	return interp4(palettes[pal % PALETTE_COUNT].c, pos);
}

// Palette for a segment. pal 0 is the segment's custom palette (cpal); pal
// 1..N map to the built-in palettes (index - 1), so adding custom at 0 did
// not renumber the const table.
static uint32_t seg_palette_at(const seg_t *s, uint8_t pos) {
	if (s->pal == 0) {
		return interp4(s->cpal, pos);
	}
	return palette_at(s->pal - 1, pos);
}

// Triangle wave 0..255..0 over a 512-step period.
static uint32_t triangle(uint32_t x) {
	x &= 511;
	return x < 256 ? x : 511 - x;
}

// ---- Effect renderers ---------------------------------------------------

static void fx_render(const seg_t *s, uint32_t *work) {
	int n = s->len;
	// Phase accumulates (see render_thd), so a speed change alters the rate
	// from here on instead of jumping the animation to a new position.
	uint32_t ph = s->phase;
	int size = s->size ? s->size : 8;

	// Animation rates. The base is 4096 phase units - one cycle per ~4 s at
	// the default speed - and each effect divides ph so its own period lands
	// there, so switching effects at one speed behaves. Two groups sit off it:
	// effects modelling something real keep that rate (heartbeat ~60 bpm, turn
	// blink ~1.9 Hz, strobe and felony a hard flash), and effects that travel
	// the strip scale their period with the LED count, holding pixel velocity
	// rather than crossing time.
	//
	// A color of 0 means "from the palette". Rainbow always renders the
	// palette, solid keeps 0 = black so segments can be blanked, and gauge
	// uses its battery gradient.
	switch (s->fx) {
	case FX_BREATHE: {
		uint32_t b = triangle(ph / 4);
		uint32_t c0 = s->color_cur ? s->color_cur : seg_palette_at(s,(uint8_t)(ph / 128));
		uint32_t c = scale(c0, b);
		for (int i = 0; i < n; i++) work[i] = c;
	} break;

	case FX_CHASE: {
		int head = (int)((ph / 32) % (uint32_t)(n > 0 ? n : 1));
		for (int i = 0; i < n; i++) {
			int d = i - head;
			if (d < 0) d += n;
			uint32_t b = d < size ? 255 - (d * 255) / size : 0;
			uint32_t c = s->color_cur ? s->color_cur
				: seg_palette_at(s,(uint8_t)((i * 255) / (n ? n : 1)));
			work[i] = scale(c, b);
		}
	} break;

	case FX_RAINBOW: {
		for (int i = 0; i < n; i++) {
			uint8_t pos = (uint8_t)((i * 255) / (n ? n : 1) + ph / 16);
			work[i] = seg_palette_at(s,pos);
		}
	} break;

	case FX_SPARKLE: {
		for (int i = 0; i < n; i++) {
			// Deterministic twinkle from phase + index
			uint32_t h = ((uint32_t)i * 2654435761u) ^ ((ph / 128) * 40503u);
			uint32_t c = s->color_cur ? s->color_cur
				: seg_palette_at(s,(uint8_t)(h >> 16));
			work[i] = ((h >> 8) & 0xFF)
				< ((uint32_t)(s->spd ? s->spd : esp_led_SPD_DEF) / 2 + 1) ? c : 0;
		}
	} break;

	case FX_COMET: {
		int head = (int)((ph / 32) % (uint32_t)(n > 0 ? n : 1));
		for (int i = 0; i < n; i++) {
			int d = head - i;
			if (d < 0) d += n;
			uint32_t b = d < size ? 255 - (d * 255) / size : 0;
			uint32_t c = s->color_cur ? s->color_cur : seg_palette_at(s,(uint8_t)(ph / 32));
			work[i] = scale(c, b);
		}
	} break;

	case FX_GAUGE: {
		// Fill the first fx_val/255 of the strip, in the segment color; else
		// the palette as a gradient revealed by the fill; else (color 0,
		// palette 0) a battery gradient, red when empty to green when full.
		// spd > 0 pulses the fill.
		int lit = (n * s->fx_val + 254) / 255;
		if (s->fx_val > 0 && lit < 1) lit = 1;
		uint32_t b = s->spd ? 140 + triangle(ph / 8) * 115 / 255
			: 255;
		if (!s->color_cur && s->pal) {
			for (int i = 0; i < n; i++) {
				work[i] = i < lit
					? scale(seg_palette_at(s,(uint8_t)((i * 255) / n)), b)
					: 0;
			}
			break;
		}
		uint32_t c;
		if (s->color_cur) {
			c = s->color_cur;
		} else if (s->fx_val < 51) { // < 20%: red
			c = 0xFF0000;
		} else {
			uint32_t g = ((uint32_t)s->fx_val * 255) / 204; // fx_val/0.8
			if (g > 255) g = 255;
			c = pack(255 - g, g, 0, 0);
		}
		c = scale(c, b);
		for (int i = 0; i < n; i++) work[i] = i < lit ? c : 0;
	} break;

	case FX_STROBE: {
		uint32_t flash = ph / 64;
		uint32_t c = s->color_cur ? s->color_cur
			: seg_palette_at(s,(uint8_t)(flash * 61)); // new hue per flash
		bool lit = flash & 1;
		for (int i = 0; i < n; i++) work[i] = lit ? c : 0;
	} break;

	case FX_LARSON: {
		int span = n > 1 ? n - 1 : 1;
		int pos = (int)((ph / 16) % (uint32_t)(2 * span));
		if (pos > span) pos = 2 * span - pos;
		uint32_t c = s->color_cur ? s->color_cur : seg_palette_at(s,(uint8_t)(ph / 128));
		for (int i = 0; i < n; i++) {
			int d = i > pos ? i - pos : pos - i;
			uint32_t b = d < size ? 255 - (d * 255) / size : 0;
			work[i] = scale(c, b);
		}
	} break;

	case FX_FELONY: {
		bool swap = ((ph / 48) & 1);
		uint32_t c1 = swap ? 0x0000FF : 0xFF0000;
		uint32_t c2 = swap ? 0xFF0000 : 0x0000FF;
		for (int i = 0; i < n; i++) {
			work[i] = i < n / 2 ? c1 : c2;
		}
	} break;

	case FX_THEATER: {
		// Marquee: every third pixel lit, marching along the strip
		int offset = (int)((ph / 64) % 3);
		for (int i = 0; i < n; i++) {
			bool lit = ((i + 3 - offset) % 3) == 0;
			uint32_t c = s->color_cur ? s->color_cur
				: seg_palette_at(s,(uint8_t)((i * 255) / n + ph / 64));
			work[i] = lit ? c : 0;
		}
	} break;

	case FX_WIPE: {
		// Fill end-to-end with color, then wipe to black from the same
		// end. With color 0 each fill cycle takes a new palette color.
		uint32_t period = 2u * (uint32_t)n;
		uint32_t pos = (ph / 32) % period;
		bool filling = pos < (uint32_t)n;
		int edge = (int)(filling ? pos : pos - (uint32_t)n);
		uint32_t c = s->color_cur ? s->color_cur
			: seg_palette_at(s,(uint8_t)(((ph / 32) / period) * 47));
		for (int i = 0; i < n; i++) {
			bool lit = filling ? (i <= edge) : (i > edge);
			work[i] = lit ? c : 0;
		}
	} break;

	case FX_WAVES: {
		// Overlapping slow waves, pacifica-like: one wave picks the
		// palette position, another modulates brightness on top of a
		// floor so the strip shimmers instead of blinking.
		for (int i = 0; i < n; i++) {
			uint32_t p = ((uint32_t)i * 255) / (uint32_t)n;
			uint32_t w1 = triangle(p * 2 + ph / 8);
			uint32_t w2 = triangle(p * 3 + 170 + 1024 - ph / 12);
			uint32_t w3 = triangle(p + 85 + ph / 20);
			uint32_t c0 = s->color_cur ? s->color_cur
				: seg_palette_at(s,(uint8_t)((w1 + w3) / 2));
			work[i] = scale(c0, 64 + (w2 * 191) / 255);
		}
	} break;

	case FX_CANDLE: {
		// Warm uneven flicker: smooth deterministic noise per pixel,
		// interpolated between flicker steps. Color 0 = candle flame
		// (this effect does not cycle the palette).
		uint32_t t = ph / 128;
		uint32_t f = (ph & 127) * 2; // 0..254 between flicker steps
		uint32_t c0 = s->color_cur ? s->color_cur : 0xFF9329;
		for (int i = 0; i < n; i++) {
			uint32_t h1 = ((uint32_t)i * 2654435761u) ^ (t * 40503u);
			uint32_t h2 = ((uint32_t)i * 2654435761u) ^ ((t + 1) * 40503u);
			uint32_t b1 = (h1 >> 8) & 0xFF;
			uint32_t b2 = (h2 >> 8) & 0xFF;
			uint32_t b = (b1 * (255 - f) + b2 * f) / 255;
			work[i] = scale(c0, 100 + (b * 155) / 255);
		}
	} break;

	case FX_HEARTBEAT: {
		// Double pulse: strong thump, short gap, weaker thump, rest
		uint32_t cyc = (ph / 2) & 511;
		uint32_t b = 0;
		if (cyc < 96) {
			b = 255 - (cyc * 255) / 96;
		} else if (cyc >= 160 && cyc < 240) {
			uint32_t d = cyc - 160;
			b = 180 - (d * 180) / 80;
		}
		if (b < 16) b = 16; // faint glow between beats
		uint32_t c = s->color_cur ? s->color_cur : seg_palette_at(s,(uint8_t)(ph / 128));
		c = scale(c, b);
		for (int i = 0; i < n; i++) work[i] = c;
	} break;

	case FX_TURN: {
		// seg.fx_val selects side + style (TURN_* enum). Amber when no segment
		// colour is set; blank if off or the mode is bad.
		for (int i = 0; i < n; i++) work[i] = 0;
		int mode = s->fx_val;
		if (mode < TURN_LEFT_SOLID || mode > TURN_HAZARD_SWEEP) {
			break;
		}
		int m = mode - 1;
		int side = m / 3;    // 0 left, 1 right, 2 both (hazard)
		int style = m % 3;   // 0 solid, 1 blink, 2 sweep
		bool do_left  = (side == 0 || side == 2);
		bool do_right = (side == 1 || side == 2);
		uint32_t c = s->color_cur ? s->color_cur : 0xFF6400; // amber default

		// Pixels per side: left is [0, half), right is [n - half, n). On an odd
		// strip that makes the centre pixel part of BOTH sides, which is what
		// keeps the effect symmetric - splitting it away instead leaves one side
		// a pixel longer, so the two sweeps run at different periods and drift,
		// and fx_period can only describe one of them. Even strips split in two
		// exactly as before.
		int half = (n + 1) / 2;

		if (style == 0) {          // solid
			if (do_left)  for (int i = 0; i < half; i++) work[i] = c;
			if (do_right) for (int i = n - half; i < n; i++) work[i] = c;
		} else if (style == 1) {   // blink
			if ((ph / 256) & 1) {
				if (do_left)  for (int i = 0; i < half; i++) work[i] = c;
				if (do_right) for (int i = n - half; i < n; i++) work[i] = c;
			}
		} else {                   // sweep, centre -> edge, with a blank gap
			// One period for both sides, so hazard stays in step.
			int period = half + (half / 2 > 3 ? half / 2 : 3);
			int prog = (int)((ph / 32) % (uint32_t)period);
			int lit = prog < half ? prog + 1 : 0;
			if (do_left)  for (int j = 0; j < lit; j++) work[(half - 1) - j] = c;
			if (do_right) for (int j = 0; j < lit; j++) work[(n - half) + j] = c;
		}
	} break;

	case FX_CUSTOM: {
		// Consumer-driven pixels; brightness / overlay still apply in render_seg.
		if (s->manual) {
			for (int i = 0; i < n; i++) work[i] = s->manual[i];
		} else {
			for (int i = 0; i < n; i++) work[i] = 0;
		}
	} break;

	case FX_OFF:
		for (int i = 0; i < n; i++) work[i] = 0;
		break;

	case FX_SOLID:
	default: {
		uint32_t c = s->color_cur ? s->color_cur
			: seg_palette_at(s,(uint8_t)(ph / 128));
		for (int i = 0; i < n; i++) work[i] = c;
	} break;
	}
}

// Phase units in one cycle of a segment's effect: each renderer's ph divisor
// times its period. Effects with no real cycle (sparkle, candle, waves) take
// the 4096 base. Only cycle_ms mode uses this - keep it in step with the
// renderers, since a wrong period gives a wrong cycle time, not a fault.
static uint32_t fx_period(const seg_t *s) {
	uint32_t n = s->len ? s->len : 1;
	switch (s->fx) {
	case FX_CHASE:
	case FX_COMET:     return 32u * n;
	case FX_WIPE:      return 64u * n;          // fill then wipe
	case FX_LARSON:    return 32u * (n > 1 ? n - 1 : 1); // there and back
	case FX_FELONY:    return 96u;
	case FX_STROBE:    return 128u;             // one on/off pair
	case FX_THEATER:   return 192u;             // three marching steps
	case FX_HEARTBEAT: return 1024u;
	case FX_BREATHE:   return 2048u;
	case FX_TURN: {
		int style = (s->fx_val >= TURN_LEFT_SOLID
			&& s->fx_val <= TURN_HAZARD_SWEEP) ? (s->fx_val - 1) % 3 : 0;
		if (style == 1) {
			return 512u;                        // blink
		}
		if (style == 2) {                       // sweep, centre -> edge
			// Both sides are this long (see FX_TURN), and n >= 1, so h >= 1.
			int h = ((int)n + 1) / 2;
			return 32u * (uint32_t)(h + (h / 2 > 3 ? h / 2 : 3));
		}
		return 4096u;                           // solid: nothing animates
	}
	default:           return 4096u;
	}
}

// ---- Render thread ------------------------------------------------------

// Close fade/32 of the remaining gap per PHASE_REF_MS of real time, so a fade
// takes the same wall-clock time at any frame rate. 0 jumps immediately.
//
// The 1-step-per-frame floor guarantees progress; at high frame rates it
// closes the last few counts faster than the rate asks, which only ever
// shortens the tail of a fade.
static uint8_t ease_u8(uint8_t cur, uint8_t target, uint8_t fade,
	uint32_t elapsed) {
	if (fade == 0) {
		return target;
	}
	int d = (int)target - (int)cur;
	if (d == 0) {
		return cur;
	}
	int mag = d > 0 ? d : -d;
	int step = (int)(((uint32_t)mag * fade * elapsed)
		/ (32u * esp_led_PHASE_REF_MS));
	if (step < 1) step = 1;
	if (step > mag) step = mag;
	return d > 0 ? cur + step : cur - step;
}

// Per-channel colour ease on the brightness curve, so the two settle together.
// Colour 0 means "from the palette", so a fade is only meaningful between two
// real colours - either end at 0 lands immediately, which also avoids fading
// up from black when a segment leaves a palette effect for a solid one.
static uint32_t ease_color(uint32_t cur, uint32_t target, uint8_t fade,
	uint32_t elapsed) {
	if (fade == 0 || cur == 0 || target == 0) {
		return target;
	}
	if (cur == target) {
		return cur;
	}
	uint32_t out = 0;
	for (int sh = 0; sh < 32; sh += 8) {
		uint8_t c = (uint8_t)((cur >> sh) & 0xFF);
		uint8_t t = (uint8_t)((target >> sh) & 0xFF);
		out |= (uint32_t)ease_u8(c, t, fade, elapsed) << sh;
	}
	return out;
}

// Render one segment into its place in the group's chain buffer. Brightness
// is sampled once per frame under the ease lock, not re-read here.
static void render_seg(esp_led_t *st, const seg_t *s, uint8_t master_cur) {
	group_t *grp = &st->group[s->group];
	int n = s->len;
	uint32_t *work = st->work;
	int colors = grp->colors;
	uint8_t *tx = grp->txbuf[grp->cur] + (uint32_t)s->offset * colors;

	fx_render(s, work);

	uint32_t bri = ((uint32_t)s->bri_cur * master_cur) / 255;

	for (int i = 0; i < n; i++) {
		uint32_t c = scale(work[i], bri);

		uint32_t w = (c >> 24) & 0xFF;
		uint32_t r = (c >> 16) & 0xFF;
		uint32_t g = (c >> 8) & 0xFF;
		uint32_t b = c & 0xFF;

		// Derive white from the common RGB part on RGBW strips
		if (s->auto_white && colors == 4 && w == 0) {
			w = r < g ? (r < b ? r : b) : (g < b ? g : b);
			r -= w; g -= w; b -= w;
		}

		work[i] = pack(r, g, b, w);
	}

	// Pack the wire bytes. Overlay pixels take their fixed positions; effect
	// pixels fill the rest in order (reverse applies to those only).
	int total = n + s->ov_count;
	int src = 0;
	for (int i = 0; i < total; i++) {
		bool is_ov = false;
		for (int k = 0; k < s->ov_count; k++) {
			if (s->ov_idx[k] == i) {
				is_ov = true;
				break;
			}
		}

		uint32_t c;
		if (is_ov) {
			c = scale(s->ov_color, s->ov_bri);
		} else if (src < n) {
			c = work[s->reverse ? n - 1 - src : src];
			src++;
		} else {
			c = 0;
		}

		// Channel shifts for each wire format. Tables live in data RAM on S3,
		// leaving more executable RAM available for the renderer itself.
		static const uint8_t shifts[][4] = {
			[TYPE_GRB]  = {8, 16, 0, 24},
			[TYPE_RGB]  = {16, 8, 0, 24},
			[TYPE_GRBW] = {8, 16, 0, 24},
			[TYPE_RGBW] = {16, 8, 0, 24},
			[TYPE_WRGB] = {24, 16, 8, 0}
		};
		unsigned int type = s->type <= TYPE_WRGB ? s->type : TYPE_GRB;
		int channels = type >= TYPE_GRBW ? 4 : 3;
		uint8_t *px = tx + i * colors;
		for (int k = 0; k < channels; k++) {
			px[k] = (uint8_t)(c >> shifts[type][k]);
		}
	}
}

static void render_thd(void *arg) {
	esp_led_t *st = (esp_led_t*)arg;
	systime_t prev = VESC_IF->system_time_ticks();

	while (!VESC_IF->should_terminate()) {
		systime_t start = VESC_IF->system_time_ticks();
		uint32_t elapsed = (uint32_t)(start - prev);
		prev = start;
		if (elapsed > esp_led_CATCHUP_MS_MAX) {
			elapsed = esp_led_CATCHUP_MS_MAX;
		}

		// Ease brightness toward the targets, once per frame.
		VESC_IF->mutex_lock(st->lock);
		st->master_cur = ease_u8(st->master_cur, st->master_bri, st->fade,
			elapsed);
		for (int i = 0; i < st->seg_count; i++) {
			seg_t *s = &st->seg[i];
			s->bri_cur = ease_u8(s->bri_cur, s->bri, st->fade, elapsed);
			s->color_cur = ease_color(s->color_cur, s->color,
				s->color_fade, elapsed);
			if (!s->defined) {
				continue;
			}
			// Two ways to say how fast, both accumulating so a change takes
			// effect in place:
			//   spd:      pixel velocity - spd units per PHASE_REF_MS, so a
			//             travelling effect crosses a longer strip slower.
			//   cycle_ms: one whole fx_period per cycle_ms, so strips of
			//             different lengths finish together and segments
			//             sharing a cycle time are in step by construction.
			// Every segment advances under ONE lock hold, unlike the render
			// pass below: a phase written from lisp mid-pass would otherwise
			// land after some segments had advanced and before others, and
			// ext-esp_led-sync could not line them up exactly.
			uint32_t div, inc;
			if (s->cycle_ms) {
				div = s->cycle_ms;
				inc = fx_period(s) * elapsed + s->phase_rem;
			} else {
				div = esp_led_PHASE_REF_MS;
				inc = (s->spd ? s->spd : esp_led_SPD_DEF) * elapsed
					+ s->phase_rem;
			}
			s->phase += inc / div;
			s->phase_rem = (uint16_t)(inc % div);
		}
		uint8_t master_cur = st->master_cur;
		uint32_t refresh_ms = st->refresh_ms;
		VESC_IF->mutex_unlock(st->lock);

		for (int gi = 0; gi < st->group_count; gi++) {
			group_t *g = &st->group[gi];

			// One lock hold per segment instead of one across the whole pass.
			bool any = false;
			for (int i = 0; i < st->seg_count; i++) {
				VESC_IF->mutex_lock(st->lock);
				seg_t *s = &st->seg[i];
				if (s->defined && s->group == gi && s->len > 0
					&& s->len <= st->buf_len) {
					if (s->on) {
						render_seg(st, s, master_cur);
					} else {
						memset(g->txbuf[g->cur] + (uint32_t)s->offset * g->colors,
							0, (uint32_t)(s->len + s->ov_count) * g->colors);
					}
					any = true;
				}
				VESC_IF->mutex_unlock(st->lock);
			}
			int pin = g->pin;
			uint8_t *tx = g->txbuf[g->cur];
			int tx_bytes = g->chain_len * g->colors;

			// Transmit only frames that differ from what the strip shows (the
			// other buffer holds the last transmitted one), plus a periodic
			// keepalive. The buffer flips only after a real transmission, so
			// the comparison stays against the wire state.
			bool send = false;
			if (any) {
				g->quiet_ms += elapsed;
				if (g->quiet_ms >= refresh_ms
					|| memcmp(g->txbuf[0], g->txbuf[1], (size_t)tx_bytes) != 0) {
					send = true;
					g->quiet_ms = 0;
					g->cur ^= 1;
				}
			}

			// Hardware IO outside the lock - the driver can block while a
			// previous transmission finishes.
			if (send) {
				VESC_IF->rgbled_update(pin, tx, tx_bytes);
			}
		}

		// Sleep until the next frame, but at least 1 ms to avoid a busy loop
		uint32_t frame_ms = st->frame_ms;
		uint32_t work = (uint32_t)(VESC_IF->system_time_ticks() - start);
		VESC_IF->sleep_ms(work < frame_ms ? frame_ms - work : 1);
	}
}

// ---- Extension helpers --------------------------------------------------

// Variable-arity callers validate their range first, then pass n = argn to
// reuse the numeric checks without duplicating this loop in executable RAM.
static bool check_num_args(lbm_value *args, lbm_uint argn, lbm_uint n) {
	if (argn != n) {
		return false;
	}
	for (lbm_uint i = 0; i < argn; i++) {
		if (!VESC_IF->lbm_is_number(args[i])) {
			return false;
		}
	}
	return true;
}

static seg_t *seg_arg(esp_led_t *st, lbm_value v) {
	int i = VESC_IF->lbm_dec_as_i32(v);
	if (i < 0 || i >= esp_led_SEG_MAX) {
		return NULL;
	}
	return &st->seg[i];
}

// ---- Extensions ---------------------------------------------------------

// (ext-esp_led-seg-def i pin type len [offset] [timing]) - define segment i
// before ext-esp_led-init. Segments on one pin form a chain; offset is the
// position in it. See the TYPE_ and TIMING_ enums.
static lbm_value ext_seg_def(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (argn < 4 || argn > 6) return VESC_IF->lbm_enc_sym_terror;
	if (!check_num_args(args, argn, argn)) return VESC_IF->lbm_enc_sym_terror;

	seg_t *s = seg_arg(st, args[0]);
	int pin = VESC_IF->lbm_dec_as_i32(args[1]);
	int type = VESC_IF->lbm_dec_as_i32(args[2]);
	int len = VESC_IF->lbm_dec_as_i32(args[3]);
	int offset = argn >= 5 ? VESC_IF->lbm_dec_as_i32(args[4]) : 0;
	int timing = argn >= 6 ? VESC_IF->lbm_dec_as_i32(args[5]) : 0;

	if (!s || pin < 0 || pin > 255 || type < 0 || type > TYPE_WRGB
		|| len < 1 || len > 1024 || offset < 0 || offset > 1024
		|| timing < 0 || timing > 4) {
		return VESC_IF->lbm_enc_sym_terror;
	}

	if (st->running) {
		VESC_IF->lbm_set_error_reason(
			"Stop with ext-esp_led-deinit before redefining segments");
		return VESC_IF->lbm_enc_sym_eerror;
	}

	VESC_IF->mutex_lock(st->lock);
	if (s->manual) { // redefining drops any custom-mode buffer
		VESC_IF->free(s->manual);
	}
	// Redefinition resets the whole appearance, overlays and custom palette.
	// The pin-group index is assigned again by ext_init.
	memset(s, 0, sizeof(*s));
	s->defined = true;
	s->on = true;
	s->pin = (uint8_t)pin;
	s->type = (uint8_t)type;
	s->timing = (uint8_t)timing;
	s->len = (uint16_t)len;
	s->offset = (uint16_t)offset;
	s->fx = FX_SOLID;
	s->pal = 1; // Spectrum (0 is the custom palette, empty by default)
	s->spd = esp_led_SPD_DEF;
	s->size = 8;
	s->fx_val = 255;
	VESC_IF->mutex_unlock(st->lock);

	return VESC_IF->lbm_enc_sym_true;
}

// (ext-esp_led-seg-overlay-def i idx0 idx1 ...) - up to 8 overlay positions
// for segment i, before ext-esp_led-init. No indices clears the overlay.
static lbm_value ext_seg_overlay_def(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (argn < 1 || argn > 1 + esp_led_OV_MAX) return VESC_IF->lbm_enc_sym_terror;
	if (!check_num_args(args, argn, argn)) return VESC_IF->lbm_enc_sym_terror;

	seg_t *s = seg_arg(st, args[0]);
	if (!s || !s->defined) return VESC_IF->lbm_enc_sym_terror;

	if (st->running) {
		VESC_IF->lbm_set_error_reason(
			"Stop with ext-esp_led-deinit before redefining segments");
		return VESC_IF->lbm_enc_sym_eerror;
	}

	int count = argn - 1;
	for (int k = 0; k < count; k++) {
		int v = VESC_IF->lbm_dec_as_i32(args[k + 1]);
		if (v < 0 || v >= s->len + count) {
			VESC_IF->lbm_set_error_reason("Overlay index outside the strip");
			return VESC_IF->lbm_enc_sym_terror;
		}
	}

	VESC_IF->mutex_lock(st->lock);
	s->ov_count = (uint8_t)count;
	for (int k = 0; k < count; k++) {
		s->ov_idx[k] = (uint8_t)VESC_IF->lbm_dec_as_i32(args[k + 1]);
	}
	VESC_IF->mutex_unlock(st->lock);

	return VESC_IF->lbm_enc_sym_true;
}

// (ext-esp_led-seg-overlay i color bri) - runtime overlay colour; bri 0 is off.
static lbm_value ext_seg_overlay(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (!check_num_args(args, argn, 3)) return VESC_IF->lbm_enc_sym_terror;

	seg_t *s = seg_arg(st, args[0]);
	if (!s) return VESC_IF->lbm_enc_sym_terror;

	VESC_IF->mutex_lock(st->lock);
	s->ov_color = VESC_IF->lbm_dec_as_u32(args[1]);
	s->ov_bri = (uint8_t)VESC_IF->lbm_dec_as_i32(args[2]);
	VESC_IF->mutex_unlock(st->lock);

	return VESC_IF->lbm_enc_sym_true;
}

// Shared by partial initialization failure and normal shutdown.
static void free_render_buffers(esp_led_t *st) {
	if (st->work) {
		VESC_IF->free(st->work);
		st->work = NULL;
	}
	for (int gi = 0; gi < st->group_count; gi++) {
		group_t *g = &st->group[gi];
		for (int b = 0; b < 2; b++) {
			if (g->txbuf[b]) {
				VESC_IF->free(g->txbuf[b]);
				g->txbuf[b] = NULL;
			}
		}
	}
	st->group_count = 0;
	st->seg_count = 0;
	st->buf_len = 0;
}


// (ext-esp_led-init n) - start rendering the first n segments.
static lbm_value ext_init(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (!check_num_args(args, argn, 1)) return VESC_IF->lbm_enc_sym_terror;

	int n = VESC_IF->lbm_dec_as_i32(args[0]);
	if (n < 1 || n > esp_led_SEG_MAX) return VESC_IF->lbm_enc_sym_terror;

	if (st->running) {
		VESC_IF->lbm_set_error_reason("Already running");
		return VESC_IF->lbm_enc_sym_eerror;
	}

	uint16_t max_len = 0;
	for (int i = 0; i < n; i++) {
		if (!st->seg[i].defined) {
			VESC_IF->lbm_set_error_reason("Segment not defined");
			return VESC_IF->lbm_enc_sym_eerror;
		}
		if (st->seg[i].len > max_len) max_len = st->seg[i].len;
	}

	// Build pin groups: segments on one pin share a chain buffer, and must
	// agree on bytes-per-pixel and timing.
	st->group_count = 0;
	for (int i = 0; i < n; i++) {
		seg_t *s = &st->seg[i];
		int colors = s->type >= TYPE_GRBW ? 4 : 3;
		uint16_t end = s->offset + s->len + s->ov_count;

		s->group = -1;
		for (int gi = 0; gi < st->group_count; gi++) {
			if (st->group[gi].pin == s->pin) {
				s->group = gi;
				break;
			}
		}

		if (s->group < 0) {
			s->group = st->group_count++;
			st->group[s->group].pin = s->pin;
			st->group[s->group].colors = (uint8_t)colors;
			st->group[s->group].timing = s->timing;
			st->group[s->group].chain_len = end;
			st->group[s->group].txbuf[0] = NULL;
			st->group[s->group].txbuf[1] = NULL;
			st->group[s->group].cur = 0;
			// Force the first frame out even if it is all-black: both buffers
			// start zeroed and would compare equal.
			st->group[s->group].quiet_ms = st->refresh_ms;
		} else {
			if (st->group[s->group].colors != colors) {
				VESC_IF->lbm_set_error_reason(
					"Segments on one pin must have the same color depth");
				return VESC_IF->lbm_enc_sym_eerror;
			}
			if (st->group[s->group].timing != s->timing) {
				VESC_IF->lbm_set_error_reason(
					"Segments on one pin must have the same timing preset");
				return VESC_IF->lbm_enc_sym_eerror;
			}
			if (end > st->group[s->group].chain_len) {
				st->group[s->group].chain_len = end;
			}
		}
	}

	// Overlapping footprints on one pin would silently overwrite each other.
	for (int i = 0; i < n; i++) {
		for (int j = i + 1; j < n; j++) {
			seg_t *a = &st->seg[i];
			seg_t *b = &st->seg[j];
			if (a->pin != b->pin) {
				continue;
			}
			uint32_t a_end = (uint32_t)a->offset + a->len + a->ov_count;
			uint32_t b_end = (uint32_t)b->offset + b->len + b->ov_count;
			if (a->offset < b_end && b->offset < a_end) {
				VESC_IF->lbm_set_error_reason(
					"Segments on one pin overlap - check the offsets");
				return VESC_IF->lbm_enc_sym_eerror;
			}
		}
	}

	// Any number of pin groups works - the firmware pools RMT channels behind
	// the pins - so the only requirement is that the LED API exists.
	if (VESC_IF->rgbled_init == NULL || VESC_IF->rgbled_update == NULL
		|| VESC_IF->rgbled_deinit == NULL) {
		VESC_IF->lbm_set_error_reason("This firmware has no LED strip support");
		return VESC_IF->lbm_enc_sym_eerror;
	}

	bool alloc_ok = true;
	st->work = VESC_IF->malloc(max_len * sizeof(uint32_t));
	alloc_ok = st->work != NULL;
	for (int gi = 0; gi < st->group_count && alloc_ok; gi++) {
		group_t *g = &st->group[gi];
		uint32_t bytes = (uint32_t)g->chain_len * g->colors;
		for (int b = 0; b < 2 && alloc_ok; b++) {
			g->txbuf[b] = VESC_IF->malloc(bytes);
			if (g->txbuf[b]) {
				memset(g->txbuf[b], 0, bytes);
			} else {
				alloc_ok = false;
			}
		}
	}

	int registered = 0;
	bool led_ok = true;

	if (alloc_ok) {
		st->buf_len = max_len;
		st->seg_count = n;
		// Register each group so the firmware binds the driver to that pin
		for (int gi = 0; gi < st->group_count; gi++) {
			if (!VESC_IF->rgbled_init(st->group[gi].pin,
					st->group[gi].timing)) {
				VESC_IF->printf("esp_led: strip init failed on pin %d",
					st->group[gi].pin);
				led_ok = false;
				break;
			}
			registered++;
		}
		if (led_ok) {
			st->thread = VESC_IF->spawn(render_thd, 3072, "esp_led_render", st);
			alloc_ok = st->thread != NULL;
		}
	}

	if (!alloc_ok || !led_ok) {
		for (int gi = 0; gi < registered; gi++) {
			VESC_IF->rgbled_deinit(st->group[gi].pin);
		}
		free_render_buffers(st);
		if (!led_ok) {
			VESC_IF->lbm_set_error_reason(
				"Could not start a strip - check the pin numbers");
			return VESC_IF->lbm_enc_sym_eerror;
		}
		return VESC_IF->lbm_enc_sym_merror;
	}

	st->running = true;

	return VESC_IF->lbm_enc_sym_true;
}

static void esp_led_stop(esp_led_t *st) {
	if (!st->running) {
		return;
	}
	VESC_IF->request_terminate(st->thread);
	st->running = false;

	for (int gi = 0; gi < st->group_count; gi++) {
		group_t *g = &st->group[gi];
		uint32_t bytes = (uint32_t)g->chain_len * g->colors;
		if (g->txbuf[g->cur]) {
			memset(g->txbuf[g->cur], 0, bytes);
			VESC_IF->rgbled_update(g->pin, g->txbuf[g->cur], bytes);
		}
	}

	for (int gi = 0; gi < st->group_count; gi++) {
		VESC_IF->rgbled_deinit(st->group[gi].pin);
	}

	free_render_buffers(st);
	for (int i = 0; i < esp_led_SEG_MAX; i++) {
		if (st->seg[i].manual) {
			VESC_IF->free(st->seg[i].manual);
			st->seg[i].manual = NULL;
		}
	}
}

static lbm_value ext_deinit(lbm_value *args, lbm_uint argn) {
	(void)args; (void)argn;
	esp_led_stop(state());
	return VESC_IF->lbm_enc_sym_true;
}

// Point a segment at a new effect, zeroing the phase so it starts clean.
//
// A segment with a cycle time instead lines up with any OTHER segment already
// on that cycle time - they animate as one, and restarting the one that
// changed was visible on the rest. Scanned over every index, not just earlier
// ones: a strip can have been showing the pattern far longer than the one
// joining. Nobody else on the cycle time leaves the zero above standing.
//
// Lining up is proportional, not a copy of the phase - the same point in a
// cycle is a different number of units on strips of different lengths.
static void fx_set(esp_led_t *st, seg_t *s, uint8_t fx) {
	if (s->fx == fx) {
		return; // repeated pushes must not stall a running animation
	}
	s->fx = fx;
	s->phase = 0;
	s->phase_rem = 0;
	if (!s->cycle_ms) {
		return;
	}
	for (int i = 0; i < esp_led_SEG_MAX; i++) {
		seg_t *o = &st->seg[i];
		if (o == s || !o->defined || o->cycle_ms != s->cycle_ms) {
			continue;
		}
		// Both bounded by the largest fx_period (64 * 1024), so the shifted
		// numerator peaks near 16.7M - no 64-bit math needed.
		uint32_t rp = fx_period(o);
		uint32_t frac = ((o->phase % rp) << 8) / rp; // 0..255 of a cycle
		s->phase = (fx_period(s) * frac) >> 8;
		break;
	}
}

// (ext-esp_led-seg-look i fx pal color spd bri [cycle-ms]) - full appearance
// in one call. Leaving cycle-ms off keeps whatever the segment had.
static lbm_value ext_seg_look(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (argn < 6 || argn > 7) return VESC_IF->lbm_enc_sym_terror;
	if (!check_num_args(args, argn, argn)) return VESC_IF->lbm_enc_sym_terror;

	seg_t *s = seg_arg(st, args[0]);
	if (!s) return VESC_IF->lbm_enc_sym_terror;

	VESC_IF->mutex_lock(st->lock);
	// Before the effect, so fx_set sees the cycle time this look asks for and
	// lines the segment up against the right set.
	if (argn >= 7) {
		s->cycle_ms = (uint16_t)VESC_IF->lbm_dec_as_i32(args[6]);
	}
	fx_set(st, s, (uint8_t)VESC_IF->lbm_dec_as_i32(args[1]));
	s->pal = (uint8_t)VESC_IF->lbm_dec_as_i32(args[2]);
	s->color = VESC_IF->lbm_dec_as_u32(args[3]);
	s->spd = (uint8_t)VESC_IF->lbm_dec_as_i32(args[4]);
	s->bri = (uint8_t)VESC_IF->lbm_dec_as_i32(args[5]);
	VESC_IF->mutex_unlock(st->lock);

	return VESC_IF->lbm_enc_sym_true;
}

// Field ids, so the per-segment and all-segment variants share one setter.
enum { SET_FX = 0, SET_PAL, SET_BRI, SET_SPD, SET_COLOR, SET_ON, SET_REVERSE, SET_SIZE, SET_FX_VAL,
	SET_AUTO_WHITE, SET_COLOR_FADE, SET_CYCLE };

static void seg_set(esp_led_t *st, seg_t *s, int field, uint32_t v) {
	switch (field) {
	case SET_FX:      fx_set(st, s, (uint8_t)v); break;
	case SET_CYCLE:   s->cycle_ms = (uint16_t)(v > 0xFFFF ? 0xFFFF : v); break;
	case SET_PAL:     s->pal = (uint8_t)v; break;
	case SET_BRI:     s->bri = (uint8_t)v; break;
	case SET_SPD:     s->spd = (uint8_t)v; break;
	case SET_COLOR:   s->color = v; break;
	case SET_ON:      s->on = v != 0; break;
	case SET_REVERSE: s->reverse = v != 0; break;
	case SET_SIZE:    s->size = (uint8_t)v; break;
	case SET_FX_VAL:  s->fx_val = (uint8_t)v; break;
	case SET_AUTO_WHITE: s->auto_white = v != 0; break;
	case SET_COLOR_FADE: s->color_fade = (uint8_t)(v > 32 ? 32 : v); break;
	}
}

static lbm_value set_one(lbm_value *args, lbm_uint argn, int field) {
	esp_led_t *st = state();
	if (!check_num_args(args, argn, 2)) return VESC_IF->lbm_enc_sym_terror;

	seg_t *s = seg_arg(st, args[0]);
	if (!s) return VESC_IF->lbm_enc_sym_terror;

	VESC_IF->mutex_lock(st->lock);
	seg_set(st, s, field, VESC_IF->lbm_dec_as_u32(args[1]));
	VESC_IF->mutex_unlock(st->lock);
	return VESC_IF->lbm_enc_sym_true;
}

static lbm_value set_all(lbm_value *args, lbm_uint argn, int field) {
	esp_led_t *st = state();
	if (!check_num_args(args, argn, 1)) return VESC_IF->lbm_enc_sym_terror;

	VESC_IF->mutex_lock(st->lock);
	for (int i = 0; i < esp_led_SEG_MAX; i++) {
		seg_set(st, &st->seg[i], field, VESC_IF->lbm_dec_as_u32(args[0]));
	}
	VESC_IF->mutex_unlock(st->lock);
	return VESC_IF->lbm_enc_sym_true;
}

static lbm_value ext_seg_fx(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_FX); }
static lbm_value ext_fx(lbm_value *a, lbm_uint n) { return set_all(a, n, SET_FX); }

static lbm_value ext_seg_pal(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_PAL); }
static lbm_value ext_pal(lbm_value *a, lbm_uint n) { return set_all(a, n, SET_PAL); }

static lbm_value ext_seg_bri(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_BRI); }

static lbm_value ext_seg_spd(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_SPD); }

// Chase head / comet tail length.
static lbm_value ext_seg_size(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_SIZE); }

// Pin one cycle of the effect to a wall-clock time instead of driving it with
// spd; 0 (the default) hands the segment back to spd. For strips of different
// lengths: spd is pixel velocity, so a chase crosses a longer strip slower and
// the two beat against each other. fx_period defines a cycle per effect.
static lbm_value ext_seg_cycle(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_CYCLE); }
static lbm_value ext_cycle(lbm_value *a, lbm_uint n) { return set_all(a, n, SET_CYCLE); }

// The selected effect's parameter: gauge fill 0..255, turn-signal mode. Named
// for the slot, since a magnitude and a mode selector share it.
static lbm_value ext_seg_fx_val(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_FX_VAL); }

// Packed 0xWWRRGGBB.
static lbm_value ext_seg_col(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_COLOR); }
static lbm_value ext_col(lbm_value *a, lbm_uint n) { return set_all(a, n, SET_COLOR); }

static lbm_value ext_seg_on(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_ON); }

// How fast this segment's colour follows a change, in 32nds of the gap per
// 33 ms; 0 (the default) is instant. Per segment because some colours are
// information, not decoration: an alarm that fades in reads as a slow one.
static lbm_value ext_seg_color_fade(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_COLOR_FADE); }

static lbm_value ext_seg_reverse(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_REVERSE); }

// Restart every animation from phase 0 under one lock hold, so effects set up
// at different times run in step. They stay locked while their speeds match.
static lbm_value ext_sync(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (!check_num_args(args, argn, 0)) return VESC_IF->lbm_enc_sym_terror;

	VESC_IF->mutex_lock(st->lock);
	for (int i = 0; i < esp_led_SEG_MAX; i++) {
		st->seg[i].phase = 0;
		st->seg[i].phase_rem = 0;
	}
	VESC_IF->mutex_unlock(st->lock);
	return VESC_IF->lbm_enc_sym_true;
}

// Restart segment i alone, leaving the others running.
static lbm_value ext_seg_sync(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (!check_num_args(args, argn, 1)) return VESC_IF->lbm_enc_sym_terror;

	seg_t *s = seg_arg(st, args[0]);
	if (!s) return VESC_IF->lbm_enc_sym_terror;

	VESC_IF->mutex_lock(st->lock);
	s->phase = 0;
	s->phase_rem = 0;
	VESC_IF->mutex_unlock(st->lock);
	return VESC_IF->lbm_enc_sym_true;
}

// Put s in custom mode: allocate the pixel buffer once, switch to FX_CUSTOM.
// Call with the lock held.
static bool seg_custom_ready(seg_t *s) {
	if (!s->manual) {
		s->manual = VESC_IF->malloc((uint32_t)s->len * sizeof(uint32_t));
		if (!s->manual) {
			return false;
		}
		for (int i = 0; i < s->len; i++) {
			s->manual[i] = 0;
		}
	}
	s->fx = FX_CUSTOM;
	return true;
}

// Put segment i in custom mode with a blank buffer; the consumer then pushes
// pixels with ext-esp_led-seg-pixel / -pixels.
static lbm_value ext_seg_custom(lbm_value *a, lbm_uint n) {
	esp_led_t *st = state();
	if (!check_num_args(a, n, 1)) return VESC_IF->lbm_enc_sym_terror;
	seg_t *s = seg_arg(st, a[0]);
	if (!s) return VESC_IF->lbm_enc_sym_terror;

	VESC_IF->mutex_lock(st->lock);
	bool ok = seg_custom_ready(s);
	VESC_IF->mutex_unlock(st->lock);
	return ok ? VESC_IF->lbm_enc_sym_true : VESC_IF->lbm_enc_sym_merror;
}

// Set one custom pixel, entering custom mode if needed. Bad idx is ignored.
static lbm_value ext_seg_pixel(lbm_value *a, lbm_uint n) {
	esp_led_t *st = state();
	if (!check_num_args(a, n, 3)) return VESC_IF->lbm_enc_sym_terror;
	seg_t *s = seg_arg(st, a[0]);
	if (!s) return VESC_IF->lbm_enc_sym_terror;
	int idx = VESC_IF->lbm_dec_as_i32(a[1]);
	uint32_t color = VESC_IF->lbm_dec_as_u32(a[2]);

	VESC_IF->mutex_lock(st->lock);
	bool ok = seg_custom_ready(s);
	if (ok && idx >= 0 && idx < s->len) {
		s->manual[idx] = color;
	}
	VESC_IF->mutex_unlock(st->lock);
	return ok ? VESC_IF->lbm_enc_sym_true : VESC_IF->lbm_enc_sym_merror;
}

// (ext-esp_led-seg-pixels i start colors) - set consecutive custom pixels from
// a list of packed colours. Pixels past the end of the segment are ignored.
static lbm_value ext_seg_pixels(lbm_value *a, lbm_uint n) {
	esp_led_t *st = state();
	if (n != 3 || !check_num_args(a, 2, 2)) {
		return VESC_IF->lbm_enc_sym_terror;
	}
	seg_t *s = seg_arg(st, a[0]);
	if (!s) return VESC_IF->lbm_enc_sym_terror;
	int idx = VESC_IF->lbm_dec_as_i32(a[1]);

	VESC_IF->mutex_lock(st->lock);
	bool ok = seg_custom_ready(s);
	if (ok) {
		lbm_value lst = a[2];
		while (VESC_IF->lbm_is_cons(lst) && idx < s->len) {
			if (idx >= 0) {
				s->manual[idx] = VESC_IF->lbm_dec_as_u32(VESC_IF->lbm_car(lst));
			}
			idx++;
			lst = VESC_IF->lbm_cdr(lst);
		}
	}
	VESC_IF->mutex_unlock(st->lock);
	return ok ? VESC_IF->lbm_enc_sym_true : VESC_IF->lbm_enc_sym_merror;
}

// (ext-esp_led-seg-palette i c0 c1 c2 c3) - set the segment's custom palette
// and select it, so the gradient effects render in these colours.
static lbm_value ext_seg_palette(lbm_value *a, lbm_uint n) {
	esp_led_t *st = state();
	if (!check_num_args(a, n, 5)) return VESC_IF->lbm_enc_sym_terror;
	seg_t *s = seg_arg(st, a[0]);
	if (!s) return VESC_IF->lbm_enc_sym_terror;

	VESC_IF->mutex_lock(st->lock);
	for (int i = 0; i < 4; i++) {
		s->cpal[i] = VESC_IF->lbm_dec_as_u32(a[i + 1]);
	}
	s->pal = 0; // select the custom palette
	VESC_IF->mutex_unlock(st->lock);
	return VESC_IF->lbm_enc_sym_true;
}

// (ext-esp_led-col-rgb r g b) / (ext-esp_led-col-rgbw r g b w) - solid colour
// on every segment, switching them all to FX_SOLID.
static lbm_value ext_col_rgbw(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (argn != 3 && argn != 4) return VESC_IF->lbm_enc_sym_terror;
	if (!check_num_args(args, argn, argn)) return VESC_IF->lbm_enc_sym_terror;

	static const uint8_t shifts[] = {16, 8, 0, 24};
	uint32_t c = 0;
	for (lbm_uint i = 0; i < argn; i++) {
		c |= (VESC_IF->lbm_dec_as_u32(args[i]) & 0xFF) << shifts[i];
	}

	VESC_IF->mutex_lock(st->lock);
	for (int i = 0; i < esp_led_SEG_MAX; i++) {
		st->seg[i].color = c;
		st->seg[i].fx = FX_SOLID;
	}
	VESC_IF->mutex_unlock(st->lock);
	return VESC_IF->lbm_enc_sym_true;
}

// Master brightness 0..255.
static lbm_value ext_bri(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (!check_num_args(args, argn, 1)) return VESC_IF->lbm_enc_sym_terror;
	st->master_bri = (uint8_t)VESC_IF->lbm_dec_as_i32(args[0]);
	return VESC_IF->lbm_enc_sym_true;
}

// Target frame rate, clamped to an effective 5..200 fps. Animation and fade
// speeds are unaffected - both advance by measured real time - so this trades
// smoothness against CPU without retuning anything.
static lbm_value ext_fps(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (!check_num_args(args, argn, 1)) return VESC_IF->lbm_enc_sym_terror;

	int fps = VESC_IF->lbm_dec_as_i32(args[0]);
	if (fps < 1) return VESC_IF->lbm_enc_sym_terror;

	uint32_t ms = 1000u / (uint32_t)fps;
	if (ms < esp_led_FRAME_MS_MIN) ms = esp_led_FRAME_MS_MIN;
	if (ms > esp_led_FRAME_MS_MAX) ms = esp_led_FRAME_MS_MAX;
	st->frame_ms = (uint16_t)ms;

	return VESC_IF->lbm_enc_sym_true;
}

// Unchanged-frame refresh interval in milliseconds. 0 transmits every frame.
static lbm_value ext_refresh(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (!check_num_args(args, argn, 1)) return VESC_IF->lbm_enc_sym_terror;
	int ms = VESC_IF->lbm_dec_as_i32(args[0]);
	if (ms < 0 || ms > 60000) return VESC_IF->lbm_enc_sym_terror;
	VESC_IF->mutex_lock(st->lock);
	st->refresh_ms = (uint32_t)ms;
	VESC_IF->mutex_unlock(st->lock);
	return VESC_IF->lbm_enc_sym_true;
}

// Brightness easing for master and segments: 32nds of the remaining gap closed
// per 33 ms of real time (0 = instant, 32 = full).
static lbm_value ext_fade(lbm_value *args, lbm_uint argn) {
	esp_led_t *st = state();
	if (!check_num_args(args, argn, 1)) return VESC_IF->lbm_enc_sym_terror;
	st->fade = (uint8_t)VESC_IF->lbm_dec_as_i32(args[0]);
	return VESC_IF->lbm_enc_sym_true;
}

// Derive W from the common RGB part. Per-segment only: it depends on the
// strip's colour order, so an all-segments variant would be meaningless.
static lbm_value ext_seg_auto_white(lbm_value *a, lbm_uint n) { return set_one(a, n, SET_AUTO_WHITE); }

// ---- Lifecycle ----------------------------------------------------------

// The extension list, consumed two ways.
//
// On the S3 it becomes a table walked at init, to save code space: the linker
// script puts .rodata in the data region but .literal - where each inline
// call's name and function pointer land - in the *code* region
// (c_libs/express/link_esp32s3.ld). Moving those 30 pointer pairs to the data
// region takes 571 bytes off the region this package runs out of.
//
// On the RISC-V targets it stays inline calls. They execute in place from
// flash with no relocation pass at load (the XIP branch of
// ext_load_native_lib), so a stored function pointer would keep its link-time
// address and be wrong at runtime - GCC puts such a table in .data.rel.ro
// precisely because it needs relocating. Inline calls are PC-relative, and
// those targets have code space to spare.
#define esp_led_EXTENSIONS(X) \
	X("ext-esp_led-seg-def", ext_seg_def) \
	X("ext-esp_led-seg-overlay-def", ext_seg_overlay_def) \
	X("ext-esp_led-seg-overlay", ext_seg_overlay) \
	X("ext-esp_led-init", ext_init) \
	X("ext-esp_led-deinit", ext_deinit) \
	X("ext-esp_led-seg-look", ext_seg_look) \
	X("ext-esp_led-seg-fx", ext_seg_fx) \
	X("ext-esp_led-fx", ext_fx) \
	X("ext-esp_led-seg-pal", ext_seg_pal) \
	X("ext-esp_led-pal", ext_pal) \
	X("ext-esp_led-seg-bri", ext_seg_bri) \
	X("ext-esp_led-seg-spd", ext_seg_spd) \
	X("ext-esp_led-seg-size", ext_seg_size) 	X("ext-esp_led-seg-cycle", ext_seg_cycle) 	X("ext-esp_led-cycle", ext_cycle) \
	X("ext-esp_led-seg-fx-val", ext_seg_fx_val) \
	X("ext-esp_led-seg-color-fade", ext_seg_color_fade) \
	X("ext-esp_led-seg-col", ext_seg_col) \
	X("ext-esp_led-col", ext_col) \
	X("ext-esp_led-seg-on", ext_seg_on) \
	X("ext-esp_led-seg-reverse", ext_seg_reverse) \
	X("ext-esp_led-sync", ext_sync) \
	X("ext-esp_led-seg-sync", ext_seg_sync) \
	X("ext-esp_led-seg-custom", ext_seg_custom) \
	X("ext-esp_led-seg-pixel", ext_seg_pixel) \
	X("ext-esp_led-seg-pixels", ext_seg_pixels) \
	X("ext-esp_led-seg-palette", ext_seg_palette) \
	X("ext-esp_led-col-rgb", ext_col_rgbw) \
	X("ext-esp_led-col-rgbw", ext_col_rgbw) \
	X("ext-esp_led-bri", ext_bri) \
	X("ext-esp_led-fade", ext_fade) \
	X("ext-esp_led-fps", ext_fps) \
	X("ext-esp_led-refresh", ext_refresh) \
	X("ext-esp_led-seg-auto-white", ext_seg_auto_white)

#ifdef CONFIG_IDF_TARGET_ESP32S3
#define X(name_, fn_) {name_, fn_},
static const struct {
	char *name;
	extension_fptr fn;
} extensions[] = { esp_led_EXTENSIONS(X) };
#undef X
#endif

static void stop(void *arg) {
	esp_led_t *st = (esp_led_t*)arg;

	if (st) {
		esp_led_stop(st);
		VESC_IF->free(st->lock);
		VESC_IF->free(st);
	}

	VESC_IF->printf("esp_led-strip lib stopped");
}

INIT_FUN(lib_info *info) {
	INIT_START

	esp_led_t *st = VESC_IF->malloc(sizeof(esp_led_t));
	if (!st) {
		return false;
	}

	for (unsigned int i = 0; i < sizeof(esp_led_t); i++) {
		((uint8_t*)st)[i] = 0;
	}

	st->master_bri = 255;
	st->master_cur = 255;
	st->fade = esp_led_FADE_DEF;
	st->frame_ms = esp_led_FRAME_MS_DEF;
	st->refresh_ms = esp_led_REFRESH_MS_DEF;
	st->lock = VESC_IF->mutex_create();
	if (!st->lock) {
		VESC_IF->free(st);
		return false;
	}

	info->arg = st;
	info->stop_fun = stop;

#ifdef CONFIG_IDF_TARGET_ESP32S3
	for (unsigned int i = 0; i < sizeof(extensions) / sizeof(extensions[0]); i++) {
		VESC_IF->lbm_add_extension(extensions[i].name, extensions[i].fn);
	}
#else
#define X(name_, fn_) VESC_IF->lbm_add_extension(name_, fn_);
	esp_led_EXTENSIONS(X)
#undef X
#endif

	VESC_IF->printf("esp_led-strip lib loaded");

	return true;
}
