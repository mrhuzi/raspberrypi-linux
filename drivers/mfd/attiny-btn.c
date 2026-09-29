// SPDX-License-Identifier: GPL-2.0
/*
 * Button driver for the ATtiny system management MCU on the Avnet SmartEdge
 * IIoT Gateway.
 *
 * The MCU has no interrupt line wired to the SoC, so the sticky bits are
 * polled and translated into the misc devices /dev/button, /dev/reset and
 * /dev/factoryreset.  A read blocks until the corresponding press happens,
 * or returns EOF once the pending event has been consumed.
 */

#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/poll.h>
#include <linux/timer.h>
#include <linux/wait.h>
#include <linux/workqueue.h>

#include "attiny.h"

/* milliseconds between polls */
#define POLL_MS	500

enum { Button = 0, Reset, FactoryReset };

struct press {
	int pressed;
	wait_queue_head_t queue;
};

struct attiny_btn_drvdata {
	struct attiny_dev *attiny;
	struct timer_list timer;
	struct work_struct work;
	struct press press[4];
};

#define work_to_drvdata(x) container_of((x), struct attiny_btn_drvdata, work)

struct btn {
	int id;
	struct attiny_btn_drvdata *drvdata;
	struct miscdevice mdev;
};

#define to_btn(x) container_of((x), struct btn, mdev)

static void worker_func(struct work_struct *work)
{
	struct attiny_btn_drvdata *drvdata = work_to_drvdata(work);
	struct attiny_dev *attiny = drvdata->attiny;
	u8 sticky = 0;
	u8 update = 0;

	attiny->lock(attiny);
	attiny->read(attiny, I2C_STICKY_BITS, &sticky);

	if (!(sticky & I2C_STICKY_INVALID)) {
		if (sticky & I2C_STICKY_FACTORY_RST_SHORT) {
			drvdata->press[Button].pressed = 1;
			update |= I2C_STICKY_FACTORY_RST_SHORT;
			wake_up_interruptible(&drvdata->press[Button].queue);
		}
		if (sticky & I2C_STICKY_FACTORY_RST_LONG) {
			drvdata->press[Reset].pressed = 1;
			update |= I2C_STICKY_FACTORY_RST_LONG;
			wake_up_interruptible(&drvdata->press[Reset].queue);
		}
		if (sticky & I2C_STICKY_FACTORY_RST_VLONG) {
			drvdata->press[FactoryReset].pressed = 1;
			update |= I2C_STICKY_FACTORY_RST_VLONG;
			wake_up_interruptible(&drvdata->press[FactoryReset].queue);
		}
	}

	if (update)
		attiny->write(attiny, I2C_STICKY_BITS, update);
	attiny->unlock(attiny);
}

static void timer_func(struct timer_list *t)
{
	struct attiny_btn_drvdata *drvdata = timer_container_of(drvdata, t, timer);

	mod_timer(t, jiffies + msecs_to_jiffies(POLL_MS));
	schedule_work(&drvdata->work);
}

static ssize_t attiny_btn_read(struct file *file, char __user *buf,
			       size_t count, loff_t *ppos)
{
	struct miscdevice *md = file->private_data;
	struct btn *btn = to_btn(md);
	struct press *press = &btn->drvdata->press[btn->id];

	while (!press->pressed) {
		if (file->f_flags & O_NONBLOCK)
			return -EAGAIN;

		if (wait_event_interruptible(press->queue, press->pressed))
			return -ERESTARTSYS;
	}

	press->pressed = 0;

	return 0;
}

static __poll_t attiny_btn_poll(struct file *file, struct poll_table_struct *pt)
{
	struct miscdevice *me = file->private_data;
	struct btn *btn = to_btn(me);
	struct press *press = &btn->drvdata->press[btn->id];
	__poll_t mask = 0;

	poll_wait(file, &press->queue, pt);
	if (press->pressed)
		mask |= EPOLLIN | EPOLLRDNORM;

	return mask;
}

static const struct file_operations attiny_btn_fops = {
	.owner		= THIS_MODULE,
	.read		= attiny_btn_read,
	.poll		= attiny_btn_poll,
	.llseek		= noop_llseek,
};

