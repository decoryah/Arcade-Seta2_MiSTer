#!/usr/bin/env python3
"""Scripted play for the light-gun games: the inputs file of the machine bench (sim/sys +inputs=FILE) and of MAME
(tools/lua/dump_state.lua INPUTS=FILE), lines "frame joy1 joy2 gun1 gun2" (hex), each holding from that frame on.

Coin at COIN, start at START (6 frames each); from PLAY on, every PERIOD frames each gun is aimed at a new place (a seeded generator,
across MAME's port ranges: X 0x25..0xC5, Y 0x08..0xF8) and fired 6 frames later (the trigger held 4 frames); every 5th shot is
followed by the pump (6 frames).  With --guns 2 the second player does the same, half a period later.  --aims puts player 1's
first shots at given places (the menus: a scene, then YES), "YYXX[*count],...".

    gun_inputs.py <mame.txt> <frames> [--bench bench.txt --lag N] [--seed N] [--coin N] [--start N] [--play N] [--period N] [--guns 1|2]
                  [--aims YYXX[*n],...]

The bench's file is the same script with every frame moved by the bench's lag behind MAME (it boots later: the program cache's
misses), so that the game sees the same input on the same frame of its own.  Joystick bits as Seta2.sv's: 4 button 1 (trigger),
5 button 2 (pump), 8 start, 9 coin.
"""
import sys


def arg(argv, name, default, conv=int):
    return conv(argv[argv.index(name) + 1]) if name in argv else default


def script(frames, seed, coin_f, start_f, play_f, period, guns, aims=()):
    rng = seed

    def rnd(n):
        nonlocal rng
        rng = (rng * 1103515245 + 12345) & 0x7fffffff
        return (rng >> 8) % n

    state = {}          # frame -> [joy1, joy2, gun1, gun2] (the state from that frame on)
    j = [0, 0]
    g = [0x8075, 0x8075 if guns == 2 else 0xffff]     # one-gun games: GUN2 unused, 1s (as s2_samports)
    events = []         # (frame, player, kind, value)
    events += [(coin_f, 0, 'bit', 9), (coin_f + 6, 0, 'clr', 9), (start_f, 0, 'bit', 8), (start_f + 6, 0, 'clr', 8)]
    if guns == 2:
        events += [(coin_f + 20, 1, 'bit', 9), (coin_f + 26, 1, 'clr', 9), (start_f + 20, 1, 'bit', 8), (start_f + 26, 1, 'clr', 8)]
    shots = [0, 0]
    for p in range(guns):
        f = play_f + p * (period // 2)
        while f < frames:
            x = 0x25 + rnd(0xc5 - 0x25 + 1)
            y = 0x08 + rnd(0xf8 - 0x08 + 1)
            if p == 0 and shots[0] < len(aims):
                y, x = aims[shots[0]] >> 8, aims[shots[0]] & 0xff
            events.append((f, p, 'gun', (y << 8) | x))
            events += [(f + 6, p, 'bit', 4), (f + 10, p, 'clr', 4)]
            shots[p] += 1
            if shots[p] % 5 == 0:
                events += [(f + 14, p, 'bit', 5), (f + 20, p, 'clr', 5)]
            f += period
    for fr in sorted({e[0] for e in events}):
        for (_, p, kind, v) in [e for e in events if e[0] == fr]:
            if kind == 'bit':
                j[p] |= 1 << v
            elif kind == 'clr':
                j[p] &= ~(1 << v)
            else:
                g[p] = v
        state[fr] = [j[0], j[1], g[0], g[1]]
    return state


def write(path, state, shift):
    with open(path, 'w') as f:
        for fr in sorted(state):
            j1, j2, g1, g2 = state[fr]
            f.write('%d %x %x %x %x\n' % (fr + shift, j1, j2, g1, g2))


def aims(spec):
    out = []
    for item in filter(None, spec.split(',')):
        v, _, n = item.partition('*')
        out += [int(v, 16)] * int(n or 1)
    return out


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    out, frames = argv[1], int(argv[2])
    st = script(frames, arg(argv, '--seed', 12345), arg(argv, '--coin', 200), arg(argv, '--start', 260),
                arg(argv, '--play', 400), arg(argv, '--period', 24), arg(argv, '--guns', 1), aims(arg(argv, '--aims', '', str)))
    write(out, st, 0)
    if '--bench' in argv:
        write(arg(argv, '--bench', None, str), st, arg(argv, '--lag', 0))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
