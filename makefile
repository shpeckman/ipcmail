# makefile
CRYSTAL = crystal
FLAGS = --release --no-debug

BUILD = build
EXAMPLES = basic bus timeout multiplex buffer
EXAMPLE_BINS = $(addprefix $(BUILD)/,$(EXAMPLES))
CLI_BIN = $(BUILD)/ipcmail
TARGETS = $(EXAMPLE_BINS) $(CLI_BIN)

SOURCES = $(wildcard src/ipcmail/*.cr) src/ipcmail.cr

.PHONY: all run spec check clean

all: $(TARGETS)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%: examples/%.cr $(SOURCES) | $(BUILD)
	$(CRYSTAL) build $(FLAGS) -o $@ $<

$(CLI_BIN): bin/ipcmail.cr $(SOURCES) | $(BUILD)
	$(CRYSTAL) build $(FLAGS) -o $@ $<

spec:
	$(CRYSTAL) spec

check:
	$(CRYSTAL) tool format --check src spec examples bin

run: $(TARGETS)
	@for example in $(EXAMPLES); do \
		echo ""; \
		echo "========================================"; \
		echo "Executing: $$example"; \
		echo "========================================"; \
		$(BUILD)/$$example; \
	done
	@echo ""
	@echo "========================================"
	@echo "Note: ipcmail is an interactive tool and was compiled, but not run."
	@echo "To try it, run an example in one terminal and inspect it from another:"
	@echo "  $(BUILD)/basic & $(BUILD)/ipcmail shm:///ipcmail_demo"
	@echo "========================================"
	@echo ""
	@$(MAKE) clean

clean:
	rm -rf $(BUILD)
	rm -f *.sock