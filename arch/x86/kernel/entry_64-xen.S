/*
 *  linux/arch/x86_64/entry.S
 *
 *  Copyright (C) 1991, 1992  Linus Torvalds
 *  Copyright (C) 2000, 2001, 2002  Andi Kleen SuSE Labs
 *  Copyright (C) 2000  Pavel Machek <pavel@suse.cz>
 *  Jun Nakajima <jun.nakajima@intel.com>
 *  Asit Mallick <asit.k.mallick@intel.com>
 *      Modified for Xen
 */

/*
 * entry.S contains the system-call and fault low-level handling routines.
 *
 * Some of this is documented in Documentation/x86/entry_64.txt
 *
 * NOTE: This code handles signal-recognition, which happens every time
 * after an interrupt and after each system call.
 *
 * Normal syscalls and interrupts don't save a full stack frame, this is
 * only done for syscall tracing, signals or fork/exec et.al.
 *
 * A note on terminology:
 * - top of stack: Architecture defined interrupt frame from SS to RIP
 * at the top of the kernel process stack.
 * - partial stack frame: partially saved registers up to R11.
 * - full stack frame: Like partial stack frame, but all register saved.
 *
 * Some macro usage:
 * - CFI macros are used to generate dwarf2 unwind information for better
 * backtraces. They don't change any code.
 * - SAVE_ALL/RESTORE_ALL - Save/restore all registers
 * - SAVE_ARGS/RESTORE_ARGS - Save/restore registers that C functions modify.
 * There are unfortunately lots of special cases where some registers
 * not touched. The macro is a big mess that should be cleaned up.
 * - SAVE_REST/RESTORE_REST - Handle the registers not saved by SAVE_ARGS.
 * Gives a full stack frame.
 * - ENTRY/END Define functions in the symbol table.
 * - FIXUP_TOP_OF_STACK/RESTORE_TOP_OF_STACK - Fix up the hardware stack
 * frame that is otherwise undefined after a SYSCALL
 * - TRACE_IRQ_* - Trace hard interrupt state for lock debugging.
 * - errorentry/paranoidentry/zeroentry - Define exception entry points.
 */

#include <linux/linkage.h>
#include <asm/segment.h>
#include <asm/cache.h>
#include <asm/errno.h>
#include <asm/dwarf2.h>
#include <asm/calling.h>
#include <asm/asm-offsets.h>
#include <asm/msr.h>
#include <asm/unistd.h>
#include <asm/thread_info.h>
#include <asm/hw_irq.h>
#include <asm/page_types.h>
#include <asm/irqflags.h>
#include <asm/processor-flags.h>
#include <asm/ftrace.h>
#include <asm/percpu.h>
#include <asm/asm.h>
#include <asm/context_tracking.h>
#include <asm/smap.h>
#include <asm/pgtable_types.h>
#include <linux/err.h>
#include <xen/interface/xen.h>
#include <xen/interface/features.h>

/* Avoid __ASSEMBLER__'ifying <linux/audit.h> just for this.  */
#include <linux/elf-em.h>
#define AUDIT_ARCH_X86_64	(EM_X86_64|__AUDIT_ARCH_64BIT|__AUDIT_ARCH_LE)
#define __AUDIT_ARCH_64BIT 0x80000000
#define __AUDIT_ARCH_LE	   0x40000000

	.code64
	.section .entry.text, "ax"

#ifdef CONFIG_FUNCTION_TRACER

#ifdef CC_USING_FENTRY
# define function_hook	__fentry__
#else
# define function_hook	mcount
#endif

#ifdef CONFIG_DYNAMIC_FTRACE

ENTRY(function_hook)
	retq
END(function_hook)

/* skip is set if stack has been adjusted */
.macro ftrace_caller_setup skip=0
	MCOUNT_SAVE_FRAME \skip

	/* Load the ftrace_ops into the 3rd parameter */
	movq function_trace_op(%rip), %rdx

	/* Load ip into the first parameter */
	movq RIP(%rsp), %rdi
	subq $MCOUNT_INSN_SIZE, %rdi
	/* Load the parent_ip into the second parameter */
#ifdef CC_USING_FENTRY
	movq SS+16(%rsp), %rsi
#else
	movq 8(%rbp), %rsi
#endif
.endm

ENTRY(ftrace_caller)
	/* Check if tracing was disabled (quick check) */
	cmpl $0, function_trace_stop
	jne  ftrace_stub

	ftrace_caller_setup
	/* regs go into 4th parameter (but make it NULL) */
	movq $0, %rcx

GLOBAL(ftrace_call)
	call ftrace_stub

	MCOUNT_RESTORE_FRAME
ftrace_return:

#ifdef CONFIG_FUNCTION_GRAPH_TRACER
GLOBAL(ftrace_graph_call)
	jmp ftrace_stub
#endif

GLOBAL(ftrace_stub)
	retq
END(ftrace_caller)

ENTRY(ftrace_regs_caller)
	/* Save the current flags before compare (in SS location)*/
	pushfq

	/* Check if tracing was disabled (quick check) */
	cmpl $0, function_trace_stop
	jne  ftrace_restore_flags

	/* skip=8 to skip flags saved in SS */
	ftrace_caller_setup 8

	/* Save the rest of pt_regs */
	movq %r15, R15(%rsp)
	movq %r14, R14(%rsp)
	movq %r13, R13(%rsp)
	movq %r12, R12(%rsp)
	movq %r11, R11(%rsp)
	movq %r10, R10(%rsp)
	movq %rbp, RBP(%rsp)
	movq %rbx, RBX(%rsp)
	/* Copy saved flags */
	movq SS(%rsp), %rcx
	movq %rcx, EFLAGS(%rsp)
	/* Kernel segments */
	movq $__KERNEL_DS, %rcx
	movq %rcx, SS(%rsp)
	movq $__KERNEL_CS, %rcx
	movq %rcx, CS(%rsp)
	/* Stack - skipping return address */
	leaq SS+16(%rsp), %rcx
	movq %rcx, RSP(%rsp)

	/* regs go into 4th parameter */
	leaq (%rsp), %rcx

GLOBAL(ftrace_regs_call)
	call ftrace_stub

	/* Copy flags back to SS, to restore them */
	movq EFLAGS(%rsp), %rax
	movq %rax, SS(%rsp)

	/* Handlers can change the RIP */
	movq RIP(%rsp), %rax
	movq %rax, SS+8(%rsp)

	/* restore the rest of pt_regs */
	movq R15(%rsp), %r15
	movq R14(%rsp), %r14
	movq R13(%rsp), %r13
	movq R12(%rsp), %r12
	movq R10(%rsp), %r10
	movq RBP(%rsp), %rbp
	movq RBX(%rsp), %rbx

	/* skip=8 to skip flags saved in SS */
	MCOUNT_RESTORE_FRAME 8

	/* Restore flags */
	popfq

	jmp ftrace_return
