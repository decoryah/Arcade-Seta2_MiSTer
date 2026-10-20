#!/usr/bin/env python3
"""Writes the machine bench's input script (sim/sys +inputs=FILE: lines "frame joy1 joy2", hex) for the scripted play of
tools/lua/dump_state.lua (capture.py --play): coin at COIN_FRAME, start at START_FRAME (both for 6 frames, every 1800 frames), from
PLAY_FRAME a random joystick direction every 10 frames and the buttons on fixed cycles, with the same generator and seed -- shifted
by the bench's lag behind MAME, so that the game sees the same input on the same frame of its own.

    play_inputs.py <out.txt> <frames> [--lag N] [--seed N] [--coin N] [--start N] [--play N]

Joystick bits as Seta2.sv's: 0 right, 1 left, 2 down, 3 up, 4..7 buttons 1..4, 8 start, 9 coin.
"""
import sys


def arg(argv, name, default):
    return int(argv[argv.index(name) + 1]) if name in argv else default


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    out, frames = argv[1], int(argv[2])
    lag = arg(argv, '--lag', 0)
    rng = arg(argv, '--seed', 12345)
    coin_f, start_f, play_f = arg(argv, '--coin', 200), arg(argv, '--start', 260), arg(argv, '--play', 330)

    def rnd(n):
        nonlocal rng
        rng = (rng * 1103515245 + 12345) & 0x7fffffff
        return (rng >> 8) % n

    d = 0
    last = None
    lines = []
    for f in range(0, frames + 1):
        j = 0
        if f >= coin_f and (f - coin_f) % 1800 < 6:
            j |= 1 << 9
        if f >= start_f and (f - start_f) % 1800 < 6:
            j |= 1 << 8
        if f >= play_f:
            if f % 10 == 0:
                d = rnd(5)
            j |= {1: 1 << 3, 2: 1 << 2, 3: 1 << 1, 4: 1 << 0}.get(d, 0)
            if f % 23 < 5: j |= 1 << 4
            if f % 37 < 4: j |= 1 << 5
            if f % 53 < 3: j |= 1 << 6
            if f % 71 < 3: j |= 1 << 7
        if j != last:
            lines.append('%d %x 0' % (f + lag, j))
            last = j
    open(out, 'w').write('\n'.join(lines) + '\n')
    print('%d changes in %s (lag %d)' % (len(lines), out, lag))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
