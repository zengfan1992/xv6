-include local.mk

X64 ?= yes

ifeq ("$(X64)","yes")
BITS = 64
XOBJS = kobj/vm64.o
XFLAGS = -m64 -DX64 -mcmodel=kernel -mtls-direct-seg-refs -mno-red-zone
LDFLAGS = -m elf_x86_64 
QEMU ?= qemu-system-x86_64
else
XFLAGS = -m32
LDFLAGS = -m elf_i386 
QEMU ?= qemu-system-i386
endif

OPT ?= -O0

OBJS := \
	kobj/bio.o\
	kobj/console.o\
	kobj/exec.o\
	kobj/file.o\
	kobj/fs.o\
	kobj/ide.o\
	kobj/ioapic.o\
	kobj/kalloc.o\
	kobj/kbd.o\
	kobj/lapic.o\
	kobj/log.o\
	kobj/main.o\
	kobj/mp.o\
	kobj/acpi.o\
	kobj/picirq.o\
	kobj/pipe.o\
	kobj/proc.o\
	kobj/spinlock.o\
	kobj/string.o\
	kobj/swtch$(BITS).o\
	kobj/syscall.o\
	kobj/sysfile.o\
	kobj/sysproc.o\
	kobj/timer.o\
	kobj/trapasm$(BITS).o\
	kobj/trap.o\
	kobj/uart.o\
	kobj/vectors.o\
	kobj/vm.o\
	$(XOBJS)

ifneq ("$(MEMFS)","")
# build filesystem image in to kernel and use memory-ide-device
# instead of mounting the filesystem on ide1
OBJS := $(filter-out kobj/ide.o,$(OBJS)) kobj/memide.o
FSIMAGE := fs.img
endif

# Cross-compiling (e.g., on Mac OS X)
#TOOLPREFIX = i386-jos-elf-

# Using native tools (e.g., on X86 Linux)
#TOOLPREFIX =

CC = $(TOOLPREFIX)gcc
AS = $(TOOLPREFIX)gas
LD = $(TOOLPREFIX)ld
OBJCOPY = $(TOOLPREFIX)objcopy
OBJDUMP = $(TOOLPREFIX)objdump
CFLAGS = -fno-pic -static -fno-builtin -fno-strict-aliasing -Wall -MD -ggdb -fno-omit-frame-pointer
CFLAGS += -ffreestanding -fno-common -nostdlib -Iinclude -gdwarf-2 $(XFLAGS) $(OPT)
CFLAGS += $(shell $(CC) -fno-stack-protector -E -x c /dev/null >/dev/null 2>&1 && echo -fno-stack-protector)
ASFLAGS = -fno-pic -gdwarf-2 -Wa,-divide -Iinclude $(XFLAGS)

xv6.img: out/bootblock out/kernel.elf fs.img
	dd if=/dev/zero of=xv6.img count=10000
	dd if=out/bootblock of=xv6.img conv=notrunc
	dd if=out/kernel.elf of=xv6.img seek=1 conv=notrunc

xv6memfs.img: out/bootblock out/kernelmemfs.elf
	dd if=/dev/zero of=xv6memfs.img count=10000
	dd if=out/bootblock of=xv6memfs.img conv=notrunc
	dd if=out/kernelmemfs.elf of=xv6memfs.img seek=1 conv=notrunc

# kernel object files
kobj/%.o: kernel/%.c
	@mkdir -p kobj
	$(CC) $(CFLAGS) -c -o $@ $<

kobj/%.o: kernel/%.S
	@mkdir -p kobj
	$(CC) $(ASFLAGS) -c -o $@ $<

# userspace object files
uobj/%.o: user/%.c
	@mkdir -p uobj
	$(CC) $(CFLAGS) -c -o $@ $<

uobj/%.o: ulib/%.c
	@mkdir -p uobj
	$(CC) $(CFLAGS) -c -o $@ $<

uobj/%.o: ulib/%.S
	@mkdir -p uobj
	$(CC) $(ASFLAGS) -c -o $@ $<

out/bootblock: kernel/bootasm.S kernel/bootmain.c
	@mkdir -p out
	$(CC) -fno-builtin -fno-pic -m32 -nostdinc -Iinclude -O -o out/bootmain.o -c kernel/bootmain.c
	$(CC) -fno-builtin -fno-pic -m32 -nostdinc -Iinclude -o out/bootasm.o -c kernel/bootasm.S
	$(LD) -m elf_i386  -N -e start -Ttext 0x7C00 -o out/bootblock.o out/bootasm.o out/bootmain.o
	$(OBJDUMP) -S out/bootblock.o > out/bootblock.asm
	$(OBJCOPY) -S -O binary -j .text out/bootblock.o out/bootblock
	tools/sign.pl out/bootblock

out/entryother: kernel/entryother.S
	@mkdir -p out
	$(CC) $(CFLAGS) -fno-pic -nostdinc -I. -o out/entryother.o -c kernel/entryother.S
	$(LD) $(LDFLAGS) -N -e start -Ttext 0x7000 -o out/bootblockother.o out/entryother.o
	$(OBJCOPY) -S -O binary -j .text out/bootblockother.o out/entryother
	$(OBJDUMP) -S out/bootblockother.o > out/entryother.asm