ftrace_restore_flags:
	popfq
	jmp  ftrace_stub

END(ftrace_regs_caller)


#else /* ! CONFIG_DYNAMIC_FTRACE */

ENTRY(function_hook)
	cmpl $0, function_trace_stop
	jne  ftrace_stub

	cmpq $ftrace_stub, ftrace_trace_function
	jnz trace

#ifdef CONFIG_FUNCTION_GRAPH_TRACER
	cmpq $ftrace_stub, ftrace_graph_return
	jnz ftrace_graph_caller

	cmpq $ftrace_graph_entry_stub, ftrace_graph_entry
	jnz ftrace_graph_caller
#endif

GLOBAL(ftrace_stub)
	retq

trace:
	MCOUNT_SAVE_FRAME

	movq RIP(%rsp), %rdi
#ifdef CC_USING_FENTRY
	movq SS+16(%rsp), %rsi
#else
	movq 8(%rbp), %rsi
#endif
	subq $MCOUNT_INSN_SIZE, %rdi

	call   *ftrace_trace_function

	MCOUNT_RESTORE_FRAME

	jmp ftrace_stub
END(function_hook)
#endif /* CONFIG_DYNAMIC_FTRACE */
#endif /* CONFIG_FUNCTION_TRACER */

#ifdef CONFIG_FUNCTION_GRAPH_TRACER
ENTRY(ftrace_graph_caller)
	MCOUNT_SAVE_FRAME

#ifdef CC_USING_FENTRY
	leaq SS+16(%rsp), %rdi
	movq $0, %rdx	/* No framepointers needed */
#else
	leaq 8(%rbp), %rdi
	movq (%rbp), %rdx
#endif
	movq RIP(%rsp), %rsi
	subq $MCOUNT_INSN_SIZE, %rsi

	call	prepare_ftrace_return

	MCOUNT_RESTORE_FRAME

	retq
END(ftrace_graph_caller)

GLOBAL(return_to_handler)
	subq  $24, %rsp

	/* Save the return values */
	movq %rax, (%rsp)
	movq %rdx, 8(%rsp)
	movq %rbp, %rdi

	call ftrace_return_to_handler

	movq %rax, %rdi
	movq 8(%rsp), %rdx
	movq (%rsp), %rax
	addq $24, %rsp
	jmp *%rdi
#endif


#ifndef CONFIG_PREEMPT
#define retint_kernel retint_restore_args
#endif


.macro TRACE_IRQS_IRETQ offset=ARGOFFSET
#ifdef CONFIG_TRACE_IRQFLAGS
	bt   $9,EFLAGS-\offset(%rsp)	/* interrupts off? */
	jnc  1f
	TRACE_IRQS_ON
1:
#endif
.endm

/*
 * When dynamic function tracer is enabled it will add a breakpoint
 * to all locations that it is about to modify, sync CPUs, update
 * all the code, sync CPUs, then remove the breakpoints. In this time
 * if lockdep is enabled, it might jump back into the debug handler
 * outside the updating of the IST protection. (TRACE_IRQS_ON/OFF).
 *
 * We need to change the IDT table before calling TRACE_IRQS_ON/OFF to
 * make sure the stack pointer does not get reset back to the top
 * of the debug stack, and instead just reuses the current stack.
 */
#if defined(CONFIG_DYNAMIC_FTRACE) && defined(CONFIG_TRACE_IRQFLAGS)

.macro TRACE_IRQS_OFF_DEBUG
	call debug_stack_set_zero
	TRACE_IRQS_OFF
	call debug_stack_reset
.endm

.macro TRACE_IRQS_ON_DEBUG
	call debug_stack_set_zero
	TRACE_IRQS_ON
	call debug_stack_reset
.endm

.macro TRACE_IRQS_IRETQ_DEBUG offset=ARGOFFSET
	bt   $9,EFLAGS-\offset(%rsp)	/* interrupts off? */
	jnc  1f
	TRACE_IRQS_ON_DEBUG
1:
.endm

#else
# define TRACE_IRQS_OFF_DEBUG		TRACE_IRQS_OFF
# define TRACE_IRQS_ON_DEBUG		TRACE_IRQS_ON
# define TRACE_IRQS_IRETQ_DEBUG		TRACE_IRQS_IRETQ
#endif

NMI_MASK = 0x80000000
	
/*
 * C code is not supposed to know about undefined top of stack. Every time
 * a C function with an pt_regs argument is called from the SYSCALL based
 * fast path FIXUP_TOP_OF_STACK is needed.
 * RESTORE_TOP_OF_STACK syncs the syscall state after any possible ptregs
 * manipulation.
 */

	/* %rsp:at FRAMEEND */
	.macro FIXUP_TOP_OF_STACK tmp offset=0
	movq $__USER_CS,CS+\offset(%rsp)
	movq $-1,RCX+\offset(%rsp)
	.endm

	.macro RESTORE_TOP_OF_STACK tmp offset=0
	.endm

	.macro FAKE_STACK_FRAME child_rip
	/* push in order ss, rsp, eflags, cs, rip */
	xorl %eax, %eax
	pushq_cfi $__KERNEL_DS /* ss */
	/*CFI_REL_OFFSET	ss,0*/
	pushq_cfi %rax /* rsp */
	CFI_REL_OFFSET	rsp,0
	pushq_cfi $(X86_EFLAGS_IF|X86_EFLAGS_FIXED) /* eflags - interrupts on */
	/*CFI_REL_OFFSET	rflags,0*/
	pushq_cfi $__KERNEL_CS /* cs */
	/*CFI_REL_OFFSET	cs,0*/
	pushq_cfi \child_rip /* rip */
	CFI_REL_OFFSET	rip,0
	pushq_cfi %rax /* orig rax */
	.endm

	.macro UNFAKE_STACK_FRAME
	addq $8*6, %rsp
	CFI_ADJUST_CFA_OFFSET	-(6*8)
	.endm

/*
 * initial frame state for syscall
 */
	.macro BASIC_FRAME start=1 offset=0
	.if \start
	CFI_STARTPROC simple
	CFI_SIGNAL_FRAME
	CFI_DEF_CFA rsp, SS+8+\offset-RIP
	.else
	CFI_DEF_CFA_OFFSET SS+8+\offset-RIP
	.endif
	/*CFI_REL_OFFSET ss, SS+\offset-RIP*/
	CFI_REL_OFFSET rsp, RSP+\offset-RIP
	/*CFI_REL_OFFSET rflags, EFLAGS+\offset-RIP*/
	/*CFI_REL_OFFSET cs, CS+\offset-RIP*/
	CFI_REL_OFFSET rip, RIP+\offset-RIP
	.endm

