#!/usr/bin/env python3
"""Generate deterministic Python oracle vectors and ROM images for RTL tests."""

import argparse
import json
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from python.ntt_ref import Parameters, evaluate_polynomial, ntt


def make_vectors(params: Parameters, seed: int, output: Path) -> dict:
    random_source = random.Random(seed)
    a = [random_source.randrange(params.q) for _ in range(params.n)]
    b = [random_source.randrange(params.q) for _ in range(params.n)]
    for j, value in enumerate((0, 1, params.q - 1, params.q - 2)):
        if j < params.n:
            a[j] = value
            b[j] = (params.q - value) % params.q
    forward_neg = ntt(a, params, negacyclic=True)
    b_ntt_neg = ntt(b, params, negacyclic=True)
    product_freq = [x * y % params.q for x, y in zip(forward_neg, b_ntt_neg)]
    product = ntt(product_freq, params, inverse=True, negacyclic=True)
    # Verify dense 8192-point multiplication independently at roots of x^N+1.
    # These checks supplement (and do not replace) small-N schoolbook tests.
    checks = []
    for k in sorted({0, 1, params.n // 3, params.n - 1}):
        point = params.psi * pow(params.omega, k, params.q) % params.q
        left = evaluate_polynomial(product, point, params.q)
        right = (
            evaluate_polynomial(a, point, params.q)
            * evaluate_polynomial(b, point, params.q)
            % params.q
        )
        if left != right:
            raise AssertionError(f"independent product evaluation failed at k={k}")
        checks.append({"k": k, "point": point, "product_value": left})
    vectors = {
        "a": a,
        "b": b,
        "forward": ntt(a, params),
        "inverse": ntt(a, params, inverse=True),
        "forward_neg": forward_neg,
        "inverse_neg": ntt(a, params, inverse=True, negacyclic=True),
        "a_ntt_neg": forward_neg,
        "b_ntt_neg": b_ntt_neg,
        "product_freq": product_freq,
        "product": product,
        "rom_forward": [pow(params.omega, k, params.q) for k in range(params.n // 2)],
        "rom_inverse": [pow(params.omega_inv, k, params.q) for k in range(params.n // 2)],
    }
    output.mkdir(parents=True, exist_ok=True)
    digits = max(8, (params.q.bit_length() + 3) // 4)
    for name, values in vectors.items():
        (output / f"{name}.hex").write_text(
            "".join(f"{value:0{digits}x}\n" for value in values), encoding="ascii"
        )
    constants = {
        "n": params.n,
        "log_n": params.log_n,
        "q": params.q,
        "primitive_root": params.primitive_root,
        "omega": params.omega,
        "omega_inv": params.omega_inv,
        "psi": params.psi,
        "psi_inv": params.psi_inv,
        "n_inv": params.n_inv,
    }
    config = {
        **constants,
        "seed": seed,
        "hex_digits": digits,
        "hex": {key: f"{value:x}" for key, value in constants.items()},
        "ordering": "natural-order input and natural-order output",
        "ring": f"Z_{params.q}[x]/(x^{params.n}+1)",
        "files": {f"{name}.hex": len(values) for name, values in vectors.items()},
        "independent_product_evaluations": checks,
    }
    (output / "config.json").write_text(
        json.dumps(config, indent=2) + "\n", encoding="utf-8"
    )
    return config


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--n", type=int, default=8192)
    parser.add_argument("--q", type=int, default=2013265921)
    parser.add_argument("--root", type=int, default=31)
    parser.add_argument("--seed", type=int, default=20261028)
    parser.add_argument("--output", type=Path, default=Path("build/vectors"))
    args = parser.parse_args()
    try:
        params = Parameters(args.n, args.q, args.root)
    except (TypeError, ValueError) as error:
        parser.error(str(error))
    config = make_vectors(params, args.seed, args.output)
    print(
        f"Generated {len(config['files'])} vector files: N={params.n}, "
        f"q={params.q}, seed={args.seed}, output={args.output}"
    )
    print(f"Independent polynomial evaluations passed: {len(config['independent_product_evaluations'])}")


if __name__ == "__main__":
    main()
