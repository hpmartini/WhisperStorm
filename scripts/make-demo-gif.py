#!/usr/bin/env python3
"""Renders docs/screenshots/overlay.gif: the overlay waveform (port of WaveformModel
in Sources/Overlay/OverlayView.swift) driven by a synthetic speech envelope, on black.
Needs: pip install pillow numpy"""
import math, random, os, subprocess, tempfile
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H, S = 340, 104, 2            # overlay size in points, supersample
FPS, BARS = 25, 48
CY, MG, VI = (0, 255, 247), (255, 43, 214), (122, 43, 255)
random.seed(7)
seeds = [(random.uniform(5.5, 11), random.uniform(0, 2 * math.pi), random.uniform(.6, 1)) for _ in range(BARS)]

def grad(x):                      # x in 0..1
    a, b, t = (CY, MG, x * 2) if x < .5 else (MG, VI, x * 2 - 1)
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def speech(t):                    # syllable-like bursts, 0..1
    gate = 0.5 + 0.5 * math.sin(t * 2.1 - .5)
    return max(0, min(1, (0.35 + 0.65 * abs(math.sin(t * 7.3) * math.sin(t * 3.1 + 1))) * gate * 1.3))

def heights(t, phase, lvl):
    mh = H - 4 - 40
    out = []
    for i in range(BARS):
        nx = i / (BARS - 1); win = math.exp(-((nx - .5) / .38) ** 2); f, p, w = seeds[i]
        if phase == 'rec':
            amp = lvl * mh * win * w * (.55 + .45 * math.sin(t * f * (1 + 1.6 * lvl) + p))
            out.append(2.5 + max(1.5 * (.5 + .5 * math.sin(t * 1.3 + i * .22)) * win, amp))
        elif phase == 'trans':
            base = .28 * mh * win * (.5 + .5 * math.sin(t * f * .7 + p))
            pos = (t * .55) % 1.4 - .2
            out.append(2.5 + base * (1 + 1.1 * math.exp(-((nx - pos) / .09) ** 2)))
        else:
            fl = max(0, 1 - phase_t[0] / .45)
            out.append(2.5 + .3 * mh * win * (.5 + .5 * math.sin(t * f + p)) * (1 + 1.4 * fl))
    return out

def frame(t, phase, label, flash=0.0):
    img = Image.new('RGB', (W * S, H * S), (0, 0, 0))
    glow = Image.new('RGB', img.size, (0, 0, 0)); sharp = Image.new('RGB', img.size, (0, 0, 0))
    step = W / BARS; bw = step * .55; cy = H / 2 - 12
    for layer in (glow, sharp):
        d = ImageDraw.Draw(layer)
        for i, h in enumerate(HS):
            x = step * (i + .5) - bw / 2
            col = (255, 255, 255) if flash > 0 and layer is sharp and False else grad(i / (BARS - 1))
            if flash > 0 and layer is sharp: col = tuple(int(c + (255 - c) * flash * .9) for c in col)
            d.rounded_rectangle([x * S, (cy - h / 2) * S, (x + bw) * S, (cy + h / 2) * S], radius=bw / 2 * S, fill=col)
    glow = glow.filter(ImageFilter.GaussianBlur(6 * S))
    a = np.asarray(glow, float) * .85 + np.asarray(sharp, float)
    img = Image.fromarray(np.clip(a, 0, 255).astype('uint8'))
    a = np.asarray(img, float)
    for y in range(0, H * S, 4 * S):           # scanlines: 8 % black
        a[y:y + S] *= .92
    img = Image.fromarray(a.astype('uint8')); d = ImageDraw.Draw(img)
    font = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 11 * S)
    tw = d.textlength(label, font=font)
    d.text(((W * S - tw) / 2, (H - 26) * S), label, font=font, fill=CY)
    # rounded gradient border
    m = Image.new('L', img.size, 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, W * S - 1, H * S - 1], 22 * S, outline=255, width=2 * S)
    bd = Image.new('RGB', img.size); bp = bd.load()
    for x in range(W * S): 
        c = grad(x / (W * S))
        for y in range(H * S): bp[x, y] = c
    img.paste(bd, mask=m)
    return img.resize((W * 2, H * 2), Image.LANCZOS)

frames, disp, phase_t = [], 0.0, [0]
T = [('rec', 4.0, 'Listening — esc to cancel'), ('trans', 1.6, 'Transcribing…'), ('done', .7, 'Done')]
t = 0.0
for ph, dur, label in T:
    for k in range(int(dur * FPS)):
        lvl = speech(t) if ph == 'rec' else 0
        disp += (lvl - disp) * (.35 if lvl > disp else .07)
        phase_t[0] = k / FPS
        HS = heights(t, ph, disp)
        frames.append(frame(t, ph, label, max(0, 1 - k / FPS / .45) if ph == 'done' else 0))
        t += 1 / FPS
tmp = tempfile.mkdtemp()
for n, f in enumerate(frames): f.save(f'{tmp}/f{n:04d}.png')
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', str(FPS), '-i', f'{tmp}/f%04d.png', '-vf',
                'split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=3',
                '-loop', '0', 'docs/screenshots/overlay.gif'], check=True)
print(len(frames), 'frames')
