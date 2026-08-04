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
	$(CRYSTAL) build --no-codegen src/ipcmail.cr

build:
	@mkdir -p $(BIN)
	$(CRYSTAL) build src/ipcmail.cr -o $(BIN)/ipcmail

spec:
	$(CRYSTAL) spec

spec-ec:
	CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) spec $(EC_SPEC)

examples: $(addprefix run-,$(EXAMPLES))

examples-ec:
	CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) run examples/$(EC_EXAMPLE).cr

run-$(EC_EXAMPLE): examples/$(EC_EXAMPLE).cr
	CRYSTAL_WORKERS=$(CRYSTAL_WORKERS) $(CRYSTAL) run $<

run-%: examples/%.cr
	$(CRYSTAL) run $<

clean:
	rm -rf $(BIN)