static void devm_misc_press_release(struct device *dev, void *res)
{
	struct btn *btn = res;

	misc_deregister(&btn->mdev);
}

static int devm_misc_press(struct device *dev, const char *name, int id)
{
	struct btn *btn;
	int err;

	btn = devres_alloc(devm_misc_press_release, sizeof(*btn), GFP_KERNEL);
	if (!btn)
		return -ENOMEM;

	btn->drvdata = dev_get_drvdata(dev);
	btn->id = id;
	btn->mdev.minor = MISC_DYNAMIC_MINOR;
	btn->mdev.fops = &attiny_btn_fops;
	btn->mdev.name = name;
	btn->mdev.parent = dev;

	err = misc_register(&btn->mdev);
	if (err) {
		devres_free(btn);
		return err;
	}

	devres_add(dev, btn);

	return 0;
}

static int attiny_btn_probe(struct platform_device *pdev)
{
	struct attiny_dev *attiny = dev_get_drvdata(pdev->dev.parent);
	struct attiny_btn_drvdata *drvdata;
	u8 val;
	int ret;

	drvdata = devm_kzalloc(&pdev->dev, sizeof(*drvdata), GFP_KERNEL);
	if (!drvdata)
		return -ENOMEM;

	drvdata->attiny = attiny;

	timer_setup(&drvdata->timer, timer_func, 0);
	INIT_WORK(&drvdata->work, worker_func);

	init_waitqueue_head(&drvdata->press[Button].queue);
	init_waitqueue_head(&drvdata->press[Reset].queue);
	init_waitqueue_head(&drvdata->press[FactoryReset].queue);

	dev_set_drvdata(&pdev->dev, drvdata);

	ret = devm_misc_press(&pdev->dev, "button", Button);
	if (ret)
		return ret;

	ret = devm_misc_press(&pdev->dev, "reset", Reset);
	if (ret)
		return ret;

	ret = devm_misc_press(&pdev->dev, "factoryreset", FactoryReset);
	if (ret)
		return ret;

	mod_timer(&drvdata->timer, jiffies + msecs_to_jiffies(POLL_MS));

	attiny->lock(attiny);
	attiny->read(attiny, I2C_WDT_CMDSTS, &val);
	dev_dbg(&pdev->dev, "WDT CMDSTS %02x\n", val);
	attiny->read(attiny, I2C_WDT_TIME_IRQ, &val);
	dev_dbg(&pdev->dev, "WDT TIME IRQ %02x\n", val);
	attiny->read(attiny, I2C_WDT_TIME_RST, &val);
	dev_dbg(&pdev->dev, "WDT TIME RST %02x\n", val);
	attiny->read(attiny, I2C_WDT_COUNTER, &val);
	dev_dbg(&pdev->dev, "WDT COUNTER %02x\n", val);
	attiny->read(attiny, I2C_LED_STATE, &val);
	dev_dbg(&pdev->dev, "LED STATE %02x\n", val);
	attiny->read(attiny, I2C_LED_DUTY, &val);
	dev_dbg(&pdev->dev, "LED DUTY %02x\n", val);
	attiny->read(attiny, I2C_STICKY_BITS, &val);
	dev_dbg(&pdev->dev, "STICKY BITS %02x\n", val);
	attiny->unlock(attiny);

	return 0;
}

static void attiny_btn_remove(struct platform_device *pdev)
{
	struct attiny_btn_drvdata *drvdata = dev_get_drvdata(&pdev->dev);

	timer_delete_sync(&drvdata->timer);
	cancel_work_sync(&drvdata->work);
}

static struct platform_driver attiny_btn_driver = {
	.driver = {
		.name = "attiny-btn",
	},
	.probe = attiny_btn_probe,
	.remove = attiny_btn_remove,
};

module_platform_driver(attiny_btn_driver);

MODULE_AUTHOR("Dale P. Smith <dales@avid-tech.com>");
MODULE_DESCRIPTION("ATtiny Button driver");
MODULE_LICENSE("GPL");