INITCODESRC = kernel/initcode$(BITS).S
out/initcode: $(INITCODESRC)
	@mkdir -p out
	$(CC) $(CFLAGS) -nostdinc -I. -o out/initcode.o -c $(INITCODESRC)
	$(LD) $(LDFLAGS) -N -e start -Ttext 0 -o out/initcode.out out/initcode.o
	$(OBJCOPY) -S -O binary out/initcode.out out/initcode
	$(OBJDUMP) -S out/initcode.o > out/initcode.asm

ENTRYCODE = kobj/entry$(BITS).o
LINKSCRIPT = kernel/kernel$(BITS).ld
out/kernel.elf: $(OBJS) $(ENTRYCODE) out/entryother out/initcode $(LINKSCRIPT) $(FSIMAGE)
	$(LD) $(LDFLAGS) -T $(LINKSCRIPT) -o out/kernel.elf $(ENTRYCODE) $(OBJS) -b binary out/initcode out/entryother $(FSIMAGE)
	$(OBJDUMP) -S out/kernel.elf > out/kernel.asm
	$(OBJDUMP) -t out/kernel.elf | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > out/kernel.sym

MKVECTORS = tools/vectors$(BITS).pl
kernel/vectors.S: $(MKVECTORS)
	perl $(MKVECTORS) > kernel/vectors.S

ULIB = uobj/ulib.o uobj/usys.o uobj/printf.o uobj/umalloc.o

fs/%: uobj/%.o $(ULIB)
	@mkdir -p fs out
	$(LD) $(LDFLAGS) -N -e main -Ttext 0 -o $@ $^
	$(OBJDUMP) -S $@ > out/$*.asm
	$(OBJDUMP) -t $@ | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > out/$*.sym

fs/forktest: uobj/forktest.o $(ULIB)
	@mkdir -p fs
	# forktest has less library code linked in - needs to be small
	# in order to be able to max out the proc table.
	$(LD) $(LDFLAGS) -N -e main -Ttext 0 -o fs/forktest uobj/forktest.o uobj/ulib.o uobj/usys.o
	$(OBJDUMP) -S fs/forktest > out/forktest.asm

out/mkfs: tools/mkfs.c include/fs.h
	gcc -Werror -Wall -o out/mkfs tools/mkfs.c

# Prevent deletion of intermediate files, e.g. cat.o, after first build, so
# that disk image changes after first build are persistent until clean.  More
# details:
# http://www.gnu.org/software/make/manual/html_node/Chained-Rules.html
.PRECIOUS: uobj/%.o

UPROGS=\
	fs/cat\
	fs/echo\
	fs/forktest\
	fs/grep\
	fs/init\
	fs/kill\
	fs/ln\
	fs/ls\
	fs/mkdir\
	fs/rm\
	fs/sh\
	fs/stressfs\
	fs/usertests\
	fs/wc\
	fs/zombie\

fs/README: README
	@mkdir -p fs
	cp README fs/README

fs.img: out/mkfs README $(UPROGS)
	out/mkfs fs.img README $(UPROGS)

-include */*.d

clean: 
	rm -rf out fs uobj kobj
	rm -f kernel/vectors.S xv6.img xv6memfs.img fs.img .gdbinit

# run in emulators

bochs : fs.img xv6.img
	if [ ! -e .bochsrc ]; then ln -s tools/dot-bochsrc .bochsrc; fi
	bochs -q

# try to generate a unique GDB port
GDBPORT = $(shell expr `id -u` % 5000 + 25000)
# QEMU's gdb stub command line changed in 0.11
QEMUGDB = $(shell if $(QEMU) -help | grep -q '^-gdb'; \
	then echo "-gdb tcp::$(GDBPORT)"; \
	else echo "-s -p $(GDBPORT)"; fi)
ifndef CPUS
CPUS := 2
endif
QEMUOPTS = -net none -hda xv6.img -hdb fs.img -smp $(CPUS) -m 512 $(QEMUEXTRA)

qemu: fs.img xv6.img
	$(QEMU) -serial mon:stdio $(QEMUOPTS)

qemu-memfs: xv6memfs.img
	$(QEMU) xv6memfs.img -smp $(CPUS)

qemu-nox: fs.img xv6.img
	$(QEMU) -nographic $(QEMUOPTS)

.gdbinit: tools/gdbinit.tmpl
	sed "s/localhost:1234/localhost:$(GDBPORT)/" < $^ > $@

qemu-gdb: fs.img xv6.img .gdbinit
	@echo "*** Now run 'gdb'." 1>&2
	$(QEMU) -serial mon:stdio $(QEMUOPTS) -S -s

qemu-nox-gdb: fs.img xv6.img .gdbinit
	@echo "*** Now run 'gdb'." 1>&2
	$(QEMU) -nographic $(QEMUOPTS) -S -s

