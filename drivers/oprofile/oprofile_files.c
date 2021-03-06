/**
 * @file oprofile_files.c
 *
 * @remark Copyright 2002 OProfile authors
 * @remark Read the file COPYING
 *
 * @author John Levon <levon@movementarian.org>
 *
 * Modified by Aravind Menon for Xen
 * These modifications are:
 * Copyright (C) 2005 Hewlett-Packard Co.
 */

#include <linux/fs.h>
#include <linux/oprofile.h>
#include <linux/jiffies.h>
#include <asm/uaccess.h>
#include <linux/ctype.h>

#include "event_buffer.h"
#include "oprofile_stats.h"
#include "oprof.h"

#define BUFFER_SIZE_DEFAULT		131072
#define CPU_BUFFER_SIZE_DEFAULT		8192
#define BUFFER_WATERSHED_DEFAULT	32768	/* FIXME: tune */
#define TIME_SLICE_DEFAULT		1

unsigned long oprofile_buffer_size;
unsigned long oprofile_cpu_buffer_size;
unsigned long oprofile_buffer_watershed;
unsigned long oprofile_time_slice;

#ifdef CONFIG_OPROFILE_EVENT_MULTIPLEX

static ssize_t timeout_read(struct file *file, char __user *buf,
		size_t count, loff_t *offset)
{
	return oprofilefs_ulong_to_user(jiffies_to_msecs(oprofile_time_slice),
					buf, count, offset);
}


static ssize_t timeout_write(struct file *file, char const __user *buf,
		size_t count, loff_t *offset)
{
	unsigned long val;
	int retval;

	if (*offset)
		return -EINVAL;

	retval = oprofilefs_ulong_from_user(&val, buf, count);
	if (retval <= 0)
		return retval;

	retval = oprofile_set_timeout(val);

	if (retval)
		return retval;
	return count;
}


static const struct file_operations timeout_fops = {
	.read		= timeout_read,
	.write		= timeout_write,
	.llseek		= default_llseek,
};

#endif


static ssize_t depth_read(struct file *file, char __user *buf, size_t count, loff_t *offset)
{
	return oprofilefs_ulong_to_user(oprofile_backtrace_depth, buf, count,
					offset);
}


static ssize_t depth_write(struct file *file, char const __user *buf, size_t count, loff_t *offset)
{
	unsigned long val;
	int retval;

	if (*offset)
		return -EINVAL;

	if (!oprofile_ops.backtrace)
		return -EINVAL;

	retval = oprofilefs_ulong_from_user(&val, buf, count);
	if (retval <= 0)
		return retval;

	retval = oprofile_set_ulong(&oprofile_backtrace_depth, val);
	if (retval)
		return retval;

	return count;
}


static const struct file_operations depth_fops = {
	.read		= depth_read,
	.write		= depth_write,
	.llseek		= default_llseek,
};


static ssize_t pointer_size_read(struct file *file, char __user *buf, size_t count, loff_t *offset)
{
	return oprofilefs_ulong_to_user(sizeof(void *), buf, count, offset);
}


static const struct file_operations pointer_size_fops = {
	.read		= pointer_size_read,
	.llseek		= default_llseek,
};


static ssize_t cpu_type_read(struct file *file, char __user *buf, size_t count, loff_t *offset)
{
	return oprofilefs_str_to_user(oprofile_ops.cpu_type, buf, count, offset);
}


static const struct file_operations cpu_type_fops = {
	.read		= cpu_type_read,
	.llseek		= default_llseek,
};


static ssize_t enable_read(struct file *file, char __user *buf, size_t count, loff_t *offset)
{
	return oprofilefs_ulong_to_user(oprofile_started, buf, count, offset);
}


static ssize_t enable_write(struct file *file, char const __user *buf, size_t count, loff_t *offset)
{
	unsigned long val;
	int retval;

	if (*offset)
		return -EINVAL;

	retval = oprofilefs_ulong_from_user(&val, buf, count);
	if (retval <= 0)
		return retval;

	retval = 0;
	if (val)
		retval = oprofile_start();
	else
		oprofile_stop();

	if (retval)
		return retval;
	return count;
}


static const struct file_operations enable_fops = {
	.read		= enable_read,
	.write		= enable_write,
	.llseek		= default_llseek,
};


static ssize_t dump_write(struct file *file, char const __user *buf, size_t count, loff_t *offset)
{
	wake_up_buffer_waiter();
	return count;
}


static const struct file_operations dump_fops = {
	.write		= dump_write,
	.llseek		= noop_llseek,
};

#ifdef CONFIG_XEN
#include <linux/slab.h>

#define TMPBUFSIZE 512

struct domain_data {
    unsigned int nr;
    int ids[MAX_OPROF_DOMAINS + 1];
    struct mutex mutex;
    int (*set)(int[], unsigned int);
};
#define DEFINE_DOMAIN_DATA(what) \
	struct domain_data what##_domains = { \
		.mutex = __MUTEX_INITIALIZER(what##_domains.mutex), \
		.set = oprofile_set_##what \
	}

