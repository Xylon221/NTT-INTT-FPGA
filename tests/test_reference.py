"""Independent mathematical checks for the integer reference and vector files."""

import json
from pathlib import Path
import random
import tempfile
import unittest

from python.ntt_ref import (
    Parameters,
    bit_reverse,
    evaluate_polynomial,
    is_prime,
    negacyclic_multiply,
    ntt,
    schoolbook_negacyclic,
)
from tools.generate_vectors import make_vectors


def direct_transform(values, params, inverse=False, negacyclic=False):
    """Definition as a dense Vandermonde product; no radix-2 operations."""
    n, q = params.n, params.q
    omega = pow(params.primitive_root, (q - 1) // n, q)
    psi = pow(params.primitive_root, (q - 1) // (2 * n), q)
    if inverse:
        inverse_n = pow(n, -1, q)
        return [
            sum(values[k] * pow(omega, -j * k, q) for k in range(n))
            * inverse_n
            * (pow(psi, -j, q) if negacyclic else 1)
            % q
            for j in range(n)
        ]
    return [
        sum(
            values[j] * pow(omega, j * k, q)
            * (pow(psi, j, q) if negacyclic else 1)
            for j in range(n)
        ) % q
        for k in range(n)
    ]


class ReferenceTests(unittest.TestCase):
    def test_bit_reverse(self):
        self.assertEqual([bit_reverse(i, 3) for i in range(8)], [0, 4, 2, 6, 1, 5, 3, 7])
        self.assertEqual(bit_reverse(0, 0), 0)
        for value, bits in ((-1, 3), (8, 3), (0, -1)):
            with self.assertRaises(ValueError):
                bit_reverse(value, bits)

    def test_primality_and_parameter_validation(self):
        for value in (2, 3, 17, 2013265921, 18446744069414584321):
            self.assertTrue(is_prime(value))
        for value in (0, 1, 9, 561, 341550071728321, (1 << 64) + 13):
            self.assertFalse(is_prime(value))
        for args in ((1, 17, 3), (3, 17, 3), (8, 15, 2), (16, 17, 3), (8, 17, 4), (8, 17, 1)):
            with self.subTest(args=args), self.assertRaises(ValueError):
                Parameters(*args)

    def test_all_transform_modes_against_direct_definition(self):
        rng = random.Random(637)
        for size in (2, 4, 8, 16, 32):
            p = Parameters(size, 2013265921, 31)
            values = [rng.randrange(-2 * p.q, 3 * p.q) for _ in range(size)]
            for inverse in (False, True):
                for negacyclic in (False, True):
                    with self.subTest(n=size, inverse=inverse, negacyclic=negacyclic):
                        self.assertEqual(
                            ntt(values, p, inverse, negacyclic),
                            direct_transform(values, p, inverse, negacyclic),
                        )

    def test_impulse_and_constant(self):
        p = Parameters(16)
        impulse = [1] + [0] * (p.n - 1)
        self.assertEqual(ntt(impulse, p), [1] * p.n)
        self.assertEqual(ntt([1] * p.n, p), [p.n] + [0] * (p.n - 1))

    def test_full_size_roundtrips(self):
        p, rng = Parameters(), random.Random(8192)
        values = [rng.randrange(p.q) for _ in range(p.n)]
        for negacyclic in (False, True):
            with self.subTest(negacyclic=negacyclic):
                self.assertEqual(
                    ntt(ntt(values, p, negacyclic=negacyclic), p, inverse=True, negacyclic=negacyclic),
                    values,
                )

    def test_negacyclic_products_against_schoolbook(self):
        rng = random.Random(947)
        for size in (2, 4, 8, 16, 32):
            p = Parameters(size)
            for _ in range(6):
                a = [rng.randrange(-p.q, p.q) for _ in range(size)]
                b = [rng.randrange(-p.q, p.q) for _ in range(size)]
                self.assertEqual(negacyclic_multiply(a, b, p), schoolbook_negacyclic(a, b, p.q))

    def test_sparse_wraparound_identity(self):
        p = Parameters()
        a = [0] * p.n
        b = [0] * p.n
        a[p.n - 1] = b[1] = 1
        self.assertEqual(negacyclic_multiply(a, b, p), [p.q - 1] + [0] * (p.n - 1))

    def test_full_size_dense_times_sparse(self):
        p, rng = Parameters(), random.Random(29)
        a = [rng.randrange(p.q) for _ in range(p.n)]
        sparse = {0: p.q - 1, 1: 3, p.n // 2: 11, p.n - 1: 2}
        b, expected = [0] * p.n, [0] * p.n
        for shift, factor in sparse.items():
            b[shift] = factor
            for i, value in enumerate(a):
                dest = i + shift
                expected[dest % p.n] += (1 if dest < p.n else -1) * value * factor
        self.assertEqual(negacyclic_multiply(a, b, p), [v % p.q for v in expected])

    def test_64_bit_modulus(self):
        p = Parameters(16, 18446744069414584321, 7)
        a = [p.q - i - 1 for i in range(p.n)]
        self.assertEqual(ntt(a, p), direct_transform(a, p))
        self.assertEqual(negacyclic_multiply(a, a, p), schoolbook_negacyclic(a, a, p.q))

    def test_invalid_inputs(self):
        p = Parameters(8, 17, 3)
        with self.assertRaises(ValueError):
            ntt([0] * 7, p)
        with self.assertRaises(TypeError):
            ntt([0.5] * 8, p)
        for a, b, q in (([], [], 17), ([1], [1, 2], 17), ([1], [1], 1)):
            with self.assertRaises(ValueError):
                schoolbook_negacyclic(a, b, q)

    def test_vector_determinism_and_independent_product_checks(self):
        p = Parameters(8, 17, 3)
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            first, second = Path(first), Path(second)
            config = make_vectors(p, 1234, first)
            make_vectors(p, 1234, second)
            for filename in ("config.json", *config["files"]):
                self.assertEqual((first / filename).read_bytes(), (second / filename).read_bytes())
            self.assertEqual(json.loads((first / "config.json").read_text())["seed"], 1234)
            product = [int(line, 16) for line in (first / "product.hex").read_text().splitlines()]
            a = [int(line, 16) for line in (first / "a.hex").read_text().splitlines()]
            b = [int(line, 16) for line in (first / "b.hex").read_text().splitlines()]
            self.assertEqual(product, schoolbook_negacyclic(a, b, p.q))
            for check in config["independent_product_evaluations"]:
                self.assertEqual(pow(check["point"], p.n, p.q), p.q - 1)
                self.assertEqual(evaluate_polynomial(product, check["point"], p.q), check["product_value"])


if __name__ == "__main__":
    unittest.main()
