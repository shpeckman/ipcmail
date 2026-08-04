# Makefile
CRYSTAL       ?= crystal
CRYSTAL_WORKERS ?= 4
BIN           := bin
EXAMPLE_SRC   := $(wildcard examples/*.cr)
EXAMPLES      := $(patsubst examples/%.cr,%,$(EXAMPLE_SRC))
BENCH_SRC     := $(filter-out bench/bench_helper.cr,$(wildcard bench/*.cr))
BENCHES       := $(patsubst bench/%_bench.cr,%,$(BENCH_SRC))
EC_SPEC       := spec/bus_execution_context_spec.cr
EC_EXAMPLE    := execution_context
EC_BENCH      := execution_context

.PHONY: all check build spec spec-ec examples examples-ec bench bench-ec clean

all: check spec examples

check:
	@printf 'CHECKING\n--------\n\n'
	$(CRYSTAL) build --no-codegen src/ipcmail.cr
	@printf '\n'

build:
	@mkdir -p $(BIN)
	$(CRYSTAL) build src/ipcmail.cr -o $(BIN)/ipcmail

spec:
	@printf '\nRUNNING SPECS\n-------------\n\n'
	$(CRYSTAL) spec
	@printf '\n'

spec-ec:
	CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) spec $(EC_SPEC)

examples:
	@printf '\nRUNNING EXAMPLES\n----------------\n'
	@first=1; for ex in $(EXAMPLES); do \
		[ $$first -eq 1 ] && first=0 || printf '\n'; \
		if [ "$$ex" = "$(EC_EXAMPLE)" ]; then \
			printf 'CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) run examples/%s.cr\n' "$$ex"; \
			CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) run examples/$$ex.cr || exit $$?; \
		else \
			printf '$(CRYSTAL) run examples/%s.cr\n' "$$ex"; \
			$(CRYSTAL) run examples/$$ex.cr || exit $$?; \
		fi; \
	done

examples-ec:
	CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) run examples/$(EC_EXAMPLE).cr

run-$(EC_EXAMPLE): examples/$(EC_EXAMPLE).cr
	CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) run $<

run-%: examples/%.cr
	$(CRYSTAL) run $<

bench:
	@printf '\nRUNNING BENCHMARKS (--release)\n------------------------------\n'
	@first=1; for b in $(BENCHES); do \
		[ $$first -eq 1 ] && first=0 || printf '\n'; \
		if [ "$$b" = "$(EC_BENCH)" ]; then \
			printf 'CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) run --release bench/%s_bench.cr\n' "$$b"; \
			CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) run --release bench/$$b'_bench.cr' || exit $$?; \
		else \
			printf '$(CRYSTAL) run --release bench/%s_bench.cr\n' "$$b"; \
			$(CRYSTAL) run --release bench/$$b'_bench.cr' || exit $$?; \
		fi; \
	done

bench-ec:
	CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) run --release bench/$(EC_BENCH)_bench.cr

bench-$(EC_BENCH): bench/$(EC_BENCH)_bench.cr
	CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) run --release $<

bench-%: bench/%_bench.cr
	$(CRYSTAL) run --release $<

clean:
	rm -rf $(BIN)