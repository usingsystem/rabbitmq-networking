TARGET_DIR=~/emqtt
SBIN_DIR=$(TARGET_DIR)/sbin
MAN_DIR=$(TARGET_DIR)/man

RABBITMQ_NODENAME=emqtt
RABBITMQ_SERVER_START_ARGS ?=
RABBITMQ_MNESIA_DIR=$(TARGET_DIR)/var/data/emqtt-$(RABBITMQ_NODENAME)-mnesia
RABBITMQ_PLUGINS_EXPAND_DIR=$(TARGET_DIR)/tmp/emqtt-$(RABBITMQ_NODENAME)-plugins-scratch

SOURCE_DIR=src
EBIN_DIR=ebin
INCLUDE_DIR=include
INCLUDES=$(wildcard $(INCLUDE_DIR)/*.hrl)
SOURCES=$(wildcard $(SOURCE_DIR)/*.erl) $(USAGES_ERL)
BEAM_TARGETS=$(patsubst $(SOURCE_DIR)/%.erl, $(EBIN_DIR)/%.beam, $(SOURCES))
TARGETS=$(EBIN_DIR)/emqtt.app $(BEAM_TARGETS) plugins
WEB_URL=http://www.emqtt.com/
QC_MODULES := rabbit_backing_queue_qc
QC_TRIALS ?= 100

BASIC_PLT=basic.plt
RABBIT_PLT=rabbit.plt

ifndef USE_SPECS
# our type specs rely on features and bug fixes in dialyzer that are
# only available in R14B03 upwards (R14B03 is erts 5.8.4)
USE_SPECS:=$(shell erl -noshell -eval 'io:format([list_to_integer(X) || X <- string:tokens(erlang:system_info(version), ".")] >= [5,8,4]), halt().')
endif

ifndef USE_PROPER_QC
# PropEr needs to be installed for property checking
# http://proper.softlab.ntua.gr/
USE_PROPER_QC:=$(shell erl -noshell -eval 'io:format({module, proper} =:= code:ensure_loaded(proper)), halt().')
endif

#other args: +native +"{hipe,[o3,verbose]}" -Ddebug=true +debug_info +no_strict_record_tests
ERLC_OPTS=-I $(INCLUDE_DIR) -o $(EBIN_DIR) -Wall -v +debug_info $(call boolean_macro,$(USE_SPECS),use_specs) $(call boolean_macro,$(USE_PROPER_QC),use_proper_qc)

VERSION=0.0.0
PLUGINS_DIR=plugins
TARBALL_NAME=emqtt-server-$(VERSION)
TARGET_SRC_DIR=dist/$(TARBALL_NAME)

ERL_CALL=erl_call -sname $(RABBITMQ_NODENAME) -e

ERL_EBIN=erl -noinput -pa $(EBIN_DIR)

define boolean_macro
$(if $(filter true,$(1)),-D$(2))
endef

# Versions prior to this are not supported
NEED_MAKE := 3.80
ifneq "$(NEED_MAKE)" "$(firstword $(sort $(NEED_MAKE) $(MAKE_VERSION)))"
$(error Versions of make prior to $(NEED_MAKE) are not supported)
endif

# .DEFAULT_GOAL introduced in 3.81
DEFAULT_GOAL_MAKE := 3.81
ifneq "$(DEFAULT_GOAL_MAKE)" "$(firstword $(sort $(DEFAULT_GOAL_MAKE) $(MAKE_VERSION)))"
.DEFAULT_GOAL=all
endif

all: $(TARGETS)

.PHONY: plugins

$(EBIN_DIR)/emqtt.app: $(EBIN_DIR)/emqtt_app.in $(SOURCES) generate_app
	escript generate_app $< $@ $(SOURCE_DIR)

$(EBIN_DIR)/%.beam: $(SOURCE_DIR)/%.erl
	erlc $(ERLC_OPTS) -pa $(EBIN_DIR) $<

dialyze: $(BEAM_TARGETS) $(BASIC_PLT)
	dialyzer --plt $(BASIC_PLT) --no_native --fullpath \
	  -Wrace_conditions $(BEAM_TARGETS)

# rabbit.plt is used by emqtt-erlang-client's dialyze make target
create-plt: $(RABBIT_PLT)

$(RABBIT_PLT): $(BEAM_TARGETS) $(BASIC_PLT)
	dialyzer --plt $(BASIC_PLT) --output_plt $@ --no_native \
	  --add_to_plt $(BEAM_TARGETS)

$(BASIC_PLT): $(BEAM_TARGETS)
	if [ -f $@ ]; then \
	    touch $@; \
	else \
	    dialyzer --output_plt $@ --build_plt \
		--apps erts kernel stdlib compiler sasl os_mon mnesia tools \
		  public_key crypto ssl; \
	fi

clean:
	rm -f $(EBIN_DIR)/*.beam
	rm -f $(EBIN_DIR)/emqtt.app $(EBIN_DIR)/emqtt.boot $(EBIN_DIR)/emqtt.script $(EBIN_DIR)/emqtt.rel
	rm -f $(RABBIT_PLT)

cleandb:
	rm -rf $(RABBITMQ_MNESIA_DIR)/*

############ various tasks to interact with RabbitMQ ###################

BASIC_SCRIPT_ENVIRONMENT_SETTINGS=\
	RABBITMQ_NODE_IP_ADDRESS="$(RABBITMQ_NODE_IP_ADDRESS)" \
	RABBITMQ_NODE_PORT="$(RABBITMQ_NODE_PORT)" \
	RABBITMQ_LOG_BASE="$(RABBITMQ_LOG_BASE)" \
	RABBITMQ_MNESIA_DIR="$(RABBITMQ_MNESIA_DIR)" \
	RABBITMQ_PLUGINS_EXPAND_DIR="$(RABBITMQ_PLUGINS_EXPAND_DIR)"

run: all
	$(BASIC_SCRIPT_ENVIRONMENT_SETTINGS) \
		RABBITMQ_ALLOW_INPUT=true \
		RABBITMQ_SERVER_START_ARGS="$(RABBITMQ_SERVER_START_ARGS)" \
		./scripts/emqtt-server

run-node: all
	$(BASIC_SCRIPT_ENVIRONMENT_SETTINGS) \
		RABBITMQ_NODE_ONLY=true \
		RABBITMQ_ALLOW_INPUT=true \
		RABBITMQ_SERVER_START_ARGS="$(RABBITMQ_SERVER_START_ARGS)" \
		./scripts/emqtt-server

run-background-node: all
	$(BASIC_SCRIPT_ENVIRONMENT_SETTINGS) \
		RABBITMQ_NODE_ONLY=true \
		RABBITMQ_SERVER_START_ARGS="$(RABBITMQ_SERVER_START_ARGS)" \
		./scripts/emqtt-server

run-tests: all
	OUT=$$(echo "rabbit_tests:all_tests()." | $(ERL_CALL)) ; \
	  echo $$OUT ; echo $$OUT | grep '^{ok, passed}$$' > /dev/null

run-qc: all
	$(foreach MOD,$(QC_MODULES),./quickcheck $(RABBITMQ_NODENAME) $(MOD) $(QC_TRIALS))

start-background-node: all
	-rm -f $(RABBITMQ_MNESIA_DIR).pid
	mkdir -p $(RABBITMQ_MNESIA_DIR)
	setsid sh -c "$(MAKE) run-background-node > $(RABBITMQ_MNESIA_DIR)/startup_log 2> $(RABBITMQ_MNESIA_DIR)/startup_err" &
	sleep 1

start-rabbit-on-node: all
	echo "rabbit:start()." | $(ERL_CALL)
	./scripts/emqtt-ctl -n $(RABBITMQ_NODENAME) wait $(RABBITMQ_MNESIA_DIR).pid

stop-rabbit-on-node: all
	echo "rabbit:stop()." | $(ERL_CALL)

set-memory-alarm: all
	echo "alarm_handler:set_alarm({{vm_memory_high_watermark, node()}, []})." | \
	$(ERL_CALL)

clear-memory-alarm: all
	echo "alarm_handler:clear_alarm({vm_memory_high_watermark, node()})." | \
	$(ERL_CALL)

stop-node:
	-$(ERL_CALL) -q

# code coverage will be created for subdirectory "ebin" of COVER_DIR
COVER_DIR=.

start-cover: all
	echo "rabbit_misc:start_cover([\"rabbit\", \"hare\"])." | $(ERL_CALL)
	echo "rabbit_misc:enable_cover([\"$(COVER_DIR)\"])." | $(ERL_CALL)

start-secondary-cover: all
	echo "rabbit_misc:start_cover([\"hare\"])." | $(ERL_CALL)

stop-cover: all
	echo "rabbit_misc:report_cover(), cover:stop()." | $(ERL_CALL)
	cat cover/summary.txt

########################################################################

srcdist: distclean
	cp -r ebin src include README $(TARGET_SRC_DIR)
	sed -i.save 's/%%VSN%%/$(VERSION)/' $(TARGET_SRC_DIR)/ebin/rabbit_app.in && rm -f $(TARGET_SRC_DIR)/ebin/rabbit_app.in.save

	cp Makefile generate_app $(TARGET_SRC_DIR)

	cp -r scripts $(TARGET_SRC_DIR)
	chmod 0755 $(TARGET_SRC_DIR)/scripts/*

	(cd dist; tar -zchf $(TARBALL_NAME).tar.gz $(TARBALL_NAME))
	(cd dist; zip -q -r $(TARBALL_NAME).zip $(TARBALL_NAME))
	rm -rf $(TARGET_SRC_DIR)

distclean: clean
	rm -rf dist
	find . -regex '.*\(~\|#\|\.swp\|\.dump\)' -exec rm {} \;

install: install_bin

install_bin: all install_dirs
	cp -r ebin include $(TARGET_DIR)

	chmod 0755 scripts/*
	for script in emqtt-env emqtt-server emqtt-ctl; do \
		cp scripts/$$script $(TARGET_DIR)/sbin; \
		[ -e $(SBIN_DIR)/$$script ] || ln -s $(SCRIPTS_REL_PATH)/$$script $(SBIN_DIR)/$$script; \
	done

install_dirs:
	@ OK=true && \
	  { [ -n "$(TARGET_DIR)" ] || { echo "Please set TARGET_DIR."; OK=false; }; } && \
	  { [ -n "$(SBIN_DIR)" ] || { echo "Please set SBIN_DIR."; OK=false; }; } && \
	  { [ -n "$(MAN_DIR)" ] || { echo "Please set MAN_DIR."; OK=false; }; } && $$OK

	mkdir -p $(TARGET_DIR)/sbin
	mkdir -p $(SBIN_DIR)
	mkdir -p $(MAN_DIR)

# Note that all targets which depend on clean must have clean in their
# name.  Also any target that doesn't depend on clean should not have
# clean in its name, unless you know that you don't need any of the
# automatic dependency generation for that target (eg cleandb).

# We want to load the dep file if *any* target *doesn't* contain
# "clean" - i.e. if removing all clean-like targets leaves something

ifeq "$(MAKECMDGOALS)" ""
TESTABLEGOALS:=$(.DEFAULT_GOAL)
else
TESTABLEGOALS:=$(MAKECMDGOALS)
endif

.PHONY: run-qc
