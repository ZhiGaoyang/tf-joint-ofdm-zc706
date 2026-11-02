#!/usr/bin/env python3
"""Readable live view of a running lean_adapt.py log, for the demo video.

Follows the JSONL log while lean_adapt.py writes it and prints one short status line about every
--period seconds, plus an event line whenever the tone, the mask or the modulation changes.
It only reads the log; all numbers are those lean_adapt.py measured.

  python3 demo_view.py /tmp/demo.jsonl --pid 1234 --title "联合策略 + 发射前感知"
  python3 demo_view.py ... --ascii      # English/ASCII labels if the terminal cannot show UTF-8
"""
import argparse
import io
import json
import os
import sys
import time

LABELS = {
    'zh': dict(win='第 %4d 窗', tone=('单音：关', '单音：开'), mask='屏蔽：%s', none='无', grp='第 %s 组', sep='、',
               mod='调制：%s', ok='本窗 %2d/%d 正确', thr='约 %5.1f Mbit/s', ev_tone=('→ 单音关闭', '→ 单音开启'),
               ev_mask='→ 屏蔽改为：%s', ev_mod='→ 调制改为：%s',
               sense='发射前感知：%s → 初始屏蔽 %s（耗时 %.2f s）', lines='谱线 %s', nolines='未发现窄带谱线',
               total='汇总（%s）：单音关闭时 %d/%d 帧正确，单音开启时 %d/%d 帧正确', fail='运行异常中止：%s', end='结束'),
    'en': dict(win='win %4d', tone=('tone OFF', 'tone ON '), mask='mask: %s', none='none', grp='groups %s', sep=',',
               mod='mod: %s', ok='%2d/%d frames ok', thr='~%5.1f Mbit/s', ev_tone=('-> tone off', '-> tone on'),
               ev_mask='-> mask now: %s', ev_mod='-> modulation now: %s',
               sense='pre-tx sensing: %s -> initial mask %s (%.2f s)', lines='lines %s', nolines='no narrowband line',
               total='summary (%s): tone off %d/%d frames ok, tone on %d/%d frames ok', fail='run aborted: %s', end='done'),
}
MODS = {0: 'QPSK', 1: '16QAM'}


def groups_text(mask, L):
    gs = [str(g) for g in range(11) if mask >> g & 1]
    return L['grp'] % L['sep'].join(gs) if gs else L['none']


TONE_DEFAULT = False      # tone state for windows without a tone_scale field (--tone-on-always)


def tone_on(r):
    return (r['tone_scale'] or 0) > 0 if 'tone_scale' in r else TONE_DEFAULT


def status_line(r, L, length):
    on = tone_on(r)
    mask = (r.get('nc') or {}).get('mask', 0)
    thr = r['ok'] * length * 8 / r['elapsed_s'] / 1e6 if r.get('elapsed_s') else 0.0
    return ' | '.join([L['win'] % r['window'], L['tone'][on], L['mask'] % groups_text(mask, L),
                       L['mod'] % MODS.get(r['mcs'], r['mcs']), L['ok'] % (r['ok'], r['sent']), L['thr'] % thr])


def alive(pid):
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


class Viewer:
    def __init__(self, L, length, out):
        self.L, self.length, self.out = L, length, out
        self.last = None
        self.shown = None
        self.prev = None          # (tone, mask, mcs) of the last window that has been seen
        self.counts = {False: [0, 0], True: [0, 0]}
        self.done = False

    def say(self, text):
        self.out.write(text + '\n')
        self.out.flush()

    def feed(self, rec):
        L = self.L
        kind = rec.get('type')
        if kind == 'sense':
            lines = rec.get('lines') or []
            found = L['lines'] % ', '.join('%.2f MHz' % (f / 1e6) for f, _ in lines) if lines else L['nolines']
            self.say(L['sense'] % (found, groups_text(rec.get('mask', 0), L), rec.get('seconds', 0.0)))
        elif kind == 'window':
            on = tone_on(rec)
            mask = (rec.get('nc') or {}).get('mask', 0)
            state = (on, mask, rec['mcs'])
            if self.prev is not None:
                if state[0] != self.prev[0]:
                    self.say(L['ev_tone'][on])
                if state[1] != self.prev[1]:
                    self.say(L['ev_mask'] % groups_text(mask, L))
                if state[2] != self.prev[2]:
                    self.say(L['ev_mod'] % MODS.get(rec['mcs'], rec['mcs']))
                if state != self.prev:
                    self.say(status_line(rec, L, self.length))
                    self.shown = rec['window']
            self.prev = state
            self.counts[on][0] += rec['ok']
            self.counts[on][1] += rec['sent']
            self.last = rec
        elif kind in ('summary', 'failure'):
            if kind == 'failure':
                self.say(L['fail'] % rec.get('error'))
            self.done = True

    def tick(self):
        if self.last is not None and self.last['window'] != self.shown:
            self.say(status_line(self.last, self.L, self.length))
            self.shown = self.last['window']


def follow(path, viewer, pid, period, timeout):
    t_start = time.monotonic()
    while not os.path.exists(path):
        if time.monotonic() - t_start > timeout:
            raise SystemExit('log did not appear: ' + path)
        time.sleep(0.05)
    buf = ''
    next_tick = time.monotonic() + period
    with open(path, encoding='utf-8') as f:
        while True:
            chunk = f.read()
            if chunk:
                buf += chunk
                *complete, buf = buf.split('\n')
                for line in complete:
                    if line.strip():
                        viewer.feed(json.loads(line))
            if viewer.done:
                break
            if not chunk and not alive(pid):
                break
            now = time.monotonic()
            if now >= next_tick:
                viewer.tick()
                next_tick = now + period
            time.sleep(0.02)
    viewer.tick()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('log')
    ap.add_argument('--pid', type=int, help='lean_adapt.py process; stop when it exits')
    ap.add_argument('--title', default='')
    ap.add_argument('--len', type=int, default=2048, help='frame payload bytes (for the Mbit/s figure)')
    ap.add_argument('--period', type=float, default=0.3)
    ap.add_argument('--timeout', type=float, default=10.0, help='seconds to wait for the log to appear')
    ap.add_argument('--ascii', action='store_true')
    ap.add_argument('--tone-on-always', action='store_true',
                    help='the tone was switched on before the run (no tone schedule in the log)')
    a = ap.parse_args(argv)
    global TONE_DEFAULT
    TONE_DEFAULT = a.tone_on_always
    L = LABELS['en' if a.ascii else 'zh']
    out = sys.stdout if a.ascii else io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', line_buffering=True)
    v = Viewer(L, a.len, out)
    if a.title:
        v.say('=' * 8 + ' ' + a.title + ' ' + '=' * 8)
    follow(a.log, v, a.pid, a.period, a.timeout)
    off, on = v.counts[False], v.counts[True]
    v.say(L['total'] % (a.title or L['end'], off[0], off[1], on[0], on[1]))
    if not a.ascii:
        out.detach()


if __name__ == '__main__':
    main()