/*
 * initial frame state for interrupts (and exceptions without error code)
 */
	.macro INTR_FRAME start=1 offset=0
	.if \start == 1
	BASIC_FRAME 1, \offset+2*8
	CFI_REL_OFFSET rcx, 0+\offset
	CFI_REL_OFFSET r11, 8+\offset
	.else
	BASIC_FRAME \start, \offset
	.endif
	.endm

/*
 * initial frame state for exceptions with error code (and interrupts
 * with vector already pushed)
 */
	.macro XCPT_FRAME start=1 offset=0
	INTR_FRAME \start, RIP+\offset-ORIG_RAX
	.endm

/*
 * frame that enables calling into C.
 */
	.macro PARTIAL_FRAME start=1 offset=0
	.if \start >= 0
	XCPT_FRAME 2*\start, ORIG_RAX+\offset-ARGOFFSET
	.endif
	CFI_REL_OFFSET rdi, RDI+\offset-ARGOFFSET
	CFI_REL_OFFSET rsi, RSI+\offset-ARGOFFSET
	CFI_REL_OFFSET rdx, RDX+\offset-ARGOFFSET
	CFI_REL_OFFSET rcx, RCX+\offset-ARGOFFSET
	CFI_REL_OFFSET rax, RAX+\offset-ARGOFFSET
	CFI_REL_OFFSET r8, R8+\offset-ARGOFFSET
	CFI_REL_OFFSET r9, R9+\offset-ARGOFFSET
	CFI_REL_OFFSET r10, R10+\offset-ARGOFFSET
	CFI_REL_OFFSET r11, R11+\offset-ARGOFFSET
	.endm

/*
 * frame that enables passing a complete pt_regs to a C function.
 */
	.macro DEFAULT_FRAME start=1 offset=0
	.if \start >= -1
	PARTIAL_FRAME \start, R11+\offset-R15
	.endif
	CFI_REL_OFFSET rbx, RBX+\offset
	CFI_REL_OFFSET rbp, RBP+\offset
	CFI_REL_OFFSET r12, R12+\offset
	CFI_REL_OFFSET r13, R13+\offset
	CFI_REL_OFFSET r14, R14+\offset
	CFI_REL_OFFSET r15, R15+\offset
	.endm

        /*
         * Must be consistent with the definition in arch-x86/xen-x86_64.h:
         *     struct iret_context {
         *        u64 rax, r11, rcx, flags, rip, cs, rflags, rsp, ss;
         *     };
         * with rax, r11, and rcx being taken care of in the hypercall stub.
         */
	.macro HYPERVISOR_IRET flag
	.if \flag == 0	# return from syscall always uses the hypercall
	testb $3,1*8(%rsp)
	jnz   2f
	testl $NMI_MASK,2*8(%rsp)
	jnz   2f

	cmpb  $0,(xen_features+XENFEAT_supervisor_mode_kernel)(%rip)
	jne   1f

	/* Direct iret to kernel space. Correct CS and SS. */
	orl   $3,1*8(%rsp)
	orl   $3,4*8(%rsp)
1:	iretq
	.endif

2:	/* Slow iret via hypervisor. */
	andl  $~NMI_MASK, 2*8(%rsp)
	pushq $\flag & VGCF_in_syscall
	jmp  hypercall_page + (__HYPERVISOR_iret * 32)
	.endm

#ifndef CONFIG_XEN
/* save partial stack frame */
	.macro SAVE_ARGS_IRQ
	cld
	/* start from rbp in pt_regs and jump over */
	movq_cfi rdi, (RDI-RBP)
	movq_cfi rsi, (RSI-RBP)
	movq_cfi rdx, (RDX-RBP)
	movq_cfi rcx, (RCX-RBP)
	movq_cfi rax, (RAX-RBP)
	movq_cfi  r8,  (R8-RBP)
	movq_cfi  r9,  (R9-RBP)
	movq_cfi r10, (R10-RBP)
	movq_cfi r11, (R11-RBP)

	/* Save rbp so that we can unwind from get_irq_regs() */
	movq_cfi rbp, 0

	/* Save previous stack value */
	movq %rsp, %rsi

	leaq -RBP(%rsp),%rdi	/* arg1 for handler */
	testl $3, CS-RBP(%rsi)
	je 1f
	SWAPGS
	/*
	 * irq_count is used to check if a CPU is already on an interrupt stack
	 * or not. While this is essentially redundant with preempt_count it is
	 * a little cheaper to use a separate counter in the PDA (short of
	 * moving irq_enter into assembly, which would be too much work)
	 */
1:	incl PER_CPU_VAR(irq_count)
	cmovzq PER_CPU_VAR(irq_stack_ptr),%rsp
	CFI_DEF_CFA_REGISTER	rsi

	/* Store previous stack value */
	pushq %rsi
	CFI_ESCAPE	0x0f /* DW_CFA_def_cfa_expression */, 6, \
			0x77 /* DW_OP_breg7 */, 0, \
			0x06 /* DW_OP_deref */, \
			0x08 /* DW_OP_const1u */, SS+8-RBP, \
			0x22 /* DW_OP_plus */
	/* We entered an interrupt context - irqs are off: */
	TRACE_IRQS_OFF
	.endm

/* save complete stack frame */
	.pushsection .kprobes.text, "ax"
ENTRY(save_paranoid)
	XCPT_FRAME offset=(ORIG_RAX-R15+8)
	cld
	movq %rdi, RDI+8(%rsp)
	movq %rsi, RSI+8(%rsp)
	movq_cfi rdx, RDX+8
	movq_cfi rcx, RCX+8
	movq_cfi rax, RAX+8
	movq %r8, R8+8(%rsp)
	movq %r9, R9+8(%rsp)
	movq %r10, R10+8(%rsp)
	movq %r11, R11+8(%rsp)
	movq_cfi rbx, RBX+8
	movq %rbp, RBP+8(%rsp)
	movq %r12, R12+8(%rsp)
	movq %r13, R13+8(%rsp)
	movq %r14, R14+8(%rsp)
	movq %r15, R15+8(%rsp)
	movl $1,%ebx
	movl $MSR_GS_BASE,%ecx
	rdmsr
	testl %edx,%edx
	js 1f	/* negative -> in kernel */
	SWAPGS
	xorl %ebx,%ebx
1:	ret
	CFI_ENDPROC
END(save_paranoid)
	.popsection
#endif

/*
 * A newly forked process directly context switches into this address.
 *
 * rdi: prev task we switched from
 */
