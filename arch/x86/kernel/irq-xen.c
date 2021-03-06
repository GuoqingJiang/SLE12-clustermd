/*
 * Common interrupt code for 32 and 64 bit
 */
#include <linux/cpu.h>
#include <linux/interrupt.h>
#include <linux/kernel_stat.h>
#include <linux/of.h>
#include <linux/seq_file.h>
#include <linux/smp.h>
#include <linux/ftrace.h>
#include <linux/delay.h>
#include <linux/export.h>

#include <asm/apic.h>
#include <asm/io_apic.h>
#include <asm/irq.h>
#include <asm/idle.h>
#include <asm/mce.h>
#include <asm/hw_irq.h>

#define CREATE_TRACE_POINTS
#include <asm/trace/irq_vectors.h>

#ifndef CONFIG_XEN
atomic_t irq_err_count;

/* Function pointer for generic interrupt vector handling */
void (*x86_platform_ipi_callback)(void) = NULL;
#endif

/*
 * 'what should we do if we get a hw irq event on an illegal vector'.
 * each architecture has to answer this themselves.
 */
void ack_bad_irq(unsigned int irq)
{
	if (printk_ratelimit())
		pr_err("unexpected IRQ trap at vector %02x\n", irq);

#ifndef CONFIG_XEN
	/*
	 * Currently unexpected vectors happen only on SMP and APIC.
	 * We _must_ ack these because every local APIC has only N
	 * irq slots per priority level, and a 'hanging, unacked' IRQ
	 * holds up an irq slot - in excessive cases (when multiple
	 * unexpected vectors occur) that might lock up the APIC
	 * completely.
	 * But only ack when the APIC is enabled -AK
	 */
	ack_APIC_irq();
#endif
}

#define irq_stats(x)		(&per_cpu(irq_stat, x))
/*
 * /proc/interrupts printing for arch specific interrupts
 */
int arch_show_interrupts(struct seq_file *p, int prec)
{
	int j;

	seq_printf(p, "%*s: ", prec, "NMI");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->__nmi_count);
	seq_printf(p, "  Non-maskable interrupts\n");
#ifdef CONFIG_X86_LOCAL_APIC
#ifndef CONFIG_XEN
	seq_printf(p, "%*s: ", prec, "LOC");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->apic_timer_irqs);
	seq_printf(p, "  Local timer interrupts\n");

	seq_printf(p, "%*s: ", prec, "SPU");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->irq_spurious_count);
	seq_printf(p, "  Spurious interrupts\n");
	seq_printf(p, "%*s: ", prec, "PMI");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->apic_perf_irqs);
	seq_printf(p, "  Performance monitoring interrupts\n");
#endif
	seq_printf(p, "%*s: ", prec, "IWI");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->apic_irq_work_irqs);
	seq_printf(p, "  IRQ work interrupts\n");
#ifndef CONFIG_XEN
	seq_printf(p, "%*s: ", prec, "RTR");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->icr_read_retry_count);
	seq_printf(p, "  APIC ICR read retries\n");
#endif
#endif
#ifndef CONFIG_XEN
	if (x86_platform_ipi_callback) {
		seq_printf(p, "%*s: ", prec, "PLT");
		for_each_online_cpu(j)
			seq_printf(p, "%10u ", irq_stats(j)->x86_platform_ipis);
		seq_printf(p, "  Platform interrupts\n");
	}
#endif
#ifdef CONFIG_SMP
	seq_printf(p, "%*s: ", prec, "RES");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->irq_resched_count);
	seq_printf(p, "  Rescheduling interrupts\n");
	seq_printf(p, "%*s: ", prec, "CAL");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->irq_call_count);
	seq_printf(p, "  Function call interrupts\n");
#ifndef CONFIG_XEN
	seq_printf(p, "%*s: ", prec, "TLB");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->irq_tlb_count);
	seq_printf(p, "  TLB shootdowns\n");
