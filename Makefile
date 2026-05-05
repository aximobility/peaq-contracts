# peaq-contracts Makefile - one entrypoint per common workflow.

.PHONY: install build test test-fuzz test-invariant snapshot fmt lint clean coverage \
        deploy-agung deploy-mainnet verify-agung verify-mainnet slither

install:
	@command -v forge >/dev/null || (echo "Foundry not installed. https://book.getfoundry.sh/getting-started/installation"; exit 1)
	forge install --no-commit OpenZeppelin/openzeppelin-contracts
	forge install --no-commit OpenZeppelin/openzeppelin-contracts-upgradeable
	forge install --no-commit foundry-rs/forge-std

build:
	forge build --sizes

test:
	forge test -vv

test-fuzz:
	FOUNDRY_PROFILE=ci forge test --fuzz-runs 5000 -vv

test-invariant:
	FOUNDRY_PROFILE=ci forge test --match-test invariant_ -vv

snapshot:
	forge snapshot --check

fmt:
	forge fmt

lint: fmt
	forge build --skip test --skip script

coverage:
	forge coverage --report lcov --report summary

clean:
	forge clean

deploy-agung:
	forge script script/Deploy.s.sol:Deploy --rpc-url agung --broadcast --verify --slow

deploy-mainnet:
	@echo "DEPLOYING TO MAINNET. Pausing 10s for sanity. Ctrl-C to abort."
	@sleep 10
	forge script script/Deploy.s.sol:Deploy --rpc-url mainnet --broadcast --verify --slow

verify-agung:
	forge script script/Verify.s.sol:Verify --rpc-url agung

verify-mainnet:
	forge script script/Verify.s.sol:Verify --rpc-url mainnet

slither:
	@command -v slither >/dev/null || (echo "Slither not installed. pip install slither-analyzer"; exit 1)
	slither . --filter-paths "lib/|test/|script/" --exclude-informational --exclude-low