ENTRY(ret_from_fork)
	DEFAULT_FRAME

	LOCK ; btr $TIF_FORK,TI_flags(%r8)

	pushq_cfi $0x0002
	popfq_cfi				# reset kernel eflags

	call schedule_tail			# rdi: 'prev' task parameter

	GET_THREAD_INFO(%rcx)

	RESTORE_REST

	testl $3, CS-ARGOFFSET(%rsp)		# from kernel_thread?
	jz   1f

	/*
	 * By the time we get here, we have no idea whether our pt_regs,
	 * ti flags, and ti status came from the 64-bit SYSCALL fast path,
	 * the slow path, or one of the ia32entry paths.
	 * Use int_ret_from_sys_call to return, since it can safely handle
	 * all of the above.
	 */
	jmp  int_ret_from_sys_call

1:
	/* Need to set the proper %ss (not NULL) for ring 3 iretq */
	movl $__KERNEL_DS, SS-ARGOFFSET(%rsp)
	subq $REST_SKIP, %rsp	# leave space for volatiles
	CFI_ADJUST_CFA_OFFSET	REST_SKIP
	movq %rbp, %rdi
	call *%rbx
	movl $0, RAX(%rsp)
	RESTORE_REST
	jmp int_ret_from_sys_call
	CFI_ENDPROC
END(ret_from_fork)

/*
 * System call entry. Up to 6 arguments in registers are supported.
 *
 * SYSCALL does not save anything on the stack and does not change the
 * stack pointer.  However, it does mask the flags register for us, so
 * CLD and CLAC are not needed.
 */

/*
 * Register setup:
 * rax  system call number
 * rdi  arg0
 * rcx  return address for syscall/sysret, C arg3
 * rsi  arg1
 * rdx  arg2
 * r10  arg3 	(--> moved to rcx for C)
 * r8   arg4
 * r9   arg5
 * r11  eflags for syscall/sysret, temporary for C
 * r12-r15,rbp,rbx saved by C code, not touched.
 *
 * Interrupts are enabled on entry.
 * Only called from user space.
 *
 * XXX	if we had a free scratch register we could save the RSP into the stack frame
 *      and report it properly in ps. Unfortunately we haven't.
 *
 * When user can change the frames always force IRET. That is because
 * it deals with uncanonical addresses better. SYSRET has trouble
 * with them due to bugs in both AMD and Intel CPUs.
 */

ENTRY(system_call)
	INTR_FRAME start=2 offset=2*8
	SAVE_ARGS -8,0
	movq  %rax,ORIG_RAX-ARGOFFSET(%rsp)
	testl $_TIF_WORK_SYSCALL_ENTRY,TI_flags+THREAD_INFO(%rsp,RIP-ARGOFFSET)
	jnz tracesys
system_call_fastpath:
#if __SYSCALL_MASK == ~0
	cmpq $__NR_syscall_max,%rax
#else
	andl $__SYSCALL_MASK,%eax
	cmpl $__NR_syscall_max,%eax
#endif
	ja badsys
	movq %r10,%rcx
	call *sys_call_table(,%rax,8)  # XXX:	 rip relative
	movq %rax,RAX-ARGOFFSET(%rsp)
/*
 * Syscall return path ending with SYSRET (fast path)
 * Has incomplete stack frame and undefined top of stack.
 */
ret_from_sys_call:
	movl $_TIF_ALLWORK_MASK,%edi
	/* edi:	flagmask */
sysret_check:
	LOCKDEP_SYS_EXIT
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF
	movl TI_flags+THREAD_INFO(%rsp,RIP-ARGOFFSET),%edx
	andl %edi,%edx
	jnz  sysret_careful
	CFI_REMEMBER_STATE
	/*
	 * sysretq will re-enable interrupts:
	 */
	TRACE_IRQS_ON
	RESTORE_ARGS 1,8,0,0
	xor %ecx,%ecx
	xor %r11,%r11
        HYPERVISOR_IRET VGCF_IN_SYSCALL

	CFI_RESTORE_STATE
	/* Handle reschedules */
	/* edx:	work, edi: workmask */
sysret_careful:
#if IS_ENABLED(CONFIG_KGRAFT)
	LOCK_PREFIX ; andl $~_TIF_KGR_IN_PROGRESS,TI_flags+THREAD_INFO(%rsp,RIP-ARGOFFSET)
#endif
	bt $TIF_NEED_RESCHED,%edx
	jnc sysret_signal
	TRACE_IRQS_ON
	ENABLE_INTERRUPTS(CLBR_NONE)
	pushq_cfi %rdi
	SCHEDULE_USER
	popq_cfi %rdi
	jmp sysret_check

	/* Handle a signal */
sysret_signal:
	TRACE_IRQS_ON
	ENABLE_INTERRUPTS(CLBR_NONE)
#ifdef CONFIG_AUDITSYSCALL
	bt $TIF_SYSCALL_AUDIT,%edx
	jc sysret_audit
#endif
	/*
	 * We have a signal, or exit tracing or single-step.
	 * These all wind up with the iret return path anyway,
	 * so just join that path right now.
	 */
	FIXUP_TOP_OF_STACK %r11, -ARGOFFSET
	jmp int_check_syscall_exit_work

badsys:
	movq $-ENOSYS,RAX-ARGOFFSET(%rsp)
	jmp ret_from_sys_call

#ifdef CONFIG_AUDITSYSCALL
	/*
	 * Fast path for syscall audit without full syscall trace.
	 * We just call __audit_syscall_entry() directly, and then
	 * jump back to the normal fast path.
	 */
auditsys:
	movq %r10,%r9			/* 6th arg: 4th syscall arg */
	movq %rdx,%r8			/* 5th arg: 3rd syscall arg */
	movq %rsi,%rcx			/* 4th arg: 2nd syscall arg */
	movq %rdi,%rdx			/* 3rd arg: 1st syscall arg */
	movq %rax,%rsi			/* 2nd arg: syscall number */
	movl $AUDIT_ARCH_X86_64,%edi	/* 1st arg: audit arch */
	call __audit_syscall_entry
	LOAD_ARGS 0		/* reload call-clobbered registers */
	jmp system_call_fastpath

	/*
	 * Return fast path for syscall audit.  Call __audit_syscall_exit()
	 * directly and then jump back to the fast path with TIF_SYSCALL_AUDIT
	 * masked off.
	 */
sysret_audit:
	movq RAX-ARGOFFSET(%rsp),%rsi	/* second arg, syscall return value */
	cmpq $-MAX_ERRNO,%rsi	/* is it < -MAX_ERRNO? */
	setbe %al		/* 1 if so, 0 if not */
	movzbl %al,%edi		/* zero-extend that into %edi */
	call __audit_syscall_exit
	movl $(_TIF_ALLWORK_MASK & ~_TIF_SYSCALL_AUDIT),%edi
	jmp sysret_check
#endif	/* CONFIG_AUDITSYSCALL */

	/* Do syscall tracing */
