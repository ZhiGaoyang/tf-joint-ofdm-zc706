import io
import json
import os
import pathlib
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT.parent / 'src' / 'ps'))
import demo_view  # noqa: E402


def win(w, ok, mask=0, mcs=0, tone=None):
    r = dict(type='window', window=w, ok=ok, sent=16, mcs=mcs, elapsed_s=0.004, nc=dict(mask=mask))
    if tone is not None:
        r['tone_scale'] = tone
    return r


RUN = [dict(type='config'), dict(type='sense', lines=[[21600000, 46.9]], groups=[7, 8], mask=0x180, seconds=0.31),
       win(0, 16, 0x180), win(1, 16, 0x180, 1, 0.0), win(2, 0, 0x180, 1, 0.1), win(3, 16, 0x1c0, 0, 0.1),
       win(4, 16, 0x1c0, 0, 0.0), win(5, 16, 0, 1, 0.0), dict(type='summary', completed=True)]


def run_view(tmp_path, records, *args, live=False):
    log = tmp_path / 'demo.jsonl'
    out = io.StringIO()
    sys_stdout = sys.stdout
    if live:
        log.write_text('', encoding='utf-8')

        def writer():
            for r in records:
                with open(log, 'a', encoding='utf-8') as f:
                    f.write(json.dumps(r) + '\n')
                time.sleep(0.01)
        t = threading.Thread(target=writer)
        t.start()
    else:
        log.write_text(''.join(json.dumps(r) + '\n' for r in records), encoding='utf-8')
    try:
        sys.stdout = out
        demo_view.main([str(log), '--ascii', '--period', '0.05', '--pid', str(os.getpid()), *args])
    finally:
        sys.stdout = sys_stdout
        if live:
            t.join()
    return out.getvalue()


def test_events_status_and_totals(tmp_path):
    text = run_view(tmp_path, RUN, '--title', 'T')
    assert 'pre-tx sensing: lines 21.60 MHz -> initial mask groups 7,8' in text
    assert '-> tone on' in text and '-> tone off' in text
    assert '-> mask now: groups 6,7,8' in text and '-> mask now: none' in text
    assert '-> modulation now: QPSK' in text
    assert 'win    2 | tone ON  | mask: groups 7,8 | mod: 16QAM |  0/16 frames ok' in text
    # window 0 has no tone_scale -> counted as tone off; windows 2-3 tone on
    assert 'summary (T): tone off 64/64 frames ok, tone on 16/32 frames ok' in text


def test_follows_a_growing_log_until_the_summary(tmp_path):
    text = run_view(tmp_path, RUN, live=True)
    assert 'tone on 16/32 frames ok' in text and text.count('pre-tx sensing') == 1


def test_tone_on_always_and_failure_record(tmp_path):
    recs = [dict(type='sense', lines=[], groups=[], mask=0, seconds=0.3), win(0, 16), win(1, 0),
            dict(type='failure', error='RuntimeError("x")')]
    text = run_view(tmp_path, recs, '--tone-on-always')
    assert 'no narrowband line -> initial mask none' in text
    assert 'run aborted' in text and 'tone off 0/0 frames ok, tone on 16/32 frames ok' in text
    demo_view.TONE_DEFAULT = False


def test_mbit_figure_uses_frame_length_and_window_time():
    line = demo_view.status_line(win(7, 16, 0, 1, 0.0), demo_view.LABELS['en'], 2048)
    assert line.endswith('~ 65.5 Mbit/s')           # 16 * 2048 * 8 / 0.004 s
