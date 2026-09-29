// SPDX-License-Identifier: GPL-2.0
/*
 * Watchdog driver for the ATtiny system management MCU on the Avnet
 * SmartEdge IIoT Gateway.
 *
 * Note: the ATtiny reset output only reaches the SoC when the WDT jumper
 * (J22) on the board is fitted.  With the jumper open the counter still
 * runs but a timeout cannot reset the board.
 */

#include <linux/init.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/platform_device.h>
#include <linux/watchdog.h>
#include <uapi/linux/watchdog.h>

#include "attiny.h"

static int heartbeat = 45;

static int attiny_wdt_start(struct watchdog_device *wdd)
{
	struct attiny_dev *attiny = watchdog_get_drvdata(wdd);
	int ret;

	attiny->lock(attiny);
	ret = attiny->write(attiny, I2C_WDT_TIME_RST, wdd->timeout);
	if (ret)
		dev_err(wdd->parent, "ATtiny write failed\n");
	ret = attiny->write(attiny, I2C_WDT_CMDSTS, WDT_CMD_START);
	if (ret)
		dev_err(wdd->parent, "ATtiny write failed\n");
	ret = attiny->write(attiny, I2C_WDT_CMDSTS, WDT_CMD_ENA_RESET);
	if (ret)
		dev_err(wdd->parent, "ATtiny write failed\n");
	attiny->unlock(attiny);

	return ret;
}

static int attiny_wdt_stop(struct watchdog_device *wdd)
{
	struct attiny_dev *attiny = watchdog_get_drvdata(wdd);
	int ret;

	attiny->lock(attiny);
	ret = attiny->write(attiny, I2C_WDT_CMDSTS, WDT_CMD_STOP);
	if (ret)
		dev_err(wdd->parent, "ATtiny write failed\n");
	attiny->unlock(attiny);

	return ret;
}

static int attiny_wdt_ping(struct watchdog_device *wdd)
{
	struct attiny_dev *attiny = watchdog_get_drvdata(wdd);
	int ret;

	attiny->lock(attiny);
	ret = attiny->write(attiny, I2C_WDT_CMDSTS, WDT_CMD_RESET);
	if (ret)
		dev_err(wdd->parent, "ATtiny write failed\n");
	attiny->unlock(attiny);

	return ret;
}

static int attiny_wdt_set_timeout(struct watchdog_device *wdd, unsigned int timeout)
{
	struct attiny_dev *attiny = watchdog_get_drvdata(wdd);
	int ret;

	if (timeout > wdd->max_timeout || timeout < wdd->min_timeout)
		return -EINVAL;

	attiny->lock(attiny);
	ret = attiny->write(attiny, I2C_WDT_TIME_RST, timeout);
	if (ret)
		dev_err(wdd->parent, "ATtiny write failed\n");
	attiny->unlock(attiny);

	if (!ret)
		wdd->timeout = timeout;

	return ret;
}

static int attiny_wdt_restart(struct watchdog_device *wdd, unsigned long action,
			      void *data)
{
	struct attiny_dev *attiny = watchdog_get_drvdata(wdd);

	attiny->lock(attiny);
	attiny->write(attiny, I2C_WDT_CMDSTS, WDT_CMD_STOP);
	attiny->write(attiny, I2C_WDT_TIME_RST, 1);
	attiny->write(attiny, I2C_WDT_CMDSTS, WDT_CMD_START);
	attiny->write(attiny, I2C_WDT_CMDSTS, WDT_CMD_ENA_RESET);
	attiny->unlock(attiny);

	return 0;
}

static unsigned int attiny_wdt_status(struct watchdog_device *wdd)
{
	struct attiny_dev *attiny = watchdog_get_drvdata(wdd);
	u8 sticky = 0;
	unsigned int ret = 0;

	attiny->lock(attiny);
	attiny->read(attiny, I2C_STICKY_BITS, &sticky);
	if (sticky & I2C_STICKY_PWR_LOW_DETECTED)
		ret |= WDIOF_POWERUNDER;
	if (sticky & I2C_STICKY_RESET_DETECTED)
		ret |= WDIOF_CARDRESET;
	attiny->unlock(attiny);

	return ret;
}

static const struct watchdog_info attiny_wdt_info = {
	.options  = WDIOF_SETTIMEOUT | WDIOF_KEEPALIVEPING,
	.identity = "ATtiny Watchdog",
};

static const struct watchdog_ops attiny_wdt_ops = {
	.owner       = THIS_MODULE,
	.start       = attiny_wdt_start,
	.stop        = attiny_wdt_stop,
	.ping        = attiny_wdt_ping,
	.set_timeout = attiny_wdt_set_timeout,
	.status      = attiny_wdt_status,
	.restart     = attiny_wdt_restart,
};

static int attiny_wdt_probe(struct platform_device *pdev)
{
	struct attiny_dev *attiny = dev_get_drvdata(pdev->dev.parent);
	struct watchdog_device *wdd;
	int err;

	wdd = devm_kzalloc(&pdev->dev, sizeof(*wdd), GFP_KERNEL);
	if (!wdd)
		return -ENOMEM;

	wdd->info = &attiny_wdt_info;
	wdd->ops = &attiny_wdt_ops;
	wdd->min_timeout = 1;
	wdd->max_timeout = 255;
	wdd->timeout = heartbeat;
	wdd->parent = &pdev->dev;

	watchdog_set_drvdata(wdd, attiny);
	watchdog_init_timeout(wdd, heartbeat, &pdev->dev);

	err = devm_watchdog_register_device(&pdev->dev, wdd);
	if (err) {
		dev_err(&pdev->dev, "failed to register ATtiny watchdog\n");
		return err;
	}

	/*
	 * The original firmware armed the watchdog as soon as the driver
	 * bound.  Keep that behaviour: user space must either open
	 * /dev/watchdog and keep pinging it, or leave the J22 jumper open.
	 */
	attiny_wdt_start(wdd);

	dev_info(&pdev->dev, "ATtiny watchdog enabled (timeout %u s)\n",
		 wdd->timeout);

	return 0;
}

static struct platform_driver attiny_wdt_driver = {
	.driver = {
		.name = "attiny-wdt",
	},
	.probe = attiny_wdt_probe,
};

module_param(heartbeat, int, 0);
MODULE_PARM_DESC(heartbeat, "Initial watchdog heartbeat in seconds");

module_platform_driver(attiny_wdt_driver);

MODULE_AUTHOR("Dale P. Smith <dales@avid-tech.com>");
MODULE_DESCRIPTION("ATtiny Watchdog Driver");
MODULE_LICENSE("GPL");