tracesys:
#if IS_ENABLED(CONFIG_KGRAFT)
	LOCK_PREFIX ; andl $~_TIF_KGR_IN_PROGRESS,TI_flags+THREAD_INFO(%rsp,RIP-ARGOFFSET)
#endif
#ifdef CONFIG_AUDITSYSCALL
	testl $(_TIF_WORK_SYSCALL_ENTRY & ~_TIF_SYSCALL_AUDIT),TI_flags+THREAD_INFO(%rsp,RIP-ARGOFFSET)
	jz auditsys
#endif
	SAVE_REST
	movq $-ENOSYS,RAX(%rsp) /* ptrace can change this for a bad syscall */
	FIXUP_TOP_OF_STACK %rdi
	movq %rsp,%rdi
	call syscall_trace_enter
	/*
	 * Reload arg registers from stack in case ptrace changed them.
	 * We don't reload %rax because syscall_trace_enter() returned
	 * the value it wants us to use in the table lookup.
	 */
	LOAD_ARGS ARGOFFSET, 1
	RESTORE_REST
#if __SYSCALL_MASK == ~0
	cmpq $__NR_syscall_max,%rax
#else
	andl $__SYSCALL_MASK,%eax
	cmpl $__NR_syscall_max,%eax
#endif
	ja   int_ret_from_sys_call	/* RAX(%rsp) set to -ENOSYS above */
	movq %r10,%rcx	/* fixup for C */
	call *sys_call_table(,%rax,8)
	movq %rax,RAX-ARGOFFSET(%rsp)
	/* Use IRET because user could have changed frame */

/*
 * Syscall return path ending with IRET.
 * Has correct top of stack, but partial stack frame.
 */
GLOBAL(int_ret_from_sys_call)
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF
	movl $_TIF_ALLWORK_MASK,%edi
	/* edi:	mask to check */
GLOBAL(int_with_check)
	LOCKDEP_SYS_EXIT_IRQ
	GET_THREAD_INFO(%rcx)
	movl TI_flags(%rcx),%edx
	andl %edi,%edx
	jnz   int_careful
	andl    $~TS_COMPAT,TI_status(%rcx)
	jmp   retint_restore_args

	/* Either reschedule or signal or syscall exit tracking needed. */
	/* First do a reschedule test. */
	/* edx:	work, edi: workmask */
int_careful:
#if IS_ENABLED(CONFIG_KGRAFT)
	LOCK_PREFIX ; andl $~_TIF_KGR_IN_PROGRESS,TI_flags(%rcx)
#endif
	bt $TIF_NEED_RESCHED,%edx
	jnc  int_very_careful
	TRACE_IRQS_ON
	ENABLE_INTERRUPTS(CLBR_NONE)
	pushq_cfi %rdi
	SCHEDULE_USER
	popq_cfi %rdi
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF
	jmp int_with_check

	/* handle signals and tracing -- both require a full stack frame */
int_very_careful:
	TRACE_IRQS_ON
	ENABLE_INTERRUPTS(CLBR_NONE)
int_check_syscall_exit_work:
	SAVE_REST
	/* Check for syscall exit trace */
	testl $_TIF_WORK_SYSCALL_EXIT,%edx
	jz int_signal
	pushq_cfi %rdi
	leaq 8(%rsp),%rdi	# &ptregs -> arg1
	call syscall_trace_leave
	popq_cfi %rdi
	andl $~(_TIF_WORK_SYSCALL_EXIT|_TIF_SYSCALL_EMU),%edi
	jmp int_restore_rest

int_signal:
	testl $_TIF_DO_NOTIFY_MASK,%edx
	jz 1f
	movq %rsp,%rdi		# &ptregs -> arg1
	xorl %esi,%esi		# oldset -> arg2
	call do_notify_resume
1:	movl $_TIF_WORK_MASK,%edi
int_restore_rest:
	RESTORE_REST
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF
	jmp int_with_check
	CFI_ENDPROC
END(system_call)

	.macro FORK_LIKE func
ENTRY(stub_\func)
	CFI_STARTPROC
	popq	%r11			/* save return address */
	PARTIAL_FRAME 0
	SAVE_REST
	pushq	%r11			/* put it back on stack */
	FIXUP_TOP_OF_STACK %r11, 8
	DEFAULT_FRAME 0 8		/* offset 8: return address */
	call sys_\func
	RESTORE_TOP_OF_STACK %r11, 8
	ret $REST_SKIP		/* pop extended registers */
	CFI_ENDPROC
END(stub_\func)
	.endm

	.macro FIXED_FRAME label,func
ENTRY(\label)
	CFI_STARTPROC
	PARTIAL_FRAME 0 8		/* offset 8: return address */
	FIXUP_TOP_OF_STACK %r11, 8-ARGOFFSET
	call \func
	RESTORE_TOP_OF_STACK %r11, 8-ARGOFFSET
	ret
	CFI_ENDPROC
END(\label)
	.endm

	FORK_LIKE  clone
	FORK_LIKE  fork
	FORK_LIKE  vfork
	FIXED_FRAME stub_iopl, sys_iopl

ENTRY(ptregscall_common)
	DEFAULT_FRAME 1 8	/* offset 8: return address */
	RESTORE_TOP_OF_STACK %r11, 8
	movq_cfi_restore R15+8, r15
	movq_cfi_restore R14+8, r14
	movq_cfi_restore R13+8, r13
	movq_cfi_restore R12+8, r12
	movq_cfi_restore RBP+8, rbp
	movq_cfi_restore RBX+8, rbx
	ret $REST_SKIP		/* pop extended registers */
	CFI_ENDPROC
END(ptregscall_common)

ENTRY(stub_execve)
	CFI_STARTPROC
	addq $8, %rsp
	PARTIAL_FRAME 0
	SAVE_REST
	FIXUP_TOP_OF_STACK %r11
	call sys_execve
	movq %rax,RAX(%rsp)
	RESTORE_REST
	jmp int_ret_from_sys_call
	CFI_ENDPROC
END(stub_execve)

/*
 * sigreturn is special because it needs to restore all registers on return.
 * This cannot be done with SYSRET, so use the IRET return path instead.
 */
ENTRY(stub_rt_sigreturn)
	CFI_STARTPROC
	addq $8, %rsp
	PARTIAL_FRAME 0
	SAVE_REST
	FIXUP_TOP_OF_STACK %r11
	call sys_rt_sigreturn
	movq %rax,RAX(%rsp) # fixme, this could be done at the higher layer
	RESTORE_REST
	jmp int_ret_from_sys_call
	CFI_ENDPROC
END(stub_rt_sigreturn)

#ifdef CONFIG_X86_X32_ABI
ENTRY(stub_x32_rt_sigreturn)
	CFI_STARTPROC
	addq $8, %rsp
	PARTIAL_FRAME 0
	SAVE_REST
	FIXUP_TOP_OF_STACK %r11
	call sys32_x32_rt_sigreturn
	movq %rax,RAX(%rsp) # fixme, this could be done at the higher layer
	RESTORE_REST
	jmp int_ret_from_sys_call
	CFI_ENDPROC