static ssize_t domain_write(struct file *filp, char const __user *buf,
			    size_t count, loff_t *offset)
{
	struct domain_data *dom = filp->private_data;
	char *tmpbuf;
	char *startp, *endp;
	int i;
	unsigned long val;
	ssize_t retval = count;

	if (*offset)
		return -EINVAL;
	if (count > TMPBUFSIZE - 1)
		return -EINVAL;

	if (!(tmpbuf = kmalloc(TMPBUFSIZE, GFP_KERNEL)))
		return -ENOMEM;

	if (copy_from_user(tmpbuf, buf, count)) {
		kfree(tmpbuf);
		return -EFAULT;
	}
	tmpbuf[count] = 0;

	mutex_lock(&dom->mutex);

	startp = tmpbuf;
	/* Parse one more than MAX_OPROF_DOMAINS, for easy error checking */
	for (i = 0; i <= MAX_OPROF_DOMAINS; i++) {
		val = simple_strtoul(startp, &endp, 0);
		if (endp == startp)
			break;
		while (ispunct(*endp) || isspace(*endp))
			endp++;
		dom->ids[i] = val;
		if (dom->ids[i] != val)
			/* Overflow, force error below */
			i = MAX_OPROF_DOMAINS + 1;
		startp = endp;
	}
	/* Force error on trailing junk */
	dom->nr = *startp ? MAX_OPROF_DOMAINS + 1 : i;

	kfree(tmpbuf);

	if (dom->nr > MAX_OPROF_DOMAINS
	    || dom->set(dom->ids, dom->nr)) {
		dom->nr = 0;
		retval = -EINVAL;
	}

	mutex_unlock(&dom->mutex);
	return retval;
}

static ssize_t domain_read(struct file *filp, char __user *buf,
			    size_t count, loff_t *offset)
{
	struct domain_data *dom = filp->private_data;
	char *tmpbuf;
	size_t len;
	int i;
	ssize_t retval;

	if (!(tmpbuf = kmalloc(TMPBUFSIZE, GFP_KERNEL)))
		return -ENOMEM;

	mutex_lock(&dom->mutex);

	len = 0;
	for (i = 0; i < dom->nr; i++)
		len += snprintf(tmpbuf + len,
				len < TMPBUFSIZE ? TMPBUFSIZE - len : 0,
				"%u ", dom->ids[i]);
	WARN_ON(len > TMPBUFSIZE);
	if (len != 0 && len <= TMPBUFSIZE)
		tmpbuf[len-1] = '\n';

	mutex_unlock(&dom->mutex);

	retval = simple_read_from_buffer(buf, count, offset, tmpbuf, len);

	kfree(tmpbuf);
	return retval;
}

static DEFINE_DOMAIN_DATA(active);

static int adomain_open(struct inode *inode, struct file *filp)
{
	filp->private_data = &active_domains;
	return 0;
}

static const struct file_operations active_domain_ops = {
	.open		= adomain_open,
	.read		= domain_read,
	.write		= domain_write,
	.llseek		= default_llseek,
};

static DEFINE_DOMAIN_DATA(passive);

static int pdomain_open(struct inode *inode, struct file *filp)
{
	filp->private_data = &passive_domains;
	return 0;
}

static const struct file_operations passive_domain_ops = {
	.open		= pdomain_open,
	.read		= domain_read,
	.write		= domain_write,
	.llseek		= default_llseek,
};

#endif /* CONFIG_XEN */

void oprofile_create_files(struct dentry *root)
{
	/* reinitialize default values */
	oprofile_buffer_size =		BUFFER_SIZE_DEFAULT;
	oprofile_cpu_buffer_size =	CPU_BUFFER_SIZE_DEFAULT;
	oprofile_buffer_watershed =	BUFFER_WATERSHED_DEFAULT;
	oprofile_time_slice =		msecs_to_jiffies(TIME_SLICE_DEFAULT);

	oprofilefs_create_file(root, "enable", &enable_fops);
	oprofilefs_create_file_perm(root, "dump", &dump_fops, 0666);
#ifdef CONFIG_XEN
	oprofilefs_create_file(root, "active_domains", &active_domain_ops);
	oprofilefs_create_file(root, "passive_domains", &passive_domain_ops);
#endif
	oprofilefs_create_file(root, "buffer", &event_buffer_fops);
	oprofilefs_create_ulong(root, "buffer_size", &oprofile_buffer_size);
	oprofilefs_create_ulong(root, "buffer_watershed", &oprofile_buffer_watershed);
	oprofilefs_create_ulong(root, "cpu_buffer_size", &oprofile_cpu_buffer_size);
	oprofilefs_create_file(root, "cpu_type", &cpu_type_fops);
	oprofilefs_create_file(root, "backtrace_depth", &depth_fops);
	oprofilefs_create_file(root, "pointer_size", &pointer_size_fops);
#ifdef CONFIG_OPROFILE_EVENT_MULTIPLEX
	oprofilefs_create_file(root, "time_slice", &timeout_fops);
#endif
	oprofile_create_stats_files(root);
	if (oprofile_ops.create_files)
		oprofile_ops.create_files(root);
}
