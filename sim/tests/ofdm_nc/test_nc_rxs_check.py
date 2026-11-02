"""Checker semantics of scripts/model/nc_rxs_check.py (independent review F10, 2026-10-26).

ANY only relaxes whether a frame must succeed; every OK record that does appear must be
complete (length, MCS, mask, zero bit errors, full comparison) and unique.
"""
from scripts.model import nc_rxs_check as chk

STATS = ('RXS_STATS samples=1 detections=2 long_plateaus=0 busy_drops=0 candidate_drops=0 frames=2 '
         'overruns=0 saturations=0 train_ok=2 train_reject=0 dropped_symbols=0 cpe_undefined=0')


def record(fid, length, mcs=0, mask=0, ber=0, cmp=None, reason=0):
    cmp = 8 * length if cmp is None else cmp
    return ('RXS_STATUS reason=%d id=%d len=%d mcs=%d mask=%d epoch=0 ber=%d cmp=%d unusable=0 start=0 '
            'step=0 evm=0 carriers=0 src=0 blind=0 t=0' % (reason, fid, length, mcs, mask, ber, cmp))


def run(records, expect_any):
    exp = dict(frames=[dict(frame_id=1, length=64, mcs=0, mask=0x80, expect='OK'),
                       dict(frame_id=2, length=18, mcs=1, mask=0x80, expect=expect_any)])
    log = '\n'.join(records + [STATS, 'RXS_DONE']) + '\n'
    return chk.check(exp, log)['problems']


GOOD1 = record(1, 64, mask=0x80)


def test_complete_records_pass():
    assert run([GOOD1, record(2, 18, mcs=1, mask=0x80)], 'ANY') == []
    assert run([GOOD1], 'ANY') == []                                # ANY may be lost


def test_any_ok_record_with_wrong_mcs_is_rejected():
    assert run([GOOD1, record(2, 18, mcs=0, mask=0x80)], 'ANY')


def test_any_ok_record_without_full_comparison_is_rejected():
    assert run([GOOD1, record(2, 18, mcs=1, mask=0x80, cmp=0)], 'ANY')


def test_any_frame_published_twice_is_rejected():
    assert run([GOOD1, record(2, 18, mcs=1, mask=0x80), record(2, 18, mcs=1, mask=0x80)], 'ANY')


def test_any_ok_record_with_wrong_mask_or_errors_is_rejected():
    assert run([GOOD1, record(2, 18, mcs=1, mask=0)], 'ANY')
    assert run([GOOD1, record(2, 18, mcs=1, mask=0x80, ber=3)], 'ANY')