#else
	seq_printf(p, "%*s: ", prec, "LCK");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->irq_lock_count);
	seq_printf(p, "  Spinlock wakeups\n");
#endif
#endif
#ifdef CONFIG_X86_THERMAL_VECTOR
	seq_printf(p, "%*s: ", prec, "TRM");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->irq_thermal_count);
	seq_printf(p, "  Thermal event interrupts\n");
#endif
#ifdef CONFIG_X86_MCE_THRESHOLD
	seq_printf(p, "%*s: ", prec, "THR");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->irq_threshold_count);
	seq_printf(p, "  Threshold APIC interrupts\n");
#endif
#ifdef CONFIG_X86_MCE
	seq_printf(p, "%*s: ", prec, "MCE");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", per_cpu(mce_exception_count, j));
	seq_printf(p, "  Machine check exceptions\n");
	seq_printf(p, "%*s: ", prec, "MCP");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", per_cpu(mce_poll_count, j));
	seq_printf(p, "  Machine check polls\n");
#endif
#if IS_ENABLED(CONFIG_HYPERV) || defined(CONFIG_PARAVIRT_XEN)
	seq_printf(p, "%*s: ", prec, "HYP");
	for_each_online_cpu(j)
		seq_printf(p, "%10u ", irq_stats(j)->irq_hv_callback_count);
	seq_printf(p, "  Hypervisor callback interrupts\n");
#endif
#ifndef CONFIG_XEN
	seq_printf(p, "%*s: %10u\n", prec, "ERR", atomic_read(&irq_err_count));
#if defined(CONFIG_X86_IO_APIC)
	seq_printf(p, "%*s: %10u\n", prec, "MIS", atomic_read(&irq_mis_count));
#endif
#endif
	return 0;
}

/*
 * /proc/stat helpers
 */
u64 arch_irq_stat_cpu(unsigned int cpu)
{
	u64 sum = irq_stats(cpu)->__nmi_count;

#ifdef CONFIG_X86_LOCAL_APIC
	sum += irq_stats(cpu)->apic_timer_irqs;
	sum += irq_stats(cpu)->irq_spurious_count;
	sum += irq_stats(cpu)->apic_perf_irqs;
	sum += irq_stats(cpu)->apic_irq_work_irqs;
	sum += irq_stats(cpu)->icr_read_retry_count;
#endif
#ifndef CONFIG_XEN
	if (x86_platform_ipi_callback)
		sum += irq_stats(cpu)->x86_platform_ipis;
#endif
#ifdef CONFIG_SMP
	sum += irq_stats(cpu)->irq_resched_count;
	sum += irq_stats(cpu)->irq_call_count;
#ifdef CONFIG_XEN
	sum += irq_stats(cpu)->irq_lock_count;
#endif
#endif
#ifdef CONFIG_X86_THERMAL_VECTOR
	sum += irq_stats(cpu)->irq_thermal_count;
#endif
#ifdef CONFIG_X86_MCE_THRESHOLD
	sum += irq_stats(cpu)->irq_threshold_count;
#endif
#ifdef CONFIG_X86_MCE
	sum += per_cpu(mce_exception_count, cpu);
	sum += per_cpu(mce_poll_count, cpu);
#endif
	return sum;
}

u64 arch_irq_stat(void)
{
#ifndef CONFIG_XEN
	u64 sum = atomic_read(&irq_err_count);
	return sum;
#else
	return 0;
#endif
}

#ifndef CONFIG_XEN
/*
 * do_IRQ handles all normal device IRQ's (the special
 * SMP cross-CPU interrupts have their own specific
 * handlers).
 */
__visible unsigned int __irq_entry do_IRQ(struct pt_regs *regs)
{
	struct pt_regs *old_regs = set_irq_regs(regs);

	/* high bit used in ret_from_ code  */
	unsigned vector = ~regs->orig_ax;
	unsigned irq;

	irq_enter();
	exit_idle();

	irq = __this_cpu_read(vector_irq[vector]);

	if (!handle_irq(irq, regs)) {
		ack_APIC_irq();

		if (printk_ratelimit())
			pr_emerg("%s: %d.%d No irq handler for vector (irq %d)\n",
				__func__, smp_processor_id(), vector, irq);
	}

	irq_exit();

	set_irq_regs(old_regs);
	return 1;
}

