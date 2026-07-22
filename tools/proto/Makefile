O ?= $(shell pwd)
TARGET := pcie-util
LAT_TARGET := scope-mmio-lat-user
CC ?= gcc
CXX := g++
CFLAGS ?= -O2 -Wall -Wextra

objs-y += devmem.o
objs-y += sighandler.o
objs-y += uart.o
objs-y += main.o

objs-path-y = $(foreach obj,$(objs-y),$(O)/$(obj))

.PHONY: all clean

all: $(TARGET)

clean:
	rm -f $(objs-path-y) $(TARGET) $(LAT_TARGET)

$(O)/%.o: %.cc
	$(CXX) -c -o $@ $^

$(TARGET): $(objs-path-y)
	$(CXX) -o $@ $^

$(LAT_TARGET): scope_mmio_lat_user.c
	$(CC) $(CFLAGS) -o $@ $<
