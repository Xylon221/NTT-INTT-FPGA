"""Dependency-free natural-order NTT reference over one prime RNS limb.

All operations use Python integers. This is a correctness oracle, not a CKKS
encoder, key generator, encryption implementation, or constant-time library.
"""

from dataclasses import dataclass
from operator import index
from typing import Iterable, Sequence


def is_prime(value: int) -> bool:
    """Deterministic Miller--Rabin for unsigned integers below 2**64."""
    value = index(value)
    if not 2 <= value < 1 << 64:
        return False
    for prime in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
        if value % prime == 0:
            return value == prime
    d, s = value - 1, 0
    while d % 2 == 0:
        d //= 2
        s += 1
    for base in (2, 325, 9375, 28178, 450775, 9780504, 1795265022):
        if base % value == 0:
            continue
        witness = pow(base, d, value)
        if witness in (1, value - 1):
            continue
        for _ in range(s - 1):
            witness = witness * witness % value
            if witness == value - 1:
                break
        else:
            return False
    return True


@dataclass(frozen=True)
class Parameters:
    """One NTT modulus; primitive_root must yield a primitive 2N-th root."""

    n: int = 8192
    q: int = 2013265921
    primitive_root: int = 31

    def __post_init__(self) -> None:
        for name in ("n", "q", "primitive_root"):
            object.__setattr__(self, name, index(getattr(self, name)))
        if self.n < 2 or self.n & (self.n - 1):
            raise ValueError("n must be a power of two and at least 2")
        if not is_prime(self.q):
            raise ValueError("q must be a prime below 2**64")
        if (self.q - 1) % (2 * self.n):
            raise ValueError("q must be congruent to 1 modulo 2*n")
        if not 1 < self.primitive_root < self.q:
            raise ValueError("primitive_root must satisfy 1 < root < q")
        if pow(self.psi, self.n, self.q) != self.q - 1:
            raise ValueError("root does not yield a primitive 2*n-th root")
        if pow(self.omega, self.n, self.q) != 1:
            raise ValueError("omega is not an n-th root")
        if pow(self.omega, self.n // 2, self.q) != self.q - 1:
            raise ValueError("omega does not have order n")

    @property
    def log_n(self) -> int:
        return self.n.bit_length() - 1

    @property
    def omega(self) -> int:
        return pow(self.primitive_root, (self.q - 1) // self.n, self.q)

    @property
    def omega_inv(self) -> int:
        return pow(self.omega, self.q - 2, self.q)

    @property
    def psi(self) -> int:
        return pow(self.primitive_root, (self.q - 1) // (2 * self.n), self.q)

    @property
    def psi_inv(self) -> int:
        return pow(self.psi, self.q - 2, self.q)

    @property
    def n_inv(self) -> int:
        return pow(self.n, self.q - 2, self.q)


def bit_reverse(value: int, bits: int) -> int:
    value, bits = index(value), index(bits)
    if bits < 0 or value < 0 or value >= 1 << bits:
        raise ValueError("value must fit in a nonnegative number of bits")
    result = 0
    for _ in range(bits):
        result = result << 1 | value & 1
        value >>= 1
    return result


def _canonical(values: Iterable[int], q: int) -> list[int]:
    return [index(value) % q for value in values]


def ntt(
    values: Sequence[int],
    params: Parameters,
    inverse: bool = False,
    negacyclic: bool = False,
) -> list[int]:
    """Transform natural-order coefficients to/from natural-order frequencies.

    Cyclic forward: A[k] = sum_j a[j] * omega**(j*k) mod q.
    Negacyclic forward: A[k] = sum_j a[j] * psi**j * omega**(j*k).
    Both inverse paths include multiplication by n**(-1); negacyclic inverse
    additionally multiplies output coefficient j by psi**(-j).
    Inputs may contain signed or noncanonical integers; outputs lie in [0,q).
    """
    if len(values) != params.n:
        raise ValueError(f"expected {params.n} coefficients, got {len(values)}")
    n, q = params.n, params.q
    data = _canonical(values, q)
    if negacyclic and not inverse:
        twist, step = 1, params.psi
        for j in range(n):
            data[j] = data[j] * twist % q
            twist = twist * step % q
    for j in range(n):
        reversed_j = bit_reverse(j, params.log_n)
        if reversed_j > j:
            data[j], data[reversed_j] = data[reversed_j], data[j]
    root = params.omega_inv if inverse else params.omega
    size = 2
    while size <= n:
        half = size // 2
        step = pow(root, n // size, q)
        for offset in range(0, n, size):
            twiddle = 1
            for j in range(half):
                left = data[offset + j]
                right = data[offset + j + half] * twiddle % q
                data[offset + j] = (left + right) % q
                data[offset + j + half] = (left - right) % q
                twiddle = twiddle * step % q
        size *= 2
    if inverse:
        scale = params.n_inv
        step = params.psi_inv if negacyclic else 1
        for j in range(n):
            data[j] = data[j] * scale % q
            scale = scale * step % q
    return data


def negacyclic_multiply(
    a: Sequence[int], b: Sequence[int], params: Parameters
) -> list[int]:
    """Product in Z_q[x]/(x**n+1), using two NTTs and one INTT."""
    spectrum_a = ntt(a, params, negacyclic=True)
    spectrum_b = ntt(b, params, negacyclic=True)
    spectrum = [x * y % params.q for x, y in zip(spectrum_a, spectrum_b)]
    return ntt(spectrum, params, inverse=True, negacyclic=True)


def schoolbook_negacyclic(
    a: Sequence[int], b: Sequence[int], q: int
) -> list[int]:
    """Independent O(N**2) convolution oracle with explicit negative wrap."""
    q = index(q)
    if not a or len(a) != len(b):
        raise ValueError("a and b must have the same positive length")
    if q < 2:
        raise ValueError("q must be at least 2")
    n = len(a)
    result = [0] * n
    for i, left in enumerate(_canonical(a, q)):
        for j, right in enumerate(_canonical(b, q)):
            k = i + j
            if k >= n:
                result[k - n] -= left * right
            else:
                result[k] += left * right
    return [value % q for value in result]


def evaluate_polynomial(values: Sequence[int], point: int, q: int) -> int:
    """Horner evaluation; independent of transform permutation/butterflies."""
    result = 0
    for value in reversed(values):
        result = (result * point + index(value)) % q
    return result
