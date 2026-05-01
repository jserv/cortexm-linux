#!/usr/bin/env python3

import importlib.util
import pathlib
import tempfile
import unittest


SCRIPT_PATH = pathlib.Path(__file__).with_name("qemu-trace-to-orderfile.py")
SPEC = importlib.util.spec_from_file_location("qemu_trace_to_orderfile", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ParseTraceTests(unittest.TestCase):
    def test_extracts_syscalls_when_r7_precedes_trace(self):
        trace_text = """\
R00=00000000 R01=00000000 R02=00000000 R03=00000000
R04=00000000 R05=00000000 R06=00000000 R07=000000a2
Trace 0: 0x0 [00000000/0000000021001000/00000000/00000000]
Trace 0: 0x0 [00000000/0000000021002000/00000000/00000000]
R00=00000000 R01=00000000 R02=00000000 R03=00000000
R04=00000000 R05=00000000 R06=00000000 R07=00000005
R00=00000000 R01=00000000 R02=00000000 R03=00000000
R04=00000000 R05=00000000 R06=00000000 R07=00000007
Trace 0: 0x0 [00000000/0000000021001002/00000000/00000000]
Trace 0: 0x0 [00000000/0000000021003000/00000000/00000000]
R00=00000000 R01=00000000 R02=00000000 R03=00000000
R04=00000000 R05=00000000 R06=00000000 R07=00001000
"""
        starts = [0x21001000, 0x21002000, 0x21003000]
        records = [
            (0x21001000, 0x21001010, "vector_swi"),
            (0x21002000, 0x21002010, "regular_path"),
            (0x21003000, 0x21003010, "vector_swi"),
        ]

        with tempfile.TemporaryDirectory() as tmpdir:
            trace_path = pathlib.Path(tmpdir) / "trace.log"
            trace_path.write_text(trace_text, encoding="utf-8")
            _, _, total, matched, syscall_counts, _ = MODULE.parse_trace(
                trace_path, starts, records
            )

        self.assertEqual(total, 4)
        self.assertEqual(matched, 4)
        self.assertEqual(syscall_counts[162], 1)
        self.assertEqual(syscall_counts[7], 1)
        self.assertNotIn(5, syscall_counts)
        self.assertNotIn(4096, syscall_counts)

    def test_r7_above_max_arm_syscall_rejected(self):
        # R07 bound to vector_swi but greater than MAX_ARM_SYSCALL must be
        # dropped. Includes the at-boundary value 511 to confirm the check
        # is `>`, not `>=`.
        trace_text = """\
R00=0 R01=0 R02=0 R03=0
R04=0 R05=0 R06=0 R07=000001ff
Trace 0: 0x0 [00000000/0000000021001000/00000000/00000000]
R00=0 R01=0 R02=0 R03=0
R04=0 R05=0 R06=0 R07=00000200
Trace 0: 0x0 [00000000/0000000021001000/00000000/00000000]
"""
        starts = [0x21001000]
        records = [(0x21001000, 0x21001010, "vector_swi")]

        with tempfile.TemporaryDirectory() as tmpdir:
            trace_path = pathlib.Path(tmpdir) / "trace.log"
            trace_path.write_text(trace_text, encoding="utf-8")
            _, _, _, _, syscall_counts, _ = MODULE.parse_trace(
                trace_path, starts, records
            )

        self.assertEqual(syscall_counts[511], 1)
        self.assertNotIn(512, syscall_counts)

    def test_orphan_tbs_do_not_steal_next_r7(self):
        # regdump R07=A binds to TB_A (non-swi). TB_B follows with no
        # intervening regdump (orphan). The next regdump R07=C must bind
        # to the upcoming vector_swi at TB_C, not to the orphan TB_B.
        trace_text = """\
R00=0 R01=0 R02=0 R03=0
R04=0 R05=0 R06=0 R07=00000001
Trace 0: 0x0 [00000000/0000000021002000/00000000/00000000]
Trace 0: 0x0 [00000000/0000000021002004/00000000/00000000]
R00=0 R01=0 R02=0 R03=0
R04=0 R05=0 R06=0 R07=0000002a
Trace 0: 0x0 [00000000/0000000021001000/00000000/00000000]
"""
        starts = [0x21001000, 0x21002000]
        records = [
            (0x21001000, 0x21001010, "vector_swi"),
            (0x21002000, 0x21002010, "regular_path"),
        ]

        with tempfile.TemporaryDirectory() as tmpdir:
            trace_path = pathlib.Path(tmpdir) / "trace.log"
            trace_path.write_text(trace_text, encoding="utf-8")
            _, _, _, _, syscall_counts, _ = MODULE.parse_trace(
                trace_path, starts, records
            )

        self.assertEqual(syscall_counts[42], 1)
        self.assertNotIn(1, syscall_counts)


if __name__ == "__main__":
    unittest.main()
