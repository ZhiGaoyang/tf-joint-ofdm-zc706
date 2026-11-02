import itertools
import pathlib
import random
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import joint_policy as jp  # noqa: E402

CAL = jp.Calibration(pathlib.Path(__file__).resolve().parents[1] / "innovation_a/results/calibration.json")
CLEAN = 2.0      # % EVM, model SNR at the top of the table
MID = 12.0       # % EVM, QPSK fine, 16QAM fails (see A design table)
BAD = 60.0       # % EVM, group destroyed by a tone / erasure


def evms(default, **groups):
    e = [default] * jp.GROUPS
    for g, v in groups.items():
        e[int(g[1:])] = v
    return e


class JointPolicyTest(unittest.TestCase):
    def decide(self, e, measured_mode=0, frames_ok=16, policy=None):
        p = policy or jp.JointPolicy(CAL)
        return p.decide(measured_mode, e, frames_ok)

    def test_clean_link_uses_16qam_without_mask(self):
        mode, mask, _ = self.decide(evms(CLEAN))
        self.assertEqual((mode, mask), (1, frozenset()))

    def test_one_destroyed_group_is_masked_at_16qam(self):
        mode, mask, _ = self.decide(evms(CLEAN, g7=BAD))
        self.assertEqual((mode, mask), (1, frozenset({7})))

    def test_uniform_degradation_falls_back_to_qpsk_without_mask(self):
        mode, mask, _ = self.decide(evms(MID))
        self.assertEqual((mode, mask), (0, frozenset()))

    def test_slightly_worse_group_is_not_worth_masking(self):
        # A weak tone that raises one group's EVM but leaves PER at 0 must not cost 9% rate.
        mode, mask, _ = self.decide(evms(CLEAN, g7=4.0))
        self.assertEqual((mode, mask), (1, frozenset()))

    def test_bad_groups_and_mid_snr_mask_and_qpsk(self):
        # 2048-byte frames as in B section 10.4: QPSK with 2 masked groups fits (L_max 3362).
        mode, mask, _ = self.decide(evms(MID, g2=BAD, g9=BAD), policy=jp.JointPolicy(CAL, length=2048))
        self.assertEqual((mode, mask), (0, frozenset({2, 9})))

    def test_4096_byte_frames_cannot_mask_in_qpsk(self):
        # Same channel with 4096-byte frames: any QPSK mask exceeds L_max, so 16QAM is masked.
        mode, mask, _ = self.decide(evms(MID, g2=BAD, g9=BAD))
        self.assertEqual((mode, mask), (1, frozenset({2, 9})))

    def test_never_more_than_three_groups(self):
        mode, mask, _ = self.decide(evms(CLEAN, g0=BAD, g1=BAD, g2=BAD, g3=BAD, g4=BAD))
        self.assertLessEqual(len(mask), jp.MAX_MASKED)

    def test_outage_returns_qpsk_and_keeps_mask(self):
        # Outage = no metric at all (nothing decoded): QPSK, mask kept (legal at 2048 B; the
        # 4096 B case, where QPSK + {7} exceeds L_max, is test_outage_returns_a_legal_length_combination).
        p = jp.JointPolicy(CAL, length=2048)
        p.decide(0, evms(CLEAN, g7=BAD), 16)
        mode, mask, reason = p.decide(1, [None] * jp.GROUPS, 0)
        self.assertEqual((mode, reason), (0, "link_lost"))
        self.assertEqual(mask, frozenset({7}))

    def test_all_frames_lost_to_a_tone_still_masks_it(self):
        # A tone that breaks every payload CRC leaves the per-group metric valid: the policy
        # must act on it (otherwise the interfered link never recovers).
        mode, mask, reason = self.decide(evms(CLEAN, g7=BAD), frames_ok=0)
        self.assertEqual((mask, reason), (frozenset({7}), "switch"))

    def test_hysteresis_holds_on_marginal_gain(self):
        p = jp.JointPolicy(CAL, hyst=10.0)        # absurd hysteresis: never switch modulation
        self.assertEqual(p.decide(0, evms(CLEAN), 16)[2], "hold")

    def test_mask_hysteresis_holds_on_tiny_gain(self):
        p = jp.JointPolicy(CAL, hyst_mask=0.10)   # unmasking gains ~4%: held below 10%
        p.mode, p.mask = 1, frozenset({7})
        snrs = jp.group_snr_from_metrics(CAL, 1, [0.0004] * jp.GROUPS, [0.0] * jp.GROUPS, p.mask)
        self.assertEqual(p.decide(1, None, 16, snrs=snrs)[2], "hold")

    def test_greedy_equals_exhaustive(self):
        rng = random.Random(20261025)
        for _ in range(200):
            e = [rng.choice([CLEAN, 5.0, 8.0, 10.0, MID, 15.0, 25.0, BAD]) for _ in range(jp.GROUPS)]
            snrs = jp.group_snr(CAL, rng.choice([0, 1]), e)
            p = jp.JointPolicy(CAL)
            greedy = max(p.score(snrs, m, msk) for m in (0, 1) for msk in jp.candidates(snrs))
            full = max(p.score(snrs, m, frozenset(c)) for m in (0, 1)
                       for k in range(jp.MAX_MASKED + 1) for c in itertools.combinations(range(jp.GROUPS), k))
            self.assertAlmostEqual(greedy, full, places=9)

    def test_payload_symbols_grow_when_masking(self):
        self.assertEqual(jp.payload_symbols(4096, 1, 88), 94)
        self.assertEqual(jp.payload_symbols(4096, 1, 80), 103)
        self.assertEqual(jp.payload_symbols(4096, 0, 88), 187)

    def test_persistently_erased_group_is_masked(self):
        m = [0.0004] * jp.GROUPS
        e = [0.0] * jp.GROUPS
        e[10] = 0.5                                  # two carriers of group 10 erased every symbol
        snrs = jp.group_snr_from_metrics(CAL, 0, m, e, frozenset())
        self.assertEqual(snrs[10], jp.DESTROYED_DB)
        mode, mask, _ = jp.JointPolicy(CAL).decide(0, None, 16, snrs=snrs)
        self.assertEqual((mode, mask), (1, frozenset({10})))

    def test_masked_group_recovers_when_interference_leaves(self):
        p = jp.JointPolicy(CAL)
        p.mode, p.mask = 1, frozenset({7})
        m = [0.0004] * jp.GROUPS                     # masked group 7 now quiet (1/M = 34 dB)
        snrs = jp.group_snr_from_metrics(CAL, 1, m, [0.0] * jp.GROUPS, p.mask)
        mode, mask, reason = p.decide(1, None, 16, snrs=snrs)
        self.assertEqual((mode, mask, reason), (1, frozenset(), "switch"))

    def test_masked_group_stays_masked_while_interfered(self):
        p = jp.JointPolicy(CAL)
        p.mode, p.mask = 1, frozenset({7})
        m = [0.0004] * jp.GROUPS
        m[7] = 10.0                                  # tone 10 dB above the signal on group 7
        snrs = jp.group_snr_from_metrics(CAL, 1, m, [0.0] * jp.GROUPS, p.mask)
        self.assertEqual(p.decide(1, None, 16, snrs=snrs)[1], frozenset({7}))

    def test_never_selects_a_mask_the_frame_length_does_not_fit(self):
        # QPSK with 3 masked groups carries at most 2988 bytes (B design section 3):
        # a 4096-byte frame there would make the TX framer fault.
        p = jp.JointPolicy(CAL, length=4096)
        snrs = [jp.DESTROYED_DB] * 3 + [12.0] * 8
        for _ in range(3):
            mode, mask, _ = p.decide(0, None, 16, snrs=snrs)
            self.assertTrue(len(mask) == 0 or 4096 <= jp.l_max(len(mask), mode))

    def test_outage_returns_a_legal_length_combination(self):
        # independent F4: from 16QAM + {7} at 4096 B, QPSK + {7} would exceed L_max (3736).
        p = jp.JointPolicy(CAL, length=4096)
        p.mode, p.mask = 1, frozenset({7})
        mode, mask, reason = p.decide(0, [None] * jp.GROUPS, 0)
        self.assertEqual((mode, reason), (0, "link_lost"))
        self.assertLessEqual(4096, jp.l_max(len(mask), mode))

    def test_no_viable_candidate_falls_back_to_qpsk(self):
        # independent F7: four destroyed groups -> every score is zero -> QPSK, protective legal mask.
        p = jp.JointPolicy(CAL, length=2048)
        p.mode = 1
        snrs = [jp.DESTROYED_DB] * 4 + [25.0] * 7
        mode, mask, reason = p.decide(0, None, 16, snrs=snrs)
        self.assertEqual((mode, len(mask), reason), (0, 3, "no_viable"))

    def test_saturated_masked_group_is_destroyed_not_an_exception(self):
        # independent review (13-15): the reference raised on log10(1/inf); the board port treats it as destroyed.
        snrs = jp.group_snr_from_metrics(CAL, 0, [0.001] * 10 + [float("inf")], [0.0] * 11, {10})
        self.assertEqual(snrs[10], jp.DESTROYED_DB)

    def test_bitmap(self):
        self.assertEqual(jp.mask_bitmap({0, 7, 10}), 0b10010000001)


if __name__ == "__main__":
    unittest.main()
