obj-$(CONFIG_EFI) 		+= efi.o efi_$(BITS).o efi_stub_$(BITS).o
obj-$(CONFIG_ACPI_BGRT) += efi-bgrt.o
obj-$(CONFIG_EARLY_PRINTK_EFI)	+= early_printk.o
ccflags-$(CONFIG_XEN)		+= -fshort-wchar
disabled-obj-$(CONFIG_XEN)	:= efi_%$(BITS).o