/*
 * Handler for X86_PLATFORM_IPI_VECTOR.
 */
void __smp_x86_platform_ipi(void)
{
	inc_irq_stat(x86_platform_ipis);

	if (x86_platform_ipi_callback)
		x86_platform_ipi_callback();
}

__visible void smp_x86_platform_ipi(struct pt_regs *regs)
{
	struct pt_regs *old_regs = set_irq_regs(regs);

	entering_ack_irq();
	__smp_x86_platform_ipi();
	exiting_irq();
	set_irq_regs(old_regs);
}

#ifdef CONFIG_HAVE_KVM
/*
 * Handler for POSTED_INTERRUPT_VECTOR.
 */
__visible void smp_kvm_posted_intr_ipi(struct pt_regs *regs)
{
	struct pt_regs *old_regs = set_irq_regs(regs);

	ack_APIC_irq();

	irq_enter();

	exit_idle();

	inc_irq_stat(kvm_posted_intr_ipis);

	irq_exit();

	set_irq_regs(old_regs);
}
#endif

__visible void smp_trace_x86_platform_ipi(struct pt_regs *regs)
{
	struct pt_regs *old_regs = set_irq_regs(regs);

	entering_ack_irq();
	trace_x86_platform_ipi_entry(X86_PLATFORM_IPI_VECTOR);
	__smp_x86_platform_ipi();
	trace_x86_platform_ipi_exit(X86_PLATFORM_IPI_VECTOR);
	exiting_irq();
	set_irq_regs(old_regs);
}

EXPORT_SYMBOL_GPL(vector_used_by_percpu_irq);
#endif

#ifdef CONFIG_HOTPLUG_CPU
#include <xen/evtchn.h>

#ifndef CONFIG_XEN
/* These two declarations are only used in check_irq_vectors_for_cpu_disable()
 * below, which is protected by stop_machine().  Putting them on the stack
 * results in a stack frame overflow.  Dynamically allocating could result in a
 * failure so declare these two cpumasks as global.
 */
static struct cpumask affinity_new, online_new;

/*
 * This cpu is going to be removed and its vectors migrated to the remaining
 * online cpus.  Check to see if there are enough vectors in the remaining cpus.
 * This function is protected by stop_machine().
 */
int check_irq_vectors_for_cpu_disable(void)
{
	int irq, cpu;
	unsigned int this_cpu, vector, this_count, count;
	struct irq_desc *desc;
	struct irq_data *data;

	this_cpu = smp_processor_id();
	cpumask_copy(&online_new, cpu_online_mask);
	cpu_clear(this_cpu, online_new);

	this_count = 0;
	for (vector = FIRST_EXTERNAL_VECTOR; vector < NR_VECTORS; vector++) {
		irq = __this_cpu_read(vector_irq[vector]);
		if (irq >= 0) {
			desc = irq_to_desc(irq);
			if (!desc)
				continue;

			data = irq_desc_get_irq_data(desc);
			cpumask_copy(&affinity_new, data->affinity);
			cpu_clear(this_cpu, affinity_new);

			/* Do not count inactive or per-cpu irqs. */
			if (!irq_has_action(irq) || irqd_is_per_cpu(data))
				continue;

			/*
			 * A single irq may be mapped to multiple
			 * cpu's vector_irq[] (for example IOAPIC cluster
			 * mode).  In this case we have two
			 * possibilities:
			 *
			 * 1) the resulting affinity mask is empty; that is
			 * this the down'd cpu is the last cpu in the irq's
			 * affinity mask, or
			 *
			 * 2) the resulting affinity mask is no longer
			 * a subset of the online cpus but the affinity
			 * mask is not zero; that is the down'd cpu is the
			 * last online cpu in a user set affinity mask.
			 */
			if (cpumask_empty(&affinity_new) ||
			    !cpumask_subset(&affinity_new, &online_new))
				this_count++;
		}
	}

	count = 0;
	for_each_online_cpu(cpu) {
		if (cpu == this_cpu)
			continue;
		for (vector = FIRST_EXTERNAL_VECTOR; vector < NR_VECTORS;
		     vector++) {
			if (per_cpu(vector_irq, cpu)[vector] < 0)
				count++;
		}
	}

	if (count < this_count) {
		pr_warn("CPU %d disable failed: CPU has %u vectors assigned and there are only %u available.\n",
			this_cpu, this_count, count);
		return -ERANGE;
	}
	return 0;
}
#endif

