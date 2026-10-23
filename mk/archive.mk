# Compile every .c under SRC into an archive. Run as a sub-make so the file
# list is read *after* the generator that produced SRC has run.
#   $(MAKE) -f mk/archive.mk SRC=dir OUT=objdir LIB=lib.a CC=... AR=... CFLAGS=...
SRCS := $(shell find $(SRC) -name '*.c')
OBJS := $(patsubst $(SRC)/%.c,$(OUT)/%.o,$(SRCS))

$(LIB): $(OBJS)
	@rm -f $@
	@printf '%s\n' $(OBJS) > $@.rsp
	$(AR) rcs $@ @$@.rsp

$(OUT)/%.o: $(SRC)/%.c
	@mkdir -p $(@D)
	@$(CC) $(CFLAGS) -c $< -o $@