END(stub_x32_rt_sigreturn)

ENTRY(stub_x32_execve)
	CFI_STARTPROC
	addq $8, %rsp
	PARTIAL_FRAME 0
	SAVE_REST
	FIXUP_TOP_OF_STACK %r11
	call compat_sys_execve
	RESTORE_TOP_OF_STACK %r11
	movq %rax,RAX(%rsp)
	RESTORE_REST
	jmp int_ret_from_sys_call
	CFI_ENDPROC
END(stub_x32_execve)

#endif

/*
 * Interrupt exit.
 */ 

retint_with_reschedule:
	PARTIAL_FRAME
	movl $_TIF_WORK_MASK,%edi
retint_check:
	LOCKDEP_SYS_EXIT_IRQ
	movl TI_flags(%rcx),%edx
	andl %edi,%edx
	CFI_REMEMBER_STATE
	jnz  retint_careful
retint_restore_args:	/* return to kernel space */
	movl EFLAGS-REST_SKIP(%rsp), %eax
	shr $9, %eax			# EAX[0] == IRET_EFLAGS.IF
	GET_VCPU_INFO
	andb evtchn_upcall_mask(%rsi),%al
	andb $1,%al			# EAX[0] == IRET_EFLAGS.IF & event_mask
	jnz restore_all_enable_events	#        != 0 => enable event delivery
		
	RESTORE_ARGS 1,8,1
	HYPERVISOR_IRET 0
	
	/* edi: workmask, edx: work */
retint_careful:
	CFI_RESTORE_STATE
	bt    $TIF_NEED_RESCHED,%edx
	jnc   retint_signal
	TRACE_IRQS_ON
	ENABLE_INTERRUPTS(CLBR_NONE)
	pushq_cfi %rdi
	SCHEDULE_USER
	popq_cfi %rdi
	GET_THREAD_INFO(%rcx)
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF
	jmp retint_check

retint_signal:
	testl $_TIF_DO_NOTIFY_MASK,%edx
	jz    retint_restore_args
	TRACE_IRQS_ON
	ENABLE_INTERRUPTS(CLBR_NONE)
	SAVE_REST
	movq $-1,ORIG_RAX(%rsp)
	xorl %esi,%esi		# oldset
	movq %rsp,%rdi		# &pt_regs
	call do_notify_resume
	RESTORE_REST
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF
	GET_THREAD_INFO(%rcx)
	jmp retint_with_reschedule

#ifdef CONFIG_PREEMPT
	/* Returning to kernel space. Check if we need preemption */
	/* rcx:	 threadinfo. interrupts off. */
ENTRY(retint_kernel)
	cmpl $0,TI_preempt_count(%rcx)
	jnz  retint_restore_args
	bt  $TIF_NEED_RESCHED,TI_flags(%rcx)
	jnc  retint_restore_args
	bt   $9,EFLAGS-ARGOFFSET(%rsp)	/* interrupts off? */
	jnc  retint_restore_args
	call preempt_schedule_irq
	jmp retint_kernel       /* check again */
#endif
	CFI_ENDPROC
END(retint_check)

/*
 * Exception entry points.
 */
.macro zeroentry sym do_sym
ENTRY(\sym)
	INTR_FRAME
	ASM_CLAC
        movq (%rsp),%rcx
	CFI_RESTORE rcx
        movq 8(%rsp),%r11
	CFI_RESTORE r11
	movq $-1,8(%rsp)	/* ORIG_RAX: no syscall to restart */
	subq $ORIG_RAX-R15-1*8,%rsp
	CFI_ADJUST_CFA_OFFSET ORIG_RAX-R15-1*8
	call error_entry
	DEFAULT_FRAME -1
	movq %rsp,%rdi		/* pt_regs pointer */
	xorl %esi,%esi		/* no error code */
	call \do_sym
	jmp error_exit		/* %ebx: no swapgs flag */
	CFI_ENDPROC
END(\sym)
.endm

.macro paranoidzeroentry sym do_sym
	zeroentry \sym \do_sym
.endm

.macro paranoidzeroentry_ist sym do_sym ist
	zeroentry \sym \do_sym
.endm

.macro errorentry sym do_sym
ENTRY(\sym)
	XCPT_FRAME
	ASM_CLAC
        movq (%rsp),%rcx
	CFI_RESTORE rcx
        movq 8(%rsp),%r11
	CFI_RESTORE r11
	subq $ORIG_RAX-R15-2*8,%rsp
	CFI_ADJUST_CFA_OFFSET ORIG_RAX-R15-2*8
	call error_entry
	DEFAULT_FRAME -1
	movq %rsp,%rdi			/* pt_regs pointer */
	movq ORIG_RAX(%rsp),%rsi	/* get error code */
	movq $-1,ORIG_RAX(%rsp)		/* no syscall to restart */
	call \do_sym
	jmp error_exit			/* %ebx: no swapgs flag */
	CFI_ENDPROC
END(\sym)
.endm

	/* error code is on the stack already */
.macro paranoiderrorentry sym do_sym
	errorentry \sym \do_sym
.endm

/*
 * Copied from arch/xen/i386/kernel/entry.S
 */               
# A note on the "critical region" in our callback handler.
# We want to avoid stacking callback handlers due to events occurring
# during handling of the last event. To do this, we keep events disabled
# until we've done all processing. HOWEVER, we must enable events before
# popping the stack frame (can't be done atomically) and so it would still
# be possible to get enough handler activations to overflow the stack.
# Although unlikely, bugs of that kind are hard to track down, so we'd
# like to avoid the possibility.
# So, on entry to the handler we detect whether we interrupted an
# existing activation in its critical region -- if so, we pop the current
# activation and restart the handler using the previous one.
ENTRY(do_hypervisor_callback)   # do_hypervisor_callback(struct *pt_regs)
	CFI_STARTPROC
# Since we don't modify %rdi, evtchn_do_upall(struct *pt_regs) will
# see the correct pointer to the pt_regs
	movq %rdi, %rsp            # we don't return, adjust the stack frame
	CFI_ENDPROC
	DEFAULT_FRAME
11:	incl PER_CPU_VAR(irq_count)
	movq %rsp,%rbp
	CFI_DEF_CFA_REGISTER rbp
	cmovzq PER_CPU_VAR(irq_stack_ptr),%rsp
	pushq %rbp			# backlink for old unwinder
	call evtchn_do_upcall
	popq %rsp
	CFI_DEF_CFA_REGISTER rsp
	decl PER_CPU_VAR(irq_count)
