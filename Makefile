.PHONY: help install build test test-deep gas fmt lint sim fixtures clean snapshot

help:
	@echo "Kairos"
	@echo ""
	@echo "  make install     install dependencies (forge-std)"
	@echo "  make build       compile contracts"
	@echo "  make test        run the full test suite"
	@echo "  make test-deep   20k fuzz runs, 512 invariant runs — the pre-release gate"
	@echo "  make gas         print the gas benchmark"
	@echo "  make fmt         format Solidity"
	@echo "  make lint        lint production code"
	@echo "  make sim         run the research simulation, regenerate docs/RESULTS.md"
	@echo "  make fixtures    regenerate the math reference vectors"
	@echo "  make clean       remove build artefacts"

install:
	forge install

build:
	forge build

test:
	forge test

test-deep:
	FOUNDRY_PROFILE=deep forge test

gas:
	forge test --match-path 'test/Gas.t.sol' -vv

snapshot:
	forge snapshot

fmt:
	forge fmt

lint:
	forge lint src/

sim:
	python3 sim/kairos_sim.py

fixtures:
	python3 sim/gen_math_fixtures.py > test/fixtures/MathFixtures.sol

clean:
	forge clean
