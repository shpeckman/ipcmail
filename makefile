# Makefile
CRYSTAL       ?= crystal
CRYSTAL_WORKERS ?= 4
BIN           := bin
EXAMPLE_SRC   := $(wildcard examples/*.cr)
EXAMPLES      := $(patsubst examples/%.cr,%,$(EXAMPLE_SRC))
EC_SPEC       := spec/bus_execution_context_spec.cr
EC_EXAMPLE    := execution_context

.PHONY: all check build spec spec-ec examples examples-ec clean

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

clean:
	rm -rf $(BIN)