#ifndef CONFIG_PREEMPT
	test %al,%al
	jz   error_exit
	GET_THREAD_INFO(%rdx)
	cmpl $0,TI_preempt_count(%rdx)
	jnz  error_exit
	bt   $TIF_NEED_RESCHED,TI_flags(%rdx)
	jnc  error_exit
	bt   $9,EFLAGS(%rsp)
	jnc  error_exit
	movb $0,PER_CPU_VAR(privcmd_hcall)
	call preempt_schedule_irq
	movb $1,PER_CPU_VAR(privcmd_hcall)
#endif
	jmp  error_exit
	CFI_ENDPROC
END(do_hypervisor_callback)

        ALIGN
restore_all_enable_events:  
	PARTIAL_FRAME
	TRACE_IRQS_ON
	__ENABLE_INTERRUPTS

scrit:	/**** START OF CRITICAL REGION ****/
	__TEST_PENDING
	CFI_REMEMBER_STATE
	jnz  14f			# process more events if necessary...
        RESTORE_ARGS 1,8,1
        HYPERVISOR_IRET 0
        
	CFI_RESTORE_STATE
14:	__DISABLE_INTERRUPTS
	SAVE_REST
        movq %rsp,%rdi                  # set the argument again
	jmp  11b
	CFI_ENDPROC
ecrit:  /**** END OF CRITICAL REGION ****/
# At this point, unlike on x86-32, we don't do the fixup to simplify the 
# code and the stack frame is more complex on x86-64.
# When the kernel is interrupted in the critical section, the kernel 
# will do IRET in that case, and everything will be restored at that point, 
# i.e. it just resumes from the next instruction interrupted with the same context. 

# Hypervisor uses this for application faults while it executes.
# We get here for two reasons:
#  1. Fault while reloading DS, ES, FS or GS
#  2. Fault while executing IRET
# Category 1 we do not need to fix up as Xen has already reloaded all segment
# registers that could be reloaded and zeroed the others.
# Category 2 we fix up by killing the current process. We cannot use the
# normal Linux return path in this case because if we use the IRET hypercall
# to pop the stack frame we end up in an infinite loop of failsafe callbacks.
# We distinguish between categories by comparing each saved segment register
# with its current contents: any discrepancy means we in category 1.
ENTRY(failsafe_callback)
	INTR_FRAME offset=4*8
	ASM_CLAC
	movw %ds,%cx
	cmpw %cx,0x10(%rsp)
	CFI_REMEMBER_STATE
	jne 1f
	movw %es,%cx
	cmpw %cx,0x18(%rsp)
	jne 1f
	movw %fs,%cx
	cmpw %cx,0x20(%rsp)
	jne 1f
	movw %gs,%cx
	cmpw %cx,0x28(%rsp)
	jne 1f
	/* All segments match their saved values => Category 2 (Bad IRET). */
	movq (%rsp),%rcx
	CFI_RESTORE rcx
	movq 8(%rsp),%r11
	CFI_RESTORE r11
	addq $0x30,%rsp
	CFI_ADJUST_CFA_OFFSET -0x30
	movq $11,%rdi	/* SIGSEGV */
	jmp do_exit			
	CFI_RESTORE_STATE
1:	/* Segment mismatch => Category 1 (Bad segment). Retry the IRET. */
	movq (%rsp),%rcx
	CFI_RESTORE rcx
	movq 8(%rsp),%r11
	CFI_RESTORE r11
	addq $0x30,%rsp
	CFI_ADJUST_CFA_OFFSET -0x30
	pushq_cfi $-1
	SAVE_ALL
	jmp error_exit
	CFI_ENDPROC

zeroentry divide_error do_divide_error
zeroentry overflow do_overflow
zeroentry bounds do_bounds
zeroentry invalid_op do_invalid_op
zeroentry device_not_available do_device_not_available
zeroentry hypervisor_callback do_hypervisor_callback
zeroentry coprocessor_segment_overrun do_coprocessor_segment_overrun
errorentry invalid_TSS do_invalid_TSS
errorentry segment_not_present do_segment_not_present
zeroentry coprocessor_error do_coprocessor_error
errorentry alignment_check do_alignment_check
zeroentry simd_coprocessor_error do_simd_coprocessor_error

/* Call softirq on interrupt stack. Interrupts are off. */
ENTRY(call_softirq)
	CFI_STARTPROC
	pushq_cfi %rbp
	CFI_REL_OFFSET rbp,0
	mov  %rsp,%rbp
	CFI_DEF_CFA_REGISTER rbp
	incl PER_CPU_VAR(irq_count)
	cmove PER_CPU_VAR(irq_stack_ptr),%rsp
	push  %rbp			# backlink for old unwinder
	call __do_softirq
	leaveq
	CFI_RESTORE		rbp
	CFI_DEF_CFA_REGISTER	rsp
	CFI_ADJUST_CFA_OFFSET   -8
	decl PER_CPU_VAR(irq_count)
	ret
	CFI_ENDPROC
END(call_softirq)

#ifdef CONFIG_STACK_UNWIND
ENTRY(arch_unwind_init_running)
	CFI_STARTPROC
	movq	%r15, R15(%rdi)
	movq	%r14, R14(%rdi)
	xchgq	%rsi, %rdx
	movq	%r13, R13(%rdi)
	movq	%r12, R12(%rdi)
	xorl	%eax, %eax
	movq	%rbp, RBP(%rdi)
	movq	%rbx, RBX(%rdi)
	movq	(%rsp), %r9
	xchgq	%rdx, %rcx
	movq	%rax, R11(%rdi)
	movq	%rax, R10(%rdi)
	movq	%rax, R9(%rdi)
	movq	%rax, R8(%rdi)
	movq	%rax, RAX(%rdi)
	movq	%rax, RCX(%rdi)
	movq	%rax, RDX(%rdi)
	movq	%rax, RSI(%rdi)
	movq	%rax, RDI(%rdi)
	movq	%rax, ORIG_RAX(%rdi)
	movq	%r9, RIP(%rdi)
	leaq	8(%rsp), %r9
	movq	$__KERNEL_CS, CS(%rdi)
	movq	%rax, EFLAGS(%rdi)
	movq	%r9, RSP(%rdi)
	movq	$__KERNEL_DS, SS(%rdi)
	jmpq	*%rcx
	CFI_ENDPROC
END(arch_unwind_init_running)
#endif

/*
 * Some functions should be protected against kprobes
 */
	.pushsection .kprobes.text, "ax"

paranoidzeroentry_ist debug do_debug DEBUG_STACK
zeroentry nmi do_nmi_callback
paranoidzeroentry_ist int3 do_int3 DEBUG_STACK
paranoiderrorentry stack_segment do_stack_segment
errorentry general_protection do_general_protection
errorentry page_fault do_page_fault
#ifdef CONFIG_KVM_GUEST
errorentry async_page_fault do_async_page_fault
#endif
#ifdef CONFIG_X86_MCE
paranoidzeroentry machine_check *machine_check_vector(%rip)
#endif