/* A cpu has been removed from cpu_online_mask.  Reset irq affinities. */
void fixup_irqs(void)
{
	unsigned int irq;
	static int warned;
	struct irq_desc *desc;
	struct irq_data *data;
	struct irq_chip *chip;
	static DECLARE_BITMAP(irqs_used, NR_IRQS);

	for_each_irq_desc(irq, desc) {
		int break_affinity = 0;
		int set_affinity = 1;
		const struct cpumask *affinity;

		if (!desc)
			continue;
		if (irq == 2)
			continue;

		/* interrupt's are disabled at this point */
		raw_spin_lock(&desc->lock);

		data = irq_desc_get_irq_data(desc);
		affinity = data->affinity;
		if (!irq_has_action(irq) || irqd_is_per_cpu(data) ||
		    cpumask_subset(affinity, cpu_online_mask)) {
			raw_spin_unlock(&desc->lock);
			continue;
		}

		if (cpumask_test_cpu(smp_processor_id(), affinity))
			__set_bit(irq, irqs_used);

		if (cpumask_any_and(affinity, cpu_online_mask) >= nr_cpu_ids) {
			break_affinity = 1;
			affinity = cpu_online_mask;
		}

		chip = irq_data_get_irq_chip(data);
		if (!irqd_can_move_in_process_context(data) && chip->irq_mask)
			chip->irq_mask(data);

		if (chip->irq_set_affinity)
			chip->irq_set_affinity(data, affinity, true);
		else if (data->chip != &no_irq_chip && !(warned++))
			set_affinity = 0;

		/*
		 * We unmask if the irq was not marked masked by the
		 * core code. That respects the lazy irq disable
		 * behaviour.
		 */
		if (!irqd_can_move_in_process_context(data) &&
		    !irqd_irq_masked(data) && chip->irq_unmask)
			chip->irq_unmask(data);

		raw_spin_unlock(&desc->lock);

		if (break_affinity && set_affinity)
			/*pr_notice("Broke affinity for irq %i\n", irq)*/;
		else if (!set_affinity)
			pr_notice("Cannot set affinity for irq %i\n", irq);
	}

	/*
	 * We can remove mdelay() and then send spuriuous interrupts to
	 * new cpu targets for all the irqs that were handled previously by
	 * this cpu. While it works, I have seen spurious interrupt messages
	 * (nothing wrong but still...).
	 *
	 * So for now, retain mdelay(1) and check the IRR and then send those
	 * interrupts to new targets as this cpu is already offlined...
	 */
	mdelay(1);

	for_each_irq_desc(irq, desc) {
		if (!__test_and_clear_bit(irq, irqs_used))
			continue;

		if (xen_test_irq_pending(irq)) {
			desc = irq_to_desc(irq);
			data = irq_desc_get_irq_data(desc);
			chip = irq_data_get_irq_chip(data);
			raw_spin_lock(&desc->lock);
			if (chip->irq_retrigger)
				chip->irq_retrigger(data);
			raw_spin_unlock(&desc->lock);
		}
#ifndef CONFIG_XEN
		__this_cpu_write(vector_irq[vector], -1);
#endif
	}
}
#endif
