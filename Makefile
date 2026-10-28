PYTHON ?= python3
N ?= 8192
SEED ?= 20261028
LOG_N ?= 13
USE_TFG ?= 1

.PHONY: test quick sim vectors reference wide rns60 synth help
help:
	@echo 'make test       Full Python + RTL regression, N=16/256/8192, ROM + TFG'
	@echo 'make quick      Small-size regression'
	@echo 'make sim N=8192 One size, both architectures'
	@echo 'make vectors    Generate default ROM and oracle files for synthesis'
	@echo 'make rns60      8192-point transform with a 60-bit modulus'
	@echo 'make synth PART=<part> LOG_N=13 USE_TFG=1  Vivado synthesis'
test:
	$(PYTHON) tools/run_regression.py
quick:
	$(PYTHON) tools/run_regression.py --sizes 16 256 --build-dir build/quick
sim:
	$(PYTHON) tools/run_regression.py --sizes $(N) --seeds $(SEED)
vectors:
	$(PYTHON) tools/generate_vectors.py --n $(N) --seed $(SEED) --output build/vectors
reference:
	$(PYTHON) -m unittest discover -s tests -v
wide:
	$(PYTHON) tools/run_regression.py --sizes 16 --width 64 --q 18446744069414584321 --root 7 --build-dir build/wide_core
rns60:
	$(PYTHON) tools/run_regression.py --sizes 16 8192 --width 64 --q 1152921504606830593 --root 5 --build-dir build/rns60
synth:
	PART="$(PART)" LOG_N="$(LOG_N)" USE_TFG="$(USE_TFG)" vivado -mode batch -source fpga/synth.tcl