#ifndef CONFIG_XEN
	/*
	 * "Paranoid" exit path from exception stack.
	 * Paranoid because this is used by NMIs and cannot take
	 * any kernel state for granted.
	 * We don't do kernel preemption checks here, because only
	 * NMI should be common and it does not enable IRQs and
	 * cannot get reschedule ticks.
	 *
	 * "trace" is 0 for the NMI handler only, because irq-tracing
	 * is fundamentally NMI-unsafe. (we cannot change the soft and
	 * hard flags at once, atomically)
	 */

	/* ebx:	no swapgs flag */
ENTRY(paranoid_exit)
	DEFAULT_FRAME
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF_DEBUG
	testl %ebx,%ebx				/* swapgs needed? */
	jnz paranoid_restore
	testl $3,CS(%rsp)
	jnz   paranoid_userspace
paranoid_swapgs:
	TRACE_IRQS_IRETQ 0
	SWAPGS_UNSAFE_STACK
	RESTORE_ALL 8
	jmp irq_return
paranoid_restore:
	TRACE_IRQS_IRETQ_DEBUG 0
	RESTORE_ALL 8
	jmp irq_return
paranoid_userspace:
	GET_THREAD_INFO(%rcx)
	movl TI_flags(%rcx),%ebx
	andl $_TIF_WORK_MASK,%ebx
	jz paranoid_swapgs
	movq %rsp,%rdi			/* &pt_regs */
	call sync_regs
	movq %rax,%rsp			/* switch stack for scheduling */
	testl $_TIF_NEED_RESCHED,%ebx
	jnz paranoid_schedule
	movl %ebx,%edx			/* arg3: thread flags */
	TRACE_IRQS_ON
	ENABLE_INTERRUPTS(CLBR_NONE)
	xorl %esi,%esi 			/* arg2: oldset */
	movq %rsp,%rdi 			/* arg1: &pt_regs */
	call do_notify_resume
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF
	jmp paranoid_userspace
paranoid_schedule:
	TRACE_IRQS_ON
	ENABLE_INTERRUPTS(CLBR_ANY)
	SCHEDULE_USER
	DISABLE_INTERRUPTS(CLBR_ANY)
	TRACE_IRQS_OFF
	jmp paranoid_userspace
	CFI_ENDPROC
END(paranoid_exit)
#endif

/*
 * Exception entry point. This expects an error code/orig_rax on the stack.
 * returns in "no swapgs flag" in %ebx.
 */
ENTRY(error_entry)
	XCPT_FRAME start=2 offset=(ORIG_RAX-R15+8)
	/* oldrax contains error code */
	cld
	movq %rdi, RDI+8(%rsp)
	movq %rsi, RSI+8(%rsp)
	movq %rdx, RDX+8(%rsp)
	movq %rcx, RCX+8(%rsp)
	movq %rax, RAX+8(%rsp)
	movq  %r8,  R8+8(%rsp)
	movq  %r9,  R9+8(%rsp)
	movq %r10, R10+8(%rsp)
	movq %r11, R11+8(%rsp)
	movq_cfi rbx, RBX+8
	movq %rbp, RBP+8(%rsp)
	movq %r12, R12+8(%rsp)
	movq %r13, R13+8(%rsp)
	movq %r14, R14+8(%rsp)
	movq %r15, R15+8(%rsp)
#ifndef CONFIG_XEN
	xorl %ebx,%ebx
	testl $3,CS+8(%rsp)
	je error_kernelspace
error_swapgs:
	SWAPGS
error_sti:
#endif
	TRACE_IRQS_OFF
	ret

#ifndef CONFIG_XEN
/*
 * There are two places in the kernel that can potentially fault with
 * usergs. Handle them here.  B stepping K8s sometimes report a
 * truncated RIP for IRET exceptions returning to compat mode. Check
 * for these here too.
 */
error_kernelspace:
	CFI_REL_OFFSET rcx, RCX+8
	incl %ebx
	leaq native_irq_return_iret(%rip),%rcx
	cmpq %rcx,RIP+8(%rsp)
	je error_bad_iret
	movl %ecx,%eax	/* zero extend */
	cmpq %rax,RIP+8(%rsp)
	je bstep_iret
	cmpq $gs_change,RIP+8(%rsp)
	je error_swapgs
	jmp error_sti

bstep_iret:
	/* Fix truncated RIP */
	movq %rcx,RIP+8(%rsp)
	/* fall through */

error_bad_iret:
	SWAPGS
	mov %rsp,%rdi
	call fixup_bad_iret
	mov %rax,%rsp
	decl %ebx	/* Return to usergs */
	jmp error_sti
#endif
	CFI_ENDPROC
END(error_entry)


ENTRY(error_exit)
	DEFAULT_FRAME
	RESTORE_REST
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF
	GET_THREAD_INFO(%rcx)
	testb $3,CS-ARGOFFSET(%rsp)
	jz retint_kernel
	LOCKDEP_SYS_EXIT_IRQ
	movl TI_flags(%rcx),%edx
	movl $_TIF_WORK_MASK,%edi
	andl %edi,%edx
	jnz retint_careful
	jmp retint_restore_args
	CFI_ENDPROC
END(error_exit)


#define extern #
#include <asm-generic/percpu.h>

.pushsection PER_CPU_BASE_SECTION, "aw", @progbits
in_NMI:	.byte	0
.popsection

do_nmi_callback:
	CFI_STARTPROC
	addq $8, %rsp
	CFI_ENDPROC
	DEFAULT_FRAME
	orb  $1, PER_CPU_VAR(in_NMI)
	js   1f
0:
	movb $0x80, PER_CPU_VAR(in_NMI)
	call do_nmi
	movl $0x80, %eax
	cmpxchgb %ah, PER_CPU_VAR(in_NMI)
	jne  0b
	orl  $NMI_MASK,EFLAGS(%rsp)
1:
	RESTORE_REST
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF
	GET_THREAD_INFO(%rcx)
	jmp  retint_restore_args
	CFI_ENDPROC
END(do_nmi_callback)


#ifndef CONFIG_IA32_EMULATION
ENTRY(ignore_sysret)
	INTR_FRAME
	popq_cfi %rcx
	CFI_RESTORE rcx
	popq_cfi %r11
	CFI_RESTORE r11
	mov $-ENOSYS,%eax
	# any non-zero value not having VGCF_in_syscall set will do:
	HYPERVISOR_IRET VGCF_i387_valid
	CFI_ENDPROC
END(ignore_sysret)
#endif

/*
 * End of kprobes section
 */
	.popsection
