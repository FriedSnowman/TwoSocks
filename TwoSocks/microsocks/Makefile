# if you want to change/override some variables, do so in a file called
# config.mak, which is gets included automatically if it exists.

prefix = /usr/local
bindir = $(prefix)/bin
BUILD_DIR ?= ../../.build/microsocks

PROG_NAME = microsocks
PROG = $(BUILD_DIR)/$(PROG_NAME)
SRCS =  main.c sockssrv.c server.c sblist.c
OBJS = $(patsubst %.c,$(BUILD_DIR)/%.o,$(SRCS))

LIBS = -lpthread

CFLAGS += -Wall -std=c99

INSTALL = ./install.sh

-include config.mak

all: $(PROG)

install: $(PROG)
	$(INSTALL) -D -m 755 $(PROG) $(DESTDIR)$(bindir)/$(PROG_NAME)

clean:
	rm -rf $(BUILD_DIR)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.o: %.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(INC) $(PIC) -c -o $@ $<

$(PROG): $(OBJS)
	$(CC) $(LDFLAGS) $(OBJS) $(LIBS) -o $@

.PHONY: all clean install
